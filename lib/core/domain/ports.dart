/// Domain ports: the abstract boundaries every outer layer implements.
///
/// Dependency rule (Stage 2): application services and data adapters depend on
/// these interfaces; nothing in the domain depends on them. UI code talks to
/// [DownloadManager] / [ExtensionEngine]; it never constructs platform-channel
/// calls itself.
library;

import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';

// ---------------------------------------------------------------------------
// Download manager (application-facing queue API)
// ---------------------------------------------------------------------------

/// Managed concurrent download queue with priority lanes, cooperative
/// cancellation, and pause hooks. Implementations are event-driven: state
/// reads come from [snapshot], transitions arrive on [events].
abstract interface class DownloadManager {
  /// Schedules [spec] and returns its initial job view. Scheduling is
  /// immediate; actual start depends on capacity and priority.
  QueueJob enqueue(DownloadJobSpec spec);

  /// Aborts a pending, held, or running job. Running jobs are signalled
  /// through their cancellation token; the matching terminal event arrives
  /// asynchronously once the worker has unwound.
  void cancel(String jobId);

  /// Parks a pending/running job back into the queue without failing it. A
  /// running job's underlying transfer is aborted cleanly (its temp artifacts
  /// are rolled back); resuming re-executes from the worker stage.
  void pause(String jobId);

  /// Returns a held job to scheduling.
  void resume(String jobId);

  /// Changes the priority lane of a pending or held job (priority reordering
  /// never preempts a running job; it takes effect at the next schedule).
  void reorder(String jobId, JobPriority priority);

  /// Gate the whole engine: running jobs are paused-aborted and nothing new
  /// starts until [resumeAll].
  void pauseAll();

  /// Opens the gate and resumes jobs that were auto-held by [pauseAll].
  void resumeAll();

  /// Ordered view of every tracked job: running first (by start order), then
  /// pending/held in schedule order, then terminal jobs (most recent last).
  List<QueueJob> get snapshot;

  /// Broadcast stream of every queue transition.
  Stream<QueueEvent> get events;

  /// Completes when no pending or running work remains.
  Future<void> get drained;

  /// Purges orphaned temporary artifacts (`.tmp` files) left behind by
  /// process kills. Returns the number of artifacts removed.
  Future<int> sweepStaleArtifacts({Duration? olderThan});

  /// Cancels all running work, stops scheduling, and closes [events].
  Future<void> dispose();
}

// ---------------------------------------------------------------------------
// Download backend (single-job executor, data layer)
// ---------------------------------------------------------------------------

/// Executes exactly one staged download. Implementations are data-layer
/// adapters (gomobile bridge, native worker offload, HTTP fallback).
abstract interface class DownloadBackend {
  /// Streams/transfers the artifact into [DownloadTask.tempPath], reporting
  /// 0..1 progress. Must honour [DownloadTask.cancellation] cooperatively:
  /// returning after [JobCancelledException] unwinds is fine, writing past
  /// cancellation is not.
  Future<DownloadTaskResult> download(DownloadTask task);

  /// Best-effort imperative abort of the platform resource behind [jobId]
  /// (HTTP transfer, native worker slot, SAF write). Called synchronously from
  /// token listeners, so this must not await long chains; enqueue native
  /// calls fire-and-forget.
  void abort(String jobId);
}

/// Everything a backend needs for one execution.
class DownloadTask {
  const DownloadTask({
    required this.job,
    required this.tempPath,
    required this.finalPath,
    required this.cancellation,
    required this.reportProgress,
  });

  final QueueJob job;

  /// Isolated temporary target (`.tmp`) the artifact must land in.
  final String tempPath;

  /// Commit destination (informational for the backend; promotion is owned by
  /// the transactional pipeline, not the backend).
  final String finalPath;

  final CancellationToken cancellation;

  /// 0..1 progress reporter. Values are clamped and de-duplicated.
  final void Function(double progress) reportProgress;
}

/// Backend outcome. On success the artifact must fully exist at
/// [DownloadTask.tempPath]; integrity verification and commit are the
/// pipeline's job, never the backend's.
class DownloadTaskResult {
  const DownloadTaskResult.success({this.byteSize, this.actualQuality})
    : success = true,
      error = null;

  const DownloadTaskResult.failure(this.error)
    : success = false,
      byteSize = null,
      actualQuality = null;

  final bool success;
  final int? byteSize;
  final String? actualQuality;
  final CoreError? error;
}

// ---------------------------------------------------------------------------
// Extension engine (dynamic provider resolution)
// ---------------------------------------------------------------------------

/// Binding to one dynamic provider (gomobile-backed JS runtime, repo plugin,
/// …). Drivers report normalized failures: implementations must convert every
/// thrown object into a [CoreError] before it leaves [resolve].
abstract interface class ExtensionDriver {
  /// Stable provider/extension identifier.
  String get providerId;

  /// Executes [request] against this provider. Payload decoding happens
  /// inside the driver layer so engine logic stays transport-agnostic.
  Future<ExtensionPayload> resolve(
    ExtensionRequest request,
    CancellationToken cancellation,
  );
}

/// Provider resolution with retries and priority fallback.
abstract interface class ExtensionEngine {
  /// Current provider priority order (ids).
  List<String> get providerOrder;

  /// Dynamically updates priority — used when repo plugins update at runtime.
  void updateProviderOrder(List<String> order);

  /// Registers a driver (hot-installed extension). Position derives from
  /// [providerOrder]; unknown ids are appended after known ones.
  void registerDriver(ExtensionDriver driver);

  /// Removes a driver (extension uninstalled/unloaded).
  void unregisterDriver(String providerId);

  /// Resolves [request] through the priority chain. Per provider, transient
  /// failures are retried per the engine's retry policy; on terminal provider
  /// failure the next provider in [providerOrder] takes over.
  ///
  /// Never throws un-normalized exceptions: the failure path is an
  /// [ExtensionExhaustedError] carrying every provider's [CoreError].
  Future<ExtensionResolution> resolve(
    ExtensionRequest request, {
    CancellationToken? cancellation,
  });

  /// Health snapshot for observability/UI badges.
  ExtensionProviderHealth healthOf(String providerId);
}

// ---------------------------------------------------------------------------
// Metadata pipeline
// ---------------------------------------------------------------------------

/// Staged metadata processing: enrich (provider lookups) → embed (container
/// writing via FFmpeg/native). Stages are cancellation-aware and report only
/// [CoreError]s.
abstract interface class MetadataPipeline {
  /// Enriches [track] from the active metadata providers.
  Future<MetadataEnvelope> enrich(TrackRef track, CancellationToken cancellation);

  /// Embeds [envelope] into [filePath], returning the final path (which may
  /// differ when the container had to be rewritten) or null when embedding
  /// was skipped/unnecessary.
  Future<String?> embed(
    String filePath,
    MetadataEnvelope envelope,
    CancellationToken cancellation,
  );
}

// ---------------------------------------------------------------------------
// Storage repository (transactional, platform-uniform)
// ---------------------------------------------------------------------------

/// Platform-uniform storage boundary covering app-sandbox `file://`, Android
/// SAF trees, and the iOS document sandbox (security-scoped bookmarks).
abstract interface class StorageRepository {
  /// Discriminator of this backend (`file`, `saf`, `bookmark`).
  String get scheme;

  /// Reserves an isolated `.tmp` staging target for [finalPath]. Implementations
  /// may create parent directories or acquire scoped access, but must not
  /// touch the final destination.
  Future<StorageTarget> stage(String finalPath);

  /// Whether [path] currently exists in this backend.
  Future<bool> exists(String path);

  /// Deletes [path]; idempotent (missing path is not an error).
  Future<void> delete(String path);

  /// Atomically promotes [StorageTarget.tempPath] to
  /// [StorageTarget.finalPath]. Called only after integrity verification
  /// succeeded. On SAF backends this publishes the staged bytes into the
  /// granted tree; on filesystem backends this is an atomic rename.
  Future<void> commit(StorageTarget target);

  /// Purges the staged temp artifact. Idempotent; called on every failure or
  /// cancellation path. Never throws — rollback failures are logged by the
  /// implementation, not surfaced over the original error.
  Future<void> rollback(StorageTarget target);

  /// Removes orphaned temp artifacts older than [olderThan]; returns the
  /// count removed. Called by [DownloadManager.sweepStaleArtifacts].
  Future<int> purgeStaleTempFiles({required Duration olderThan});
}

// ---------------------------------------------------------------------------
// Integrity + sanity (finalize pipeline gates)
// ---------------------------------------------------------------------------

/// Computes content checksums for the transactional finalize.
abstract interface class IntegrityVerifier {
  /// Streams [path] and returns its lowercase SHA-256 hex digest.
  Future<String> checksumSha256(String path, CancellationToken cancellation);
}

/// Sanity-checks the *contents* of a staged artifact before destination
/// commit (guards against HTML error pages or truncated payloads being
/// committed as media).
abstract interface class MetadataSanityChecker {
  Future<SanityReport> inspect(String path);
}

// ---------------------------------------------------------------------------
// Audio transcoder (FFmpeg boundary)
// ---------------------------------------------------------------------------

/// Container/codec conversion boundary, implemented over FFmpeg in the data
/// layer. Cancellation must abort the underlying FFmpeg session where the
/// platform supports it and always prevents post-hoc output promotion.
abstract interface class AudioTranscoder {
  Future<TranscodeOutcome> transcode(
    TranscodeRequest request,
    CancellationToken cancellation,
  );
}
