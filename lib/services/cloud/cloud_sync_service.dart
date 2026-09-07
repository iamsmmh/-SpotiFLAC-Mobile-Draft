/// Cloud sync service (Phase 3) — favorites, playlists, queue, history,
/// settings and Daily Mix state.
///
/// Wraps the existing [CloudSyncProvider] port + [SyncOrchestrator] so a
/// configured Supabase / Firebase / self-hosted backend is used without
/// replacing the outbox. Last-write-wins at record level; playlist contents
/// go through [SyncMergeEngine] so concurrent edits union-merge.
library;

import 'package:spotiflac_android/core/sync/cloud_sync_provider.dart';
import 'package:spotiflac_android/core/sync/sync_entities.dart';
import 'package:spotiflac_android/core/sync/sync_orchestrator.dart';
import 'package:spotiflac_android/services/cloud/merge_engine.dart';

/// Scopes this service will cycle, in a stable order. Daily Mix state rides
/// inside [SyncScope.settings] under the `dailyMix` payload key so we do not
/// introduce a breaking [SyncScope] value.
const List<SyncScope> cloudSyncScopes = <SyncScope>[
  SyncScope.favorites,
  SyncScope.playlists,
  SyncScope.history,
  SyncScope.settings,
  SyncScope.queueState,
];

/// Outcome of one full cycle across every scope.
class CloudSyncCycleReport {
  const CloudSyncCycleReport({
    required this.pulled,
    required this.pushed,
    required this.conflicts,
    this.error,
  });

  final int pulled;
  final int pushed;
  final int conflicts;
  final String? error;

  bool get succeeded => error == null;
}

/// High-level facade the settings page and bootstrap call.
class CloudSyncService {
  CloudSyncService({
    required CloudSyncProvider provider,
    SyncOrchestrator? orchestrator,
    SyncMergeEngine merge = const SyncMergeEngine(),
  })  : _provider = provider,
        _orchestrator = orchestrator ?? SyncOrchestrator(),
        _merge = merge;

  final CloudSyncProvider _provider;
  final SyncOrchestrator _orchestrator;
  final SyncMergeEngine _merge;

  CloudSyncProvider get provider => _provider;

  SyncOrchestrator get orchestrator => _orchestrator;

  SyncMergeEngine get mergeEngine => _merge;

  /// One pull → merge → push cycle for every [cloudSyncScopes] entry.
  /// Never throws: transport failures surface on [CloudSyncCycleReport.error]
  /// and the outbox is retained for the next cycle.
  Future<CloudSyncCycleReport> syncNow() async {
    var pulled = 0;
    var pushed = 0;
    var conflicts = 0;
    try {
      final user = await _provider.currentUser();
      if (user == null) {
        return const CloudSyncCycleReport(
          pulled: 0,
          pushed: 0,
          conflicts: 0,
          error: 'signed out',
        );
      }
      for (final scope in cloudSyncScopes) {
        final remote = await _provider.pull(
          scope,
          sinceRevision: _orchestrator.serverRevisionWatermark(scope),
        );
        pulled += remote.length;
        final merged = _orchestrator.mergeRemote(scope, remote);
        conflicts += merged.conflictsResolved;
        final pending = _orchestrator.pendingPush(scope);
        if (pending.isEmpty) continue;
        final revisions = await _provider.push(scope, pending);
        _orchestrator.acknowledgePush(scope, revisions.keys);
        pushed += revisions.length;
      }
      return CloudSyncCycleReport(
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
      );
    } on SyncAuthException catch (error) {
      return CloudSyncCycleReport(
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
        error: error.message,
      );
    } on SyncUnavailableException catch (error) {
      return CloudSyncCycleReport(
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
        error: error.message,
      );
    } catch (error) {
      return CloudSyncCycleReport(
        pulled: pulled,
        pushed: pushed,
        conflicts: conflicts,
        error: error.toString(),
      );
    }
  }

  /// Records a local write into the outbox (favorites, history, …).
  SyncRecord enqueue(
    SyncScope scope,
    String recordId,
    Map<String, Object?> payload, {
    DateTime? at,
  }) {
    return _orchestrator.upsertLocal(scope, recordId, payload, at: at);
  }

  /// Daily Mix / Discover Weekly generation stamp. Stored under settings so
  /// a second device does not regenerate the same Monday mix twice.
  SyncRecord enqueueDailyMixState({
    required String mixId,
    required DateTime generatedAt,
    required List<String> trackIds,
  }) {
    return enqueue(SyncScope.settings, 'dailymix:$mixId', <String, Object?>{
      'mixId': mixId,
      'generatedAt': generatedAt.toUtc().toIso8601String(),
      'trackIds': trackIds,
    }, at: generatedAt);
  }
}
