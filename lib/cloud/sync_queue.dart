/// Durable cloud sync queue (Phase 3).
///
/// The [SyncOrchestrator] keeps an in-memory push outbox that survives only
/// as long as the app process (its state is exported on graceful shutdown).
/// This queue is the *durable* transport buffer for the SpotiFLAC Cloud
/// backend: pending push records land in SQLite before the first attempt,
/// survive crashes, dedupe per (scope, recordId), and retry with capped
/// exponential backoff so a flaky network never blocks the UI.
///
/// Layout follows `lib/cache/cache_database.dart` (SQLite +
/// `openAppDatabase` + AppLogger + busy_timeout pragma) — see
/// `docs/DATA_STORAGE.md`.
library;

import 'dart:convert';

import 'package:spotiflac_android/core/sync/sync_entities.dart';
import 'package:spotiflac_android/services/sqlite_helpers.dart' as sqlite;
import 'package:spotiflac_android/utils/logger.dart';
import 'package:sqflite/sqflite.dart';

final _log = AppLogger('CloudSyncQueue');

/// Backoff before attempt [attempts] (1-based). 5 s, 15 s, 45 s, 2 min,
/// 5 min, then capped at 15 min.
Duration syncQueueBackoff(int attempts) {
  if (attempts <= 1) return const Duration(seconds: 5);
  if (attempts == 2) return const Duration(seconds: 15);
  if (attempts == 3) return const Duration(seconds: 45);
  if (attempts == 4) return const Duration(minutes: 2);
  if (attempts == 5) return const Duration(minutes: 5);
  return const Duration(minutes: 15);
}

/// One pending push operation.
class CloudSyncOperation {
  final SyncScope scope;
  final String recordId;
  final SyncRecord record;
  final DateTime updatedAt;
  final int attempts;
  final String? lastError;
  final DateTime? nextAttemptAt;

  const CloudSyncOperation({
    required this.scope,
    required this.recordId,
    required this.record,
    required this.updatedAt,
    this.attempts = 0,
    this.lastError,
    this.nextAttemptAt,
  });

  bool get isDue =>
      nextAttemptAt == null || !nextAttemptAt!.isAfter(DateTime.now());

  CloudSyncOperation withFailure(String error, DateTime now) =>
      CloudSyncOperation(
        scope: scope,
        recordId: recordId,
        record: record,
        updatedAt: updatedAt,
        attempts: attempts + 1,
        lastError: error,
        nextAttemptAt: now.add(syncQueueBackoff(attempts + 1)),
      );
}

/// Result of one [CloudSyncQueue.drain] pass.
class CloudSyncDrainReport {
  final int pushed;
  final int failed;
  final int remaining;

  /// Record ids accepted by the backend during this pass, keyed by scope
  /// wire id — lets the caller acknowledge exactly what was pushed.
  final Map<String, List<String>> acceptedByScope;

  const CloudSyncDrainReport({
    required this.pushed,
    required this.failed,
    required this.remaining,
    this.acceptedByScope = const <String, List<String>>{},
  });

  @override
  String toString() =>
      'CloudSyncDrainReport(pushed: $pushed, failed: $failed, '
      'remaining: $remaining)';
}

/// Callback that uploads one batch and returns the server revision per
/// accepted record id (the `CloudSyncProvider.push` shape).
typedef CloudSyncPusher =
    Future<Map<String, int>> Function(SyncScope scope, List<SyncRecord> batch);

/// Outbox surface the engine consumes; [CloudSyncQueue] is the SQLite
/// implementation, tests substitute in-memory fakes.
abstract interface class CloudSyncOutbox {
  Future<void> enqueueAll(Iterable<SyncRecord> records);

  Future<CloudSyncDrainReport> drain(CloudSyncPusher pusher);

  Future<int> count({SyncScope? scope});

  Future<void> clear({SyncScope? scope});
}

/// The durable queue.
class CloudSyncQueue implements CloudSyncOutbox {
  static const String databaseName = 'cloud_sync_queue.db';
  static const int databaseVersion = 1;
  static const int maxBatchSize = 100;

  CloudSyncQueue({Future<Database> Function()? open})
    : _open = open ?? _openDefault;

  final Future<Database> Function() _open;

  static final sqlite.SingleFlightInitializer<Database> _database =
      sqlite.SingleFlightInitializer<Database>();

  static Future<Database> _openDefault() {
    // openAppDatabase sets busy_timeout = 5000 in its own onConfigure.
    return sqlite.openAppDatabase(
      databaseName,
      version: databaseVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE pending_ops (
            scope TEXT NOT NULL,
            record_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            next_attempt_at INTEGER,
            PRIMARY KEY (scope, record_id)
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_pending_ops_due '
          'ON pending_ops(scope, next_attempt_at)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {},
    );
  }

  Future<Database> get database => _database.getOrCreate(_open);

  /// Enqueues (or replaces) the push for [record]. Deduped on
  /// (scope, recordId): the newest write wins and resets attempts.
  Future<void> enqueue(SyncRecord record) async {
    try {
      final db = await database;
      await db.insert(
        'pending_ops',
        _rowFor(record),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (error) {
      _log.w('enqueue failed: $error');
    }
  }

  /// Enqueues a batch in one transaction.
  @override
  Future<void> enqueueAll(Iterable<SyncRecord> records) async {
    final list = records.toList(growable: false);
    if (list.isEmpty) return;
    try {
      final db = await database;
      await db.transaction((txn) async {
        for (final record in list) {
          await txn.insert(
            'pending_ops',
            _rowFor(record),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      });
    } catch (error) {
      _log.w('enqueueAll failed: $error');
    }
  }

  Map<String, Object?> _rowFor(SyncRecord record) {
    return <String, Object?>{
      'scope': record.scope.wireId,
      'record_id': record.recordId,
      'payload_json': jsonEncode(record.toJson()),
      'deleted': record.deleted ? 1 : 0,
      'updated_at': record.updatedAt.millisecondsSinceEpoch,
      'attempts': 0,
      'last_error': null,
      'next_attempt_at': null,
    };
  }

  /// Operations queued for [scope] (or all scopes), oldest first.
  Future<List<CloudSyncOperation>> pending({SyncScope? scope}) async {
    try {
      final db = await database;
      final rows = await db.query(
        'pending_ops',
        where: scope == null ? null : 'scope = ?',
        whereArgs: scope == null ? null : <Object?>[scope.wireId],
        orderBy: 'updated_at ASC',
      );
      return <CloudSyncOperation>[
        for (final row in rows) ?_opFromRow(row),
      ];
    } catch (error) {
      _log.w('pending failed: $error');
      return const <CloudSyncOperation>[];
    }
  }

  /// Count of queued operations (optionally per scope).
  @override
  Future<int> count({SyncScope? scope}) async {
    try {
      final db = await database;
      final result = await db.rawQuery(
        'SELECT COUNT(*) AS n FROM pending_ops'
        '${scope == null ? '' : ' WHERE scope = ?'}',
        scope == null ? null : <Object?>[scope.wireId],
      );
      if (result.isEmpty) return 0;
      return (result.first['n'] as num?)?.toInt() ?? 0;
    } catch (error) {
      _log.w('count failed: $error');
      return 0;
    }
  }

  /// Drains due operations in per-scope batches until the queue is empty or
  /// every remaining operation failed. Failed operations stay queued with
  /// backoff applied; the report reflects one pass.
  @override
  Future<CloudSyncDrainReport> drain(CloudSyncPusher pusher) async {
    final now = DateTime.now();
    var pushed = 0;
    var failed = 0;
    final acceptedByScope = <String, List<String>>{};
    while (true) {
      final byScope = <SyncScope, List<CloudSyncOperation>>{};
      for (final scope in SyncScope.values) {
        final ops = await _dueForScope(scope);
        if (ops.isEmpty) continue;
        byScope[scope] = ops;
      }
      if (byScope.isEmpty) break;
      var anySuccess = false;
      var anyFailure = false;
      for (final entry in byScope.entries) {
        final batch = entry.value
            .map((op) => op.record)
            .toList(growable: false);
        try {
          final revisions = await pusher(entry.key, batch);
          pushed += batch.length;
          anySuccess = true;
          for (final op in entry.value) {
            await _acknowledge(op, revisions[op.record.recordId]);
          }
          acceptedByScope
              .putIfAbsent(entry.key.wireId, () => <String>[])
              .addAll(<String>[for (final op in entry.value) op.recordId]);
        } catch (error) {
          failed += batch.length;
          anyFailure = true;
          for (final op in entry.value) {
            await _recordFailure(op.withFailure(error.toString(), now));
          }
        }
      }
      if (!anySuccess && anyFailure) break;
    }
    final remaining = await count();
    return CloudSyncDrainReport(
      pushed: pushed,
      failed: failed,
      remaining: remaining,
      acceptedByScope: acceptedByScope,
    );
  }

  Future<List<CloudSyncOperation>> _dueForScope(SyncScope scope) async {
    try {
      final db = await database;
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await db.query(
        'pending_ops',
        where:
            'scope = ? AND (next_attempt_at IS NULL OR next_attempt_at <= ?)',
        whereArgs: <Object?>[scope.wireId, now],
        orderBy: 'updated_at ASC',
        limit: maxBatchSize,
      );
      return <CloudSyncOperation>[
        for (final row in rows) ?_opFromRow(row),
      ];
    } catch (error) {
      _log.w('due query failed: $error');
      return const <CloudSyncOperation>[];
    }
  }

  /// Removes the operation once the server accepted it (any revision,
  /// including a losing conflict — the server state is authoritative).
  Future<void> _acknowledge(
    CloudSyncOperation op,
    int? acceptedRevision,
  ) async {
    try {
      final db = await database;
      await db.delete(
        'pending_ops',
        where: 'scope = ? AND record_id = ?',
        whereArgs: <Object?>[op.scope.wireId, op.recordId],
      );
    } catch (error) {
      _log.w('acknowledge failed: $error');
    }
  }

  Future<void> _recordFailure(CloudSyncOperation op) async {
    try {
      final db = await database;
      await db.update(
        'pending_ops',
        <String, Object?>{
          'attempts': op.attempts,
          'last_error': op.lastError,
          'next_attempt_at': op.nextAttemptAt?.millisecondsSinceEpoch,
        },
        where: 'scope = ? AND record_id = ?',
        whereArgs: <Object?>[op.scope.wireId, op.recordId],
      );
    } catch (error) {
      _log.w('failure bookkeeping failed: $error');
    }
  }

  /// Clears the queue (account sign-out, "reset cloud data").
  @override
  Future<void> clear({SyncScope? scope}) async {
    try {
      final db = await database;
      if (scope == null) {
        await db.delete('pending_ops');
      } else {
        await db.delete(
          'pending_ops',
          where: 'scope = ?',
          whereArgs: <Object?>[scope.wireId],
        );
      }
    } catch (error) {
      _log.w('clear failed: $error');
    }
  }

  CloudSyncOperation? _opFromRow(Map<String, Object?> row) {
    final payloadJson = row['payload_json']?.toString() ?? '';
    SyncRecord? record;
    try {
      final decoded = jsonDecode(payloadJson);
      if (decoded is Map) {
        record = SyncRecord.tryParse(Map<String, Object?>.from(decoded));
      }
    } on FormatException {
      record = null;
    }
    if (record == null) return null;
    final nextAttempt = (row['next_attempt_at'] as num?)?.toInt();
    return CloudSyncOperation(
      scope: record.scope,
      recordId: record.recordId,
      record: record,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (row['updated_at'] as num?)?.toInt() ?? 0,
      ),
      attempts: (row['attempts'] as num?)?.toInt() ?? 0,
      lastError: row['last_error']?.toString(),
      nextAttemptAt: nextAttempt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(nextAttempt),
    );
  }
}
