import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/audio/normalization_manager.dart';
import 'package:spotiflac_android/audio/replaygain_processor.dart';
import 'package:spotiflac_android/engine/advanced_audio.dart';

void main() {
  group('LoudnessTarget', () {
    test('presets carry the documented LUFS values', () {
      expect(LoudnessTarget.replayGain18.targetLufs, -18.0);
      expect(LoudnessTarget.streaming14.targetLufs, -14.0);
      expect(LoudnessTarget.broadcast23.targetLufs, -23.0);
    });

    test('fromLufs snaps unknown values to the ReplayGain reference', () {
      expect(LoudnessTarget.fromLufs(-14.0), LoudnessTarget.streaming14);
      expect(LoudnessTarget.fromLufs(-17.5), LoudnessTarget.replayGain18);
    });
  });

  group('NormalizationManager', () {
    test('unity plan when disabled', () {
      final manager = NormalizationManager()..configure(enabled: false);
      final processor = ReplayGainProcessor()
        ..configure(const ReplayGainConfig(mode: ReplayGainMode.track));
      final plan = manager.planFor(
        processor: processor,
        context: const GainContext(trackId: 't'),
        tags: const GainTagSet(trackGainDb: -6.0),
      );
      expect(plan.volume, 1.0);
      expect(plan.applied, isFalse);
    });

    test('delegates gain selection to the processor (track tag)', () {
      final manager = NormalizationManager()..configure(enabled: true);
      final processor = ReplayGainProcessor()
        ..configure(const ReplayGainConfig(mode: ReplayGainMode.track));
      final plan = manager.planFor(
        processor: processor,
        context: const GainContext(trackId: 't'),
        tags: const GainTagSet(trackGainDb: -6.0),
      );
      expect(plan.applied, isTrue);
      expect(plan.source, LoudnessSource.localTags);
      expect(plan.gainDb, -6.0);
    });

    test('attributes stream descriptors and manual overrides', () {
      final manager = NormalizationManager()..configure(enabled: true);
      final processor = ReplayGainProcessor()
        ..configure(const ReplayGainConfig(mode: ReplayGainMode.track));
      final streamed = manager.planFor(
        processor: processor,
        context: const GainContext(trackId: 't'),
        tags: const GainTagSet(trackGainDb: -6.0),
        source: LoudnessSource.streamDescriptor,
      );
      expect(streamed.source, LoudnessSource.streamDescriptor);

      processor.overrides.setTrack('t', -4.0);
      final manual = manager.planFor(
        processor: processor,
        context: const GainContext(trackId: 't'),
        tags: const GainTagSet(trackGainDb: -6.0),
      );
      expect(manual.source, LoudnessSource.manualOverride);
    });

    test('loudness targeting composes with the processor', () {
      final manager = NormalizationManager()
        ..configure(enabled: true, targetLufs: -14.0);
      final processor = ReplayGainProcessor()
        ..configure(
          const ReplayGainConfig(
            mode: ReplayGainMode.track,
            loudness: LoudnessNormalizationSettings(
              enabled: true,
              targetLufs: -14.0,
            ),
          ),
        );
      // -18 LUFS master tagged -6 dB → -24 LUFS absolute; at a -14 LUFS
      // target the needed gain is -6 + 4 = -2 dB.
      final plan = manager.planFor(
        processor: processor,
        context: const GainContext(trackId: 't'),
        tags: const GainTagSet(trackGainDb: -6.0),
      );
      expect(plan.gainDb, closeTo(-2.0, 1e-9));
    });

    test('clamps the pre-amp to the shared ±6 dB window', () {
      final manager = NormalizationManager()..setPreAmpDb(20.0);
      expect(manager.preAmpDb, 6.0);
      manager.setPreAmpDb(-20.0);
      expect(manager.preAmpDb, -6.0);
    });

    test('target getter reflects the configured LUFS', () {
      final manager = NormalizationManager()
        ..configure(enabled: true, targetLufs: -23.0);
      expect(manager.target, LoudnessTarget.broadcast23);
      expect(manager.enabled, isTrue);
    });
  });

  group('NormalizationPlan', () {
    test('unity is not applied', () {
      expect(NormalizationPlan.unity.applied, isFalse);
      const plan = NormalizationPlan(volume: 0.5, source: LoudnessSource.none);
      expect(plan.applied, isTrue);
    });
  });
}
