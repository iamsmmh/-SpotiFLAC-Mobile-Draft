/// SpotiFLAC Cloud providers (Phase 3).
///
/// Wires the cloud module (`lib/cloud/**`) into the app: server
/// configuration state, the account manager, the concrete sync backend
/// (bound into `cloudSyncBackendProvider` via the `ProviderScope` override
/// in `main.dart`), the durable sync queue + engine, and the backup
/// manager.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/cloud/account_manager.dart';
import 'package:spotiflac_android/cloud/backup_manager.dart';
import 'package:spotiflac_android/cloud/cloud_service.dart';
import 'package:spotiflac_android/cloud/sync_engine.dart';
import 'package:spotiflac_android/cloud/sync_queue.dart';
import 'package:spotiflac_android/providers/ecosystem_providers.dart';
import 'package:spotiflac_android/providers/sync_provider.dart';

// ---------------------------------------------------------------------------
// Server configuration
// ---------------------------------------------------------------------------

/// The configured SpotiFLAC Cloud / self-hosted deployment.
final cloudServerConfigProvider = NotifierProvider<CloudServerConfigNotifier,
    CloudServerConfig>(CloudServerConfigNotifier.new);

// ---------------------------------------------------------------------------
// Account + service
// ---------------------------------------------------------------------------

/// The cloud account manager bound to the configured server.
final cloudAccountManagerProvider = Provider<CloudAccountManager>((ref) {
  final account = ref.watch(accountServiceProvider);
  final server = ref.watch(cloudServerConfigProvider);
  final manager = CloudAccountManager(account: account, server: server);
  return manager;
});

/// The concrete SpotiFLAC Cloud sync backend, or null when no server is
/// configured. The `ProviderScope` override in `main.dart` funnels this into
/// [cloudSyncBackendProvider].
final spotiFlacCloudServiceProvider = Provider<SpotiFlacCloudService?>((ref) {
  final server = ref.watch(cloudServerConfigProvider);
  if (!server.isConfigured) return null;
  final account = ref.watch(accountServiceProvider);
  return SpotiFlacCloudService(baseUrl: server.base, account: account);
});

// ---------------------------------------------------------------------------
// Durable queue + engine
// ---------------------------------------------------------------------------

/// The durable outbox for cloud pushes (SQLite-backed).
final cloudSyncQueueProvider = Provider<CloudSyncQueue>((ref) {
  return CloudSyncQueue();
});

/// The cloud sync engine (pull → merge → durable queue → drain).
final cloudSyncEngineProvider = Provider<CloudSyncEngine>((ref) {
  final backend = ref.watch(cloudSyncBackendProvider);
  final orchestrator = ref.watch(syncOrchestratorProvider);
  final queue = ref.watch(cloudSyncQueueProvider);
  final service = ref.watch(spotiFlacCloudServiceProvider);
  return CloudSyncEngine(
    provider: service ?? backend,
    orchestrator: orchestrator,
    queue: queue,
  );
});

/// Operations surfaced to the cloud sync UI.
class CloudSyncUiState {
  final bool configured;
  final CloudServerConfig server;
  final bool signedIn;
  final String? userLabel;
  final int queuedOperations;
  final CloudSyncCycleReport? lastReport;
  final bool syncing;

  const CloudSyncUiState({
    required this.configured,
    required this.server,
    required this.signedIn,
    this.userLabel,
    this.queuedOperations = 0,
    this.lastReport,
    this.syncing = false,
  });
}

/// Refreshes the queue count after engine cycles / local writes.
final cloudSyncUiStateProvider = NotifierProvider<CloudSyncUiStateNotifier,
    CloudSyncUiState>(CloudSyncUiStateNotifier.new);

class CloudSyncUiStateNotifier extends Notifier<CloudSyncUiState> {
  Timer? _queuePoll;

  @override
  CloudSyncUiState build() {
    ref.listen(cloudServerConfigProvider, (_, __) {
      _refresh();
    });
    ref.listen(accountStateProvider, (_, __) {
      _refresh();
    });
    _startQueuePolling();
    ref.onDispose(() {
      _queuePoll?.cancel();
    });
    final server = ref.watch(cloudServerConfigProvider);
    final account = ref.watch(accountServiceProvider);
    return CloudSyncUiState(
      configured: server.isConfigured,
      server: server,
      signedIn: account.state.user != null,
      userLabel: account.state.user?.displayName,
      queuedOperations: 0,
    );
  }

  void _startQueuePolling() {
    _queuePoll?.cancel();
    _queuePoll = Timer.periodic(const Duration(seconds: 10), (_) {
      _pollQueue();
    });
  }

  Future<void> _pollQueue() async {
    final queue = ref.read(cloudSyncQueueProvider);
    final count = await queue.count();
    if (!ref.mounted) return;
    if (count != state.queuedOperations) {
      state = _copyWith(queuedOperations: count);
    }
  }

  Future<void> _refresh() async {
    final server = ref.read(cloudServerConfigProvider);
    final account = ref.read(accountServiceProvider);
    if (!ref.mounted) return;
    state = CloudSyncUiState(
      configured: server.isConfigured,
      server: server,
      signedIn: account.state.user != null,
      userLabel: account.state.user?.displayName,
      queuedOperations: state.queuedOperations,
      lastReport: state.lastReport,
    );
  }

  CloudSyncUiState _copyWith({
    bool? configured,
    bool? signedIn,
    String? userLabel,
    int? queuedOperations,
    CloudSyncCycleReport? lastReport,
    bool? syncing,
  }) {
    return CloudSyncUiState(
      configured: configured ?? state.configured,
      server: state.server,
      signedIn: signedIn ?? state.signedIn,
      userLabel: userLabel ?? state.userLabel,
      queuedOperations: queuedOperations ?? state.queuedOperations,
      lastReport: lastReport ?? state.lastReport,
      syncing: syncing ?? state.syncing,
    );
  }

  /// Connects the app to a server URL and applies it to the account stack.
  Future<void> connectServer(String baseUrl) async {
    await ref.read(cloudServerConfigProvider.notifier).configure(baseUrl);
    final manager = ref.read(cloudAccountManagerProvider);
    await manager.applyServerConfig();
  }

  Future<void> disconnectServer() async {
    await ref.read(cloudServerConfigProvider.notifier).disconnect();
  }

  Future<void> registerThisDevice({
    required String name,
    required String platform,
  }) async {
    final manager = ref.read(cloudAccountManagerProvider);
    await manager.registerDevice(name: name, platform: platform);
  }

  Future<List<CloudDevice>> devices() =>
      ref.read(cloudAccountManagerProvider).listDevices();

  Future<bool> revokeDevice(String deviceId) =>
      ref.read(cloudAccountManagerProvider).revokeDevice(deviceId);

  /// Runs one engine cycle (also invoked from a manual "Sync now" button).
  Future<CloudSyncCycleReport> syncNow() async {
    state = _copyWith(syncing: true);
    try {
      final engine = ref.read(cloudSyncEngineProvider);
      final report = await engine.runCycle();
      final count = await ref.read(cloudSyncQueueProvider).count();
      if (ref.mounted) {
        state = _copyWith(
          syncing: false,
          lastReport: report,
          queuedOperations: count,
        );
      }
      return report;
    } catch (_) {
      if (ref.mounted) state = _copyWith(syncing: false);
      rethrow;
    }
  }
}

// ---------------------------------------------------------------------------
// Cloud backup
// ---------------------------------------------------------------------------

/// The cloud backup manager (transport-only; section wiring lives in the
/// backup settings page which owns the same providers as the local flow).
