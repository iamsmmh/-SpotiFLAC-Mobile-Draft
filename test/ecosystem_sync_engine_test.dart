import 'package:flutter_test/flutter_test.dart';
import 'package:spotimusic/core/sync/cloud_sync_provider.dart';
import 'package:spotimusic/core/sync/sync_entities.dart';
import 'package:spotimusic/core/sync/sync_orchestrator.dart';
import 'package:spotimusic/ecosystem/ecosystem.dart';

/// In-memory backend that can be told to fail a number of times.
class FakeSyncBackend implements CloudSyncProvider {
  FakeSyncBackend({this.failures = 0, this.authFailures = false});

  int failures;
  bool authFailures;
  int pullCalls = 0;
  int pushCalls = 0;
  final Map<String, List<SyncRecord>> remote =
      <String, List<SyncRecord>>{};

  @override
  String get id => 'fake';

  @override
  String get displayName => 'Fake backend';

  @override
  Future<UserProfile?> currentUser() async =>
      const UserProfile(userId: 'u1', providerId: 'fake');

  @override
  Future<UserProfile> signIn(Map<String, Object?> credentials) =>
      currentUser().then((user) => user!);

  @override
  Future<void> signOut() async {}

  @override
  Future<List<SyncRecord>> pull(SyncScope scope, {int? sinceRevision}) async {
    pullCalls++;
    _maybeThrow();
    return remote[scope.wireId] ?? const <SyncRecord>[];
  }

  @override
  Future<Map<String, int>> push(SyncScope scope, List<SyncRecord> records) {
    pushCalls++;
    _maybeThrow();
    remote[scope.wireId] = List<SyncRecord>.of(records);
    return Future<Map<String, int>>.value(<String, int>{
      for (final record in records) record.recordId: record.revision,
    });
  }

  void _maybeThrow() {
    if (authFailures) throw const SyncAuthException('session expired');
    if (failures > 0) {
      failures--;
      throw const SyncUnavailableException('transient');
    }
  }
}

SyncEngine _engine(
  CloudSyncProvider backend, {
  SyncNetworkState network = SyncNetworkState.wifi,
  SyncPolicy? policy,
  List<Duration>? delays,
  SyncOrchestrator? orchestrator,
}) {
  return SyncEngine(
    backend: backend,
    orchestrator: orchestrator ?? SyncOrchestrator(),
    policy: policy ?? SyncPolicy(enabledScopes: <SyncScope>{SyncScope.favorites}),
    networkGate: StaticNetworkGate(network),
    sleeper: (delay) {
      delays?.add(delay);
      return Future<void>.value();
    },
  );
}

void main() {
  test('an offline cycle is skipped, never failed', () async {
    final backend = FakeSyncBackend();
    final engine = _engine(backend, network: SyncNetworkState.offline);
    addTearDown(engine.dispose);

    final report = await engine.runCycle();
    expect(report.skipped, 'offline');
    expect(backend.pullCalls, 0);
  });

  test('metered links are skipped unless the policy allows them', () async {
    final backend = FakeSyncBackend();
    final engine = _engine(backend, network: SyncNetworkState.cellular);
    addTearDown(engine.dispose);

    expect((await engine.runCycle()).skipped, 'metered');

    engine.updatePolicy(
      SyncPolicy(
        allowMetered: true,
        enabledScopes: <SyncScope>{SyncScope.favorites},
      ),
    );
    final report = await engine.runCycle(trigger: SyncTrigger.manual);
    expect(report.skipped, isNull);
    expect(report.succeeded, isTrue);
  });

  test('the no-op backend keeps sync inert', () async {
    final engine = _engine(const NoOpCloudSyncProvider());
    addTearDown(engine.dispose);
    expect((await engine.runCycle()).skipped, 'disabled');
  });

  test('local writes are pushed and acknowledged', () async {
    final backend = FakeSyncBackend();
    final orchestrator = SyncOrchestrator();
    final engine = _engine(backend, orchestrator: orchestrator);
    addTearDown(engine.dispose);

    orchestrator.upsertLocal(
      SyncScope.favorites,
      'isrc:AAA',
      const <String, Object?>{'title': 'Alpha'},
    );
    expect(orchestrator.totalPendingPushCount, 1);

    engine.notifyLocalChange();
    final report = await engine.runCycle(trigger: SyncTrigger.localChange);
    expect(report.succeeded, isTrue);
    expect(report.pushedRecords, 1);
    expect(orchestrator.totalPendingPushCount, 0);
    expect(backend.remote[SyncScope.favorites.wireId]?.single.recordId,
        'isrc:AAA');
  });

  test('transient failures are retried with backoff', () async {
    final backend = FakeSyncBackend(failures: 2);
    final delays = <Duration>[];
    final engine = _engine(
      backend,
      policy: SyncPolicy(
        maxRetries: 3,
        retryBaseDelay: const Duration(milliseconds: 10),
        enabledScopes: <SyncScope>{SyncScope.favorites},
      ),
      delays: delays,
    );
    addTearDown(engine.dispose);

    final report = await engine.runCycle();
    expect(report.succeeded, isTrue);
    expect(backend.pullCalls, 3);
    expect(delays.length, 2);
    expect(engine.stats.consecutiveFailures, 0);
  });

  test('auth failures stop the cycle and are never retried', () async {
    final backend = FakeSyncBackend(authFailures: true);
    final engine = _engine(backend);
    addTearDown(engine.dispose);

    final report = await engine.runCycle();
    expect(report.succeeded, isFalse);
    expect(report.error, contains('session expired'));
    expect(backend.pullCalls, 1);
    expect(engine.stats.consecutiveFailures, 1);
    expect(engine.stats.nextRetryAt, isNotNull);
  });

  test('only enabled scopes are synced', () async {
    final backend = FakeSyncBackend();
    final engine = _engine(
      backend,
      policy: const SyncPolicy(enabledScopes: <SyncScope>{SyncScope.favorites}),
    );
    addTearDown(engine.dispose);
    await engine.runCycle();
    expect(backend.pullCalls, 1);
  });

  test('an empty scope set falls back to the defaults', () {
    final engine = _engine(
      FakeSyncBackend(),
      policy: const SyncPolicy(),
    );
    addTearDown(engine.dispose);
    expect(engine.policy.enabledScopes, SyncScopeDescriptor.defaultEnabledScopes());
  });

  test('concurrent cycles do not overlap', () async {
    final backend = FakeSyncBackend();
    final engine = _engine(backend);
    addTearDown(engine.dispose);
    final first = engine.runCycle();
    final second = engine.runCycle();
    final results = await Future.wait(<Future<SyncCycleReport>>[first, second]);
    expect(
      results.where((report) => report.skipped == 'already running').length,
      1,
    );
  });

  test('stats accumulate across cycles', () async {
    final backend = FakeSyncBackend();
    final engine = _engine(backend);
    addTearDown(engine.dispose);
    await engine.runCycle();
    await engine.runCycle();
    expect(engine.stats.cycles, 2);
    expect(engine.stats.lastSuccessAt, isNotNull);
  });
}
