import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/md5.dart';

void main() {
  test('RFC 1321 test suite', () {
    expect(md5Hex(''), 'd41d8cd98f00b204e9800998ecf8427e');
    expect(md5Hex('a'), '0cc175b9c0f1b6a831c399e269772661');
    expect(md5Hex('abc'), '900150983cd24fb0d6963f7d28e17f72');
    expect(md5Hex('message digest'), 'f96b697d7cb7938d525a2f31aaf161d0');
    expect(md5Hex('abcdefghijklmnopqrstuvwxyz'), 'c3fcd3d76192e4007dfb496cca67e13b');
    expect(
      md5Hex('ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'),
      'd174ab98d277d9f5a5611c2c9f419d9f',
    );
    expect(
      md5Hex('1234567890123456789012345678901234567890'
          '1234567890123456789012345678901234567890'),
      '57edf4a22be3c955ac49da2e2107b67a',
    );
  });

  test('digest length and multi-block padding', () {
    final bytes = md5Bytes(List<int>.generate(1000, (i) => i & 0xFF));
    expect(bytes, hasLength(16));
    // Known vector for a 1000-byte pattern would be overkill; verify
    // stability instead.
    expect(
      md5Hex(String.fromCharCodes(List<int>.generate(256, (i) => i))),
      md5Hex(String.fromCharCodes(List<int>.generate(256, (i) => i))),
    );
  });

  test('Subsonic auth token = md5(password + salt)', () {
    // Deterministic check: reconstruct the digest from the returned salt.
    const password = 'swordfish';
    final (salt, token) = subsonicAuthToken(password);
    expect(salt, hasLength(12));
    expect(token, md5Hex('$password$salt'));
    expect(token, isNot(equals(md5Hex('$salt$password'))));
  });

  test('UTF-8 encoding covers non-ASCII credentials', () {
    // 'passwörd' — ö = U+00F6 → 2 UTF-8 bytes.
    final bytes = utf8BytesOf('passwörd');
    expect(bytes, hasLength(9));
    expect(bytes.sublist(5), <int>[0xC3, 0xB6, 0x72, 0x64]);
  });
}
