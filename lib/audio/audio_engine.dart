/// Audio engine facade (premium audio engine, Phase 1).
///
/// Composes the five phase-1 managers into one coherent, testable unit and
/// bridges them to the audio service:
///
/// ```
/// AudioEngine
/// ├── GaplessManager            (gapless + album-run optimization)
/// ├── CrossfadeManager          (1–12 s fades, curves)
/// ├── ReplayGainProcessor       (track/album/smart gain + overrides)
/// ├── NormalizationManager      (target-LUFS loudness normalization)
/// └── QueueManager              (snapshots, persistence, export/import)
/// ```
///
/// The player (`services/music_player_service.dart`) consults this engine
/// through one process-level hook — [AudioEngineRuntime.resolveGain] — while
/// the Riverpod layer (`providers/audio_engine_provider.dart`) owns
/// persistence and lifecycle. Legacy behaviour is preserved: when the engine
/// is unconfigured the hook defers to the pre-existing tag-only path.
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/audio/crossfade_manager.dart';
import 'package:spotiflac_android/audio/gapless_manager.dart';
import 'package:spotiflac_android/audio/normalization_manager.dart';
import 'package:spotiflac_android/audio/queue_manager.dart';
import 'package:spotiflac_android/audio/replaygain_processor.dart';
import 'package:spotiflac_android/engine/crossfade_policy.dart';
import 'package:spotiflac_android/engine/gapless_policy.dart';

/// Persisted user preferences for the premium audio engine.
///
/// Storage key: `audio_engine.settings.v1`. Deliberately **additive** to the
/// existing `engine_settings_v1` surface: gapless + crossfade seconds stay
/// owned by `EngineSettings` (unchanged keys, unchanged settings UI); this
/// model owns only the *new* knobs (gain mode, pre-amp, loudness target,
/// fade curve, manual overrides). Missing/corrupt values fall back to the
/// exact legacy behaviour.
class AudioEngineSettings {
  static const String storageKey = 'audio_engine.settings.v1';

  final ReplayGainMode replayGainMode;
  final double replayGainPreAmpDb;
  final bool preventClipping;

  /// Master switch for the *engine* normalization path (mode + loudness
  /// re-targeting). When false the resolver defers to the legacy
  /// `playbackNormalization` toggle exactly as before this engine existed.
  final bool normalizationEnabled;

  /// Target integrated loudness in LUFS (ReplayGain reference -18 by
  /// default; -14/-23 presets available).
  final double loudnessTargetLufs;

  /// Manual per-track/album gain overrides (`track:<id>` → dB).
  final Map<String, double> gainOverrides;

  final FadeCurveKind fadeCurve;
  final bool fadeCurveAuto;

  const AudioEngineSettings({
    this.replayGainMode = ReplayGainMode.off,
    this.replayGainPreAmpDb = 0.0,
    this.preventClipping = true,
    this.normalizationEnabled = false,
    this.loudnessTargetLufs = -18.0,
    this.gainOverrides = const <String, double>{},
    this.fadeCurve = FadeCurveKind.equalPower,
    this.fadeCurveAuto = true,
  });

  bool get usesEngineNormalization => normalizationEnabled;

  AudioEngineSettings copyWith({
    ReplayGainMode? replayGainMode,
    double? replayGainPreAmpDb,
    bool? preventClipping,
    bool? normalizationEnabled,
    double? loudnessTargetLufs,
    Map<String, double>? gainOverrides,
    FadeCurveKind? fadeCurve,
    bool? fadeCurveAuto,
  }) => AudioEngineSettings(
    replayGainMode: replayGainMode ?? this.replayGainMode,
    replayGainPreAmpDb: replayGainPreAmpDb ?? this.replayGainPreAmpDb,
    preventClipping: preventClipping ?? this.preventClipping,
    normalizationEnabled: normalizationEnabled ?? this.normalizationEnabled,
    loudnessTargetLufs: loudnessTargetLufs ?? this.loudnessTargetLufs,
    gainOverrides: gainOverrides ?? this.gainOverrides,
    fadeCurve: fadeCurve ?? this.fadeCurve,
    fadeCurveAuto: fadeCurveAuto ?? this.fadeCurveAuto,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'replaygain_mode': replayGainMode.name,
    'replaygain_preamp_db': replayGainPreAmpDb,
    'prevent_clipping': preventClipping,
    'normalization_enabled': normalizationEnabled,
    'loudness_target_lufs': loudnessTargetLufs,
    'gain_overrides': gainOverrides,
    'fade_curve': fadeCurve.name,
    'fade_curve_auto': fadeCurveAuto,
  };

  /// Lenient parse: unknown/invalid fields fall back to legacy defaults so a
  /// corrupted preferences blob can never hard-disable playback features.
  static AudioEngineSettings tryParse(Object? raw) {
    if (raw is! Map) return const AudioEngineSettings();
    final map = Map<String, Object?>.from(raw);
    final overrides = <String, double>{};
    final rawOverrides = map['gain_overrides'];
    if (rawOverrides is Map) {
      rawOverrides.forEach((key, value) {
        final gain = value is num
            ? value.toDouble()
            : double.tryParse('$value');
        final keyText = key.toString();
        if (gain == null || !gain.isFinite || keyText.isEmpty) return;
        overrides[keyText] = gain.clamp(
          ManualGainOverrides.minDb,
          ManualGainOverrides.maxDb,
        );
      });
    }
    final preamp = map['replaygain_preamp_db'] is num
        ? (map['replaygain_preamp_db'] as num).toDouble()
        : (double.tryParse('${map['replaygain_preamp_db']}') ?? 0.0);
    final target = map['loudness_target_lufs'] is num
        ? (map['loudness_target_lufs'] as num).toDouble()
        : (double.tryParse('${map['loudness_target_lufs']}') ?? -18.0);
    return AudioEngineSettings(
      replayGainMode: ReplayGainMode.fromName(map['replaygain_mode']),
      replayGainPreAmpDb: preamp.isFinite
          ? preamp.clamp(ReplayGainConfig.minPreAmpDb, ReplayGainConfig.maxPreAmpDb)
          : 0.0,
      preventClipping: map['prevent_clipping'] != false,
      normalizationEnabled: map['normalization_enabled'] == true,
      loudnessTargetLufs: target.isFinite
          ? target.clamp(-40.0, -6.0)
          : -18.0,
      gainOverrides: overrides,
      fadeCurve: FadeCurveKind.fromName(map['fade_curve']),
      fadeCurveAuto: map['fade_curve_auto'] != false,
    );
  }

  static Future<AudioEngineSettings> load(
    SharedPreferences prefs,
  ) async {
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return const AudioEngineSettings();
    try {
      return tryParse(jsonDecode(raw));
    } on FormatException {
      return const AudioEngineSettings();
    }
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(storageKey, jsonEncode(toJson()));
  }
}

/// The composed engine.
class AudioEngine {
  final GaplessManager gapless = GaplessManager();
  final CrossfadeManager crossfade = CrossfadeManager();
  final ReplayGainProcessor replayGain = ReplayGainProcessor();
  final NormalizationManager normalization = NormalizationManager();

  /// Applies the persisted settings + the legacy master toggles that still
  /// own gapless/crossfade. Returns true when anything audible changed.
  bool applySettings(
    AudioEngineSettings settings, {
    required bool gaplessEnabled,
    required int crossfadeSeconds,
    required bool crossfadeSmart,
  }) {
    var changed = gapless.configure(enabled: gaplessEnabled);
    changed = crossfade.configure(
          seconds: CrossfadeManager.clampSeconds(crossfadeSeconds),
          smart: crossfadeSmart,
          curve: settings.fadeCurve,
          autoCurve: settings.fadeCurveAuto,
        ) ||
        changed;

    final loudness = settings.usesEngineNormalization
        ? LoudnessNormalizationSettings(
            enabled: true,
            targetLufs: settings.loudnessTargetLufs,
          )
        : const LoudnessNormalizationSettings(enabled: false);
    final config = ReplayGainConfig(
      mode: settings.replayGainMode,
      preAmpDb: settings.replayGainPreAmpDb,
      preventClipping: settings.preventClipping,
      loudness: loudness,
    );
    changed = replayGain.configure(config) || changed;
    normalization.configure(
      enabled: settings.usesEngineNormalization,
      targetLufs: settings.loudnessTargetLufs,
    );
    normalization.setPreAmpDb(settings.replayGainPreAmpDb);

    replayGain.overrides.clear();
    settings.gainOverrides.forEach((key, gainDb) {
      if (key.startsWith('${ManualGainOverrides.trackKey('')}')) {
        replayGain.overrides.setTrack(
          key.substring('track:'.length),
          gainDb,
        );
      } else if (key.startsWith('album:')) {
        replayGain.overrides.setAlbum(key.substring('album:'.length), gainDb);
      }
    });
    return changed;
  }

  /// Plans a combined transition (what gapless does, what crossfade does).
  /// Used by the preloader/predictive cache and by tests to pin behaviour.
  /// [sameAlbum] may be omitted: it is then derived from the album-run
  /// detection in [GaplessManager.albumRuns].
  ({GaplessDecision gapless, CrossfadeDecision crossfade}) planTransition({
    required GaplessQueueItem current,
    required GaplessQueueItem next,
    required Duration? trackDuration,
    bool? sameAlbum,
    bool repeatOne = false,
  }) {
    final inSameAlbum = sameAlbum ??
        GaplessManager.albumRuns(<GaplessQueueItem>[current, next]).isNotEmpty;
    final gaplessDecision = gapless.decideNext(
      current: current,
      next: next,
      sameAlbum: inSameAlbum,
    );
    final crossfadeDecision = crossfade.decide(
      trackDuration: trackDuration,
      current: current.characteristics,
      next: next.characteristics,
      sameTransport: current.isRemote == next.isRemote,
      gaplessEnabled: gapless.enabled,
      sameAlbum: inSameAlbum,
      repeatOne: repeatOne,
    );
    return (gapless: gaplessDecision, crossfade: crossfadeDecision);
  }
}

/// The gain facts the player hands to the engine for the track about to
/// play. Plain values — `PlayableMedia` adapts itself into this at the call
/// site so `lib/audio` never imports the audio service stack.
class GainRequest {
  final String trackId;
  final String albumKey;
  final bool isAlbumContext;
  final bool shuffle;

  /// Parsed ReplayGain/R128 tags (local probe or stream descriptor).
  final double? trackGainDb;
  final double? albumGainDb;
  final double? trackPeak;

  const GainRequest({
    required this.trackId,
    this.albumKey = '',
    this.isAlbumContext = false,
    this.shuffle = false,
    this.trackGainDb,
    this.albumGainDb,
    this.trackPeak,
  });
}

/// Process-level bridge installed once at startup and consulted by the audio
/// service on every track start / normalization re-apply.
abstract final class AudioEngineRuntime {
  static AudioEngine? _engine;

  static AudioEngine? get engine => _engine;

  /// Installs (or replaces) the engine with [settings] applied. Returns the
  /// engine instance.
  static AudioEngine install(
    AudioEngineSettings settings, {
    required bool gaplessEnabled,
    required int crossfadeSeconds,
    required bool crossfadeSmart,
  }) {
    final engine = _engine ??= AudioEngine();
    engine.applySettings(
      settings,
      gaplessEnabled: gaplessEnabled,
      crossfadeSeconds: crossfadeSeconds,
      crossfadeSmart: crossfadeSmart,
    );
    return engine;
  }

  /// The gain resolver the audio service calls. Returns null when the engine
  /// is not installed or its normalization path is disabled — the caller
  /// then falls back to the legacy tag-only behaviour, byte-for-byte.
  static double? resolveGain(GainRequest request) {
    final engine = _engine;
    if (engine == null || !engine.replayGain.config.enabled) return null;
    final resolved = engine.replayGain.resolve(
      context: GainContext(
        trackId: request.trackId,
        albumKey: request.albumKey,
        isAlbumContext: request.isAlbumContext,
        shuffle: request.shuffle,
      ),
      tags: GainTagSet(
        trackGainDb: request.trackGainDb,
        albumGainDb: request.albumGainDb,
        trackPeak: request.trackPeak,
      ),
    );
    return resolved.volume;
  }

  static void reset() {
    _engine = null;
  }
}
