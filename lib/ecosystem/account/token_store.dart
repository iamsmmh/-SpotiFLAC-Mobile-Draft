/// Secure credential persistence for account sessions (Feature Group 1).
///
/// Split by sensitivity, mirroring the extension-credential policy:
///   * **tokens** (access/refresh JWTs) → platform secure store
///     (`SecureStore`), i.e. Android EncryptedSharedPreferences / iOS
///     Keychain. Never in `SharedPreferences`, never in SQLite, never logged.
///   * **non-secret profile + handles** → the ecosystem database
///     (`ec_account_state`) so the UI can paint the account page before the
///     keystore unlocks on a locked device.
///
/// Keys are namespaced `account.<providerId>.<field>`; the secure store turns
/// that into `spotiflac.token.account.<providerId>.<field>`.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;
import 'package:spotimusic/core/data/secure_store.dart';
import 'package:spotimusic/ecosystem/account/account_models.dart';
import 'package:spotimusic/ecosystem/ecosystem_database.dart';

/// Everything needed to silently restore a session, minus the secrets.
class StoredCredentials {
  const StoredCredentials({
    required this.providerId,
    required this.user,
    this.accessToken,
    this.refreshToken,
    this.expiresAtEpochMs,
    this.issuedAtEpochMs,
  });

  final String providerId;
  final AccountUser user;
  final String? accessToken;
  final String? refreshToken;
  final int? expiresAtEpochMs;
  final int? issuedAtEpochMs;

  bool get hasAnyToken =>
      (accessToken?.isNotEmpty ?? false) || (refreshToken?.isNotEmpty ?? false);

  AccountSession toSession() => AccountSession(
    user: user,
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: expiresAtEpochMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            expiresAtEpochMs!,
            isUtc: true,
          ),
    issuedAt: issuedAtEpochMs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(
            issuedAtEpochMs!,
            isUtc: true,
          ),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'providerId': providerId,
    'user': user.toJson(),
    'accessToken': accessToken,
    'refreshToken': refreshToken,
    'expiresAtEpochMs': expiresAtEpochMs,
    'issuedAtEpochMs': issuedAtEpochMs,
  };

  static StoredCredentials? tryParse(Map<String, Object?> json) {
    final providerId = json['providerId']?.toString();
    final rawUser = json['user'];
    if (providerId == null || providerId.isEmpty || rawUser is! Map) {
      return null;
    }
    final user = AccountUser.tryParse(Map<String, Object?>.from(rawUser));
    if (user == null) return null;
    int? asInt(Object? value) =>
        value is num ? value.toInt() : int.tryParse(value?.toString() ?? '');
    return StoredCredentials(
      providerId: providerId,
      user: user,
      accessToken: json['accessToken']?.toString(),
      refreshToken: json['refreshToken']?.toString(),
      expiresAtEpochMs: asInt(json['expiresAtEpochMs']),
      issuedAtEpochMs: asInt(json['issuedAtEpochMs']),
    );
  }

  @override
  String toString() =>
      'StoredCredentials($providerId, ${user.id}, hasToken: $hasAnyToken)';
}

/// Reads/writes the secure part of a session.
class AccountTokenStore {
  AccountTokenStore(this._secure, {EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final SecureStore _secure;
  final EcosystemDatabase _database;

  static const String _profileMetaKey = 'account_profile_v1';
  static const String _activeProviderKey = 'account_active_provider_v1';

  String _key(String providerId, String field) => 'account.$providerId.$field';

  /// Persists [session] for [providerId]. Tokens go to the keystore, the
  /// profile mirror to SQLite.
  Future<void> persist(String providerId, AccountSession session) async {
    try {
      final access = session.accessToken;
      if (access != null && access.isNotEmpty) {
        await _secure.writeToken(_key(providerId, 'access'), access);
      }
      final refresh = session.refreshToken;
      if (refresh != null && refresh.isNotEmpty) {
        await _secure.writeToken(_key(providerId, 'refresh'), refresh);
      }
      await _secure.writeToken(
        _key(providerId, 'expires'),
        session.expiresAt == null
            ? '0'
            : '${session.expiresAt!.toUtc().millisecondsSinceEpoch}',
      );
      await _secure.writeToken(
        _key(providerId, 'issued'),
        '${session.issuedAt.toUtc().millisecondsSinceEpoch}',
      );
      await _secure.writeToken(_key(providerId, 'user'), _encode(session.user));
    } catch (_) {
      // A locked keystore must not break sign-in: the in-memory session is
      // still valid for this run, it just will not survive a restart.
    }
    await _writeActiveProvider(providerId);
    await _mirrorProfile(session.user);
  }

  Future<StoredCredentials?> read(String providerId) async {
    String? access;
    String? refresh;
    String? encodedUser;
    String? expiresRaw;
    String? issuedRaw;
    try {
      access = await _secure.readToken(_key(providerId, 'access'));
      refresh = await _secure.readToken(_key(providerId, 'refresh'));
      expiresRaw = await _secure.readToken(_key(providerId, 'expires'));
      issuedRaw = await _secure.readToken(_key(providerId, 'issued'));
      encodedUser = await _secure.readToken(_key(providerId, 'user'));
    } catch (_) {
      // Keystore unavailable (device locked / plugin missing) — fall back to
      // the non-secret profile mirror so the UI stays truthful.
      final mirrored = await readMirroredProfile();
      if (mirrored == null) return null;
      return StoredCredentials(
        providerId: providerId,
        user: mirrored,
      );
    }

    AccountUser? user;
    if (encodedUser != null && encodedUser.isNotEmpty) {
      user = _decodeUser(encodedUser);
    }
    user ??= await readMirroredProfile();
    if (user == null) return null;

    return StoredCredentials(
      providerId: providerId,
      user: user,
      accessToken: access,
      refreshToken: refresh,
      expiresAtEpochMs: int.tryParse(expiresRaw ?? ''),
      issuedAtEpochMs: int.tryParse(issuedRaw ?? ''),
    );
  }

  /// Scrubs every secret held for [providerId] and clears the profile mirror.
  Future<void> clear(String providerId) async {
    for (final field in const <String>['access', 'refresh', 'expires', 'issued', 'user']) {
      try {
        await _secure.deleteToken(_key(providerId, field));
      } catch (_) {
        // Best effort: a missing key is already the desired state.
      }
    }
    await _clearMirror();
  }

  Future<String?> readActiveProvider() async {
    try {
      return await _secure.readToken(_activeProviderKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeActiveProvider(String providerId) async {
    try {
      await _secure.writeToken(_activeProviderKey, providerId);
    } catch (_) {
      // Non-fatal: restore falls back to scanning the mirrored profile.
    }
  }

  // -------------------------------------------------------------------------
  // Non-secret profile mirror (survives a locked keystore)
  // -------------------------------------------------------------------------

  Future<void> _mirrorProfile(AccountUser user) async {
    try {
      final db = await _database.database;
      await db.insert(tableAccountState, <String, Object?>{
        'id': 1,
        'provider_id': user.providerId,
        'user_id': user.id,
        'email': user.email,
        'display_name': user.displayName ?? '',
        'avatar_url': user.avatarUrl,
        'is_guest': user.isGuest ? 1 : 0,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _database.writeMeta(
        _profileMetaKey,
        jsonEncode(user.toJson()),
      );
    } catch (_) {
      // The mirror is an optimization; never fail an auth flow for it.
    }
  }

  Future<AccountUser?> readMirroredProfile() async {
    try {
      final raw = await _database.readMeta(_profileMetaKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          final user = AccountUser.tryParse(Map<String, Object?>.from(decoded));
          if (user != null) return user;
        }
      }
      final db = await _database.database;
      final rows = await db.query(tableAccountState, limit: 1);
      if (rows.isEmpty) return null;
      final row = rows.first;
      final id = row['user_id']?.toString() ?? '';
      if (id.isEmpty) return null;
      return AccountUser(
        id: id,
        providerId: row['provider_id']?.toString() ?? '',
        email: row['email']?.toString() ?? '',
        displayName: (row['display_name']?.toString() ?? '').isEmpty
            ? null
            : row['display_name']!.toString(),
        avatarUrl: row['avatar_url']?.toString(),
        isGuest: row['is_guest'] == 1,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearMirror() async {
    try {
      final db = await _database.database;
      await db.delete(tableAccountState);
      await _database.writeMeta(_profileMetaKey, '');
    } catch (_) {
      // Best effort.
    }
  }

  static String _encode(AccountUser user) => jsonEncode(user.toJson());

  static AccountUser? _decodeUser(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return AccountUser.tryParse(Map<String, Object?>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}
