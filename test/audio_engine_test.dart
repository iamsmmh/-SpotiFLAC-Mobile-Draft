import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/audio/audio_engine.dart';
import 'package:spotiflac_android/audio/crossfade_manager.dart';
import 'package:spotiflac_android/audio/gapless_manager.dart';
import 'package:spotiflac_android/audio/normalization_manager.dart';
import 'package:spotiflac_android/audio/replaygain_processor.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/crossfade_policy.dart';
import 'package:spotiflac_android/engine/gapless_policy.dart';

class _Item implements GaplessQueueItem {
  const _Item(this.id, {this.characteristics = _flac});

  @override
  final String id;
  @override
  final String album = 'album';
  @override
  final AudioCharacteristics characteristics;
  @override
  final bool isRemote = false;
}

const AudioCharacteristics _flac = AudioCharacteristics(
  codec: 'FLAC',
  sampleRateHz: 44100,
  bitDepth: 16,
  channels: 2,
  lossless: true,
);

const AudioCharacteristics _mp3 = AudioCharacteristics(
  codec: 'MP3',
  bitrateKbps: 320,
);

void main() {
  group('AudioEngineSettings', () {
    test('defaults preserve legacy behaviour', () {
      const settings = AudioEngineSettings();
      expect(settings.replayGainMode, ReplayGainMode.off);
      expect(settings.normalizationEnabled, isFalse);
      expect(settings.usesEngineNormalization, isFalse);
      expect(settings.loudnessTargetLufs, -18.0);
      expect(settings.preventClipping, isTrue);
      expect(settings.fadeCurve, FadeCurveKind.equalPower);
      expect(settings.fadeCurveAuto, isTrue);
    });

    test('JSON round-trip keeps every field', () {
      const settings = AudioEngineSettings(
        replayGainMode: ReplayGainMode.smart,
        replayGainPreAmpDb: -1.5,
        preventClipping: false,
        normalizationEnabled: true,
        loudnessTargetLufs: -14.0,
        gainOverrides: <String, double>{'track:t1': -3.0},
        fadeCurve: FadeCurveKind.linear,
        fadeCurveAuto: false,
      );
      final restored = AudioEngineSettings.tryParse(settings.toJson());
      expect(restored.replayGainMode, ReplayGainMode.smart);
      expect(restored.replayGainPreAmpDb, -1.5);
      expect(restored.preventClipping, isFalse);
      expect(restored.normalizationEnabled, isTrue);
      expect(restored.loudnessTargetLufs, -14.0);
      expect(restored.gainOverrides['track:t1'], -3.0);
      expect(restored.fadeCurve, FadeCurveKind.linear);
      expect(restored.fadeCurveAuto, isFalse);
    });

    test('corrupt payloads fall back to defaults', () {
      expect(AudioEngineSettings.tryParse('nope'), const AudioEngineSettings());
      expect(
        AudioEngineSettings.tryParse(<String, Object?>{
          'replaygain_mode': 42,
          'replaygain_preamp_db': 'zzz',
          'loudness_target_lufs': -999,
          'gain_overrides': 'not-a-map',
        }),
        isA<AudioEngineSettings>(),
      );
    });

    test('out-of-range values are clamped on parse', () {
      final restored = AudioEngineSettings.tryParse(<String, Object?>{
        'replaygain_preamp_db': 99,
        'loudness_target_lufs': 0,
        'gain_overrides': <String, Object?>{'track:t1': -99.0},
      });
      expect(restored.replayGainPreAmpDb, ReplayGainConfig.maxPreAmpDb);
      expect(restored.loudnessTargetLufs, -6.0);
      expect(restored.gainOverrides['track:t1'], ManualGainOverrides.minDb);
    });

    test('SharedPreferences load/save round-trip', () async {
      SharedPreferences.setMockInitialValues(<String, Object?>{});
      final prefs = await SharedPreferences.getInstance();
      const settings = AudioEngineSettings(
        replayGainMode: ReplayGainMode.album,
        normalizationEnabled: true,
        loudnessTargetLufs: -23.0,
      );
      await settings.save(prefs);
      final loaded = await AudioEngineSettings.load(prefs);
      expect(loaded.replayGainMode, ReplayGainMode.album);
      expect(loaded.normalizationEnabled, isTrue);
      expect(loaded.loudnessTargetLufs, -23.0);
    });

    test('load tolerates a corrupt blob', () async {
      SharedPreferences.setMockInitialValues(<String, Object?>{
        AudioEngineSettings.storageKey: '{{{',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(await AudioEngineSettings.load(prefs), const AudioEngineSettings());
    });
  });

  group('AudioEngine', () {
    test('applySettings wires gapless + crossfade + gain config', () {
      final engine = AudioEngine();
      final changed = engine.applySettings(
        const AudioEngineSettings(
          replayGainMode: ReplayGainMode.track,
          normalizationEnabled: true,
        ),
        gaplessEnabled: true,
        crossfadeSeconds: 5,
        crossfadeSmart: true,
      );
      expect(changed, isTrue);
      expect(engine.gapless.enabled, isTrue);
      expect(engine.crossfade.seconds, 5);
      expect(engine.replayGain.config.mode, ReplayGainMode.track);
      expect(engine.normalization.enabled, isTrue);
      // Applying the identical state again reports no change.
      expect(
        engine.applySettings(
          const AudioEngineSettings(
            replayGainMode: ReplayGainMode.track,
            normalizationEnabled: true,
          ),
          gaplessEnabled: true,
          crossfadeSeconds: 5,
          crossfadeSmart: true,
        ),
        isFalse,
      );
    });

    test('planTransition: splicable pair prefers gapless over crossfade', () {
      final engine = AudioEngine()
        ..applySettings(
          const AudioEngineSettings(),
          gaplessEnabled: true,
          crossfadeSeconds: 6,
          crossfadeSmart: true,
        );
      final plan = engine.planTransition(
        current: const _Item('a'),
        next: const _Item('b'),
        trackDuration: const Duration(minutes: 3),
        sameAlbum: false,
      );
      expect(plan.gapless.kind, GaplessTransitionKind.seamless);
      expect(plan.crossfade.shouldCrossfade, isFalse);
    });

    test('planTransition: lossy pair crossfades instead', () {
      final engine = AudioEngine()
        ..applySettings(
          const AudioEngineSettings(),
          gaplessEnabled: true,
          crossfadeSeconds: 6,
          crossfadeSmart: true,
        );
      final plan = engine.planTransition(
        current: const _Item('a', characteristics: _mp3),
        next: const _Item('b', characteristics: _mp3),
        trackDuration: const Duration(minutes: 3),
        sameAlbum: false,
      );
      expect(plan.gapless.kind, GaplessTransitionKind.prebuffer);
      expect(plan.crossfade.shouldCrossfade, isTrue);
    });

    test('gain overrides load into the processor by key prefix', () {
      final engine = AudioEngine()
        ..applySettings(
          const AudioEngineSettings(
            replayGainMode: ReplayGainMode.track,
            normalizationEnabled: true,
            gainOverrides: <String, double>{
              'track:t1': -4.0,
              'album:a1': -7.0,
              'bogus': -1.0,
            },
          ),
          gaplessEnabled: true,
          crossfadeSeconds: 0,
          crossfadeSmart: true,
        );
      expect(engine.replayGain.overrides.forTrack('t1'), -4.0);
      expect(engine.replayGain.overrides.forAlbum('a1'), -7.0);
      expect(
        engine.replayGain.overrides.lookup(
          trackId: 'other',
          albumKey: 'other',
        ),
        isNull,
      );
    });
  });

  group('AudioEngineRuntime', () {
    setUp(() {
      AudioEngineRuntime.reset();
    });

    tearDown(() {
      AudioEngineRuntime.reset();
    });

    test('resolveGain defers (null) when no engine is installed', () {
      expect(
        AudioEngineRuntime.resolveGain(const GainRequest(trackId: 't')),
        isNull,
      );
    });

    test('resolveGain defers when the engine path is disabled', () {
      AudioEngineRuntime.install(
        const AudioEngineSettings(),
        gaplessEnabled: true,
        crossfadeSeconds: 0,
        crossfadeSmart: true,
      );
      expect(
        AudioEngineRuntime.resolveGain(
          const GainRequest(trackId: 't', trackGainDb: -6.0),
        ),
        isNull,
      );
    });

    test('resolveGain applies the configured mode', () {
      AudioEngineRuntime.install(
        const AudioEngineSettings(
          replayGainMode: ReplayGainMode.track,
          normalizationEnabled: true,
        ),
        gaplessEnabled: true,
        crossfadeSeconds: 0,
        crossfadeSmart: true,
      );
      final volume = AudioEngineRuntime.resolveGain(
        const GainRequest(trackId: 't', trackGainDb: -6.0),
      );
      expect(volume, isNotNull);
      expect(volume!, lessThan(1.0));
      // Untagged track stays at unity.
      expect(
        AudioEngineRuntime.resolveGain(const GainRequest(trackId: 't2')),
        1.0,
      );
    });

    test('install reuses one engine instance across settings changes', () {
      final first = AudioEngineRuntime.install(
        const AudioEngineSettings(
          replayGainMode: ReplayGainMode.track,
          normalizationEnabled: true,
        ),
        gaplessEnabled: true,
        crossfadeSeconds: 0,
        crossfadeSmart: true,
      );
      final second = AudioEngineRuntime.install(
        const AudioEngineSettings(
          replayGainMode: ReplayGainMode.track,
          normalizationEnabled: true,
          loudnessTargetLufs: -14.0,
        ),
        gaplessEnabled: true,
        crossfadeSeconds: 3,
        crossfadeSmart: true,
      );
      expect(identical(first, second), isTrue);
      expect(second.crossfade.seconds, 3);
      expect(second.normalization.target, LoudnessTarget.streaming14);
    });
  });

  group('AlbumRun', () {
    test('contains covers the half-open range', () {
      const run = AlbumRun(startIndex: 2, endIndex: 5);
      expect(run.length, 3);
      expect(run.contains(2), isTrue);
      expect(run.contains(4), isTrue);
      expect(run.contains(5), isFalse);
      expect(run.contains(1), isFalse);
    });
  });
}
