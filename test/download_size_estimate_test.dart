import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/download_size_estimate.dart';

void main() {
  group('bitrateKbpsForQuality', () {
    test('known quality ids resolve to typical bitrates', () {
      expect(bitrateKbpsForQuality('LOSSLESS'), 1000);
      expect(bitrateKbpsForQuality('lossless'), 1000);
      expect(bitrateKbpsForQuality('HI_RES'), 2200);
      expect(bitrateKbpsForQuality('HI_RES_LOSSLESS'), 4600);
    });

    test('codec_bitrate ids are parsed from the suffix', () {
      expect(bitrateKbpsForQuality('MP3_320'), 320);
      expect(bitrateKbpsForQuality('opus_128'), 128);
      expect(bitrateKbpsForQuality('AAC_256'), 256);
    });

    test('unknown ids return null', () {
      expect(bitrateKbpsForQuality('WILD_FORMAT'), isNull);
      expect(bitrateKbpsForQuality(''), isNull);
      expect(bitrateKbpsForQuality('MP3_'), isNull);
      expect(bitrateKbpsForQuality('MP3_abc'), isNull);
      // Out-of-range "bitrates" are not treated as bitrate hints.
      expect(bitrateKbpsForQuality('WEIRD_99999'), isNull);
    });
  });

  group('estimateTrackBytes', () {
    test('200 s at 320 kbps is about 8 MB', () {
      final bytes = estimateTrackBytes(durationSeconds: 200, qualityId: 'MP3_320')!;
      expect(bytes, 200 * 320 * 1000 ~/ 8);
      expect(formatBytesShort(bytes), '7.6 MB');
    });

    test('null duration or unknown quality yields no estimate', () {
      expect(estimateTrackBytes(durationSeconds: null, qualityId: 'LOSSLESS'), isNull);
      expect(estimateTrackBytes(durationSeconds: 0, qualityId: 'LOSSLESS'), isNull);
      expect(estimateTrackBytes(durationSeconds: 210, qualityId: 'UNKNOWN'), isNull);
    });

    test('three-minute lossless track lands in a plausible band', () {
      final bytes = estimateTrackBytes(durationSeconds: 180, qualityId: 'LOSSLESS')!;
      // 180 s @ ~1000 kbps ≈ 22 MB; assert a wide-but-useful window.
      expect(bytes, greaterThan(15 * 1024 * 1024));
      expect(bytes, lessThan(30 * 1024 * 1024));
    });
  });

  group('formatBytesShort', () {
    test('switches units at powers of 1024', () {
      expect(formatBytesShort(0), '0 B');
      expect(formatBytesShort(1023), '1023 B');
      expect(formatBytesShort(1024), '1.0 KB');
      expect(formatBytesShort(5 * 1024 * 1024), '5.0 MB');
      expect(formatBytesShort(128 * 1024 * 1024), '128 MB');
      expect(formatBytesShort(3840 * 1024 * 1024), '3.8 GB');
    });
  });

  group('approxSizeLabel', () {
    test('labels only when an estimate exists', () {
      expect(approxSizeLabel(durationSeconds: 210, qualityId: 'MP3_320'), startsWith('≈ '));
      expect(approxSizeLabel(durationSeconds: null, qualityId: 'MP3_320'), isNull);
    });
  });
}
