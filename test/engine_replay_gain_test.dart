import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/replay_gain.dart';

void main() {
  group('parseGainDb', () {
    test('parses signed dB strings', () {
      expect(ReplayGain.parseGainDb('+3.42 dB'), closeTo(3.42, 0.001));
      expect(ReplayGain.parseGainDb('-7.21 dB'), closeTo(-7.21, 0.001));
      expect(ReplayGain.parseGainDb('3.42'), closeTo(3.42, 0.001));
    });

    test('rejects empty, N/A and malformed values', () {
      expect(ReplayGain.parseGainDb(null), isNull);
      expect(ReplayGain.parseGainDb(''), isNull);
      expect(ReplayGain.parseGainDb('N/A'), isNull);
      expect(ReplayGain.parseGainDb('none'), isNull);
      expect(ReplayGain.parseGainDb('loud'), isNull);
    });
  });

  group('parsePeak', () {
    test('parses and rejects peak values', () {
      expect(ReplayGain.parsePeak('0.987654'), closeTo(0.987654, 1e-6));
      expect(ReplayGain.parsePeak('1.0'), 1.0);
      expect(ReplayGain.parsePeak(null), isNull);
      expect(ReplayGain.parsePeak('-1.0'), isNull);
      expect(ReplayGain.parsePeak('abc'), isNull);
    });
  });

  group('volume', () {
    test('no tags → unity gain', () {
      expect(ReplayGain.volume(), 1.0);
    });

    test('negative gain attenuates', () {
      // -6.02 dB ≈ half amplitude.
      expect(ReplayGain.volume(trackGainDb: -6.0206), closeTo(0.5, 0.001));
    });

    test('positive gain clamps to 1.0 (setVolume cannot boost)', () {
      expect(ReplayGain.volume(trackGainDb: 6.0), 1.0);
    });

    test('album gain is the fallback when track gain is missing', () {
      expect(ReplayGain.volume(albumGainDb: -6.0206), closeTo(0.5, 0.001));
    });

    test('preferAlbumGain uses album gain over track gain', () {
      final volume = ReplayGain.volume(
        trackGainDb: -3.0,
        albumGainDb: -9.0,
        preferAlbumGain: true,
      );
      expect(volume, closeTo(0.3548, 0.001));
    });

    test('pre-amp shifts the applied gain', () {
      final volume = ReplayGain.volume(trackGainDb: -6.0206, preAmpDb: 3.0);
      expect(volume, closeTo(0.7063, 0.001));
    });

    test('a peak above full scale is attenuated back to 1.0', () {
      final volume = ReplayGain.volume(trackGainDb: 6.0, trackPeak: 1.25);
      expect(volume, closeTo(0.8, 0.001));
    });

    test('a peak below full scale does not attenuate a clamped boost', () {
      expect(ReplayGain.volume(trackGainDb: 6.0, trackPeak: 0.8), 1.0);
    });

    test('preventClipping off leaves a boost clamped at 1.0', () {
      expect(
        ReplayGain.volume(
          trackGainDb: 6.0,
          trackPeak: 1.25,
          preventClipping: false,
        ),
        1.0,
      );
    });
  });

  group('dbToLinear / linearToDb', () {
    test('round trip is lossless', () {
      expect(ReplayGain.dbToLinear(0.0), 1.0);
      expect(ReplayGain.linearToDb(1.0), closeTo(0.0, 1e-9));
      expect(
        ReplayGain.linearToDb(ReplayGain.dbToLinear(-5.0)),
        closeTo(-5.0, 1e-6),
      );
    });
  });
}
