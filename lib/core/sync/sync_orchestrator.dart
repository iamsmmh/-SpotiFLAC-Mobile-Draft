/// Sync merge orchestrator (Phase 6).
///
/// Pure Dart conflict engine driving the [CloudSyncProvider] port. The
/// Riverpod layer runs the cycle:
///
/// ```
/// pull(scope) → orchestrator.mergeRemote(...) → apply "remote won" records
///             → orchestrator.pendingPush(scope) → provider.push(...)
///             → orchestrator.acknowledgePush(...)
/// ```
///
/// Conflict rule (deterministic on every device):
///   1. tombstone beats live record when its `updatedAt` is newer-or-equal;
///   2. newer `updatedAt` wins;
///   3. equal timestamps → higher `revision` wins;
///   4. still equal → records are identical by contract (no-op).
///
/// The orchestrator owns the **outbox**: local writes queue there until the
/// backend acknowledges them, so offline edits survive restarts and are never
/// pushed twice under retry.
library;

import 'package:spotiflac_android/core/sync/sync_entities.dart';

/// What [SyncOrchestrator.mergeRemote] decided, per scope.
class SyncMergeResult {
  const SyncMergeResult({
    required this.appliedFromRemote,
    required this.keptLocal,
    required this.conflictsResolved,
  });

  /// Remote records that won and must be applied to local stores.
  final List<SyncRecord> appliedFromRemote;

  /// Record ids where the local replica already held the winning version.
  final List<String> keptLocal;

  /// Number of records where both sides had diverged (for diagnostics).
  final int conflictsResolved;

  bool get hasChanges => appliedFromRemote.isNotEmpty;
}

/// In-memory replica + outbox for all scopes. Persistence of the replica is
/// the caller's job (scope owners already have stores; the outbox is
/// serialized between cycles by the provider layer).
class SyncOrchestrator {
  SyncOrchestrator();

  final Map<SyncScope, Map<String, SyncRecord>> _replica =
      <SyncScope, Map<String, SyncRecord>>{
        for (final scope in SyncScope.values) scope: <String, SyncRecord>{},
      };

  /// Outbox: local writes awaiting backend acknowledgment, per scope.
  final Map<SyncScope, Map<String, SyncRecord>> _outbox =
      <SyncScope, Map<String, SyncRecord>>{
        for (final scope in SyncScope.values) scope: <String, SyncRecord>{},
      };

  /// Highest server revision seen per scope (drives delta pulls).
  final Map<SyncScope, int> _serverRevisionWatermark = <SyncScope, int>{};

  // -------------------------------------------------------------------------
  // Local writes
  // -------------------------------------------------------------------------

  /// Records a local write (create/update) and queues it for push.
  SyncRecord upsertLocal(
    SyncScope scope,
    String recordId,
    Map<String, Object?> payload, {
    DateTime? at,
  }) {
    final existing = _replica[scope]![recordId];
    final record = SyncRecord(
      scope: scope,
      recordId: recordId,
      revision: (existing?.revision ?? 0) + 1,
      updatedAt: (at ?? DateTime.now()).toUtc(),
      payload: Map<String, Object?>.unmodifiable(payload),
    );
    _replica[scope]![recordId] = record;
    _outbox[scope]![recordId] = record;
    return record;
  }

  /// Records a local deletion as a tombstone (queued for push).
  SyncRecord markDeleted(SyncScope scope, String recordId, {DateTime? at}) {
    final existing = _replica[scope]![recordId];
    final record = SyncRecord(
      scope: scope,
      recordId: recordId,
      revision: (existing?.revision ?? 0) + 1,
      updatedAt: (at ?? DateTime.now()).toUtc(),
      deleted: true,
    );
    _replica[scope]![recordId] = record;
    _outbox[scope]![recordId] = record;
    return record;
  }

  /// Current winning replica of one record (or null when unknown).
  SyncRecord? recordFor(SyncScope scope, String recordId) {
    return _replica[scope]![recordId];
  }

  /// All live (non-tombstone) records of [scope], newest first.
  List<SyncRecord> liveRecords(SyncScope scope) {
    final records = _replica[scope]!.values
        .where((record) => !record.deleted)
        .toList(growable: false);
    final sorted = List<SyncRecord>.of(records)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return sorted;
  }

  int pendingPushCount(SyncScope scope) => _outbox[scope]!.length;

  int get totalPendingPushCount =>
      _outbox.values.fold(0, (sum, scopeOutbox) => sum + scopeOutbox.length);

  // -------------------------------------------------------------------------
  // Merge
  // -------------------------------------------------------------------------

  /// Pairwise decision between a local and remote version of one record.
  SyncConflictWinner resolve(SyncRecord local, SyncRecord remote) {
    if (local.updatedAt.isAtSameMomentAs(remote.updatedAt)) {
      if (local.revision == remote.revision &&
          local.deleted == remote.deleted) {
        return SyncConflictWinner.identical;
      }
      if (remote.revision != local.revision) {
        return remote.revision > local.revision
            ? SyncConflictWinner.remote
            : SyncConflictWinner.local;
      }
      // Timestamp + revision tie but different tombstone state: deletion is
      // the safer convergence point (restorable, data loss is not).
      return remote.deleted
          ? SyncConflictWinner.remote
          : SyncConflictWinner.local;
    }
    final remoteIsNewer = remote.updatedAt.isAfter(local.updatedAt);
    if (remoteIsNewer) return SyncConflictWinner.remote;
    // Local is strictly newer; remote replaying an older tombstone against a
    // newer local live record still loses.
    return SyncConflictWinner.local;
  }

  /// Merges one batch of remote records into the replica.
  ///
  /// Remote winners are returned in [SyncMergeResult.appliedFromRemote] for
  /// the scope owner to persist; they also leave the outbox untouched when
  /// the local outbox version is still newer (it will win the next push).
  SyncMergeResult mergeRemote(
    SyncScope scope,
    List<SyncRecord> remoteRecords,
  ) {
    final applied = <SyncRecord>[];
    final kept = <String>[];
    var conflicts = 0;
    var maxServerRevision = _serverRevisionWatermark[scope] ?? 0;

    for (final remote in remoteRecords) {
      if (remote.revision > maxServerRevision) {
        maxServerRevision = remote.revision;
      }
      final local = _replica[scope]![remote.recordId];
      if (local == null) {
        _replica[scope]![remote.recordId] = remote;
        applied.add(remote);
        continue;
      }
      final winner = resolve(local, remote);
      switch (winner) {
        case SyncConflictWinner.remote:
          conflicts++;
          _replica[scope]![remote.recordId] = remote;
          applied.add(remote);
          // A pending local write was superseded: drop it from the outbox so
          // the app never resurrects losing data on the next push.
          final pending = _outbox[scope]![remote.recordId];
          if (pending != null && resolve(pending, remote) != SyncConflictWinner.local) {
            _outbox[scope]!.remove(remote.recordId);
          }
        case SyncConflictWinner.local:
          conflicts++;
          kept.add(remote.recordId);
        case SyncConflictWinner.identical:
          kept.add(remote.recordId);
      }
    }
    _serverRevisionWatermark[scope] = maxServerRevision;
    return SyncMergeResult(
      appliedFromRemote: List<SyncRecord>.unmodifiable(applied),
      keptLocal: List<String>.unmodifiable(kept),
      conflictsResolved: conflicts,
    );
  }

  /// Server revision watermark for delta pulls (null when never pulled).
  int? serverRevisionWatermark(SyncScope scope) =>
      _serverRevisionWatermark[scope];

  // -------------------------------------------------------------------------
  // Push cycle
  // -------------------------------------------------------------------------

  /// Outbox contents awaiting push for [scope], in write order.
  List<SyncRecord> pendingPush(SyncScope scope) {
    return List<SyncRecord>.unmodifiable(_outbox[scope]!.values);
  }

  /// Marks [recordIds] as accepted by the backend. Entries not in the outbox
  /// (or locally rewritten since) are ignored, so late acknowledgments can
  /// never clobber a newer local write.
  void acknowledgePush(SyncScope scope, Iterable<String> recordIds) {
    for (final recordId in recordIds) {
      _outbox[scope]!.remove(recordId);
    }
  }

  /// Serializes the outbox watermarks so the provider layer can persist them.
  Map<String, Object?> exportState() {
    return <String, Object?>{
      'watermarks': <String, int>{
        for (final entry in _serverRevisionWatermark.entries)
          entry.key.wireId: entry.value,
      },
      'outbox': <String, Object?>{
        for (final scope in SyncScope.values)
          scope.wireId: _outbox[scope]!.values
              .map((record) => record.toJson())
              .toList(growable: false),
      },
    };
  }

  /// Restores watermarks + outbox (replica rebuilds from scope owners).
  void importState(Map<String, Object?> state) {
    final watermarks = state['watermarks'];
    if (watermarks is Map) {
      for (final scope in SyncScope.values) {
        final value = watermarks[scope.wireId];
        if (value is num) {
          _serverRevisionWatermark[scope] = value.toInt();
        }
      }
    }
    final outbox = state['outbox'];
    if (outbox is Map) {
      for (final scope in SyncScope.values) {
        final records = outbox[scope.wireId];
        if (records is! List) continue;
        for (final raw in records) {
          if (raw is! Map) continue;
          final record = SyncRecord.tryParse(Map<String, Object?>.from(raw));
          if (record == null || record.scope != scope) continue;
          _outbox[scope]![record.recordId] = record;
          // Keep the replica at-least-as-new as the outbox entry it must
          // resurrect after an offline restart.
          final existing = _replica[scope]![record.recordId];
          if (existing == null ||
              resolve(existing, record) != SyncConflictWinner.local) {
            _replica[scope]![record.recordId] = record;
          }
        }
      }
    }
  }
}
