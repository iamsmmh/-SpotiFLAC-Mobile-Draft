/// Cloud backup manager (Phase 3) — extends the existing on-device backup
/// flow (`lib/services/backup_service.dart`, used by the backup settings
/// page) with the cloud gateway on the SpotiFLAC Cloud backend
/// (`PUT/GET/DELETE /v1/backup`, ≤8 MiB per backup, newest three kept per
/// device server-side).
///
/// The manager is transport + policy only: *what* goes into a backup and
/// *how* a restore is applied stays exactly where it is today (the settings
/// page gathers/applies via its providers). Sections are injected as typed
/// closures so the manager stays unit-testable and the existing local
/// backup path is untouched.
library;

import 'dart:convert';

import 'package:spotiflac_android/services/backup_service.dart';
import 'package:spotiflac_android/utils/logger.dart';

import 'package:spotiflac_android/cloud/account_manager.dart';
import 'package:spotiflac_android/cloud/cloud_service.dart';

final _log = AppLogger('CloudBackupManager');

/// Loads one backup section (returns null when the section is unavailable).
typedef BackupSectionLoader = Future<Object?> Function();

/// Applies one backup section during restore.
typedef BackupSectionApplier = Future<void> Function(Object? value);

/// The backup sections wired to their providers.
class CloudBackupSections {
  final Map<String, BackupSectionLoader> loaders;
  final Map<String, BackupSectionApplier> appliers;

  const CloudBackupSections({
    required this.loaders,
    required this.appliers,
  });

  /// Section names this configuration can gather and apply.
  Iterable<String> get restorableKeys =>
      appliers.keys.where((key) => loaders.containsKey(key));
}

/// Outcome of a manager operation surfaced to the UI.
class CloudBackupOperation {
  final bool ok;
  final String? error;
  final CloudBackupSummary? backup;
  final int restoredSections;

  const CloudBackupOperation._({
    required this.ok,
    this.error,
    this.backup,
    this.restoredSections = 0,
  });

  const CloudBackupOperation.success(CloudBackupSummary backup)
    : this._(ok: true, backup: backup);

  const CloudBackupOperation.restored(int sections)
    : this._(ok: true, restoredSections: sections);

  const CloudBackupOperation.failure(String error)
    : this._(ok: false, error: error);
}

/// The manager.
class CloudBackupManager {
  CloudBackupManager({
    required SpotiFlacCloudService service,
    required CloudAccountManager account,
    required CloudBackupSections sections,
  }) : _service = service,
       _account = account,
       _sections = sections;

  final SpotiFlacCloudService _service;
  final CloudAccountManager _account;
  final CloudBackupSections _sections;

  /// True when a cloud deployment is configured (account may still be
  /// signed out).
  bool get isConfigured => _account.isConfigured;

  /// Builds the backup envelope from the injected section loaders using the
  /// exact same envelope shape as the on-device flow (`BackupService`).
  Future<Map<String, dynamic>?> buildEnvelope() async {
    try {
      final settings = await _load('settings');
      final history = await _load('history');
      final collections = await _load('collections');
      final playlistCovers = await _load('playlistCovers');
      final extensions = await _load('extensions');
      return BackupService.buildEnvelope(
        settings: _asMap(settings),
        history: _asList(history),
        collections:
            _asMap(collections) ?? const <String, dynamic>{},
        playlistCovers:
            _asMap(playlistCovers) ?? const <String, dynamic>{},
        extensions: _asMap(extensions) ?? const <String, dynamic>{},
      );
    } catch (error) {
      _log.w('backup envelope build failed: $error');
      return null;
    }
  }

  Future<Object?> _load(String key) async {
    final loader = _sections.loaders[key];
    if (loader == null) return null;
    return loader();
  }

  Map<String, dynamic>? _asMap(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : null;

  List<Map<String, dynamic>> _asList(Object? value) => value is List
      ? <Map<String, dynamic>>[
          for (final entry in value)
            if (entry is Map) Map<String, dynamic>.from(entry),
        ]
      : <Map<String, dynamic>>[];

  /// Creates a backup and uploads it for this device.
  Future<CloudBackupOperation> createBackup() async {
    final token = await _serviceAccessToken();
    final deviceId = await _account.deviceId();
    if (token == null) {
      return const CloudBackupOperation.failure('sign in to back up');
    }
    final envelope = await buildEnvelope();
    if (envelope == null) {
      return const CloudBackupOperation.failure('could not build backup');
    }
    final bytes = utf8.encode(jsonEncode(envelope));
    final summary = await _service.uploadBackup(
      token: token,
      deviceId: deviceId,
      bytes: bytes,
    );
    if (summary == null) {
      return const CloudBackupOperation.failure('backup upload failed');
    }
    return CloudBackupOperation.success(summary);
  }

  /// Lists the cloud backups for this device (newest first).
  Future<List<CloudBackupSummary>> listBackups() async {
    final token = await _serviceAccessToken();
    if (token == null) return const <CloudBackupSummary>[];
    final deviceId = await _account.deviceId();
    return _service.listBackups(token: token, deviceId: deviceId);
  }

  /// Deletes a stored cloud backup.
  Future<bool> deleteBackup(String backupId) async {
    final token = await _serviceAccessToken();
    if (token == null) return false;
    return _service.deleteBackup(token: token, backupId: backupId);
  }

  /// Downloads and applies the newest backup. Sections are applied in the
  /// order given by [CloudBackupSections.restorableKeys] and a failing
  /// section aborts the restore (the caller keeps its prior state).
  Future<CloudBackupOperation> restoreLatest() async {
    final token = await _serviceAccessToken();
    if (token == null) {
      return const CloudBackupOperation.failure('sign in to restore');
    }
    final deviceId = await _account.deviceId();
    final backups = await _service.listBackups(token: token, deviceId: deviceId);
    if (backups.isEmpty) {
      return const CloudBackupOperation.failure('no cloud backups yet');
    }
    final bytes = await _service.downloadBackup(
      token: token,
      backupId: backups.first.id,
    );
    if (bytes == null) {
      return const CloudBackupOperation.failure('backup download failed');
    }
    final bundle = BackupService.parse(utf8.decode(bytes));
    if (bundle == null) {
      return const CloudBackupOperation.failure('backup is not readable');
    }
    final data = <String, Object?>{
      'settings': bundle.settings,
      'history': bundle.history,
      'collections': bundle.collections,
      'playlistCovers': bundle.playlistCovers,
      'extensions': bundle.extensions,
    };
    var restored = 0;
    for (final key in _sections.restorableKeys) {
      if (!data.containsKey(key)) continue;
      try {
        await _sections.appliers[key]!(data[key]);
        restored++;
      } catch (error) {
        _log.w('restore of section "$key" failed: $error');
        return CloudBackupOperation.failure('restore failed at "$key"');
      }
    }
    return CloudBackupOperation.restored(restored);
  }

  Future<String?> _serviceAccessToken() => _service.accessToken();
}
