/// Riverpod wiring for the premium audio engine (Phase 1).
///
/// Owns:
///   * persistence of [AudioEngineSettings] (`audio_engine.settings.v1`),
///   * installation into the process-level [AudioEngineRuntime],
///   * the binding that keeps the engine in sync with the existing
///     `EngineSettings` (gapless/crossfade) and the legacy normalization
///     master toggle,
///   * the [QueueManager] singleton (queue snapshots / export / import).
///
/// The binding provider is watched once from `MainShell`; every settings
/// change re-runs it, so no widget code needs to push values around.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/audio/audio_engine.dart';
import 'package:spotiflac_android/audio/queue_manager.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/music_player_service.dart';

/// Persisted audio-engine settings.
final audioEngineSettingsProvider =
    NotifierProvider<AudioEngineSettingsNotifier, AudioEngineSettings>(
      AudioEngineSettingsNotifier.new,
    );

class AudioEngineSettingsNotifier extends Notifier<AudioEngineSettings> {
  Completer<void>? _loading;

  @override
  AudioEngineSettings build() {
    unawaited(_restore());
    return const AudioEngineSettings();
  }

  Future<void> _restore() async {
    if (_loading != null) return _loading!.future;
    final completer = Completer<void>();
    _loading = completer;
    try {
      final prefs = await SharedPreferences.getInstance();
      final restored = await AudioEngineSettings.load(prefs);
      if (!ref.mounted) {
        completer.complete();
        return;
      }
      state = restored;
    } finally {
      _loading = null;
      completer.complete();
    }
  }

  Future<void> update(AudioEngineSettings Function(AudioEngineSettings) mutate) async {
    final next = mutate(state);
    state = next;
    final prefs = await SharedPreferences.getInstance();
    await next.save(prefs);
  }

  /// Sets the ReplayGain mode (off/track/album/smart) and flips the engine
  /// normalization master on unless the user explicitly turned it off.
  Future<void> setReplayGainMode(ReplayGainMode mode) async {
    await update(
      (settings) => settings.copyWith(
        replayGainMode: mode,
        normalizationEnabled:
            mode == ReplayGainMode.off ? settings.normalizationEnabled : true,
      ),
    );
  }

  Future<void> setNormalizationEnabled(bool enabled) => update(
    (settings) => settings.copyWith(normalizationEnabled: enabled),
  );

  Future<void> setPreAmpDb(double db) => update(
    (settings) => settings.copyWith(
      replayGainPreAmpDb: db.clamp(
        ReplayGainConfig.minPreAmpDb,
        ReplayGainConfig.maxPreAmpDb,
      ),
    ),
  );

  Future<void> setLoudnessTargetLufs(double lufs) => update(
    (settings) =>
        settings.copyWith(loudnessTargetLufs: lufs.clamp(-40.0, -6.0)),
  );

  Future<void> setPreventClipping(bool value) =>
      update((settings) => settings.copyWith(preventClipping: value));

  Future<void> setFadeCurve({
    FadeCurveKind? curve,
    bool? auto,
  }) => update(
    (settings) => settings.copyWith(
      fadeCurve: curve ?? settings.fadeCurve,
      fadeCurveAuto: auto ?? settings.fadeCurveAuto,
    ),
  );

  /// Manual gain override for one track (dB, clamped).
  Future<void> setTrackOverride(String trackId, double gainDb) => update(
    (settings) {
      final overrides = Map<String, double>.of(settings.gainOverrides)
        ..[ManualGainOverrides.trackKey(trackId)] = gainDb.clamp(
          ManualGainOverrides.minDb,
          ManualGainOverrides.maxDb,
        );
      return settings.copyWith(gainOverrides: overrides);
    },
  );

  Future<void> clearTrackOverride(String trackId) => update((settings) {
    final overrides = Map<String, double>.of(settings.gainOverrides)
      ..remove(ManualGainOverrides.trackKey(trackId));
    return settings.copyWith(gainOverrides: overrides);
  });
}

/// Keeps [AudioEngineRuntime] + the audio-service hooks in sync with the
/// persisted settings and the legacy toggles. Watched from `MainShell`.
final audioEngineBindingProvider = Provider<void>((ref) {
  final settings = ref.watch(audioEngineSettingsProvider);
  final engineSettings = ref.watch(engineSettingsProvider);
  final legacyNormalization = ref.watch(
    settingsProvider.select((AppSettings s) => s.playbackNormalization),
  );

  AudioEngineRuntime.install(
    settings,
    gaplessEnabled: engineSettings.gaplessEnabled,
    crossfadeSeconds: engineSettings.crossfadeSeconds,
    crossfadeSmart: engineSettings.crossfadeSmart,
  );
  setPlaybackGainResolver(
    settings.usesEngineNormalization
        ? (request) => AudioEngineRuntime.resolveGain(request)
        : null,
  );
  // The legacy toggle keeps governing when the engine path is disabled, so
  // the pre-existing settings switch never regresses.
  setPlaybackNormalizationEnabled(
    settings.usesEngineNormalization ? false : legacyNormalization,
  );
});

/// App-wide queue snapshot manager (SQLite-backed).
final queueManagerProvider = Provider<QueueManager>((ref) {
  return QueueManager(store: SQLiteQueueSnapshotStore());
});
