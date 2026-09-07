import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/qr_code.dart';

/// Golden vectors produced with the reference encoder (ISO/IEC 18004),
/// cross-validated module-by-module against an independent QR implementation
/// for every forced mask and decode-verified with OpenCV. Matrix encoding:
/// one bit per module, row-major, rows padded to a byte boundary, base64.
class _Golden {
  const _Golden({
    required this.data,
    required this.level,
    required this.version,
    required this.mask,
    required this.size,
    required this.matrixB64,
    this.forcedZeroB64,
  });

  final String data;
  final QrErrorLevel level;
  final int version;
  final int mask;
  final int size;
  final String matrixB64;

  /// Matrix when mask 0 is forced (covers the forced-mask code path).
  final String? forcedZeroB64;
}

final List<_Golden> _goldens = <_Golden>[
  const _Golden(
    data: 'AZO24',
    level: QrErrorLevel.low,
    version: 1,
    mask: 0,
    size: 21,
    matrixB64:
        '/lv8E5Butrt0pduirsEFB/qv4BsA7/Yh5hMTsiZbxAs8qoBKm/tdcFe4utdd0BqusiMFxq/ovYA=',
  ),
  const _Golden(
    data: 'HELLO WORLD',
    level: QrErrorLevel.medium,
    version: 1,
    mask: 4,
    size: 21,
    matrixB64:
        '/sv8EJBulLt1JduursFJB/qv4BMAi/fIhcPPzaXxiA+qswBXr/urUEuzutY10kbunHEEKA/v+oA=',
    forcedZeroB64:
        '/mv8FlBugrt0ZdusrsElB/qv4AcAqlCVIxii+39jwSs4+gB6G/jG8E8huvKl0J2uqqsEYS/ts4A=',
  ),
  const _Golden(
    data: 'https://spotiflac.app/p/abcd1234',
    level: QrErrorLevel.medium,
    version: 3,
    mask: 1,
    size: 29,
    matrixB64:
        '/pHD/BA0UG60+Lt09KXbp/KuwWyxB/qqr+AAdACjdhErgbDY4PpfekHoSoG42SCILE2P7XrIKhBwcJvGmwqlMNn9qm5yOFlwDeBQ/QBMhHf6vSowSWEQuk8/3dFZ726xfycEalOP77K4gA==',
    forcedZeroB64:
        '/kST/Bae0G6BrLt0XgXbqqeuwQYZB/qqr+AK3gCqI0CRKxpyda8KLutC4CTtjHWihucmuC+dYLra2s6TzlgPmnNo/zsmkvPaqLUF+ABmLF/56GtwQ8sauppvjdPzRe6kKnMEwPkv6uftgA==',
  ),
  const _Golden(
    data: '日本語テスト',
    level: QrErrorLevel.medium,
    version: 2,
    mask: 1,
    size: 25,
    matrixB64:
        '/qu/wTjQbrGrt0sF26Q67BX9B/qq/gAqAKMFktJU3mHbnM+ST/ypZMuqOGv6w9QYStXevfqAREd/q+uQR1FboG/d0T166kffBMmM/vxUgA==',
    forcedZeroB64:
        '/n6/wVJQboTrt0Gl26lq7BNVB/qq/gCAAKpQiXj+dPSOyYU45Vn8MZkAksKvloCy4H+L6P+AbsX/nqrQTfH7rT+N05fS6xKLBGMm/qkBgA==',
  ),
  // Version 9: exercises 16-bit length field, version info BCH and the
  // three-position alignment pattern table (incl. centres on timing lines).
  _Golden(
    data: 'x' * 160,
    level: QrErrorLevel.medium,
    version: 9,
    mask: 2,
    size: 53,
    matrixB64:
        '/gnlbg0j/BOhsSU9kG6/21x6pLt19MI2oNXbqge/4FYuwXnDRlvxB/qqqqqqr+AfgJEuUQC+YmD6WDvmaVbReGuFQ+CxwQnwgfpZi6vlHq2ooA+Vg9/mCVkWBrhU+/McCp8IFA5YujpR6m6qEPsYPf1jpZFya4Vh5vdBIfCA0+FTo+Uer7uRz7WD38bFuBMGuFbKYx5SnwgElCGYP1Hq778h+0g//keKVHDrxXKhw6sr9qDRXmkQ5RGu+tIfvYL/gvAVu0ay1xz9OjafYgwL0ph+U0rixSEXWCdxr4Ma0GstfMTVq6n2IMgRKQNlNKM+KpU3gneKqHG/FrLXjc3qsx9iGK2n0D5TSqetU1NYJ36jlevwSy131dWrKHYgwazJA9U0oSC0n7UC/4BqmUcCtFf5QTKy3yoQWq8xLlEauoKt+lg//db0grhr+e6+K18J9WcEqrZr5QGv6S24lYKmAA==',
    forcedZeroB64:
        '/mprVu6j/BdCPx3fkG6HONJCRLt0zCG4mFXbrD9f7m4uwTf7xdXRB/qqqqqqr+AMDrHN3wCqAe76u7CQQbVfQIgLTdhSTzETDnBhaCXd/S4mmOwbuzwEh2H1iIC0GH0k6REw7K3Wgtnf0lZJnsP7s8NLRh9KiAtv3hTPGRMPWdmwLd39LDWpLDu7PCRLgPCIgLYp7SaxETD8N6+g3N/S39yv+6u/wEdp3EgIR365ICsTFq9RZose3fEt/Or/s7r8YH4tWMiKN/9zAtURWvSoXKCd3XLaJq8vu6lPh2CU6Iijcvw2JZEVr0Ipyo1d1yCwEna5upRoJklcmIo3bkPSUJFa4A4p6N3dcp9O3Wu7qUCLdmXIqKN37TYlEJWuw5Qqje3XIS6Mf7s6/ABkocSMjHf4zwqxUSrwSSERzd8SuuEj+ru/xdIXDICId+6myNExFukEklXl3eIv7xVbG7pFgA==',
  ),
  // The share-link shape produced by the playlist share UI.
  const _Golden(
    data: 'spotiflac://playlist/9f8e7d6c5b4a39281706f5e4d3c2b1a0',
    level: QrErrorLevel.quaternary,
    version: 5,
    mask: 2,
    size: 37,
    matrixB64:
        '/to6y/wQ6FDQbpyppLt0WBWF266jcq7BQmNJB/qqqq/gBBCjAH9zoImKhzr4CCyt3oe3eg9aZLjo6Q/73PmdwCiJJ2nM+43BIINWCT/fr4yZ4SuKzQFmx3ppelk3InU0P+bUEvaj6CZrz+2rOJk5O6a6M77ho2xirfFzlmtrDexsKTPuLf6AeKr0Y/tVUitwW43zEbqK1X/11tx0Na67/Z5TBZm9fB/ln4U3gA==',
    forcedZeroB64:
        '/rm08/wUC97QbqRKKrt1YPYF26ibkS7BDFupB/qqqq/gF56bAGsQLrL8r9l2MOKVPQmO8De56otm0ex1vnelI6RqqVEvYy5PGGBu6rHnSaR6bxNE9eLo/vBRmdcErE3XsYRaKhUvC6hTLHUItqHaA0U0C1jJQOJaY8mQGFLhNQ/iGr3WzviAdpIUb/rbaurwSAPLErrpW0+V0j/6DW6jHhBrBaFe8i/jp2a5gA==',
  ),
];

List<List<bool>> _decodeMatrix(String b64, int size) {
  final bytes = base64Decode(b64);
  final bits = <int>[];
  for (final b in bytes) {
    for (var i = 7; i >= 0; i--) {
      bits.add((b >> i) & 1);
    }
  }
  // Vectors are stored as a flat MSB-first bit stream padded to a byte
  // boundary, so drop the trailing pad bits (7 for every valid QR size).
  expect(bits.length >= size * size, isTrue, reason: 'matrix bit count');
  return List<List<bool>>.generate(
    size,
    (r) => List<bool>.generate(size, (c) => bits[r * size + c] == 1),
  );
}

void _expectSameMatrix(QrCode actual, List<List<bool>> expected) {
  final n = expected.length;
  List<int>? firstDiff;
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (actual.modules[r][c] != expected[r][c] && firstDiff == null) {
        firstDiff = <int>[r, c];
      }
    }
  }
  expect(
    firstDiff,
    isNull,
    reason: firstDiff == null
        ? 'matrix matches'
        : 'first module diff at (row ${firstDiff[0]}, col ${firstDiff[1]})',
  );
}

void main() {
  group('QR golden matrices (exact vs reference encoder)', () {
    for (final g in _goldens) {
      test(
        '${g.data.length < 24 ? g.data : '${g.data.substring(0, 24)}…'} '
        '@ ${g.level.name} -> v${g.version} mask ${g.mask}',
        () {
          final code = QrEncoder.encode(g.data, level: g.level);
          expect(code.version, g.version);
          expect(code.level, g.level);
          expect(code.mask, g.mask);
          expect(code.size, g.size);
          _expectSameMatrix(code, _decodeMatrix(g.matrixB64, g.size));
        },
      );
    }

    test('forced mask 0 reproduces the forced-mask reference matrices', () {
      for (final g in _goldens) {
        if (g.forcedZeroB64 == null) continue;
        final code = QrEncoder.encode(g.data, level: g.level, mask: 0);
        expect(code.mask, 0);
        expect(code.version, g.version);
        _expectSameMatrix(code, _decodeMatrix(g.forcedZeroB64!, g.size));
      }
    });

    test('all eight forced masks are valid square grids', () {
      final code0 = QrEncoder.encode('AZO24', level: QrErrorLevel.low, mask: 0);
      for (var m = 0; m < 8; m++) {
        final code = QrEncoder.encode('AZO24', level: QrErrorLevel.low, mask: m);
        expect(code.mask, m);
        expect(code.size, code0.size);
        // Function patterns must be identical across masks.
        for (var r = 0; r < code.size; r++) {
          for (var c = 0; c < code.size; c++) {
            if (_isFunctionCell(r, c, code.size)) {
              expect(code.modules[r][c], code0.modules[r][c],
                  reason: 'function pattern at ($r, $c) differs between '
                      'mask 0 and mask $m');
            }
          }
        }
      }
    });
  });

  group('QR encoder invariants', () {
    test('version selection matches the capacity table', () {
      // v1-M: 16 data codewords -> (128 - 12) / 8 = 14 payload bytes.
      expect(QrEncoder.encode('A').version, 1);
      expect(QrEncoder.encode('A' * 14).version, 1);
      expect(QrEncoder.encode('A' * 15).version, 2);
      // v2-M: 28 data codewords -> (224 - 12) / 8 = 26 payload bytes.
      expect(QrEncoder.encode('A' * 26).version, 2);
      expect(QrEncoder.encode('A' * 27).version, 3);
      // v9-M: 182 data codewords -> (1456 - 12) / 8 = 180 payload bytes;
      // v10-M switches to the 16-bit length field (capacity 213 bytes).
      final v9Code = QrEncoder.encode('A' * 180, level: QrErrorLevel.medium);
      expect(v9Code.version, 9);
      final v10Code = QrEncoder.encode('A' * 181, level: QrErrorLevel.medium);
      expect(v10Code.version, 10);
      final v10Max = QrEncoder.encode('A' * 213, level: QrErrorLevel.medium);
      expect(v10Max.version, 10);
      expect(QrEncoder.encode('A' * 214, level: QrErrorLevel.medium).version,
          11);
    });

    test('structure: finders, separators, timing, dark module', () {
      final code = QrEncoder.encode('spotiflac://playlist/abc123',
          level: QrErrorLevel.high);
      final s = code.size;
      // Finder corners are dark; separators are light.
      expect(code.modules[0][0], isTrue);
      expect(code.modules[0][s - 1], isTrue);
      expect(code.modules[s - 1][0], isTrue);
      expect(code.modules[7][0], isFalse); // separator row (top-left)
      expect(code.modules[0][7], isFalse); // separator col (top-left)
      // Timing pattern (v2+): even index = dark, from 8 to size-9.
      for (var i = 8; i <= s - 9; i++) {
        expect(code.modules[6][i], i.isEven, reason: 'timing col $i');
        expect(code.modules[i][6], i.isEven, reason: 'timing row $i');
      }
      // Always-dark module.
      expect(code.modules[s - 8][8], isTrue);
      // Quiet zone is not part of the matrix, but the edge modules must
      // belong to the function patterns (finder rings) on all four sides.
      expect(code.modules[0][6], isTrue);
      expect(code.modules[6][s - 1], isTrue);
    });

    test('version info cells are mask-independent (v7+)', () {
      final data = 'x' * 160; // v9
      final a = QrEncoder.encode(data, level: QrErrorLevel.medium, mask: 0);
      final b = QrEncoder.encode(data, level: QrErrorLevel.medium, mask: 7);
      final s = a.size;
      for (var i = 0; i < 18; i++) {
        final tr = i ~/ 3;
        final tc = i % 3 + s - 11;
        expect(a.modules[tr][tc], b.modules[tr][tc]);
        expect(a.modules[tc][tr], b.modules[tc][tr]);
      }
    });

    test('deterministic output', () {
      const data = 'spotiflac://playlist/9f8e7d6c5b4a39281706f5e4d3c2b1a0';
      final a = QrEncoder.encode(data, level: QrErrorLevel.quaternary);
      final b = QrEncoder.encode(data, level: QrErrorLevel.quaternary);
      expect(a.modules.length, b.modules.length);
      for (var r = 0; r < a.size; r++) {
        expect(a.modules[r], equals(b.modules[r]));
      }
    });

    test('overflow behaviour', () {
      // v40-L byte mode capacity is 2953 bytes.
      expect(
        () => QrEncoder.encode('a' * 2954, level: QrErrorLevel.low),
        throwsArgumentError,
      );
      final max = QrEncoder.encode('a' * 2953, level: QrErrorLevel.low);
      expect(max.version, 40);
      expect(max.size, 177);
    });

    test('invalid mask rejected', () {
      expect(() => QrEncoder.encode('abc', mask: 8), throwsArgumentError);
      expect(() => QrEncoder.encode('abc', mask: -1), throwsArgumentError);
    });
  });

  group('RS / BCH internals', () {
    test('rsEncode matches the standard generator (v1-L AZO24 EC)', () {
      // Data codewords of 'AZO24' at L (mode + length + payload + pads).
      final data = <int>[
        0x40, 0x54, 0x15, 0xa4, 0xf3, 0x23, 0x40, 0xec, 0x11, 0xec,
        0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11, 0xec, 0x11,
      ];
      expect(
        rsEncode(data, 7),
        <int>[0x3b, 0x7f, 0x7a, 0x63, 0x65, 0xb5, 0xb8],
      );
    });

    test('rsEncode remainder is divisible by the generator', () {
      // (data(x) * x^ec + rem) mod g(x) == 0, verified with an independent
      // shift-XOR GF(256) implementation (no shared log/exp tables).
      final data = <int>[0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef];
      final ec = rsEncode(data, 10);
      expect(ec.length, 10);
      final all = <int>[...data, ...ec];
      expect(_polyModByGenerator(all, 10), List<int>.filled(10, 0));
      // A second block, odd EC count.
      final data2 = <int>[0x3b, 0x7f, 0x7a, 0x63, 0x65, 0xb5, 0xb8];
      final ec2 = rsEncode(data2, 7);
      expect(
        _polyModByGenerator(<int>[...data2, ...ec2], 7),
        List<int>.filled(7, 0),
      );
    });

    test('BCH known values', () {
      // Format info: M (00) mask 0 == 101010000010010.
      expect(bchFormatInfo((0x0 << 3) | 0), 0x5412);
      // L (01) mask 0 == 1110111110000100.
      expect(bchFormatInfo((0x1 << 3) | 0), 0x77c4);
      // H (10) mask 7 == 1100101010100001.
      expect(bchFormatInfo((0x2 << 3) | 7), 0xcaa1);
      // Version info: v7 == 000111110010010100, v20, v40.
      expect(bchVersionInfo(7), 0x07c94);
      expect(bchVersionInfo(20), 0x149a6);
      expect(bchVersionInfo(40), 0x28c69);
    });

    test('mask functions match the ISO definitions', () {
      expect(maskMatches(0, 0, 0), isTrue);
      expect(maskMatches(0, 0, 1), isFalse);
      expect(maskMatches(1, 1, 5), isFalse);
      expect(maskMatches(1, 0, 3), isTrue);
      expect(maskMatches(2, 3, 3), isTrue);
      expect(maskMatches(2, 1, 2), isFalse);
      expect(maskMatches(3, 1, 2), isTrue);
      expect(maskMatches(3, 2, 1), isTrue);
      expect(maskMatches(4, 4, 6), isTrue);
      expect(maskMatches(4, 1, 2), isTrue);
      expect(maskMatches(5, 0, 0), isTrue);
      expect(maskMatches(5, 1, 0), isTrue);
      expect(maskMatches(5, 2, 2), isFalse);
      expect(maskMatches(6, 2, 2), isFalse);
      expect(maskMatches(6, 0, 0), isTrue);
      expect(maskMatches(6, 1, 1), isTrue);
      expect(maskMatches(7, 0, 0), isTrue);
      expect(maskMatches(7, 1, 1), isFalse);
      expect(maskMatches(7, 1, 2), isFalse);
      expect(maskMatches(7, 2, 2), isFalse);
    });
  });
}

/// True for cells covered by finder patterns + separators, timing, format
/// info, version info (v7+, i.e. size >= 41) and the dark module. Alignment
/// patterns (v2+) are function patterns too but are conservatively skipped.
bool _isFunctionCell(int r, int c, int s) {
  final inTopLeft = r <= 8 && c <= 8;
  final inTopRight = r <= 8 && c >= s - 9;
  final inBottomLeft = r >= s - 9 && c <= 8;
  final onTiming = r == 6 || c == 6;
  final onFormatRow = r == 8 && (c <= 8 || c >= s - 8);
  final onFormatCol = c == 8 && (r <= 8 || r >= s - 7 || r == s - 8);
  final hasVersionInfo = s >= 41;
  final inVersionTr = hasVersionInfo && r <= 5 && c >= s - 11;
  final inVersionBl = hasVersionInfo && r >= s - 11 && c <= 5;
  return inTopLeft ||
      inTopRight ||
      inBottomLeft ||
      onTiming ||
      onFormatRow ||
      onFormatCol ||
      inVersionTr ||
      inVersionBl;
}

// ---------------------------------------------------------------------------
// Independent GF(256) helpers (shift-XOR multiplication, no shared tables)
// used only by the cross-check above.
// ---------------------------------------------------------------------------

int _gfMul(int a, int b) {
  var p = 0;
  for (var i = 7; i >= 0; i--) {
    p = (p << 1) ^ ((p & 0x80) != 0 ? 0x11D : 0);
    p ^= ((b >> i) & 1) != 0 ? a : 0;
  }
  return p;
}

/// Polynomial multiply, highest-degree-first.
List<int> _gfPolyMul(List<int> a, List<int> b) {
  final out = List<int>.filled(a.length + b.length - 1, 0);
  for (var i = 0; i < a.length; i++) {
    for (var j = 0; j < b.length; j++) {
      out[i + j] ^= _gfMul(a[i], b[j]);
    }
  }
  while (out.length > 1 && out.first == 0) {
    out.removeAt(0);
  }
  return out;
}

/// QR generator polynomial `prod_{i=0}^{deg-1} (x + alpha^i)`, highest-first.
List<int> _rsGenerator(int deg) {
  var g = <int>[1];
  var alphaPow = 1;
  for (var i = 0; i < deg; i++) {
    g = _gfPolyMul(g, <int>[1, alphaPow]);
    alphaPow = _gfMul(alphaPow, 2);
  }
  return g;
}

/// Remainder of [poly] (highest-first) divided by the RS generator of
/// degree [deg] (monic), so synthetic division suffices.
List<int> _polyModByGenerator(List<int> poly, int deg) {
  final b = _rsGenerator(deg);
  final a = [...poly];
  while (true) {
    while (a.isNotEmpty && a.first == 0) {
      a.removeAt(0);
    }
    if (a.length < b.length) break;
    final factor = a.first; // b is monic
    for (var i = 0; i < b.length; i++) {
      a[i] ^= _gfMul(factor, b[i]);
    }
    a.removeAt(0);
  }
  final rem = List<int>.filled(b.length - 1, 0);
  for (var i = 0; i < a.length; i++) {
    rem[rem.length - a.length + i] = a[i];
  }
  return rem;
}
