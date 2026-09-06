/// SpotiFLAC Cloud service (Phase 3) — the concrete `CloudSyncProvider`
/// backed by a SpotiFLAC Cloud / self-hosted deployment implementing the
/// wire contract in `backend/` (see `docs/API_CONTRACTS.md`).
///
/// Pull/push delegate to the existing [SelfHostedSyncAdapter] so the merge
/// semantics stay identical across backends; this class adds the
/// SpotiFLAC-specific surfaces the milestone needs on top:
///
/// * playlist **share links** (`POST /v1/playlists/share`,
///   `GET /v1/playlists/shared/{slug}`) consumed by the QR/social layer;
/// * the **backup gateway** (`/v1/backup`) consumed by
///   `cloud_backup_manager.dart`;
/// * a thin `health()` probe used by the settings UI.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:spotiflac_android/core/sync/cloud_sync_provider.dart';
import 'package:spotiflac_android/core/sync/sync_entities.dart';
import 'package:spotiflac_android/ecosystem/account/account_service.dart';
import 'package:spotiflac_android/ecosystem/sync/cloud_sync_adapters.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SpotiFlacCloud');

/// A public playlist share as the backend resolves it.
class CloudPlaylistShare {
  final String slug;
  final Map<String, Object?> payload;
  final int views;

  const CloudPlaylistShare({
    required this.slug,
    required this.payload,
    required this.views,
  });

  String get title => payload['title']?.toString() ?? '';

  static CloudPlaylistShare? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final slug = map['slug']?.toString() ?? '';
    if (slug.isEmpty) return null;
    return CloudPlaylistShare(
      slug: slug,
      payload: Map<String, Object?>.from(
        (map['payload'] as Map?) ?? const <String, Object?>{},
      ),
      views: (map['views'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Summary of one stored cloud backup.
class CloudBackupSummary {
  final String id;
  final String deviceId;
  final int sizeBytes;
  final String sha256;
  final DateTime? createdAt;

  const CloudBackupSummary({
    required this.id,
    required this.deviceId,
    required this.sizeBytes,
    required this.sha256,
    this.createdAt,
  });

  static CloudBackupSummary? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final backup = Map<String, Object?>.from(
      (map['backup'] as Map?) ?? map,
    );
    final id = backup['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    return CloudBackupSummary(
      id: id,
      deviceId: backup['deviceId']?.toString() ?? '',
      sizeBytes: (backup['sizeBytes'] as num?)?.toInt() ?? 0,
      sha256: backup['sha256']?.toString() ?? '',
      createdAt: DateTime.tryParse(backup['createdAt']?.toString() ?? ''),
    );
  }

  static List<CloudBackupSummary> listFrom(Object? raw) {
    if (raw is! Map) return const <CloudBackupSummary>[];
    final backups = (raw as Map)['backups'];
    if (backups is! List) return const <CloudBackupSummary>[];
    return <CloudBackupSummary>[
      for (final entry in backups) ?CloudBackupSummary.tryParse(entry),
    ];
  }
}

/// The concrete provider.
class SpotiFlacCloudService implements CloudSyncProvider {
  SpotiFlacCloudService({
    required String baseUrl,
    required AccountService account,
    http.Client? client,
  }) : _base = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
       _account = AccountServiceAuthBridge(account),
       _client = client ?? http.Client(),
       _ownsClient = client == null {
    _adapter = SelfHostedSyncAdapter(
      config: SelfHostedSyncConfig(baseUrl: baseUrl),
      auth: _account,
    );
  }

  final String _base;
  final AccountServiceAuthBridge _account;
  final http.Client _client;
  final bool _ownsClient;
  late final SelfHostedSyncAdapter _adapter;

  void dispose() {
    if (_ownsClient) _client.close();
  }

  @override
  String get id => 'spotiflac-cloud';

  @override
  String get displayName => _base;

  // -- CloudSyncProvider delegation -------------------------------------------

  @override
  Future<UserProfile?> currentUser() => _account.currentUser();

  @override
  Future<UserProfile> signIn(Map<String, Object?> credentials) =>
      _account.signIn(credentials);

  @override
  Future<void> signOut() => _account.signOut();

  /// A usable access token for the cloud endpoints, or null when signed out.
  Future<String?> accessToken() => _account.accessToken();

  @override
  Future<List<SyncRecord>> pull(SyncScope scope, {int? sinceRevision}) =>
      _adapter.pull(scope, sinceRevision: sinceRevision);

  @override
  Future<Map<String, int>> push(SyncScope scope, List<SyncRecord> records) =>
      _adapter.push(scope, records);

  // -- Diagnostics -------------------------------------------------------------

  /// `GET /healthz` on the deployment; false when unreachable.
  Future<bool> health() async {
    if (_base.isEmpty) return false;
    try {
      final response = await _client
          .get(Uri.parse('$_base/healthz'))
          .timeout(const Duration(seconds: 8));
      return response.statusCode == 200;
    } catch (error) {
      _log.w('health probe failed: $error');
      return false;
    }
  }

  // -- Playlist sharing ---------------------------------------------------------

  Map<String, String> _headers(String token) => <String, String>{
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  /// Publishes (or refreshes) a share link for a playlists-scope record.
  Future<CloudPlaylistShare?> publishShare({
    required String token,
    required String recordId,
    required Map<String, Object?> payload,
  }) async {
    try {
      final response = await _client
          .post(
            Uri.parse('$_base/v1/playlists/share'),
            headers: _headers(token),
            body: jsonEncode(<String, Object?>{
              'recordId': recordId,
              'payload': payload,
            }),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 && response.statusCode != 201) {
        _log.w('share publish failed: ${response.statusCode}');
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final share = CloudPlaylistShare.tryParse(decoded['share']);
      if (share != null) return share;
      final map = Map<String, Object?>.from(decoded);
      final slug = map['slug']?.toString() ?? '';
      if (slug.isEmpty) return null;
      return CloudPlaylistShare(
        slug: slug,
        payload: payload,
        views: 0,
      );
    } catch (error) {
      _log.w('share publish failed: $error');
      return null;
    }
  }

  /// Removes a share link (owner only).
  Future<bool> unpublishShare({
    required String token,
    required String slug,
  }) async {
    try {
      final response = await _client
          .delete(
            Uri.parse('$_base/v1/playlists/share/$slug'),
            headers: _headers(token),
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200;
    } catch (error) {
      _log.w('share unpublish failed: $error');
      return false;
    }
  }

  /// Resolves a share link publicly (QR code / deep link entry point).
  Future<CloudPlaylistShare?> resolveShare(String slug) async {
    final sanitized = slug.trim();
    if (sanitized.isEmpty || sanitized.length > 80) return null;
    try {
      final response = await _client
          .get(Uri.parse('$_base/v1/playlists/shared/$sanitized'))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final map = Map<String, Object?>.from(decoded);
      final share = CloudPlaylistShare.tryParse(map['share']);
      if (share != null) return share;
      final slugValue = map['slug']?.toString() ?? sanitized;
      return CloudPlaylistShare(
        slug: slugValue,
        payload: Map<String, Object?>.from(
          (map['payload'] as Map?) ?? const <String, Object?>{},
        ),
        views: (map['views'] as num?)?.toInt() ?? 0,
      );
    } catch (error) {
      _log.w('share resolve failed: $error');
      return null;
    }
  }

  // -- Backup gateway -----------------------------------------------------------

  /// `PUT /v1/backup?deviceId=…` — uploads raw backup bytes (≤8 MiB).
  Future<CloudBackupSummary?> uploadBackup({
    required String token,
    required String deviceId,
    required List<int> bytes,
  }) async {
    if (bytes.length > 8 * 1024 * 1024) {
      _log.w('backup upload rejected: payload too large');
      return null;
    }
    try {
      final response = await _client
          .put(
            Uri.parse('$_base/v1/backup').replace(
              queryParameters: <String, String>{'deviceId': deviceId},
            ),
            headers: <String, String>{
              'Content-Type': 'application/octet-stream',
              'Authorization': 'Bearer $token',
            },
            body: bytes,
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200 && response.statusCode != 201) {
        _log.w('backup upload failed: ${response.statusCode}');
        return null;
      }
      return CloudBackupSummary.tryParse(jsonDecode(response.body));
    } catch (error) {
      _log.w('backup upload failed: $error');
      return null;
    }
  }

  /// `GET /v1/backup?deviceId=…` — newest-first summaries for a device.
  Future<List<CloudBackupSummary>> listBackups({
    required String token,
    required String deviceId,
  }) async {
    try {
      final response = await _client
          .get(
            Uri.parse(
              '$_base/v1/backup',
            ).replace(queryParameters: <String, String>{'deviceId': deviceId}),
            headers: _headers(token),
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return const <CloudBackupSummary>[];
      return CloudBackupSummary.listFrom(jsonDecode(response.body));
    } catch (error) {
      _log.w('backup list failed: $error');
      return const <CloudBackupSummary>[];
    }
  }

  /// `GET /v1/backup/{id}` — downloads the raw backup bytes.
  Future<List<int>?> downloadBackup({
    required String token,
    required String backupId,
  }) async {
    try {
      final response = await _client
          .get(
            Uri.parse('$_base/v1/backup/$backupId'),
            headers: _headers(token),
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      return response.bodyBytes;
    } catch (error) {
      _log.w('backup download failed: $error');
      return null;
    }
  }

  /// `DELETE /v1/backup/{id}`.
  Future<bool> deleteBackup({
    required String token,
    required String backupId,
  }) async {
    try {
      final response = await _client
          .delete(
            Uri.parse('$_base/v1/backup/$backupId'),
            headers: _headers(token),
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200;
    } catch (error) {
      _log.w('backup delete failed: $error');
      return false;
    }
  }
}
