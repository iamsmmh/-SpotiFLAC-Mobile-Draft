import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/core/sync/cloud_sync_provider.dart';
import 'package:spotiflac_android/core/sync/sync_entities.dart';
import 'package:spotiflac_android/core/sync/sync_orchestrator.dart';

/// The registered cloud-sync backend (Phase 6, repository pattern).
///
/// Composition root: shipped builds bind the [NoOpCloudSyncProvider] (sync is
/// honestly "not configured"). A Firebase / Supabase / self-hosted adapter
/// (see `docs/CLOUD_SYNC.md`) overrides this provider at start-up and every
/// sync surface activates without further changes.
final cloudSyncBackendProvider = Provider<CloudSyncProvider>((ref) {
  return const NoOpCloudSyncProvider();
});

/// One app-wide orchestrator holding the conflict replica + offline outbox.
final syncOrchestratorProvider = Provider<SyncOrchestrator>((ref) {
  return SyncOrchestrator();
});

/// UI-facing sync state (status, user, pending outbox, last error).
final syncStateProvider = NotifierProvider<SyncStateNotifier, SyncSnapshot>(
  SyncStateNotifier.new,
);

class SyncStateNotifier extends Notifier<SyncSnapshot> {
  static const String _persistKey = 'cloud_sync_state_v1';

  bool _restored = false;

  @override
  SyncSnapshot build() {
    final backend = ref.watch(cloudSyncBackendProvider);
    if (backend is NoOpCloudSyncProvider) {
      return const SyncSnapshot(status: SyncStatus.disabled);
    }
    unawaited(_restoreThenProbe());
    return const SyncSnapshot(status: SyncStatus.signedOut);
  }

  Future<void> _restoreThenProbe() async {
    if (_restored) return;
    _restored = true;
    final orchestrator = ref.read(syncOrchestratorProvider);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_persistKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          orchestrator.importState(Map<String, Object?>.from(decoded));
        }
      }
    } catch (_) {
      // Corrupt sync scratch state degrades to "nothing pending".
    }
    await refreshUser();
  }

  /// Re-reads the backend's session and reflects it in [state].
  Future<void> refreshUser() async {
    final backend = ref.read(cloudSyncBackendProvider);
    if (backend is NoOpCloudSyncProvider) {
      state = const SyncSnapshot(status: SyncStatus.disabled);
      return;
    }
    try {
      final user = await backend.currentUser();
      state = state.copyWith(
        status: user == null ? SyncStatus.signedOut : SyncStatus.idle,
        user: user,
        pendingOutboxCount:
            ref.read(syncOrchestratorProvider).totalPendingPushCount,
        lastError: null,
      );
    } catch (error) {
      state = state.copyWith(
        status: SyncStatus.error,
        lastError: error.toString(),
      );
    }
  }

  /// Delegates to the backend's sign-in UX.
  Future<void> signIn() async {
    final backend = ref.read(cloudSyncBackendProvider);
    state = state.copyWith(status: SyncStatus.syncing, lastError: null);
    try {
      final user = await backend.signIn(const <String, Object?>{});
      state = state.copyWith(status: SyncStatus.idle, user: user);
      await syncNow();
    } catch (error) {
      state = state.copyWith(
        status: SyncStatus.error,
        lastError: error.toString(),
      );
    }
  }

  Future<void> signOut() async {
    final backend = ref.read(cloudSyncBackendProvider);
    try {
      await backend.signOut();
    } finally {
      state = const SyncSnapshot(status: SyncStatus.signedOut);
    }
  }

  /// One full cycle for every scope: pull → merge → push outbox → persist.
  /// Fail-open per scope so one failing domain never blocks the others.
  Future<void> syncNow() async {
    final backend = ref.read(cloudSyncBackendProvider);
    if (backend is NoOpCloudSyncProvider) return;
    final orchestrator = ref.read(syncOrchestratorProvider);
    state = state.copyWith(status: SyncStatus.syncing, lastError: null);
    String? firstError;
    try {
      for (final scope in SyncScope.values) {
        try {
          final remote = await backend.pull(
            scope,
            sinceRevision: orchestrator.serverRevisionWatermark(scope),
          );
          final result = orchestrator.mergeRemote(scope, remote);
          if (result.hasChanges && scope == SyncScope.settings) {
            // Scope owners subscribe to applied records themselves; the
            // settings listener lives in the settings provider.
            _appliedSettings = result.appliedFromRemote;
          }
          final pending = orchestrator.pendingPush(scope);
          if (pending.isNotEmpty) {
            final acknowledged = await backend.push(scope, pending);
            orchestrator.acknowledgePush(scope, acknowledged.keys);
          }
        } on SyncAuthException {
          rethrow; // session lost: surface signed-out to the UI
        } catch (error) {
          firstError ??= error.toString();
        }
      }
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_persistKey, jsonEncode(orchestrator.exportState()));
      state = state.copyWith(
        status: firstError == null ? SyncStatus.idle : SyncStatus.error,
        lastSyncAt: DateTime.now().toUtc(),
        pendingOutboxCount: orchestrator.totalPendingPushCount,
        lastError: firstError,
      );
    } on SyncAuthException catch (error) {
      state = state.copyWith(
        status: SyncStatus.signedOut,
        lastError: error.message,
      );
    }
  }

  /// Records a local change into the outbox (called by scope owners such as
  /// the collections provider when favorites/playlists change). No-ops while
  /// sync is disabled so the outbox never grows without a backend to drain it.
  void recordLocalWrite(
    SyncScope scope,
    String recordId,
    Map<String, Object?> payload,
  ) {
    if (state.status == SyncStatus.disabled) return;
    ref.read(syncOrchestratorProvider).upsertLocal(scope, recordId, payload);
    state = state.copyWith(
      pendingOutboxCount:
          ref.read(syncOrchestratorProvider).totalPendingPushCount,
    );
  }

  /// Records a local deletion (tombstone) into the outbox.
  void recordLocalDelete(SyncScope scope, String recordId) {
    if (state.status == SyncStatus.disabled) return;
    ref.read(syncOrchestratorProvider).markDeleted(scope, recordId);
    state = state.copyWith(
      pendingOutboxCount:
          ref.read(syncOrchestratorProvider).totalPendingPushCount,
    );
  }

  List<SyncRecord>? _appliedSettings;

  /// Settings records applied from the backend during the last [syncNow]
  /// cycle (consumed by the settings layer, then read as null).
  List<SyncRecord>? consumeAppliedSettings() {
    final applied = _appliedSettings;
    _appliedSettings = null;
    return applied;
  }
}
