// ignore_for_file: unnecessary_const
/// Pure-Dart QR Code encoder (byte mode, versions 1-40, EC levels L/M/Q/H).
///
/// No external dependencies. The implementation mirrors the reference
/// encoder verified against the ISO/IEC 18004 tables (see
/// `test/qr_code_test.dart` for exact-matrix golden vectors):
///
/// * mode `0100` (byte), length field 8 bits (v1-9) / 16 bits (v10+);
/// * smallest version whose data capacity fits;
/// * terminator, byte alignment, alternating `0xEC`/`0x11` pad bytes;
/// * per-block Reed-Solomon over GF(256) (poly `0x11D`, generator
///   `prod_{i=0}^{ec-1} (x + alpha^i)`), then standard block interleaving;
/// * finder/timing/alignment/format/version function patterns;
/// * zig-zag placement with the 8 ISO mask patterns and the ISO penalty
///   rule (N1..N4) for mask selection.
library;

import 'dart:convert';

/// Error correction levels, ordered as in the RS block table
/// (index 0 = L, 1 = M, 2 = Q, 3 = H).
enum QrErrorLevel {
  low,
  medium,
  quaternary,
  high,
}

/// Result of encoding: dark-module matrix plus metadata.
class QrCode {
  const QrCode({
    required this.version,
    required this.level,
    required this.mask,
    required this.modules,
  });

  /// QR version 1..40.
  final int version;

  final QrErrorLevel level;

  /// The mask pattern actually applied (0..7).
  final int mask;

  /// `modules[row][col]` — `true` = dark module. Square, size x size.
  final List<List<bool>> modules;

  int get size => modules.length;

  bool isDark(int row, int col) => modules[row][col];

  @override
  String toString() =>
      'QrCode(v$version, ${level.name}, mask $mask, ${size}x$size)';
}

/// Entry point. See [QrCode] for the result shape.
///
/// [mask] forces a specific ISO mask pattern (0..7); when omitted the mask
/// with the lowest penalty score wins (ties: lowest index).
class QrEncoder {
  QrEncoder._();

  /// Encodes [data] (UTF-8) into a [QrCode].
  ///
  /// Throws [ArgumentError] when [data] does not fit in version 40 at the
  /// requested [level] (byte mode capacity is 2953 bytes for L, far beyond
  /// any share link).
  static QrCode encode(
    String data, {
    QrErrorLevel level = QrErrorLevel.medium,
    int? mask,
  }) {
    final payload = utf8.encode(data);
    return encodeBytes(payload, level: level, mask: mask);
  }

  /// Encodes raw bytes into a [QrCode] (byte mode).
  static QrCode encodeBytes(
    List<int> payload, {
    QrErrorLevel level = QrErrorLevel.medium,
    int? mask,
  }) {
    if (mask != null && (mask < 0 || mask > 7)) {
      throw ArgumentError.value(mask, 'mask', 'must be 0..7');
    }
    final levelIndex = level.index;

    // --- version selection: smallest version with enough data bits -------
    var version = 0;
    for (var v = 1; v <= 40; v++) {
      final blocks = rsBlockTable[(v - 1) * 4 + levelIndex];
      final dataBits = _dataBits(blocks);
      final lenBits = v <= 9 ? 8 : 16;
      if (4 + lenBits + 8 * payload.length <= dataBits) {
        version = v;
        break;
      }
    }
    if (version == 0) {
      throw ArgumentError.value(
        payload.length,
        'payload',
        'too long for QR byte mode at level ${level.name}',
      );
    }

    final blocks = rsBlockTable[(version - 1) * 4 + levelIndex];
    final dataBitsTotal = _dataBits(blocks);
    final lenBits = version <= 9 ? 8 : 16;

    // --- bit packing ------------------------------------------------------
    final bits = <int>[];
    void put(int num, int length) {
      for (var i = length - 1; i >= 0; i--) {
        bits.add((num >> i) & 1);
      }
    }

    put(0x4, 4); // mode indicator: byte
    put(payload.length, lenBits);
    for (final b in payload) {
      put(b, 8);
    }
    // terminator (up to four zero bits)
    final room = dataBitsTotal - bits.length;
    for (var i = 0; i < (room < 4 ? room : 4); i++) {
      bits.add(0);
    }
    // byte alignment
    final rem = bits.length % 8;
    if (rem != 0) {
      for (var i = 0; i < 8 - rem; i++) {
        bits.add(0);
      }
    }
    // pad bytes
    var pad = _pad0;
    while (bits.length < dataBitsTotal) {
      put(pad, 8);
      pad = pad == _pad0 ? _pad1 : _pad0;
    }

    final dataCodewords = <int>[];
    for (var i = 0; i < bits.length; i += 8) {
      var byte = 0;
      for (var j = 0; j < 8; j++) {
        byte = (byte << 1) | bits[i + j];
      }
      dataCodewords.add(byte);
    }

    // --- split into blocks, RS-encode, interleave -------------------------
    final blockData = <List<int>>[];
    final blockEc = <List<int>>[];
    var offset = 0;
    for (final entry in blocks) {
      final count = entry[0];
      final total = entry[1];
      final dCount = entry[2];
      for (var i = 0; i < count; i++) {
        final chunk = dataCodewords.sublist(offset, offset + dCount);
        offset += dCount;
        blockData.add(chunk);
        blockEc.add(rsEncode(chunk, total - dCount));
      }
    }
    var maxDc = 0;
    var maxEc = 0;
    for (final b in blockData) {
      if (b.length > maxDc) maxDc = b.length;
    }
    for (final b in blockEc) {
      if (b.length > maxEc) maxEc = b.length;
    }
    final codewords = <int>[];
    for (var i = 0; i < maxDc; i++) {
      for (final b in blockData) {
        if (i < b.length) codewords.add(b[i]);
      }
    }
    for (var i = 0; i < maxEc; i++) {
      for (final b in blockEc) {
        if (i < b.length) codewords.add(b[i]);
      }
    }

    // --- matrix + function patterns ---------------------------------------
    final size = 17 + 4 * version;
    final pos = patternPositionTable[version - 1];

    List<List<bool?>> freshModules() =>
        List<List<bool?>>.generate(size, (_) => List<bool?>.filled(size, null));

    void drawFunctionPatterns(List<List<bool?>> modules) {
      void finder(int row, int col) {
        for (var r = -1; r < 8; r++) {
          if (row + r < 0 || size <= row + r) continue;
          for (var c = -1; c < 8; c++) {
            if (col + c < 0 || size <= col + c) continue;
            final dark =
                (r >= 0 && r <= 6 && (c == 0 || c == 6)) ||
                (c >= 0 && c <= 6 && (r == 0 || r == 6)) ||
                (r >= 2 && r <= 4 && c >= 2 && c <= 4);
            modules[row + r][col + c] = dark;
          }
        }
      }

      finder(0, 0);
      finder(size - 7, 0);
      finder(0, size - 7);
      // Alignment patterns BEFORE timing: centres that lie on the timing
      // row/col (e.g. (6, mid) from v7 up) must win over timing modules.
      for (final row in pos) {
        for (final col in pos) {
          if (modules[row][col] != null) continue;
          for (var r = -2; r <= 2; r++) {
            for (var c = -2; c <= 2; c++) {
              final dark =
                  (r == -2 || r == 2 || c == -2 || c == 2) || (r == 0 && c == 0);
              modules[row + r][col + c] = dark;
            }
          }
        }
      }
      for (var i = 8; i < size - 8; i++) {
        if (modules[i][6] == null) modules[i][6] = i.isEven;
        if (modules[6][i] == null) modules[6][i] = i.isEven;
      }
    }

    void drawFormat(List<List<bool?>> modules, int maskPattern,
        {bool test = false}) {
      final fmt = bchFormatInfo((_ecFormatBits[levelIndex] << 3) | maskPattern);
      // vertical (copy 2 along column 8 bottom + copy 1 along column 8 top)
      for (var i = 0; i < 15; i++) {
        final mod = !test && (((fmt >> (14 - i)) & 1) == 1);
        if (i < 6) {
          modules[i][8] = mod;
        } else if (i < 8) {
          modules[i + 1][8] = mod;
        } else {
          modules[size - 15 + i][8] = mod;
        }
      }
      // horizontal (copy 2 along row 8 right + copy 1 along row 8 left)
      for (var i = 0; i < 15; i++) {
        final mod = !test && (((fmt >> (14 - i)) & 1) == 1);
        if (i < 8) {
          modules[8][size - i - 1] = mod;
        } else if (i < 9) {
          modules[8][15 - i] = mod;
        } else {
          modules[8][15 - i - 1] = mod;
        }
      }
      // fixed dark module
      modules[size - 8][8] = !test;
    }

    void drawVersion(List<List<bool?>> modules, {bool test = false}) {
      if (version < 7) return;
      final versionBits = bchVersionInfo(version);
      for (var i = 0; i < 18; i++) {
        final mod = !test && (((versionBits >> i) & 1) == 1);
        modules[i ~/ 3][i % 3 + size - 11] = mod;
        modules[i % 3 + size - 11][i ~/ 3] = mod;
      }
    }

    void mapData(List<List<bool?>> modules, int maskPattern) {
      var inc = -1;
      var row = size - 1;
      var bitIndex = 7;
      var byteIndex = 0;
      for (var col = size - 1; col > 0; col -= 2) {
        if (col <= 6) col -= 1;
        while (true) {
          for (final c in <int>[col, col - 1]) {
            if (modules[row][c] == null) {
              var dark = false;
              if (byteIndex < codewords.length) {
                dark = (((codewords[byteIndex] >> bitIndex) & 1) == 1);
              }
              if (maskMatches(maskPattern, row, c)) {
                dark = !dark;
              }
              modules[row][c] = dark;
              bitIndex -= 1;
              if (bitIndex == -1) {
                byteIndex += 1;
                bitIndex = 7;
              }
            }
          }
          row += inc;
          if (row < 0 || size <= row) {
            row -= inc;
            inc = -inc;
            break;
          }
        }
      }
    }

    List<List<bool?>> build(
      List<List<bool?>> modules,
      int maskPattern, {
      bool test = false,
    }) {
      drawFormat(modules, maskPattern, test: test);
      drawVersion(modules, test: test);
      mapData(modules, maskPattern);
      return modules;
    }

    List<List<bool>> finalizeModules(List<List<bool?>> modules) {
      return List<List<bool>>.generate(
        size,
        (r) => List<bool>.generate(size, (c) => modules[r][c] ?? false),
      );
    }

    if (mask != null) {
      final modules = freshModules();
      drawFunctionPatterns(modules);
      build(modules, mask);
      return QrCode(
        version: version,
        level: level,
        mask: mask,
        modules: finalizeModules(modules),
      );
    }

    // --- mask selection by penalty (each mask evaluated on a fresh grid) --
    int bestPenalty = -1;
    var bestMask = 0;
    for (var candidate = 0; candidate < 8; candidate++) {
      final modules = freshModules();
      drawFunctionPatterns(modules);
      build(modules, candidate, test: true);
      final penalty = penaltyScore(modules, size);
      if (bestPenalty == -1 || penalty < bestPenalty) {
        bestPenalty = penalty;
        bestMask = candidate;
      }
    }
    final modules = freshModules();
    drawFunctionPatterns(modules);
    build(modules, bestMask);
    return QrCode(
      version: version,
      level: level,
      mask: bestMask,
      modules: finalizeModules(modules),
    );
  }
}

// ---------------------------------------------------------------------------
// Reed-Solomon / GF(256)
// ---------------------------------------------------------------------------

const int _pad0 = 0xEC;
const int _pad1 = 0x11;
const int _bchFormatGen = 0x537;
const int _bchFormatMask = 0x5412;
const int _bchVersionGen = 0x1F25;

/// GF(256) with the QR primitive polynomial 0x11D (alpha = 0x02).
class _Gf256 {
  _Gf256() {
    var x = 1;
    for (var i = 0; i < 255; i++) {
      _exp[i] = x;
      _log[x] = i;
      x <<= 1;
      if ((x & 0x100) != 0) x ^= 0x11D;
    }
    for (var i = 255; i < 512; i++) {
      _exp[i] = _exp[i - 255];
    }
  }

  final List<int> _exp = List<int>.filled(512, 0);
  final List<int> _log = List<int>.filled(256, 0);

  int exp(int n) => _exp[n % 255];

  int log(int n) => _log[n];

  static final _Gf256 instance = _Gf256();
}

/// QR generator polynomial of degree [deg], highest-degree-first, monic:
/// `prod_{i=0}^{deg-1} (x + alpha^i)`.
List<int> _generatorPoly(int deg) {
  final gf = _Gf256.instance;
  var g = <int>[1]; // highest-degree-first
  for (var i = 0; i < deg; i++) {
    final nxt = List<int>.filled(g.length + 1, 0);
    for (var j = 0; j < g.length; j++) {
      final c = g[j];
      if (c != 0) {
        nxt[j] ^= c; // x * g
        nxt[j + 1] ^= gf.exp(gf.log(c) + i); // alpha^i * g
      }
    }
    g = nxt;
  }
  return g;
}

/// Reed-Solomon EC codewords for [dataCodewords] with [ecCount] EC bytes.
///
/// The result is the remainder of `data(x) * x^ecCount` divided by the QR
/// generator polynomial, highest-degree-first, length [ecCount].
List<int> rsEncode(List<int> dataCodewords, int ecCount) {
  final gf = _Gf256.instance;
  final gen = _generatorPoly(ecCount);
  final dividend = <int>[...dataCodewords, ...List<int>.filled(ecCount, 0)];
  while (dividend.length > ecCount) {
    if (dividend.first == 0) {
      dividend.removeAt(0);
      continue;
    }
    // Monic divisor: the leading terms cancel by plain XOR.
    final ratio = dividend.first;
    for (var i = 0; i <= ecCount; i++) {
      final coeff = gen[i];
      if (coeff != 0) {
        dividend[i] ^= gf.exp(gf.log(coeff) + gf.log(ratio));
      }
    }
    dividend.removeAt(0);
  }
  return dividend;
}

/// 15-bit BCH for the 5-bit [data] (2 EC bits + 3 mask bits).
int bchFormatInfo(int data) {
  var d = data << 10;
  final g = _bchFormatGen;
  while (_bitLength(d) - _bitLength(g) >= 0) {
    d ^= g << (_bitLength(d) - _bitLength(g));
  }
  return ((data << 10) | d) ^ _bchFormatMask;
}

/// 18-bit BCH for the 6-bit version number [data] (7..40).
int bchVersionInfo(int data) {
  var d = data << 12;
  final g = _bchVersionGen;
  while (_bitLength(d) - _bitLength(g) >= 0) {
    d ^= g << (_bitLength(d) - _bitLength(g));
  }
  return (data << 12) | d;
}

int _bitLength(int n) {
  var bits = 0;
  while (n > 0) {
    n >>= 1;
    bits++;
  }
  return bits;
}

/// Whether ISO mask pattern [pattern] (0..7) matches [row]/[col].
bool maskMatches(int pattern, int row, int col) {
  switch (pattern) {
    case 0:
      return (row + col) % 2 == 0;
    case 1:
      return row % 2 == 0;
    case 2:
      return col % 3 == 0;
    case 3:
      return (row + col) % 3 == 0;
    case 4:
      return (row ~/ 2 + col ~/ 3) % 2 == 0;
    case 5:
      return ((row * col) % 2) + ((row * col) % 3) == 0;
    case 6:
      return (((row * col) % 2) + ((row * col) % 3)) % 2 == 0;
    case 7:
      return (((row * col) % 3) + ((row + col) % 2)) % 2 == 0;
    default:
      throw ArgumentError.value(pattern, 'pattern', 'must be 0..7');
  }
}

// ---------------------------------------------------------------------------
// ISO penalty rules (mask selection)
// ---------------------------------------------------------------------------

/// Total ISO/IEC 18004 penalty score for a fully-built module grid.
int penaltyScore(List<List<bool?>> modules, int size) {
  var total = 0;

  // N1: runs of >=5 same-colour modules in rows and columns.
  for (var row = 0; row < size; row++) {
    var prev = modules[row][0];
    var length = 0;
    for (var col = 0; col < size; col++) {
      if (modules[row][col] == prev) {
        length += 1;
      } else {
        if (length >= 5) total += length - 2;
        length = 1;
        prev = modules[row][col];
      }
    }
    if (length >= 5) total += length - 2;
  }
  for (var col = 0; col < size; col++) {
    var prev = modules[0][col];
    var length = 0;
    for (var row = 0; row < size; row++) {
      if (modules[row][col] == prev) {
        length += 1;
      } else {
        if (length >= 5) total += length - 2;
        length = 1;
        prev = modules[row][col];
      }
    }
    if (length >= 5) total += length - 2;
  }

  // N2: 2x2 blocks of same colour.
  for (var row = 0; row < size - 1; row++) {
    for (var col = 0; col < size - 1; col++) {
      final c = modules[row][col];
      if (c == modules[row][col + 1] &&
          c == modules[row + 1][col] &&
          c == modules[row + 1][col + 1]) {
        total += 3;
      }
    }
  }

  // N3: 1:1:3:1:1 (dark) pattern with a 4-module light run on either side.
  const p1 = [true, false, true, true, true, false, true, false, false, false, false];
  const p2 = [false, false, false, false, true, false, true, true, true, false, true];
  bool matchesAt(int row, int col, List<bool> pattern) {
    for (var i = 0; i < 11; i++) {
      if (modules[row][col + i] != pattern[i]) return false;
    }
    return true;
  }

  for (var row = 0; row < size; row++) {
    for (var col = 0; col <= size - 11; col++) {
      if (matchesAt(row, col, p1)) total += 40;
      if (matchesAt(row, col, p2)) total += 40;
    }
  }
  for (var col = 0; col < size; col++) {
    for (var row = 0; row <= size - 11; row++) {
      var hitP1 = true;
      var hitP2 = true;
      for (var i = 0; i < 11; i++) {
        if (modules[row + i][col] != p1[i]) hitP1 = false;
        if (modules[row + i][col] != p2[i]) hitP2 = false;
        if (!hitP1 && !hitP2) break;
      }
      if (hitP1) total += 40;
      if (hitP2) total += 40;
    }
  }

  // N4: dark-module ratio. Exact integer arithmetic matching the spec:
  // floor(|percent*100 - 50| / 5) * 10 with percent = dark/total.
  var dark = 0;
  for (var row = 0; row < size; row++) {
    for (var col = 0; col < size; col++) {
      if (modules[row][col] == true) dark++;
    }
  }
  final num = (dark * 100 - 50 * size * size).abs();
  total += (num ~/ (5 * size * size)) * 10;
  return total;
}

// ---------------------------------------------------------------------------
// ISO/IEC 18004 tables
// ---------------------------------------------------------------------------

/// EC format bits (2 bits) used in the format information, indexed by
/// [QrErrorLevel.index] (L, M, Q, H).
const List<int> _ecFormatBits = [0x1, 0x0, 0x3, 0x2];

/// Alignment pattern centre positions per version (empty for v1).
const List<List<int>> patternPositionTable = [
  const <int>[],
  const <int>[6, 18],
  const <int>[6, 22],
  const <int>[6, 26],
  const <int>[6, 30],
  const <int>[6, 34],
  const <int>[6, 22, 38],
  const <int>[6, 24, 42],
  const <int>[6, 26, 46],
  const <int>[6, 28, 50],
  const <int>[6, 30, 54],
  const <int>[6, 32, 58],
  const <int>[6, 34, 62],
  const <int>[6, 26, 46, 66],
  const <int>[6, 26, 48, 70],
  const <int>[6, 26, 50, 74],
  const <int>[6, 30, 54, 78],
  const <int>[6, 30, 56, 82],
  const <int>[6, 30, 58, 86],
  const <int>[6, 34, 62, 90],
  const <int>[6, 28, 50, 72, 94],
  const <int>[6, 26, 50, 74, 98],
  const <int>[6, 30, 54, 78, 102],
  const <int>[6, 28, 54, 80, 106],
  const <int>[6, 32, 58, 84, 110],
  const <int>[6, 30, 58, 86, 114],
  const <int>[6, 34, 62, 90, 118],
  const <int>[6, 26, 50, 74, 98, 122],
  const <int>[6, 30, 54, 78, 102, 126],
  const <int>[6, 26, 52, 78, 104, 130],
  const <int>[6, 30, 56, 82, 108, 134],
  const <int>[6, 34, 60, 86, 112, 138],
  const <int>[6, 30, 58, 86, 114, 142],
  const <int>[6, 34, 62, 90, 118, 146],
  const <int>[6, 30, 54, 78, 102, 126, 150],
  const <int>[6, 24, 50, 76, 102, 128, 154],
  const <int>[6, 28, 54, 80, 106, 132, 158],
  const <int>[6, 32, 58, 84, 110, 136, 162],
  const <int>[6, 26, 54, 82, 110, 138, 166],
  const <int>[6, 30, 58, 86, 114, 142, 170],
];

/// RS block table: for each version 1..40 and level (L, M, Q, H) a list of
/// `[count, totalCodewords, dataCodewords]` triples. ISO/IEC 18004 Table 9.
const List<List<List<int>>> rsBlockTable = [
  // version 1
  const <List<int>>[const <int>[1, 26, 19]],
  const <List<int>>[const <int>[1, 26, 16]],
  const <List<int>>[const <int>[1, 26, 13]],
  const <List<int>>[const <int>[1, 26, 9]],
  // version 2
  const <List<int>>[const <int>[1, 44, 34]],
  const <List<int>>[const <int>[1, 44, 28]],
  const <List<int>>[const <int>[1, 44, 22]],
  const <List<int>>[const <int>[1, 44, 16]],
  // version 3
  const <List<int>>[const <int>[1, 70, 55]],
  const <List<int>>[const <int>[1, 70, 44]],
  const <List<int>>[const <int>[2, 35, 17]],
  const <List<int>>[const <int>[2, 35, 13]],
  // version 4
  const <List<int>>[const <int>[1, 100, 80]],
  const <List<int>>[const <int>[2, 50, 32]],
  const <List<int>>[const <int>[2, 50, 24]],
  const <List<int>>[const <int>[4, 25, 9]],
  // version 5
  const <List<int>>[const <int>[1, 134, 108]],
  const <List<int>>[const <int>[2, 67, 43]],
  const <List<int>>[const <int>[2, 33, 15], <int>[2, 34, 16]],
  const <List<int>>[const <int>[2, 33, 11], <int>[2, 34, 12]],
  // version 6
  const <List<int>>[const <int>[2, 86, 68]],
  const <List<int>>[const <int>[4, 43, 27]],
  const <List<int>>[const <int>[4, 43, 19]],
  const <List<int>>[const <int>[4, 43, 15]],
  // version 7
  const <List<int>>[const <int>[2, 98, 78]],
  const <List<int>>[const <int>[4, 49, 31]],
  const <List<int>>[const <int>[2, 32, 14], <int>[4, 33, 15]],
  const <List<int>>[const <int>[4, 39, 13], <int>[1, 40, 14]],
  // version 8
  const <List<int>>[const <int>[2, 121, 97]],
  const <List<int>>[const <int>[2, 60, 38], <int>[2, 61, 39]],
  const <List<int>>[const <int>[4, 40, 18], <int>[2, 41, 19]],
  const <List<int>>[const <int>[4, 40, 14], <int>[2, 41, 15]],
  // version 9
  const <List<int>>[const <int>[2, 146, 116]],
  const <List<int>>[const <int>[3, 58, 36], <int>[2, 59, 37]],
  const <List<int>>[const <int>[4, 36, 16], <int>[4, 37, 17]],
  const <List<int>>[const <int>[4, 36, 12], <int>[4, 37, 13]],
  // version 10
  const <List<int>>[const <int>[2, 86, 68], <int>[2, 87, 69]],
  const <List<int>>[const <int>[4, 69, 43], <int>[1, 70, 44]],
  const <List<int>>[const <int>[6, 43, 19], <int>[2, 44, 20]],
  const <List<int>>[const <int>[6, 43, 15], <int>[2, 44, 16]],
  // version 11
  const <List<int>>[const <int>[4, 101, 81]],
  const <List<int>>[const <int>[1, 80, 50], <int>[4, 81, 51]],
  const <List<int>>[const <int>[4, 50, 22], <int>[4, 51, 23]],
  const <List<int>>[const <int>[3, 36, 12], <int>[8, 37, 13]],
  // version 12
  const <List<int>>[const <int>[2, 116, 92], <int>[2, 117, 93]],
  const <List<int>>[const <int>[6, 58, 36], <int>[2, 59, 37]],
  const <List<int>>[const <int>[4, 46, 20], <int>[6, 47, 21]],
  const <List<int>>[const <int>[7, 42, 14], <int>[4, 43, 15]],
  // version 13
  const <List<int>>[const <int>[4, 133, 107]],
  const <List<int>>[const <int>[8, 59, 37], <int>[1, 60, 38]],
  const <List<int>>[const <int>[8, 44, 20], <int>[4, 45, 21]],
  const <List<int>>[const <int>[12, 33, 11], <int>[4, 34, 12]],
  // version 14
  const <List<int>>[const <int>[3, 145, 115], <int>[1, 146, 116]],
  const <List<int>>[const <int>[4, 64, 40], <int>[5, 65, 41]],
  const <List<int>>[const <int>[11, 36, 16], <int>[5, 37, 17]],
  const <List<int>>[const <int>[11, 36, 12], <int>[5, 37, 13]],
  // version 15
  const <List<int>>[const <int>[5, 109, 87], <int>[1, 110, 88]],
  const <List<int>>[const <int>[5, 65, 41], <int>[5, 66, 42]],
  const <List<int>>[const <int>[5, 54, 24], <int>[7, 55, 25]],
  const <List<int>>[const <int>[11, 36, 12], <int>[7, 37, 13]],
  // version 16
  const <List<int>>[const <int>[5, 122, 98], <int>[1, 123, 99]],
  const <List<int>>[const <int>[7, 73, 45], <int>[3, 74, 46]],
  const <List<int>>[const <int>[15, 43, 19], <int>[2, 44, 20]],
  const <List<int>>[const <int>[3, 45, 15], <int>[13, 46, 16]],
  // version 17
  const <List<int>>[const <int>[1, 135, 107], <int>[5, 136, 108]],
  const <List<int>>[const <int>[10, 74, 46], <int>[1, 75, 47]],
  const <List<int>>[const <int>[1, 50, 22], <int>[15, 51, 23]],
  const <List<int>>[const <int>[2, 42, 14], <int>[17, 43, 15]],
  // version 18
  const <List<int>>[const <int>[5, 150, 120], <int>[1, 151, 121]],
  const <List<int>>[const <int>[9, 69, 43], <int>[4, 70, 44]],
  const <List<int>>[const <int>[17, 50, 22], <int>[1, 51, 23]],
  const <List<int>>[const <int>[2, 42, 14], <int>[19, 43, 15]],
  // version 19
  const <List<int>>[const <int>[3, 141, 113], <int>[4, 142, 114]],
  const <List<int>>[const <int>[3, 70, 44], <int>[11, 71, 45]],
  const <List<int>>[const <int>[17, 47, 21], <int>[4, 48, 22]],
  const <List<int>>[const <int>[9, 39, 13], <int>[16, 40, 14]],
  // version 20
  const <List<int>>[const <int>[3, 135, 107], <int>[5, 136, 108]],
  const <List<int>>[const <int>[3, 67, 41], <int>[13, 68, 42]],
  const <List<int>>[const <int>[15, 54, 24], <int>[5, 55, 25]],
  const <List<int>>[const <int>[15, 43, 15], <int>[10, 44, 16]],
  // version 21
  const <List<int>>[const <int>[4, 144, 116], <int>[4, 145, 117]],
  const <List<int>>[const <int>[17, 68, 42]],
  const <List<int>>[const <int>[17, 50, 22], <int>[6, 51, 23]],
  const <List<int>>[const <int>[19, 46, 16], <int>[6, 47, 17]],
  // version 22
  const <List<int>>[const <int>[2, 139, 111], <int>[7, 140, 112]],
  const <List<int>>[const <int>[17, 74, 46]],
  const <List<int>>[const <int>[7, 54, 24], <int>[16, 55, 25]],
  const <List<int>>[const <int>[34, 37, 13]],
  // version 23
  const <List<int>>[const <int>[4, 151, 121], <int>[5, 152, 122]],
  const <List<int>>[const <int>[4, 75, 47], <int>[14, 76, 48]],
  const <List<int>>[const <int>[11, 54, 24], <int>[14, 55, 25]],
  const <List<int>>[const <int>[16, 45, 15], <int>[14, 46, 16]],
  // version 24
  const <List<int>>[const <int>[6, 147, 117], <int>[4, 148, 118]],
  const <List<int>>[const <int>[6, 73, 45], <int>[14, 74, 46]],
  const <List<int>>[const <int>[11, 54, 24], <int>[16, 55, 25]],
  const <List<int>>[const <int>[30, 46, 16], <int>[2, 47, 17]],
  // version 25
  const <List<int>>[const <int>[8, 132, 106], <int>[4, 133, 107]],
  const <List<int>>[const <int>[8, 75, 47], <int>[13, 76, 48]],
  const <List<int>>[const <int>[7, 54, 24], <int>[22, 55, 25]],
  const <List<int>>[const <int>[22, 45, 15], <int>[13, 46, 16]],
  // version 26
  const <List<int>>[const <int>[10, 142, 114], <int>[2, 143, 115]],
  const <List<int>>[const <int>[19, 74, 46], <int>[4, 75, 47]],
  const <List<int>>[const <int>[28, 50, 22], <int>[6, 51, 23]],
  const <List<int>>[const <int>[33, 46, 16], <int>[4, 47, 17]],
  // version 27
  const <List<int>>[const <int>[8, 152, 122], <int>[4, 153, 123]],
  const <List<int>>[const <int>[22, 73, 45], <int>[3, 74, 46]],
  const <List<int>>[const <int>[8, 53, 23], <int>[26, 54, 24]],
  const <List<int>>[const <int>[12, 45, 15], <int>[28, 46, 16]],
  // version 28
  const <List<int>>[const <int>[3, 147, 117], <int>[10, 148, 118]],
  const <List<int>>[const <int>[3, 73, 45], <int>[23, 74, 46]],
  const <List<int>>[const <int>[4, 54, 24], <int>[31, 55, 25]],
  const <List<int>>[const <int>[11, 45, 15], <int>[31, 46, 16]],
  // version 29
  const <List<int>>[const <int>[7, 146, 116], <int>[7, 147, 117]],
  const <List<int>>[const <int>[21, 73, 45], <int>[7, 74, 46]],
  const <List<int>>[const <int>[1, 53, 23], <int>[37, 54, 24]],
  const <List<int>>[const <int>[19, 45, 15], <int>[26, 46, 16]],
  // version 30
  const <List<int>>[const <int>[5, 145, 115], <int>[10, 146, 116]],
  const <List<int>>[const <int>[19, 75, 47], <int>[10, 76, 48]],
  const <List<int>>[const <int>[15, 54, 24], <int>[25, 55, 25]],
  const <List<int>>[const <int>[23, 45, 15], <int>[25, 46, 16]],
  // version 31
  const <List<int>>[const <int>[13, 145, 115], <int>[3, 146, 116]],
  const <List<int>>[const <int>[2, 74, 46], <int>[29, 75, 47]],
  const <List<int>>[const <int>[42, 54, 24], <int>[1, 55, 25]],
  const <List<int>>[const <int>[23, 45, 15], <int>[28, 46, 16]],
  // version 32
  const <List<int>>[const <int>[17, 145, 115]],
  const <List<int>>[const <int>[10, 74, 46], <int>[23, 75, 47]],
  const <List<int>>[const <int>[10, 54, 24], <int>[35, 55, 25]],
  const <List<int>>[const <int>[19, 45, 15], <int>[35, 46, 16]],
  // version 33
  const <List<int>>[const <int>[17, 145, 115], <int>[1, 146, 116]],
  const <List<int>>[const <int>[14, 74, 46], <int>[21, 75, 47]],
  const <List<int>>[const <int>[29, 54, 24], <int>[19, 55, 25]],
  const <List<int>>[const <int>[11, 45, 15], <int>[46, 46, 16]],
  // version 34
  const <List<int>>[const <int>[13, 145, 115], <int>[6, 146, 116]],
  const <List<int>>[const <int>[14, 74, 46], <int>[23, 75, 47]],
  const <List<int>>[const <int>[44, 54, 24], <int>[7, 55, 25]],
  const <List<int>>[const <int>[59, 46, 16], <int>[1, 47, 17]],
  // version 35
  const <List<int>>[const <int>[12, 151, 121], <int>[5, 152, 122]],
  const <List<int>>[const <int>[12, 75, 47], <int>[26, 76, 48]],
  const <List<int>>[const <int>[39, 54, 24], <int>[14, 55, 25]],
  const <List<int>>[const <int>[22, 45, 15], <int>[41, 46, 16]],
  // version 36
  const <List<int>>[const <int>[6, 151, 121], <int>[14, 152, 122]],
  const <List<int>>[const <int>[6, 75, 47], <int>[34, 76, 48]],
  const <List<int>>[const <int>[46, 54, 24], <int>[10, 55, 25]],
  const <List<int>>[const <int>[2, 45, 15], <int>[64, 46, 16]],
  // version 37
  const <List<int>>[const <int>[17, 152, 122], <int>[4, 153, 123]],
  const <List<int>>[const <int>[29, 74, 46], <int>[14, 75, 47]],
  const <List<int>>[const <int>[49, 54, 24], <int>[10, 55, 25]],
  const <List<int>>[const <int>[24, 45, 15], <int>[46, 46, 16]],
  // version 38
  const <List<int>>[const <int>[4, 152, 122], <int>[18, 153, 123]],
  const <List<int>>[const <int>[13, 74, 46], <int>[32, 75, 47]],
  const <List<int>>[const <int>[48, 54, 24], <int>[14, 55, 25]],
  const <List<int>>[const <int>[42, 45, 15], <int>[32, 46, 16]],
  // version 39
  const <List<int>>[const <int>[20, 147, 117], <int>[4, 148, 118]],
  const <List<int>>[const <int>[40, 75, 47], <int>[7, 76, 48]],
  const <List<int>>[const <int>[43, 54, 24], <int>[22, 55, 25]],
  const <List<int>>[const <int>[10, 45, 15], <int>[67, 46, 16]],
  // version 40
  const <List<int>>[const <int>[19, 148, 118], <int>[6, 149, 119]],
  const <List<int>>[const <int>[18, 75, 47], <int>[31, 76, 48]],
  const <List<int>>[const <int>[34, 54, 24], <int>[34, 55, 25]],
  const <List<int>>[const <int>[20, 45, 15], <int>[61, 46, 16]],
];

int _dataBits(List<List<int>> blocks) {
  var bits = 0;
  for (final entry in blocks) {
    bits += entry[0] * entry[2];
  }
  return bits * 8;
}
