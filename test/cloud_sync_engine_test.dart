import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/cloud/sync_engine.dart';
import 'package:spotiflac_android/cloud/sync_queue.dart';
import 'package:spotiflac_android/core/sync/cloud_sync_provider.dart';
import 'package:spotiflac_android/core/sync/sync_entities.dart';
import 'package:spotiflac_android/core/sync/sync_orchestrator.dart';
import 'package:spotiflac_android/ecosystem/sync/sync_engine.dart';

SyncRecord record(
  String id, {
  int revision = 1,
  bool deleted = false,
  SyncScope scope = SyncScope.favorites,
}) {
  return SyncRecord(
    scope: scope,
    recordId: id,
    revision: revision,
    updatedAt: DateTime.utc(2026, 9, 6, 12, 0, id.hashCode % 60),
    deleted: deleted,
    payload: <String, Object?>{'liked': !deleted},
  );
}

/// Scripted provider: serves queued pulls and captures pushes.
class FakeCloudProvider implements CloudSyncProvider {
  final Map<SyncScope, List<SyncRecord>> remote = <SyncScope, List<SyncRecord>>{};
  final Map<SyncScope, List<List<SyncRecord>>> pushedBatches =
      <SyncScope, List<List<SyncRecord>>>{};
  Map<String, int> Function(List<SyncRecord> batch)? onPush;
  Object? pullError;

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake';

  @override
  Future<UserProfile?> currentUser() async => null;

  @override
  Future<UserProfile> signIn(Map<String, Object?> credentials) =>
      throw UnimplementedError();

  @override
  Future<void> signOut() async {}

  @override
  Future<List<SyncRecord>> pull(SyncScope scope, {int? sinceRevision}) async {
    if (pullError != null) throw pullError!;
    return remote[scope] ?? const <SyncRecord>[];
  }

  @override
  Future<Map<String, int>> push(SyncScope scope, List<SyncRecord> batch) async {
    pushedBatches.putIfAbsent(scope, () => <List<SyncRecord>>[]).add(batch);
    if (onPush != null) return onPush!(batch);
    return <String, int>{for (final r in batch) r.recordId: 1};
  }
}

/// In-memory outbox mirroring CloudSyncQueue semantics.
class FakeOutbox implements CloudSyncOutbox {
  final Map<String, SyncRecord> ops = <String, SyncRecord>{};
  Object? drainError;
  int drains = 0;

  @override
  Future<void> enqueueAll(Iterable<SyncRecord> records) async {
    for (final record in records) {
      ops['${record.scope.wireId}:${record.recordId}'] = record;
    }
  }

  @override
  Future<CloudSyncDrainReport> drain(CloudSyncPusher pusher) async {
    drains++;
    if (drainError != null) throw drainError!;
    var pushed = 0;
    final accepted = <String, List<String>>{};
    for (final scope in SyncScope.values) {
      final batch = <SyncRecord>[
        for (final op in ops.values)
          if (op.scope == scope) op,
      ];
      if (batch.isEmpty) continue;
      await pusher(scope, batch);
      pushed += batch.length;
      accepted[scope.wireId] = <String>[
        for (final r in batch) r.recordId,
      ];
      for (final r in batch) {
        ops.remove('${scope.wireId}:${r.recordId}');
      }
    }
    return CloudSyncDrainReport(
      pushed: pushed,
      failed: 0,
      remaining: ops.length,
      acceptedByScope: accepted,
    );
  }

  @override
  Future<int> count({SyncScope? scope}) async => ops.length;

  @override
  Future<void> clear({SyncScope? scope}) async => ops.clear();
}

CloudSyncEngine buildEngine({
  required CloudSyncProvider provider,
  required CloudSyncOutbox outbox,
  NetworkGate? gate,
}) {
  return CloudSyncEngine(
    provider: provider,
    orchestrator: SyncOrchestrator(),
    queue: outbox,
    networkGate: gate,
  );
}

void main() {
  test('full cycle: pull delta, merge, queue, push, acknowledge', () async {
    final provider = FakeCloudProvider()
      ..remote[SyncScope.favorites] = <SyncRecord>[record('t1', revision: 3)];
    final outbox = FakeOutbox();

    // Seed a local write that must be pushed.
    final orchestrator = SyncOrchestrator();
    orchestrator.upsertLocal(SyncScope.favorites, 't2', <String, Object?>{
      'liked': true,
    });
    final seeded = CloudSyncEngine(
      provider: provider,
      orchestrator: orchestrator,
      queue: outbox,
    );
    expect(seeded.pendingCount, 1);

    final report = await seeded.runCycle();
    expect(report.ok, isTrue);
    expect(report.pulled, 1);
    expect(report.applied, 1);
    expect(report.pushed, 1);
    expect(report.queueRemaining, 0);
    expect(report.scopesSynced, contains('favorites'));
    expect(seeded.pendingCount, 0);
    expect(provider.pushedBatches[SyncScope.favorites]!.first, isNotEmpty);
  });

  test('offline gate aborts the cycle with a report', () async {
    final provider = FakeCloudProvider();
    final engine = buildEngine(
      provider: provider,
      outbox: FakeOutbox(),
      gate: StaticNetworkGate(SyncNetworkState.offline),
    );
    final report = await engine.runCycle();
    expect(report.ok, isFalse);
    expect(report.online, isFalse);
    expect(report.scopesSynced, isEmpty);
    expect(provider.pushedBatches, isEmpty);
  });

  test('metered networks are skipped when not allowed', () async {
    final provider = FakeCloudProvider();
    final engine = buildEngine(
      provider: provider,
      outbox: FakeOutbox(),
      gate: StaticNetworkGate(const SyncNetworkState(online: true, metered: true)),
    );
    final report = await engine.runCycle(allowMetered: false);
    expect(report.ok, isFalse);
    expect(provider.pushedBatches, isEmpty);
  });

  test('pull failure keeps the report error and still surfaces scope state', () async {
    final provider = FakeCloudProvider()..pullError = Exception('503');
    final engine = buildEngine(provider: provider, outbox: FakeOutbox());
    final report = await engine.runCycle();
    expect(report.ok, isFalse);
    expect(report.scopesSynced, isEmpty);
  });

  test('concurrent cycles coalesce into the running pass', () async {
    final provider = FakeCloudProvider();
    final engine = buildEngine(provider: provider, outbox: FakeOutbox());
    final first = engine.runCycle();
    final second = engine.runCycle();
    final reports = await Future.wait(<Future<CloudSyncCycleReport>>[
      first,
      second,
    ]);
    expect(reports.first.startedAt, reports.last.startedAt);
  });

  test('syncQueueBackoff ladder caps at 15 minutes', () {
    expect(syncQueueBackoff(1), const Duration(seconds: 5));
    expect(syncQueueBackoff(2), const Duration(seconds: 15));
    expect(syncQueueBackoff(3), const Duration(seconds: 45));
    expect(syncQueueBackoff(4), const Duration(minutes: 2));
    expect(syncQueueBackoff(5), const Duration(minutes: 5));
    expect(syncQueueBackoff(6), const Duration(minutes: 15));
    expect(syncQueueBackoff(50), const Duration(minutes: 15));
  });

  test('CloudSyncOperation.withFailure bumps attempts and schedules backoff', () {
    // Relative to the real clock so isDue's internal DateTime.now() compare
    // holds regardless of when the test runs.
    final base = DateTime.now();
    final op = CloudSyncOperation(
      scope: SyncScope.favorites,
      recordId: 't1',
      record: record('t1'),
      updatedAt: base,
    );
    expect(op.isDue, isTrue);
    final failed = op.withFailure('socket closed', base);
    expect(failed.attempts, 1);
    expect(failed.lastError, 'socket closed');
    expect(failed.nextAttemptAt, base.add(const Duration(seconds: 5)));
    expect(failed.isDue, isFalse);
  });
}
