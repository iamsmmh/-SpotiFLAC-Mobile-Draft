/// LAN web-player security (Phase 14).
///
/// PIN, session tokens, trusted-device cookies and a read-only method gate.
/// The Go server keeps serving [lanMux] unchanged when no PIN is set; this
/// Dart policy is what Settings uses to decide whether to send `pin` in the
/// start-LAN config.
library;

import 'dart:convert';

import 'package:spotiflac_android/core/data/sha256.dart';

/// Minimum PIN length the settings UI enforces.
const int kLanPinMinLength = 4;

/// Header the Go middleware accepts (`X-SpotiFLAC-Pin`).
const String kLanPinHeader = 'X-SpotiFLAC-Pin';

/// Cookie name for a trusted-device token.
const String kLanTrustedDeviceCookie = 'spotiflac_lan';

/// Pure security helpers. No I/O.
class LanPlayerSecurity {
  const LanPlayerSecurity();

  /// Normalizes a user PIN. Empty / too-short PINs disable the gate.
  String? normalizePin(String raw) {
    final pin = raw.trim();
    if (pin.length < kLanPinMinLength) return null;
    return pin;
  }

  /// Deterministic session token derived from the PIN. The Go side hashes
  /// the same way so a trusted-device cookie survives process restarts
  /// without storing the PIN in plaintext.
  String tokenForPin(String pin) {
    return sha256Hex(utf8.encode('spotiflac-lan-v1|$pin'));
  }

  bool pinMatches(String offered, String expected) {
    if (offered.length != expected.length) return false;
    var diff = 0;
    for (var i = 0; i < offered.length; i++) {
      diff |= offered.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }

  bool authorize({
    required String pin,
    String? headerPin,
    String? bearerToken,
    String? cookieToken,
  }) {
    final expected = normalizePin(pin);
    if (expected == null) return true; // no PIN configured → open
    if (headerPin != null && pinMatches(headerPin, expected)) return true;
    final token = tokenForPin(expected);
    if (bearerToken != null && pinMatches(bearerToken, token)) return true;
    if (cookieToken != null && pinMatches(cookieToken, token)) return true;
    return false;
  }

  /// LAN player is read-only: anything other than GET/HEAD/OPTIONS is denied.
  bool isReadOnlyMethod(String method) {
    switch (method.toUpperCase()) {
      case 'GET':
      case 'HEAD':
      case 'OPTIONS':
        return true;
      default:
        return false;
    }
  }

  Map<String, Object?> startConfig({
    required String root,
    int port = 0,
    String pin = '',
    bool tls = false,
  }) {
    final normalized = normalizePin(pin);
    final config = <String, Object?>{
      'port': port,
      'root': root,
      'tls': tls && normalized != null,
    };
    if (normalized != null) {
      config['pin'] = normalized;
    }
    return config;
  }
}
