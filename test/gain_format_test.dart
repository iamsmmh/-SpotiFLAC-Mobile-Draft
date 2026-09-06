import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/gain_format.dart';

void main() {
  group('formatGainDb', () {
    test('positive gains carry an explicit + sign', () {
      expect(formatGainDb(2.5), '+2.5');
      expect(formatGainDb(0.5), '+0.5');
    });

    test('negative gains carry a - sign', () {
      expect(formatGainDb(-1.0), '-1.0');
      expect(formatGainDb(-12.0), '-12.0');
    });

    test('zero is rendered unsigned, including negative zero', () {
      expect(formatGainDb(0), '0.0');
      expect(formatGainDb(-0.0), '0.0');
    });

    test('decimals controls precision', () {
      expect(formatGainDb(1.234, decimals: 2), '+1.23');
      expect(formatGainDb(-1.234, decimals: 2), '-1.23');
    });
  });
}
