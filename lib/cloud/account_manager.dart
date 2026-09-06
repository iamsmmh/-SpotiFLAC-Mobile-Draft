/// SpotiFLAC Cloud account manager (Phase 3).
///
/// The milestone layer over the existing account stack
/// (`ecosystem/account/**`): it owns the *server configuration* (which
/// SpotiFLAC Cloud / self-hosted deployment the app talks to), onboarding
/// (register / sign in / sign out through the configured adapter), and
/// **device registration** — one stable device id per installation so the
/// backend can list and revoke devices and queue hand-off can name them.
///
/// Everything rides on the reference backend contract in
/// `docs/API_CONTRACTS.md` (§1.3) — the same contract the `backend/` module
/// in this repository implements.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/ecosystem/account/account_models.dart';
import 'package:spotiflac_android/ecosystem/account/account_service.dart';
import 'package:spotiflac_android/ecosystem/account/auth_adapters.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('CloudAccount');

/// Where the cloud server endpoint is persisted.
const String cloudServerConfigKey = 'cloud.server.v1';

/// Where the stable device id is persisted.
const String cloudDeviceIdKey = 'cloud.device.id.v1';

/// The configured cloud deployment.
class CloudServerConfig {
  static const CloudServerConfig unconfigured = CloudServerConfig();

  final String baseUrl;

  const CloudServerConfig({this.baseUrl = ''});

  bool get isConfigured => baseUrl.trim().isNotEmpty;

  /// Normalized base URL without a trailing slash.
  String get base => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  CloudServerConfig copyWith({String? baseUrl}) =>
      CloudServerConfig(baseUrl: baseUrl ?? this.baseUrl);

  Map<String, Object?> toJson() => <String, Object?>{'baseUrl': baseUrl};

  static CloudServerConfig fromJson(Map<String, Object?> json) =>
      CloudServerConfig(baseUrl: json['baseUrl']?.toString() ?? '');
}

/// Persists the server configuration and flips the sync backend when it
/// changes.
class CloudServerConfigNotifier extends Notifier<CloudServerConfig> {
  bool _restored = false;

  @override
  CloudServerConfig build() {
    _restore();
    return CloudServerConfig.unconfigured;
  }

  Future<void> _restore() async {
    if (_restored) return;
    _restored = true;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(cloudServerConfigKey);
    if (raw == null || raw.isEmpty || !ref.mounted) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        state = CloudServerConfig.fromJson(
          Map<String, Object?>.from(decoded),
        );
      }
    } on FormatException {
      _log.w('Corrupt cloud server config ignored');
    }
  }

  Future<void> configure(String baseUrl) async {
    final config = CloudServerConfig(baseUrl: baseUrl.trim());
    state = config;
    final prefs = await SharedPreferences.getInstance();
    if (config.isConfigured) {
      await prefs.setString(cloudServerConfigKey, jsonEncode(config.toJson()));
    } else {
      await prefs.remove(cloudServerConfigKey);
    }
  }

  Future<void> disconnect() => configure('');
}

/// One registered device as the backend reports it.
class CloudDevice {
  final String id;
  final String name;
  final String platform;
  final DateTime? lastSeenAt;

  const CloudDevice({
    required this.id,
    required this.name,
    required this.platform,
    this.lastSeenAt,
  });

  static CloudDevice? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final id = map['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return CloudDevice(
      id: id,
      name: map['name']?.toString() ?? '',
      platform: map['platform']?.toString() ?? '',
      lastSeenAt: DateTime.tryParse(map['lastSeenAt']?.toString() ?? ''),
    );
  }

  static List<CloudDevice> listFrom(Object? raw) {
    if (raw is! List) return const <CloudDevice>[];
    return <CloudDevice>[
      for (final entry in raw) ?CloudDevice.tryParse(entry),
    ];
  }
}

/// Outcome of an account operation surfaced to the UI.
class CloudAccountOperation {
  final bool ok;
  final String? error;
  final AccountUser? user;

  const CloudAccountOperation.ok(this.user)
    : ok = true,
      error = null;

  const CloudAccountOperation.failure(this.error)
    : ok = false,
      user = null;
}

/// The manager.
class CloudAccountManager {
  CloudAccountManager({
    required AccountService account,
    required CloudServerConfig server,
    http.Client? client,
    Future<SharedPreferences>? prefs,
  }) : _account = account,
       _server = server,
       _client = client ?? http.Client(),
       _prefs = prefs ?? SharedPreferences.getInstance();

  final AccountService _account;
  final CloudServerConfig _server;
  final http.Client _client;
  final Future<SharedPreferences> _prefs;

  bool get isConfigured => _server.isConfigured && _account.isConfigured;

  AccountState get accountState => _account.state;

  /// Registers the self-hosted adapter against [server] so the existing
  /// account + sync stack can be used as-is. Called by the provider layer
  /// whenever the configuration changes.
  Future<void> applyServerConfig() async {
    if (!_server.isConfigured) return;
    await _account.configureSelfHosted(
      SelfHostedAuthConfig(baseUrl: _server.baseUrl),
    );
  }

  // ---------------------------------------------------------------------------
  // Onboarding
  // ---------------------------------------------------------------------------

  /// Registers a new cloud account. The reference backend derives the
  /// display name server-side (the shared adapter contract posts only
  /// email + password), so [displayName] is advisory for the local profile.
  Future<CloudAccountOperation> signUp({
    required String email,
    required String password,
    String displayName = '',
  }) {
    return _run(() async {
      final session = await _account.signUpWithEmail(
        email: email,
        password: password,
      );
      return session.user;
    });
  }

  Future<CloudAccountOperation> signIn({
    required String email,
    required String password,
  }) => _run(() async {
    final session = await _account.signInWithEmail(
      email: email,
      password: password,
    );
    return session.user;
  });

  Future<void> signOut() => _account.signOut();

  Future<CloudAccountOperation> _run(
    Future<AccountUser> Function() action,
  ) async {
    if (!isConfigured) {
      return const CloudAccountOperation.failure(
        'no cloud server is configured',
      );
    }
    try {
      final user = await action();
      return CloudAccountOperation.ok(user);
    } catch (error) {
      _log.w('Cloud account operation failed: $error');
      return CloudAccountOperation.failure(error.toString());
    }
  }

  // ---------------------------------------------------------------------------
  // Device registration
  // ---------------------------------------------------------------------------

  /// The stable per-installation device id (created on first use).
  Future<String> deviceId() async {
    final prefs = await _prefs;
    final existing = prefs.getString(cloudDeviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final id = _generateDeviceId();
    await prefs.setString(cloudDeviceIdKey, id);
    return id;
  }

  static String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return 'dev_${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }

  Map<String, String> _authHeaders(String token) => <String, String>{
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  /// Registers this installation with the backend (idempotent).
  Future<CloudDevice?> registerDevice({required String name, required String platform}) async {
    final token = await _account.accessToken();
    if (token == null || !_server.isConfigured) return null;
    final id = await deviceId();
    try {
      final response = await _client.post(
        Uri.parse('${_server.base}/v1/auth/devices'),
        headers: _authHeaders(token),
        body: jsonEncode(<String, Object?>{
          'deviceId': id,
          'name': name,
          'platform': platform,
        }),
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        _log.w('Device registration failed: ${response.statusCode}');
        return null;
      }
      final decoded = jsonDecode(response.body);
      final devices = CloudDevice.listFrom(decoded is Map ? decoded['devices'] : null);
      for (final device in devices) {
        if (device.id == id) return device;
      }
      return null;
    } catch (error) {
      _log.w('Device registration failed: $error');
      return null;
    }
  }

  /// Lists the devices registered for the signed-in account.
  Future<List<CloudDevice>> listDevices() async {
    final token = await _account.accessToken();
    if (token == null || !_server.isConfigured) {
      return const <CloudDevice>[];
    }
    try {
      final response = await _client
          .get(
            Uri.parse('${_server.base}/v1/auth/devices'),
            headers: _authHeaders(token),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return const <CloudDevice>[];
      final decoded = jsonDecode(response.body);
      return CloudDevice.listFrom(decoded is Map ? decoded['devices'] : null);
    } catch (error) {
      _log.w('Device list failed: $error');
      return const <CloudDevice>[];
    }
  }

  /// Revokes a device (and thereby its refresh tokens server-side).
  Future<bool> revokeDevice(String deviceId) async {
    final token = await _account.accessToken();
    if (token == null || !_server.isConfigured) return false;
    try {
      final response = await _client
          .delete(
            Uri.parse('${_server.base}/v1/auth/devices/$deviceId'),
            headers: _authHeaders(token),
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200;
    } catch (error) {
      _log.w('Device revoke failed: $error');
      return false;
    }
  }
}
