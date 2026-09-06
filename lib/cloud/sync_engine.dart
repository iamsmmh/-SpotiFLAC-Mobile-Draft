/// Cloud sync engine (Phase 3) — one reconciliation cycle for the
/// SpotiFLAC Cloud backend.
///
/// A cycle is: pull each enabled scope as a delta since the orchestrator's
/// server-revision watermark, merge remote records (last-writer-wins with
/// tombstones, see `SyncOrchestrator.mergeRemote`), funnel every pending
/// local write through the durable [CloudSyncQueue], then drain the queue
/// with retry/backoff. Watermarks live in the orchestrator (already
/// persisted by the provider layer); the queue persists its own retry
/// state, so a cycle is safe to interrupt at any point.
library;

import 'package:spotiflac_android/cloud/sync_queue.dart';
import 'package:spotiflac_android/core/sync/cloud_sync_provider.dart';
import 'package:spotiflac_android/core/sync/sync_entities.dart';
import 'package:spotiflac_android/core/sync/sync_orchestrator.dart';
import 'package:spotiflac_android/ecosystem/sync/sync_engine.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('CloudSyncEngine');

/// What one [CloudSyncEngine.runCycle] pass did.
class CloudSyncCycleReport {
  final DateTime startedAt;
  final Duration duration;
  final int pulled;
  final int applied;
  final int pushed;
  final int queueRemaining;
  final bool online;
  final List<String> scopesSynced;
  final Object? error;

  const CloudSyncCycleReport({
    required this.startedAt,
    required this.duration,
    required this.pulled,
    required this.applied,
    required this.pushed,
    required this.queueRemaining,
    required this.online,
    required this.scopesSynced,
    this.error,
  });

  bool get ok => error == null;

  @override
  String toString() =>
      'CloudSyncCycleReport(scopes: $scopesSynced, pulled: $pulled, '
      'applied: $applied, pushed: $pushed, remaining: $queueRemaining, '
      'ok: $ok)';
}

/// The engine.
class CloudSyncEngine {
  CloudSyncEngine({
    required CloudSyncProvider provider,
    required SyncOrchestrator orchestrator,
    required CloudSyncOutbox queue,
    NetworkGate? networkGate,
    Set<SyncScope>? scopes,
  }) : _provider = provider,
       _orchestrator = orchestrator,
       _queue = queue,
       _networkGate = networkGate ?? StaticNetworkGate(SyncNetworkState.wifi),
       _scopes = scopes ?? SyncScope.values.toSet();

  final CloudSyncProvider _provider;
  final SyncOrchestrator _orchestrator;
  final CloudSyncOutbox _queue;
  final NetworkGate _networkGate;
  final Set<SyncScope> _scopes;

  bool _running = false;

  Future<CloudSyncCycleReport>? _inFlight;

  CloudSyncCycleReport? _lastReport;

  CloudSyncCycleReport? get lastReport => _lastReport;

  int get pendingCount => _orchestrator.totalPendingPushCount;

  /// Runs one full cycle. Concurrent calls coalesce into the running cycle
  /// (a second caller awaits the in-flight pass instead of double-pushing).
  Future<CloudSyncCycleReport> runCycle({
    Set<SyncScope>? scopes,
    bool allowMetered = true,
  }) {
    if (_running && _inFlight != null) {
      return _inFlight!;
    }
    _running = true;
    _inFlight = _execute(scopes: scopes, allowMetered: allowMetered);
    return _inFlight!.whenComplete(() {
      _running = false;
      _inFlight = null;
    });
  }

  Future<CloudSyncCycleReport> _execute({
    Set<SyncScope>? scopes,
    required bool allowMetered,
  }) async {
    final startedAt = DateTime.now();
    var pulled = 0;
    var applied = 0;
    var pushed = 0;
    var remaining = 0;
    final synced = <String>[];
    Object? error;
    var online = true;
    try {
      final network = await _networkGate.current();
      online = network.online;
      if (!network.online) {
        throw const SyncUnavailableException('device is offline');
      }
      if (!allowMetered && network.metered) {
        throw const SyncUnavailableException('metered network not allowed');
      }
      for (final scope in (scopes ?? _scopes)) {
        // 1. Pull the remote delta.
        final watermark = _orchestrator.serverRevisionWatermark(scope);
        final remote = await _provider.pull(scope, sinceRevision: watermark);
        pulled += remote.length;
        // 2. Merge into the local replica (also advances the watermark and
        //    drops outbox entries that lost a conflict).
        final result = _orchestrator.mergeRemote(scope, remote);
        applied += result.appliedFromRemote.length;
        // 3. Durably enqueue every pending local write.
        final pending = _orchestrator.pendingPush(scope);
        await _queue.enqueueAll(pending);
        // 4. Drain what is due for this scope.
        final report = await _queue.drain(_provider.push);
        pushed += report.pushed;
        // 5. Acknowledge exactly the writes the backend accepted in the
        //    orchestrator outbox (failed writes stay queued).
        final accepted = report.acceptedByScope[scope.wireId];
        if (accepted != null && accepted.isNotEmpty) {
          _orchestrator.acknowledgePush(scope, accepted);
        }
        remaining = report.remaining;
        synced.add(scope.wireId);
      }
    } catch (e) {
      error = e;
      _log.w('sync cycle failed: $e');
    }
    final report = CloudSyncCycleReport(
      startedAt: startedAt,
      duration: DateTime.now().difference(startedAt),
      pulled: pulled,
      applied: applied,
      pushed: pushed,
      queueRemaining: remaining,
      online: online,
      scopesSynced: List<String>.unmodifiable(synced),
      error: error,
    );
    _lastReport = report;
    return report;
  }
}
