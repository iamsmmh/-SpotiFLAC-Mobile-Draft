import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/engine/audio_effects.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('AudioEffects');

/// Storage key for user-defined equalizer presets (JSON list).
const String _userPresetsKey = 'audio_effects_user_presets_v1';

/// Full DSP state: the persisted settings, the user's saved presets, what the
/// device supports and whether the chain is currently attached to a player.
class AudioEffectsState {
  final AudioEffectsSettings settings;
  final List<EqualizerPreset> userPresets;
  final AudioEffectsCapabilities capabilities;

  /// Native chain is bound to at least one live player session.
  final bool attached;

  /// Why the chain is not attached (from the platform), if known.
  final String? attachReason;

  const AudioEffectsState({
    required this.settings,
    this.userPresets = const [],
    this.capabilities = AudioEffectsCapabilities.none,
    this.attached = false,
    this.attachReason,
  });

  /// Built-in presets followed by the user's, for pickers.
  List<EqualizerPreset> get allPresets => [
    ...EqualizerPreset.builtIns,
    ...userPresets,
  ];

  AudioEffectsState copyWith({
    AudioEffectsSettings? settings,
    List<EqualizerPreset>? userPresets,
    AudioEffectsCapabilities? capabilities,
    bool? attached,
    Object? attachReason = _unset,
  }) {
    return AudioEffectsState(
      settings: settings ?? this.settings,
      userPresets: userPresets ?? this.userPresets,
      capabilities: capabilities ?? this.capabilities,
      attached: attached ?? this.attached,
      attachReason: identical(attachReason, _unset)
          ? this.attachReason
          : attachReason as String?,
    );
  }

  static const Object _unset = Object();
}

final audioEffectsProvider =
    NotifierProvider<AudioEffectsNotifier, AudioEffectsState>(
      AudioEffectsNotifier.new,
    );

class AudioEffectsNotifier extends Notifier<AudioEffectsState> {
  SharedPreferences? _prefs;
  Timer? _applyDebounce;
  bool _applying = false;
  bool _applyAgain = false;

  @override
  AudioEffectsState build() {
    ref.onDispose(() {
      _applyDebounce?.cancel();
      if (playbackSourceStartedListener == _onSourceStarted) {
        playbackSourceStartedListener = null;
      }
    });
    return AudioEffectsState(settings: AudioEffectsSettings());
  }

  /// Restores persisted settings/presets, queries device capabilities and
  /// installs the player hook. Called once from bootstrap.
  Future<void> attach(SharedPreferences prefs) async {
    _prefs = prefs;
    final settings = loadAudioEffectsSettings(prefs);
    final presets = _loadUserPresets(prefs);
    final capabilities = await PlatformBridge.audioEffectsCapabilities();
    state = state.copyWith(
      settings: settings,
      userPresets: presets,
      capabilities: capabilities,
    );
    playbackSourceStartedListener = _onSourceStarted;
    if (settings.enabled) _scheduleApply();
  }

  void _onSourceStarted() {
    if (!state.settings.enabled) return;
    // Sessions are created asynchronously by the platform player; give it a
    // moment so the first bind lands on the real session id.
    _scheduleApply(delay: const Duration(milliseconds: 250));
  }

  // ---- Settings ------------------------------------------------------------

  Future<void> setEnabled(bool value) =>
      _update(state.settings.copyWith(enabled: value));

  Future<void> setBandGain(int band, double gainDb) =>
      _update(state.settings.withBandGain(band, gainDb));

  Future<void> applyPreset(EqualizerPreset preset) =>
      _update(state.settings.withPreset(preset));

  Future<void> resetEqualizer() =>
      _update(state.settings.withPreset(EqualizerPreset.builtIns.first));

  Future<void> setBassBoost(double value) =>
      _update(state.settings.copyWith(bassBoost: value));

  Future<void> setVirtualizer(double value) =>
      _update(state.settings.copyWith(virtualizer: value));

  Future<void> setEnhancerGainDb(double value) =>
      _update(state.settings.copyWith(enhancerGainDb: value));

  Future<void> setCompressorEnabled(bool value) =>
      _update(state.settings.copyWith(compressorEnabled: value));

  Future<void> setCompressorThresholdDb(double value) =>
      _update(state.settings.copyWith(compressorThresholdDb: value));

  Future<void> setCompressorRatio(double value) =>
      _update(state.settings.copyWith(compressorRatio: value));

  Future<void> setLimiterEnabled(bool value) =>
      _update(state.settings.copyWith(limiterEnabled: value));

  Future<void> setLimiterThresholdDb(double value) =>
      _update(state.settings.copyWith(limiterThresholdDb: value));

  Future<void> _update(AudioEffectsSettings next) async {
    if (next == state.settings) return;
    state = state.copyWith(settings: next);
    _scheduleApply();
    await _persistSettings(next);
  }

  Future<void> _persistSettings(AudioEffectsSettings settings) async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      _prefs = prefs;
      await prefs.setString(
        AudioEffectsSettings.storageKey,
        jsonEncode(settings.toJson()),
      );
    } catch (e) {
      _log.w('Failed to persist audio effects: $e');
    }
  }

  // ---- User presets --------------------------------------------------------

  /// Saves the current curve under [name] (replacing a user preset with the
  /// same name; built-in names are rejected). Returns the saved preset or
  /// null when the name is unusable.
  Future<EqualizerPreset?> saveCurrentAsPreset(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 40) return null;
    if (EqualizerPreset.builtIns.any(
      (p) => p.name.toLowerCase() == trimmed.toLowerCase(),
    )) {
      return null;
    }
    final preset = state.settings.asPreset(trimmed);
    final presets = [
      for (final existing in state.userPresets)
        if (existing.name.toLowerCase() != trimmed.toLowerCase()) existing,
      preset,
    ];
    state = state.copyWith(
      userPresets: presets,
      settings: state.settings.copyWith(presetName: preset.name),
    );
    await _persistPresets(presets);
    await _persistSettings(state.settings);
    return preset;
  }

  Future<void> deletePreset(EqualizerPreset preset) async {
    if (preset.builtIn) return;
    final presets = state.userPresets
        .where((p) => p.name != preset.name)
        .toList(growable: false);
    var settings = state.settings;
    if (settings.presetName == preset.name) {
      settings = settings.copyWith(presetName: null);
    }
    state = state.copyWith(userPresets: presets, settings: settings);
    await _persistPresets(presets);
    await _persistSettings(settings);
  }

  /// Merges presets parsed from an export file; existing user presets with
  /// the same name are replaced. Returns how many were imported.
  Future<int> importPresets(String text) async {
    final imported = EqualizerPresetCodec.decode(text);
    if (imported.isEmpty) return 0;
    final builtInNames = EqualizerPreset.builtIns
        .map((p) => p.name.toLowerCase())
        .toSet();
    final merged = <String, EqualizerPreset>{
      for (final preset in state.userPresets) preset.name.toLowerCase(): preset,
    };
    var count = 0;
    for (final preset in imported) {
      final key = preset.name.toLowerCase();
      if (builtInNames.contains(key)) continue;
      merged[key] = preset;
      count++;
    }
    final presets = merged.values.toList(growable: false);
    state = state.copyWith(userPresets: presets);
    await _persistPresets(presets);
    return count;
  }

  /// Export payload for the user's presets (plus the current curve when it
  /// is a manual, unsaved one so nothing is lost).
  String exportPresets() {
    final presets = <EqualizerPreset>[...state.userPresets];
    if (state.settings.presetName == null && !state.settings.isEqualizerFlat) {
      presets.add(state.settings.asPreset('Current'));
    }
    return EqualizerPresetCodec.encode(presets);
  }

  Future<void> _persistPresets(List<EqualizerPreset> presets) async {
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      _prefs = prefs;
      await prefs.setString(
        _userPresetsKey,
        jsonEncode([for (final p in presets) p.toJson()]),
      );
    } catch (e) {
      _log.w('Failed to persist EQ presets: $e');
    }
  }

  static List<EqualizerPreset> _loadUserPresets(SharedPreferences prefs) {
    final raw = prefs.getString(_userPresetsKey);
    if (raw == null || raw.isEmpty) return const [];
    return EqualizerPresetCodec.decode(raw);
  }

  // ---- Native application --------------------------------------------------

  void _scheduleApply({Duration delay = const Duration(milliseconds: 80)}) {
    _applyDebounce?.cancel();
    _applyDebounce = Timer(delay, () {
      _applyDebounce = null;
      unawaited(_applyNow());
    });
  }

  Future<void> _applyNow() async {
    if (_applying) {
      _applyAgain = true;
      return;
    }
    _applying = true;
    try {
      do {
        _applyAgain = false;
        final settings = state.settings;
        final result = await PlatformBridge.applyAudioEffects(
          settings.toPlatformMap(),
        );
        if (!ref.mounted) return;
        final attached = result['attached'] == true;
        final reason = result['reason']?.toString();
        if (attached != state.attached || reason != state.attachReason) {
          state = state.copyWith(attached: attached, attachReason: reason);
        }
        if (kDebugMode && settings.enabled && !attached) {
          _log.d('Audio effects not attached: ${reason ?? 'unknown'}');
        }
      } while (_applyAgain);
    } finally {
      _applying = false;
    }
  }
}

/// Reads persisted DSP settings (safe on corrupt or missing data).
AudioEffectsSettings loadAudioEffectsSettings(SharedPreferences prefs) {
  final raw = prefs.getString(AudioEffectsSettings.storageKey);
  if (raw == null || raw.isEmpty) return AudioEffectsSettings();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) return AudioEffectsSettings();
    return AudioEffectsSettings.fromJson(decoded);
  } catch (_) {
    return AudioEffectsSettings();
  }
}
