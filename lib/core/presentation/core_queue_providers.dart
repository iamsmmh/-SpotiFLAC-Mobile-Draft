import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:spotiflac_android/core/application/download_manager.dart';
import 'package:spotiflac_android/core/application/queue_engine.dart';
import 'package:spotiflac_android/core/application/retry_policy.dart';
import 'package:spotiflac_android/core/data/atomic_file_ops.dart';
import 'package:spotiflac_android/core/data/audio_sanity.dart';
import 'package:spotiflac_android/core/data/bridge_download_backend.dart';
import 'package:spotiflac_android/core/data/bridge_storage_repositories.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';

// Presentation wiring for the Stage 2 core engine.
//
// Strict consumption rule: widgets/controllers read
// [coreQueueControllerProvider] and issue commands against the domain
// [DownloadManager]; they never invoke platform channels, FFmpeg, or the
// gomobile bridge directly. Every piece of platform glue resolves through the
// overridable port providers below — tests substitute fakes by overriding
// exactly one provider each.

// ---------------------------------------------------------------------------
// Port bindings (composition points)
// ---------------------------------------------------------------------------

final coreIntegrityVerifierProvider = Provider<IntegrityVerifier>((ref) {
  return const Sha256FileIntegrityVerifier();
});

final coreSanityCheckerProvider = Provider<MetadataSanityChecker>((ref) {
  return const AudioMagicSanityChecker();
});

final coreDownloadRetryPolicyProvider = Provider<RetryPolicy>((ref) {
  // Conservative: the legacy queue owns user-visible retry UX in Stage 2;
  // engine-level auto-retry is opt-in for migrated flows.
  return RetryPolicy.never;
});

/// Storage binding selected from the persisted storage mode:
///  - Android SAF: [SafStorageRepository] over the granted tree URI
///  - iOS document sandbox: [IosSandboxStorageRepository] under the
///    security-scoped bookmark
///  - App-managed folder: [LocalFileStorageRepository]
final coreStorageRepositoryProvider = Provider<StorageRepository>((ref) {
  final settings = ref.watch(
    settingsProvider.select(
      (s) => (
        mode: s.storageMode,
        treeUri: s.downloadTreeUri,
        directory: s.downloadDirectory,
        bookmark: s.downloadDirectoryBookmark,
      ),
    ),
  );

  if (Platform.isAndroid &&
      settings.mode == 'saf' &&
      settings.treeUri.isNotEmpty) {
    return SafStorageRepository(
      treeUri: settings.treeUri,
      stagingDir: settings.directory,
    );
  }
  if (Platform.isIOS && settings.bookmark.isNotEmpty) {
    return IosSandboxStorageRepository(
      bookmark: settings.bookmark,
      stagingRoot: settings.directory,
    );
  }
  return LocalFileStorageRepository(stagingRoot: settings.directory);
});

/// Payload construction seam. `DownloadRequestPayload` assembly needs the
/// full settings × extension-priority context (see the legacy
/// `_buildDownloadRequestPayload`); Stage 3 migrates that builder behind this
/// provider via an override. Until then the manager composition returns the
/// [UnconfiguredDownloadManager] placeholder and NO code path can
/// accidentally enqueue a job against a half-built backend.
final coreBridgePayloadBuilderProvider = Provider<BridgePayloadBuilder?>(
  (ref) => null,
);

/// Backend binding: the gomobile bridge adapter once a payload builder is
/// bound, else null (pair with [coreBridgePayloadBuilderProvider]).
final coreDownloadBackendProvider = Provider<DownloadBackend?>((ref) {
  final builder = ref.watch(coreBridgePayloadBuilderProvider);
  if (builder == null) return null;
  final settings = ref.watch(
    settingsProvider.select(
      (s) => (useExtensions: s.useExtensionProviders, autoFallback: s.autoFallback),
    ),
  );
  return BridgeDownloadBackend(
    payloadBuilder: builder,
    useExtensions: settings.useExtensions,
    useFallback: settings.autoFallback,
  );
});

/// The managed queue engine composition. Rebuilds when any port binding
/// changes; engine resources are disposed with the provider.
final coreDownloadManagerProvider = Provider<DownloadManager>((ref) {
  final backend = ref.watch(coreDownloadBackendProvider);
  if (backend == null) {
    return const UnconfiguredDownloadManager();
  }
  final maxConcurrent = ref.watch(
    settingsProvider.select((s) => s.concurrentDownloads),
  );
  final manager = TransactionalDownloadManager(
    backend: backend,
    storage: ref.watch(coreStorageRepositoryProvider),
    sanityChecker: ref.watch(coreSanityCheckerProvider),
    integrityVerifier: ref.watch(coreIntegrityVerifierProvider),
    config: QueueEngineConfig(
      // The engine self-guards the lower bound; the app clamps the upper
      // bound in settings (1-3 today).
      maxConcurrent: maxConcurrent,
      retryPolicy: ref.watch(coreDownloadRetryPolicyProvider),
    ),
  );
  ref.onDispose(manager.dispose);
  return manager;
});

// ---------------------------------------------------------------------------
// UI-facing controller
// ---------------------------------------------------------------------------

/// Immutable view state for queue-adjacent UI.
class CoreQueueViewState {
  const CoreQueueViewState({
    this.jobs = const <QueueJob>[],
    this.isEngineConfigured = false,
    this.isGatePaused = false,
  });

  /// Ordered job view from the engine (running → scheduled → held → recent
  /// terminal).
  final List<QueueJob> jobs;

  /// Whether a backend is bound (payload builder override installed).
  final bool isEngineConfigured;
  final bool isGatePaused;

  int get runningCount =>
      jobs.where((j) => j.lifecycle == JobLifecycle.running).length;
  int get pendingCount => jobs
      .where(
        (j) =>
            j.lifecycle == JobLifecycle.pending ||
            j.lifecycle == JobLifecycle.held,
      )
      .length;

  CoreQueueViewState copyWith({
    List<QueueJob>? jobs,
    bool? isEngineConfigured,
    bool? isGatePaused,
  }) {
    return CoreQueueViewState(
      jobs: jobs ?? this.jobs,
      isEngineConfigured: isEngineConfigured ?? this.isEngineConfigured,
      isGatePaused: isGatePaused ?? this.isGatePaused,
    );
  }
}

/// UI-facing controller: consumes domain events, exposes [CoreQueueViewState]
/// + command methods. Contains zero platform-channel knowledge.
class CoreQueueController extends Notifier<CoreQueueViewState> {
  StreamSubscription<QueueEvent>? _eventsSub;

  @override
  CoreQueueViewState build() {
    ref.onDispose(() {
      unawaited(_eventsSub?.cancel());
      _eventsSub = null;
    });
    final manager = ref.read(coreDownloadManagerProvider);
    _bindManager(manager);
    // Rebind whenever the manager composition changes (port override in
    // tests, storage-mode switch, backend binding in Stage 3).
    ref.listen<DownloadManager>(
      coreDownloadManagerProvider,
      (previous, next) {
        _bindManager(next);
        state = state.copyWith(
          jobs: next.snapshot,
          isEngineConfigured: next is! UnconfiguredDownloadManager,
        );
      },
    );

    // Live concurrency tuning from settings (bounded by the engine).
    ref.listen<int>(
      settingsProvider.select((s) => s.concurrentDownloads),
      (previous, next) {
        final manager = ref.read(coreDownloadManagerProvider);
        if (manager is TransactionalDownloadManager) {
          manager.updateConcurrency(next);
        }
      },
    );

    return CoreQueueViewState(
      jobs: manager.snapshot,
      isEngineConfigured: manager is! UnconfiguredDownloadManager,
    );
  }

  void _bindManager(DownloadManager manager) {
    unawaited(_eventsSub?.cancel());
    _eventsSub = manager.events.listen(_handleEvent);
    // Startup janitor: purge temp artifacts orphaned by a previous process.
    unawaited(
      manager.sweepStaleArtifacts().then<void>((_) {}, onError: (Object _) {}),
    );
  }

  void _handleEvent(QueueEvent event) {
    final manager = ref.read(coreDownloadManagerProvider);
    state = state.copyWith(
      jobs: manager.snapshot,
      isGatePaused: manager is TransactionalDownloadManager && manager.isPaused,
    );
  }

  DownloadManager get _manager => ref.read(coreDownloadManagerProvider);

  // ----- Commands (presentation → domain) -----

  QueueJob enqueue(DownloadJobSpec spec) => _manager.enqueue(spec);

  void cancel(String jobId) => _manager.cancel(jobId);

  void pauseJob(String jobId) => _manager.pause(jobId);

  void resumeJob(String jobId) => _manager.resume(jobId);

  void reorderJob(String jobId, JobPriority priority) =>
      _manager.reorder(jobId, priority);

  void pauseAll() => _manager.pauseAll();

  void resumeAll() => _manager.resumeAll();
}

final coreQueueControllerProvider =
    NotifierProvider<CoreQueueController, CoreQueueViewState>(
      CoreQueueController.new,
    );

// ---------------------------------------------------------------------------
// Placeholder composition (pre-Stage-3)
// ---------------------------------------------------------------------------

/// [DownloadManager] placeholder used while no [BridgePayloadBuilder] is
/// bound. Every read reports an empty, healthy engine; [enqueue] fails loudly
/// with configuration guidance instead of silently dropping work. Keep this
/// until the legacy payload builder is migrated behind
/// [coreBridgePayloadBuilderProvider].
class UnconfiguredDownloadManager implements DownloadManager {
  const UnconfiguredDownloadManager();

  static const String configurationHint =
      'No DownloadBackend is bound: override coreBridgePayloadBuilderProvider '
      'with the migrated DownloadRequestPayload builder';

  @override
  QueueJob enqueue(DownloadJobSpec spec) {
    throw StateError('UnconfiguredDownloadManager: $configurationHint');
  }

  @override
  void cancel(String jobId) {}

  @override
  void pause(String jobId) {}

  @override
  void resume(String jobId) {}

  @override
  void reorder(String jobId, JobPriority priority) {}

  @override
  void pauseAll() {}

  @override
  void resumeAll() {}

  @override
  List<QueueJob> get snapshot => const <QueueJob>[];

  @override
  Stream<QueueEvent> get events => const Stream<QueueEvent>.empty();

  @override
  Future<void> get drained => Future<void>.value();

  @override
  Future<int> sweepStaleArtifacts({Duration? olderThan}) async => 0;

  @override
  Future<void> dispose() async {}
}
