import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/data/sha256.dart';

void main() {
  group('sha256Hex one-shot', () {
    test('empty input matches the FIPS 180-4 empty digest', () {
      expect(
        sha256Hex(const <int>[]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('"abc" matches the canonical NIST vector', () {
      expect(
        sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('two-block NIST message vector', () {
      expect(
        sha256Hex(
          utf8.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('one million "a" bytes (multi-block streaming)', () {
      expect(
        sha256Hex(List<int>.filled(1000000, 0x61)),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });
  });

  group('Sha256Accumulator streaming', () {
    test('chunked feeding equals one-shot for every boundary length', () {
      for (final length in <int>[0, 1, 3, 55, 56, 57, 63, 64, 65, 119, 120,
        127, 128, 129, 1000]) {
        final bytes = List<int>.generate(length, (i) => (i * 31 + 7) & 0xFF);
        final accumulator = Sha256Accumulator();
        // Feed in odd chunk sizes to stress the internal 64-byte buffer.
        for (var offset = 0; offset < bytes.length; offset += 13) {
          final end = offset + 13 > bytes.length ? bytes.length : offset + 13;
          accumulator.add(bytes.sublist(offset, end));
        }
        expect(
          accumulator.digestHex(),
          sha256Hex(bytes),
          reason: 'chunked digest differs at length $length',
        );
      }
    });

    test('digest seals the accumulator', () {
      final accumulator = Sha256Accumulator()..add(utf8.encode('x'));
      accumulator.digestHex();
      expect(
        () => accumulator.add(utf8.encode('y')),
        throwsStateError,
      );
      expect(() => accumulator.digestHex(), throwsStateError);
    });

    test('digestBytes returns 32 bytes consistent with digestHex', () {
      final one = Sha256Accumulator()..add(utf8.encode('integrity'));
      final two = Sha256Accumulator()..add(utf8.encode('integrity'));
      final hex = one.digestHex();
      final bytes = two.digestBytes();
      expect(bytes, hasLength(32));
      final rebuilt = bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(rebuilt, hex);
    });

    test('tracks the number of bytes fed', () {
      final accumulator = Sha256Accumulator()
        ..add(List<int>.filled(10, 0))
        ..add(List<int>.filled(5, 1));
      expect(accumulator.length, 15);
    });
  });
}
