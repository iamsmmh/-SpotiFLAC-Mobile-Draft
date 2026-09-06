import 'dart:async';

import 'package:spotiflac_android/core/application/queue_engine.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';

/// Application-layer [DownloadManager]: the transactional download pipeline
/// scheduled by the [QueueEngine].
///
/// Pipeline per job (atomic):
///   1. `storage.stage(finalPath)`      → isolated `.tmp` target
///   2. `backend.download(task)`        → bytes into the temp target
///   3. sanity gate: `sanityChecker.inspect(tempPath)` rejects non-audio
///      payloads (HTML error pages, truncated stubs) before they can reach
///      the user's library
///   4. integrity gate: SHA-256 / exact-size verification when the job
///      carries expectations
///   5. `storage.commit(target)`        → atomic promotion to destination
///
/// Any failure or cancellation unwinds to `storage.rollback(target)`, which
/// purges the temp artifact. Nothing partially written is ever published;
/// nothing orphaned is left behind.
class TransactionalDownloadManager implements DownloadManager {
  TransactionalDownloadManager({
    required DownloadBackend backend,
    required StorageRepository storage,
    required MetadataSanityChecker sanityChecker,
    IntegrityVerifier? integrityVerifier,
    QueueEngineConfig config = const QueueEngineConfig(),
    Duration staleTempAge = const Duration(hours: 24),
  }) : _storage = storage,
       _staleTempAge = staleTempAge,
       _engine = QueueEngine(
         runner: _PipelineRunner(
           backend: backend,
           storage: storage,
           sanityChecker: sanityChecker,
           integrityVerifier: integrityVerifier,
         ).run,
         config: config,
         cancellationHook: backend.abort,
       );

  final QueueEngine _engine;
  final StorageRepository _storage;
  final Duration _staleTempAge;

  @override
  QueueJob enqueue(DownloadJobSpec spec) => _engine.enqueue(spec);

  @override
  void cancel(String jobId) => _engine.cancel(jobId);

  @override
  void pause(String jobId) => _engine.pause(jobId);

  @override
  void resume(String jobId) => _engine.resume(jobId);

  @override
  void reorder(String jobId, JobPriority priority) =>
      _engine.reorder(jobId, priority);

  @override
  void pauseAll() => _engine.pauseAll();

  @override
  void resumeAll() => _engine.resumeAll();

  @override
  List<QueueJob> get snapshot => _engine.snapshot;

  @override
  Stream<QueueEvent> get events => _engine.events;

  @override
  Future<void> get drained => _engine.drained;

  /// Live concurrency tuning (e.g. from the settings screen).
  void updateConcurrency(int maxConcurrent) =>
      _engine.updateConcurrency(maxConcurrent);

  /// Whether the engine gate is closed ([pauseAll]).
  bool get isPaused => _engine.isPaused;

  @override
  Future<int> sweepStaleArtifacts({Duration? olderThan}) {
    return _storage.purgeStaleTempFiles(
      olderThan: olderThan ?? _staleTempAge,
    );
  }

  @override
  Future<void> dispose() => _engine.dispose();
}

/// The worker body scheduled by the engine. Kept separate from the manager so
/// the stage sequence reads top-to-bottom and stays unit-testable in
/// isolation via the manager.
class _PipelineRunner {
  _PipelineRunner({
    required DownloadBackend backend,
    required StorageRepository storage,
    required MetadataSanityChecker sanityChecker,
    required IntegrityVerifier? integrityVerifier,
  }) : _backend = backend,
       _storage = storage,
       _sanityChecker = sanityChecker,
       _integrityVerifier = integrityVerifier;

  final DownloadBackend _backend;
  final StorageRepository _storage;
  final MetadataSanityChecker _sanityChecker;
  final IntegrityVerifier? _integrityVerifier;

  Future<QueueJobResult> run(QueueJobExecution execution) async {
    final job = execution.job;
    final token = execution.cancellation;
    token.throwIfCancelled(jobId: job.id);

    final target = await _stage(job, token);
    try {
      final outcome = await _backend.download(
        DownloadTask(
          job: job,
          tempPath: target.tempPath,
          finalPath: target.finalPath,
          cancellation: token,
          reportProgress: execution.reportProgress,
        ),
      );
      token.throwIfCancelled(jobId: job.id);

      if (!outcome.success) {
        final error =
            outcome.error ??
            const CoreError(
              category: CoreErrorCategory.unknown,
              message: 'Download backend reported failure without an error',
            );
        return await _abort(target, error);
      }

      final gate = await _verify(target, job, token);
      if (gate != null) {
        return await _abort(target, gate);
      }

      await _commit(target, token);
      return QueueJobResult.success(
        outputPath: target.finalPath,
        byteSize: outcome.byteSize,
      );
    } on JobCancelledException {
      await _rollbackQuietly(target);
      rethrow; // Engine settles held/cancelled from the token state.
    } catch (error) {
      await _rollbackQuietly(target);
      if (error is CoreError) return QueueJobResult.failure(error);
      return QueueJobResult.failure(
        normalizeCoreError(
          error,
          fallback: CoreErrorCategory.storage,
          fallbackMessage: 'Pipeline stage failure: $error',
        ),
      );
    }
  }

  Future<StorageTarget> _stage(QueueJob job, CancellationToken token) async {
    token.throwIfCancelled(jobId: job.id);
    try {
      return await _storage.stage(job.spec.finalPath);
    } catch (error) {
      throw normalizeCoreError(
        error,
        fallback: CoreErrorCategory.storage,
        fallbackMessage: 'Failed to stage temp target: $error',
      );
    }
  }

  /// Runs the sanity + integrity gates; returns the rejecting [CoreError] or
  /// null when the artifact may be committed.
  Future<CoreError?> _verify(
    StorageTarget target,
    QueueJob job,
    CancellationToken token,
  ) async {
    token.throwIfCancelled(jobId: job.id);

    final report = await _sanityChecker.inspect(target.tempPath);
    if (!report.ok) {
      return CoreError(
        category: CoreErrorCategory.integrity,
        message: 'Metadata sanity check failed: ${report.reason}',
        retryable: false,
      );
    }

    final spec = job.spec;
    final expectedSize = spec.expectedSizeBytes;
    if (expectedSize != null && expectedSize >= 0) {
      if (report.sizeBytes != expectedSize) {
        return CoreError(
          category: CoreErrorCategory.integrity,
          message:
              'Size check failed: expected $expectedSize bytes, '
              'got ${report.sizeBytes}',
          retryable: true,
        );
      }
    }

    final expectedSha = spec.expectedSha256Hex?.trim().toLowerCase();
    final verifier = _integrityVerifier;
    if (expectedSha != null && expectedSha.isNotEmpty && verifier != null) {
      token.throwIfCancelled(jobId: job.id);
      final actual = await verifier.checksumSha256(target.tempPath, token);
      if (actual.toLowerCase() != expectedSha) {
        return CoreError(
          category: CoreErrorCategory.integrity,
          message: 'SHA-256 mismatch: expected $expectedSha, got $actual',
          retryable: true,
        );
      }
    }
    return null;
  }

  Future<void> _commit(StorageTarget target, CancellationToken token) async {
    token.throwIfCancelled();
    try {
      await _storage.commit(target);
      token.throwIfCancelled();
    } on JobCancelledException {
      // Commit may have happened before the abort landed; publish is durable,
      // the token decides the job's lifecycle. Re-throw for engine settle.
      rethrow;
    } catch (error) {
      throw normalizeCoreError(
        error,
        fallback: CoreErrorCategory.storage,
        fallbackMessage: 'Atomic commit failed: $error',
      );
    }
  }

  Future<QueueJobResult> _abort(StorageTarget target, CoreError error) async {
    await _rollbackQuietly(target);
    return QueueJobResult.failure(error);
  }

  /// Rollback never throws over the original failure: a cleanup problem must
  /// not mask why the job actually failed.
  Future<void> _rollbackQuietly(StorageTarget target) async {
    try {
      await _storage.rollback(target);
    } catch (_) {
      // Janitor sweep (sweepStaleArtifacts) is the second line of defense.
    }
  }
}
