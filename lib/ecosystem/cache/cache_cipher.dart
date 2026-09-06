/// ChaCha20 stream cipher for cache at-rest encryption (Feature Group 7).
///
/// Implemented in pure Dart for the same reason the core keeps its own
/// SHA-256: avoiding a new third-party dependency in a verified build.
/// Conforms to RFC 8439 (the original ChaCha20 construction with a 96-bit
/// nonce and a 32-bit block counter — the IETF AEAD nonce layout). The
/// round function and block generation follow §2.3/§2.4 of the RFC; test
/// vectors live in `test/cache_cipher_test.dart`.
///
/// Security scope: this encrypts *cache artifacts at rest* with a key held
/// in the platform secure store. It is not a DRM mechanism — the app only
/// caches sources whose providers permit offline caching.
library;

import 'dart:math' as math;

const int _mask32 = 0xFFFFFFFF;

int _rotl(int value, int shift) =>
    ((value << shift) | (value >> (32 - shift))) & _mask32;

/// Computes the 64-byte ChaCha20 block for [key], [nonce], [counter].
///
/// Exposed for tests; production code uses [ChaCha20.processBytes].
List<int> chacha20Block(
  List<int> key,
  List<int> nonce,
  int counter,
) {
  final constants = <int>[0x61707865, 0x3320646e, 0x79622d32, 0x6b206574];
  final state = <int>[
    ...constants,
    for (var i = 0; i < 8; i++) key[i * 4 + 0] |
        (key[i * 4 + 1] << 8) |
        (key[i * 4 + 2] << 16) |
        (key[i * 4 + 3] << 24),
    counter & _mask32,
    nonce[0] |
        (nonce[1] << 8) |
        (nonce[2] << 16) |
        (nonce[3] << 24),
    nonce[4] |
        (nonce[5] << 8) |
        (nonce[6] << 16) |
        (nonce[7] << 24),
    nonce[8] |
        (nonce[9] << 8) |
        (nonce[10] << 16) |
        (nonce[11] << 24),
  ];

  final working = List<int>.of(state);
  for (var round = 0; round < 10; round++) {
    // Column rounds
    _quarterRound(working, 0, 4, 8, 12);
    _quarterRound(working, 1, 5, 9, 13);
    _quarterRound(working, 2, 6, 10, 14);
    _quarterRound(working, 3, 7, 11, 15);
    // Diagonal rounds
    _quarterRound(working, 0, 5, 10, 15);
    _quarterRound(working, 1, 6, 11, 12);
    _quarterRound(working, 2, 7, 8, 13);
    _quarterRound(working, 3, 4, 9, 14);
  }

  final out = <int>[];
  for (var i = 0; i < 16; i++) {
    final word = (working[i] + state[i]) & _mask32;
    out.add(word & 0xFF);
    out.add((word >> 8) & 0xFF);
    out.add((word >> 16) & 0xFF);
    out.add((word >> 24) & 0xFF);
  }
  return out;
}

void _quarterRound(List<int> s, int a, int b, int c, int d) {
  s[a] = (s[a] + s[b]) & _mask32;
  s[d] = _rotl(s[d] ^ s[a], 16);
  s[c] = (s[c] + s[d]) & _mask32;
  s[b] = _rotl(s[b] ^ s[c], 12);
  s[a] = (s[a] + s[b]) & _mask32;
  s[d] = _rotl(s[d] ^ s[a], 8);
  s[c] = (s[c] + s[d]) & _mask32;
  s[b] = _rotl(s[b] ^ s[c], 7);
}

/// One-shot ChaCha20 cipher instance over a message (encrypt == decrypt:
/// XOR with the keystream).
class ChaCha20 {
  ChaCha20({required this.key, required this.nonce})
    : assert(key.length == 32, 'ChaCha20 key must be 32 bytes'),
      assert(nonce.length == 12, 'IETF ChaCha20 nonce must be 12 bytes');

  final List<int> key;
  final List<int> nonce;

  /// Processes [input] (any length) against the keystream starting at
  /// [initialCounter] (1 per RFC 8439 §2.4.2 — block counter 0 is reserved
  /// for the AEAD key-masking block). Returns a new byte list; [input] is
  /// not modified.
  List<int> processBytes(List<int> input, {int initialCounter = 1}) {
    final output = List<int>.filled(input.length, 0);
    var counter = initialCounter;
    for (var offset = 0; offset < input.length; offset += 64) {
      final keystream = chacha20Block(key, nonce, counter);
      counter = (counter + 1) & _mask32;
      final blockEnd = (offset + 64 > input.length)
          ? input.length
          : offset + 64;
      for (var i = offset; i < blockEnd; i++) {
        output[i] = (input[i] ^ keystream[i - offset]) & 0xFF;
      }
    }
    return output;
  }
}

/// Hex helpers shared by the cache module (IV persistence).
String bytesToHex(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write((byte & 0xFF).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

List<int> hexToBytes(String hex) {
  final clean = hex.trim();
  final out = <int>[];
  for (var i = 0; i + 1 < clean.length; i += 2) {
    final byte = int.tryParse(clean.substring(i, i + 2), radix: 16);
    if (byte == null) return const <int>[];
    out.add(byte);
  }
  return out;
}

/// Generates a random 32-byte key from the platform CSPRNG.
List<int> generateCacheKey() {
  final random = math.Random.secure();
  return List<int>.generate(32, (_) => random.nextInt(256));
}

/// Generates a random 12-byte (96-bit) nonce from the platform CSPRNG.
List<int> generateCacheNonce() {
  final random = math.Random.secure();
  return List<int>.generate(12, (_) => random.nextInt(256));
}
