/// Advanced audio wiring (Feature Group: advanced audio).
///
/// `AdvancedAudioController` owns the [AdvancedAudioChain] state, persists
/// it as JSON in shared preferences, and *applies it through the existing
/// equalizer path*: the chain is flattened onto band gains via real DSP
/// math (`AdvancedAudioChain.flattenToBands`) and pushed with the engine's
/// own centre frequencies, so there is exactly one platform apply path.
/// When the chain is disabled the previous 10-band state is restored.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotimusic/engine/advanced_audio.dart';
import 'package:spotimusic/engine/audio_effects.dart';
import 'package:spotimusic/providers/audio_effects_provider.dart';
import 'package:spotimusic/utils/logger.dart';

final _log = AppLogger('AdvancedAudio');

const String _storageKey = 'advanced_audio_chain_v1';
const String _presetsKey = 'advanced_audio_presets_v1';
const String _savedBandsKey = 'advanced_audio_saved_band_gains_v1';

final advancedAudioProvider =
    NotifierProvider<AdvancedAudioNotifier, AdvancedAudioChain>(
      AdvancedAudioNotifier.new,
    );

class AdvancedAudioNotifier extends Notifier<AdvancedAudioChain> {
  @override
  AdvancedAudioChain build() => const AdvancedAudioChain();

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        state = AdvancedAudioChain.fromJson(decoded);
      }
    } catch (_) {
      // Corrupt store degrades to the default chain.
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonEncode(state.toJson()));
    } catch (_) {
      // Best-effort.
    }
  }

  Future<void> _apply() async {
    final effects = ref.read(audioEffectsProvider.notifier);
    final chain = state;
    if (!chain.enabled) {
      await effects.resetEqualizer();
      await _restoreSavedBands();
      return;
    }

    // Remember the user's manual 10-band state once, so disabling restores.
    await _rememberBandsOnce(effects);
    final centers = <double>[
      for (final int hz in equalizerBandFrequencies) hz.toDouble(),
    ];
    final gains = chain.flattenToBandGains(centers);
    for (var band = 0; band < gains.length; band++) {
      await effects.setBandGain(band, gains[band]);
    }
    // Bass boost amount rides the platform bass boost node when active.
    if (chain.bassBoost.enabled) {
      await effects.setBassBoost(chain.bassBoost.amount);
    }
    _log.d('Applied advanced chain (${chain.activeBands.length} bands)');
  }

  Future<void> _rememberBandsOnce(AudioEffectsNotifier effects) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.containsKey(_savedBandsKey)) return;
      final current = ref.read(audioEffectsProvider).settings.bandGainsDb;
      await prefs.setString(
        _savedBandsKey,
        jsonEncode(<double>[...current]),
      );
    } catch (_) {
      // Best-effort snapshot.
    }
  }

  Future<void> _restoreSavedBands() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_savedBandsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final effects = ref.read(audioEffectsProvider.notifier);
      final gains = normalizeBandGains(decoded);
      for (var band = 0; band < gains.length; band++) {
        await effects.setBandGain(band, gains[band]);
      }
      await prefs.remove(_savedBandsKey);
    } catch (_) {
      // Best-effort restore.
    }
  }

  Future<void> setEnabled(bool value) async {
    state = state.copyWith(enabled: value);
    await _persist();
    await _apply();
  }

  Future<void> setEqualizerBands(List<ParametricBand> bands) async {
    state = state.copyWith(equalizer: ParametricEqualizer(bands: bands));
    await _persist();
    await _apply();
  }

  Future<void> addBand(ParametricBand band) async {
    await setEqualizerBands(<ParametricBand>[...state.equalizer.bands, band]);
  }

  Future<void> removeBandAt(int index) async {
    final bands = <ParametricBand>[...state.equalizer.bands];
    if (index < 0 || index >= bands.length) return;
    bands.removeAt(index);
    await setEqualizerBands(bands);
  }

  Future<void> updateBandAt(int index, ParametricBand band) async {
    final bands = <ParametricBand>[...state.equalizer.bands];
    if (index < 0 || index >= bands.length) return;
    bands[index] = band;
    await setEqualizerBands(bands);
  }

  Future<void> setBassBoost(BassBoostSettings value) async {
    state = state.copyWith(bassBoost: value);
    await _persist();
    await _apply();
  }

  Future<void> setVocalBoost(VocalBoostSettings value) async {
    state = state.copyWith(vocalBoost: value);
    await _persist();
    await _apply();
  }

  Future<void> setHeadphoneProfile(HeadphoneProfile value) async {
    state = state.copyWith(headphoneProfile: value);
    await _persist();
    await _apply();
  }

  Future<void> setCrossfeed(CrossfeedSettings value) async {
    state = state.copyWith(crossfeed: value);
    await _persist();
    await _apply();
  }

  Future<void> setConvolver(ConvolverSettings value) async {
    state = state.copyWith(convolver: value);
    await _persist();
  }

  Future<void> setLoudness(LoudnessNormalizationSettings value) async {
    state = state.copyWith(loudness: value);
    await _persist();
  }

  Future<void> applyPreset(DspPreset preset) async {
    state = preset.chain;
    await _persist();
    await _apply();
  }
}

// ---------------------------------------------------------------------------
// Presets
// ---------------------------------------------------------------------------

final dspPresetsProvider = FutureProvider<List<DspPreset>>((ref) async {
  final builtIns = builtInDspPresets;
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_presetsKey);
  if (raw == null || raw.isEmpty) return builtIns;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return builtIns;
    final user = <DspPreset?>[
      for (final Object? entry in decoded) DspPreset.fromJson(entry),
    ].whereType<DspPreset>().toList(growable: false);
    return <DspPreset>[...builtIns, ...user];
  } catch (_) {
    return builtIns;
  }
});

Future<int> saveDspPreset(String name, AdvancedAudioChain chain) async {
  final prefs = await SharedPreferences.getInstance();
  final existing = <DspPreset?>[
    for (final Object? entry in _decodePresets(prefs))
      DspPreset.fromJson(entry),
  ].whereType<DspPreset>().toList(growable: false);
  final cleaned = <DspPreset>[
    for (final preset in existing)
      if (preset.name != name) preset,
  ];
  cleaned.add(DspPreset(name: name, chain: chain));
  await prefs.setString(_presetsKey, jsonEncode(<Map<String, Object?>>[
    for (final preset in cleaned) preset.toJson(),
  ]));
  return cleaned.length;
}

Future<void> deleteDspPreset(String name) async {
  final prefs = await SharedPreferences.getInstance();
  final existing = <DspPreset?>[
    for (final Object? entry in _decodePresets(prefs)) DspPreset.fromJson(entry),
  ].whereType<DspPreset>().toList(growable: false);
  await prefs.setString(_presetsKey, jsonEncode(<Map<String, Object?>>[
    for (final preset in existing)
      if (preset.name != name) preset.toJson(),
  ]));
}

List<Object?> _decodePresets(SharedPreferences prefs) {
  final raw = prefs.getString(_presetsKey);
  if (raw == null || raw.isEmpty) return const <Object?>[];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) return decoded;
  } catch (_) {
    // Fall through to empty.
  }
  return const <Object?>[];
}
