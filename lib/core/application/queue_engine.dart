import 'dart:async';

import 'package:spotiflac_android/core/application/retry_policy.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';

/// What the engine hands to the worker runner for one job execution.
class QueueJobExecution {
  QueueJobExecution({
    required this.job,
    required this.cancellation,
    required void Function(double progress) reportProgress,
  }) : _reportProgress = reportProgress;

  /// Current immutable view of the job being executed.
  final QueueJob job;

  /// Cooperative cancellation: aborted by cancel, pause, or engine shutdown.
  final CancellationToken cancellation;

  final void Function(double) _reportProgress;

  /// Reports 0..1 transfer progress. Values are clamped and de-duplicated.
  void reportProgress(double progress) => _reportProgress(progress);
}

/// Signature of the worker the engine schedules jobs onto.
typedef QueueJobRunner = Future<QueueJobResult> Function(
  QueueJobExecution execution,
);

/// Pre-handler for a job's cancellation token. Registered by the
/// DownloadManager composition so imperative aborts (native worker, HTTP
/// client, FFmpeg session) fire synchronously at cancel time.
typedef JobCancellationHook = void Function(String jobId);

/// Engine configuration.
class QueueEngineConfig {
  const QueueEngineConfig({
    this.maxConcurrent = 2,
    this.retryPolicy = RetryPolicy.never,
    Future<void> Function(Duration delay)? sleeper,
    this.finishedCapacity = 128,
    this.shutdownGrace = const Duration(seconds: 5),
  }) : sleeper = sleeper ?? _defaultSleeper;

  /// Upper bound of concurrently executing jobs. Live-adjustable via
  /// [QueueEngine.updateConcurrency].
  final int maxConcurrent;

  /// Automatic retry policy for failed jobs. Defaults to no retries, matching
  /// the legacy queue where retries are user-driven.
  final RetryPolicy retryPolicy;

  /// Injectable delay for backoff waits (tests: instant).
  final Future<void> Function(Duration delay) sleeper;

  /// Ring capacity of terminal jobs kept for the snapshot.
  final int finishedCapacity;

  /// How long [QueueEngine.dispose] waits for cancelled workers to unwind
  /// before closing the event stream regardless.
  final Duration shutdownGrace;

  static Future<void> _defaultSleeper(Duration delay) =>
      Future<void>.delayed(delay);

  QueueEngineConfig copyWith({
    int? maxConcurrent,
    RetryPolicy? retryPolicy,
    Future<void> Function(Duration delay)? sleeper,
    int? finishedCapacity,
    Duration? shutdownGrace,
  }) {
    return QueueEngineConfig(
      maxConcurrent: maxConcurrent ?? this.maxConcurrent,
      retryPolicy: retryPolicy ?? this.retryPolicy,
      sleeper: sleeper ?? this.sleeper,
      finishedCapacity: finishedCapacity ?? this.finishedCapacity,
      shutdownGrace: shutdownGrace ?? this.shutdownGrace,
    );
  }
}

class _JobEntry {
  _JobEntry(this.job);

  QueueJob job;
  CancellationTokenSource? cancelSource;
  bool pauseRequestedByUser = false;
  bool heldByQueuePause = false;

  /// Set while a delayed engine retry is armed; the retry completes only if
  /// the job is still pending when the backoff elapses.
  bool retryArmed = false;
}

/// Managed concurrent worker engine for downloads.
///
/// Semantics (Stage 2, replacing the ad-hoc loop in the legacy queue):
///  - **Priority lanes**: pending jobs start in (priority rank, insertion
///    sequence) order. [reorder] moves a queued job between lanes.
///  - **Configurable concurrency**: [QueueEngineConfig.maxConcurrent] bounds
///    the number of active workers; live-updatable via [updateConcurrency].
///  - **Responsive cancellation**: every running job owns a
///    [CancellationTokenSource]; cancel/pause fires listeners synchronously so
///    data adapters abort HTTP/native/FFmpeg work immediately, then unwinds
///    the worker future. Nothing is orphaned: after [dispose] no worker
///    future keeps running unobserved.
///  - **Pause semantics**: pausing a running job aborts the current transfer
///    *without failing it*; the job returns to the queue's held set and
///    re-executes on resume.
///  - **Event-driven**: all transitions are emitted on [events]; the engine
///    never polls and needs no timers for its core loop.
class QueueEngine {
  QueueEngine({
    required QueueJobRunner runner,
    QueueEngineConfig config = const QueueEngineConfig(),
    JobCancellationHook? cancellationHook,
  }) : _runner = runner,
       _config = config,
       _cancellationHook = cancellationHook;

  final QueueJobRunner _runner;
  QueueEngineConfig _config;
  final JobCancellationHook? _cancellationHook;

  final List<_JobEntry> _pending = <_JobEntry>[];
  final List<_JobEntry> _held = <_JobEntry>[];
  final Map<String, _JobEntry> _running = <String, _JobEntry>{};
  final List<_JobEntry> _finished = <_JobEntry>[];
  final Map<String, _JobEntry> _index = <String, _JobEntry>{};

  final StreamController<QueueEvent> _events =
      StreamController<QueueEvent>.broadcast();

  Completer<void>? _drainCompleter;
  int _idSequence = 0;
  int _orderSequence = 0;
  bool _gateClosed = false;
  bool _disposed = false;
  bool _emptiedSignalled = true;

  /// Retries currently waiting on their backoff delay. They hold no worker,
  /// but they *are* pending work: `drained` and `QueueEmptied` must not fire
  /// while one is armed, or a caller awaiting the queue would resume before
  /// the retry even started.
  int _armedRetries = 0;

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  Stream<QueueEvent> get events => _events.stream;

  QueueEngineConfig get config => _config;

  bool get isPaused => _gateClosed;

  int get pendingCount => _pending.length;
  int get heldCount => _held.length;
  int get runningCount => _running.length;

  /// Pending jobs in exact schedule order (priority, then FIFO).
  List<QueueJob> get pendingJobs =>
      List<QueueJob>.unmodifiable(_pending.map((_JobEntry e) => e.job));

  List<QueueJob> get heldJobs =>
      List<QueueJob>.unmodifiable(_held.map((_JobEntry e) => e.job));

  List<QueueJob> get runningJobs =>
      List<QueueJob>.unmodifiable(_running.values.map((_JobEntry e) => e.job));

  /// Ordered view: running (start order), then pending/held (schedule order),
  /// then terminal (most recent last).
  List<QueueJob> get snapshot {
    return List<QueueJob>.unmodifiable(<QueueJob>[
      ..._running.values.map((_JobEntry e) => e.job),
      ..._pending.map((_JobEntry e) => e.job),
      ..._held.map((_JobEntry e) => e.job),
      ..._finished.reversed.map((_JobEntry e) => e.job),
    ]);
  }

  /// Job view by id, or null when unknown/evicted.
  QueueJob? jobById(String jobId) => _index[jobId]?.job;

  /// Completes when no pending/running work remains. Held jobs don't block:
  /// they consume no resources. When work is (re)queued later, a fresh future
  /// is handed out.
  Future<void> get drained {
    if (_pending.isEmpty && _running.isEmpty && _armedRetries == 0) {
      return Future<void>.value();
    }
    final current = _drainCompleter;
    if (current == null || current.isCompleted) {
      return (_drainCompleter = Completer<void>()).future;
    }
    return current.future;
  }

  // -------------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------------

  /// Inserts [spec] into the queue and kicks scheduling. Returns the initial
  /// job view (further state arrives through [events]). Idempotent per id:
  /// re-enqueueing a live job returns the existing view.
  QueueJob enqueue(DownloadJobSpec spec) {
    _ensureAlive();
    final id = spec.jobId ?? 'job-${++_idSequence}';
    final existing = _index[id];
    if (existing != null && !existing.job.isTerminal) {
      return existing.job; // Idempotent: never duplicate a live job.
    }
    // Pin the resolved id so the batch path cannot mint a second one.
    return enqueueAll(<DownloadJobSpec>[spec.copyWith(jobId: id)]).first;
  }

  /// Enqueues a whole batch (e.g. a 5,000-track playlist) in a single pass.
  ///
  /// Inserting one-by-one is O(n²) because every `_insertPending` shifts the
  /// sorted pending list; a batch appends and sorts once, so importing a large
  /// collection stays O(n log n). Re-enqueueing a live id is idempotent (the
  /// existing job view is returned and no duplicate is created).
  /// Returns one job view per [specs] entry, in input order — the existing
  /// view when the id was already live, the new one otherwise.
  List<QueueJob> enqueueAll(Iterable<DownloadJobSpec> specs) {
    _ensureAlive();
    final created = <QueueJob>[];
    final resolved = <QueueJob>[];
    for (final spec in specs) {
      final id = spec.jobId ?? 'job-${++_idSequence}';
      final existing = _index[id];
      if (existing != null) {
        if (!existing.job.isTerminal) {
          resolved.add(existing.job);
          continue;
        }
        // A terminal entry with this id can still sit in the finished ring.
        // Drop it *before* installing the new one: both `clearFinished()`
        // and `_archiveFinished` eviction remove entries from `_index` by
        // id, and leaving the stale row behind would make them delete the
        // replacement's index entry (queue corruption: the job becomes
        // invisible to cancel/pause while still running).
        _finished.remove(existing);
      }
      final entry = _JobEntry(
        QueueJob(
          id: id,
          sequence: ++_orderSequence,
          spec: spec,
          lifecycle: JobLifecycle.pending,
        ),
      );
      _index[id] = entry;
      _pending.add(entry);
      created.add(entry.job);
      resolved.add(entry.job);
    }
    if (_pending.isNotEmpty) {
      _pending.sort(_comparePending);
    }
    for (final job in created) {
      _emit(QueueJobEnqueued(job));
    }
    if (created.isNotEmpty) _pump();
    return resolved;
  }

  /// Total order of the pending list: priority lane first, then FIFO.
  static int _comparePending(_JobEntry a, _JobEntry b) {
    final byPriority = JobPriority.compare(a.job.priority, b.job.priority);
    if (byPriority != 0) return byPriority;
    return a.job.sequence.compareTo(b.job.sequence);
  }

  void cancel(String jobId) {
    if (_disposed) return;
    final entry = _index[jobId];
    if (entry == null) return;
    switch (entry.job.lifecycle) {
      case JobLifecycle.pending:
        _pending.remove(entry);
        _disarmRetry(entry);
        _settlePreStartCancellation(entry, 'cancelled');
      case JobLifecycle.held:
        _held.remove(entry);
        _disarmRetry(entry);
        _settlePreStartCancellation(entry, 'cancelled');
      case JobLifecycle.running:
        // The worker's done-handler finalizes as cancelled.
        entry.cancelSource?.cancel('cancelled');
      case JobLifecycle.completed:
      case JobLifecycle.failed:
      case JobLifecycle.cancelled:
        break;
    }
  }

  void pause(String jobId) {
    if (_disposed) return;
    final entry = _index[jobId];
    if (entry == null) return;
    switch (entry.job.lifecycle) {
      case JobLifecycle.pending:
        _pending.remove(entry);
        _disarmRetry(entry);
        entry.pauseRequestedByUser = true;
        _transition(entry, JobLifecycle.held);
        _held.add(entry);
        _emit(QueueJobHeld(entry.job, byUser: true));
      case JobLifecycle.running:
        entry.pauseRequestedByUser = true;
        entry.heldByQueuePause = false;
        entry.cancelSource?.cancel(kQueuePauseCancelReason);
      case JobLifecycle.held:
      case JobLifecycle.completed:
      case JobLifecycle.failed:
      case JobLifecycle.cancelled:
        break;
    }
  }

  void resume(String jobId) {
    if (_disposed) return;
    final entry = _index[jobId];
    if (entry == null) return;
    if (entry.job.lifecycle != JobLifecycle.held) return;
    _held.remove(entry);
    entry.pauseRequestedByUser = false;
    entry.heldByQueuePause = false;
    _transition(entry, JobLifecycle.pending);
    entry.job = entry.job.copyWith(progress: 0, error: null);
    _insertPending(entry);
    _emit(QueueJobResumed(entry.job));
    _pump();
  }

  void reorder(String jobId, JobPriority priority) {
    if (_disposed) return;
    final entry = _index[jobId];
    if (entry == null) return;
    final lifecycle = entry.job.lifecycle;
    if (lifecycle != JobLifecycle.pending && lifecycle != JobLifecycle.held) {
      return; // Never re-lane running/terminal jobs.
    }
    entry.job = entry.job.copyWith(
      spec: entry.job.spec.copyWith(priority: priority),
    );
    if (lifecycle == JobLifecycle.pending) {
      _pending.remove(entry);
      _insertPending(entry);
    }
    _emit(QueueJobReordered(entry.job));
    _pump();
  }

  /// Closes the scheduling gate; running jobs are pause-aborted and pending
  /// jobs wait for [resumeAll].
  void pauseAll() {
    if (_disposed || _gateClosed) return;
    _gateClosed = true;
    for (final entry in _running.values) {
      entry.heldByQueuePause = true;
      entry.cancelSource?.cancel(kQueuePauseCancelReason);
    }
    _signalEmptinessIfIdle();
  }

  void resumeAll() {
    if (_disposed || !_gateClosed) return;
    _gateClosed = false;
    final autoHeld = _held.where((_JobEntry e) => e.heldByQueuePause).toList();
    for (final entry in autoHeld) {
      _held.remove(entry);
      entry.heldByQueuePause = false;
      _transition(entry, JobLifecycle.pending);
      entry.job = entry.job.copyWith(progress: 0, error: null);
      _insertPending(entry);
      _emit(QueueJobResumed(entry.job));
    }
    _pump();
  }

  /// Adjusts the concurrency bound. Raising it starts waiting jobs
  /// immediately; lowering it lets running jobs drain naturally.
  void updateConcurrency(int maxConcurrent) {
    if (_disposed) return;
    _config = _config.copyWith(
      maxConcurrent: maxConcurrent < 1 ? 1 : maxConcurrent,
    );
    _pump();
  }

  /// Drops terminal entries (completed/failed/cancelled) from the snapshot.
  void clearFinished() {
    for (final entry in _finished) {
      if (identical(_index[entry.job.id], entry)) {
        _index.remove(entry.job.id);
      }
    }
    _finished.clear();
  }

  /// Cancels running work, drops queued work from scheduling, and closes
  /// [events] once workers have unwound.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final entry in _running.values) {
      entry.cancelSource?.cancel('shutdown');
    }
    for (final entry in <_JobEntry>[..._pending, ..._held]) {
      _disarmRetry(entry);
    }
    _pending.clear();
    _held.clear();
    if (_running.isNotEmpty && _config.shutdownGrace > Duration.zero) {
      final stopwatch = Stopwatch()..start();
      while (_running.isNotEmpty && stopwatch.elapsed < _config.shutdownGrace) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
    final completer = _drainCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
    await _events.close();
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  void _ensureAlive() {
    if (_disposed) {
      throw StateError('QueueEngine has been disposed');
    }
  }

  void _insertPending(_JobEntry entry) {
    // The pending list is kept in (priority, sequence) order, so the insertion
    // point is found by binary search: a 5,000-item playlist enqueued one by
    // one stays O(n log n) instead of degrading to O(n²) list shifts.
    var low = 0;
    var high = _pending.length;
    while (low < high) {
      final mid = low + ((high - low) >> 1);
      final before = _comparePending(entry, _pending[mid]) < 0;
      if (before) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    _pending.insert(low, entry);
  }

  /// Disarms a pending engine retry and releases its "work in flight" slot.
  void _disarmRetry(_JobEntry entry) {
    if (!entry.retryArmed) return;
    entry.retryArmed = false;
    if (_armedRetries > 0) _armedRetries--;
  }

  void _emit(QueueEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
  }

  void _transition(_JobEntry entry, JobLifecycle next) {
    entry.job = entry.job.copyWith(lifecycle: next);
    _index[entry.job.id] = entry;
  }

  /// Central scheduler. Called after every mutation; starts as many jobs as
  /// capacity allows and publishes drain/emptiness.
  void _pump() {
    if (_disposed || _gateClosed) {
      _signalEmptinessIfIdle();
      return;
    }
    while (_running.length < _config.maxConcurrent && _pending.isNotEmpty) {
      final entry = _pending.removeAt(0);
      _start(entry);
    }
    _signalEmptinessIfIdle();
  }

  void _signalEmptinessIfIdle() {
    if (_pending.isEmpty && _running.isEmpty && _armedRetries == 0) {
      if (!_emptiedSignalled) {
        _emptiedSignalled = true;
        _emit(const QueueEmptied());
      }
      final completer = _drainCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
      // A completed drain completer must not be reused for a later work
      // cycle. Otherwise a caller that awaits `drained` while a second batch
      // is running gets an already-completed future and resumes before the
      // batch actually finished.
      if (identical(_drainCompleter, completer)) {
        _drainCompleter = null;
      }
    } else {
      _emptiedSignalled = false;
    }
  }

  void _start(_JobEntry entry) {
    final source = CancellationTokenSource();
    entry.cancelSource?.dispose();
    entry.cancelSource = source;
    entry.retryArmed = false;
    entry.pauseRequestedByUser = false;
    _transition(entry, JobLifecycle.running);
    entry.job = entry.job.copyWith(attempt: entry.job.attempt + 1);
    _running[entry.job.id] = entry;

    final execution = QueueJobExecution(
      job: entry.job,
      cancellation: source.token,
      reportProgress: (double progress) {
        final clamped = progress.clamp(0.0, 1.0).toDouble();
        // Never rewind: a worker that restarts an internal phase must not
        // pull the UI's percentage backwards while the job is still running.
        if (clamped < entry.job.progress) return;
        if ((clamped - entry.job.progress).abs() < 0.0001) return;
        entry.job = entry.job.copyWith(progress: clamped);
        _emit(QueueJobProgress(entry.job.id, clamped));
      },
    );

    final hook = _cancellationHook;
    if (hook != null) {
      final jobId = entry.job.id;
      source.token.addListener(() => hook(jobId));
    }

    _emit(QueueJobStarted(entry.job));

    Future<QueueJobResult> future;
    try {
      future = Future<QueueJobResult>.value(_runner(execution));
    } catch (error, stackTrace) {
      future = Future<QueueJobResult>.error(error, stackTrace);
    }
    future.then(
      (QueueJobResult result) => _handleDone(entry, result),
      onError: (Object error, StackTrace stackTrace) {
        _handleFailed(entry, error);
      },
    );
  }

  /// Normalizes the terminal state of a job whose worker finished, in the one
  /// place all worker futures drain into.
  void _handleDone(_JobEntry entry, QueueJobResult result) {
    final wasRunning = _running.remove(entry.job.id) != null;
    if (!wasRunning) return; // Already settled via pending/held path.
    final token = entry.cancelSource?.token;
    try {
      if (token != null && token.isCancelled) {
        _settleCancellation(entry, token.reason ?? 'cancelled');
        return;
      }
      if (result.success) {
        _transition(entry, JobLifecycle.completed);
        entry.job = entry.job.copyWith(progress: 1, error: null);
        _archiveFinished(entry);
        _emit(QueueJobCompleted(entry.job, result));
      } else {
        _settleFailure(
          entry,
          result.error ??
              const CoreError(
                category: CoreErrorCategory.unknown,
                message: 'Worker returned failure without an error',
              ),
        );
      }
    } finally {
      entry.cancelSource?.dispose();
      entry.cancelSource = null;
      _pump();
    }
  }

  void _handleFailed(_JobEntry entry, Object error) {
    final wasRunning = _running.remove(entry.job.id) != null;
    if (!wasRunning) return;
    final token = entry.cancelSource?.token;
    try {
      if (token != null && token.isCancelled) {
        _settleCancellation(entry, token.reason ?? 'cancelled');
        return;
      }
      _settleFailure(entry, normalizeCoreError(error));
    } finally {
      entry.cancelSource?.dispose();
      entry.cancelSource = null;
      _pump();
    }
  }

  void _settleCancellation(_JobEntry entry, String reason) {
    if (reason == kQueuePauseCancelReason) {
      _transition(entry, JobLifecycle.held);
      entry.job = entry.job.copyWith(progress: 0, error: null);
      _held.add(entry);
      _emit(QueueJobHeld(entry.job, byUser: entry.pauseRequestedByUser));
    } else {
      _transition(entry, JobLifecycle.cancelled);
      entry.job = entry.job.copyWith(
        error: CoreError(
          category: CoreErrorCategory.cancelled,
          message: 'Job $reason',
          retryable: false,
        ),
      );
      _archiveFinished(entry);
      _emit(QueueJobCancelled(entry.job, reason));
    }
  }

  void _settleFailure(_JobEntry entry, CoreError error) {
    final policy = _config.retryPolicy;
    final failedAttempt = entry.job.attempt;
    if (!entry.pauseRequestedByUser &&
        policy.shouldRetry(error, failedAttempt: failedAttempt)) {
      // Automatic retry with backoff; any cancel/pause during the backoff
      // vetoes the retry because the job leaves the pending lifecycle.
      final delay = policy.delayFor(failedAttempt);
      _transition(entry, JobLifecycle.pending);
      entry.job = entry.job.copyWith(progress: 0, error: error);
      _emit(QueueJobRetryScheduled(entry.job, delay: delay));
      _armRetry(entry, delay);
      return;
    }
    _transition(entry, JobLifecycle.failed);
    entry.job = entry.job.copyWith(progress: 0, error: error);
    _archiveFinished(entry);
    _emit(QueueJobFailed(entry.job, error));
  }

  void _armRetry(_JobEntry entry, Duration delay) {
    if (!entry.retryArmed) _armedRetries++;
    entry.retryArmed = true;
    unawaited(_runArmedRetry(entry, delay));
  }

  Future<void> _runArmedRetry(_JobEntry entry, Duration delay) async {
    try {
      await _config.sleeper(delay);
    } catch (_) {
      // A failing sleeper must not strand the job; requeue immediately.
    } finally {
      _disarmRetry(entry);
    }
    if (_disposed) return;
    // Vetoed by cancel/pause while backing off: the job left `pending`.
    if (entry.job.lifecycle != JobLifecycle.pending) return;
    entry.job = entry.job.copyWith(error: null);
    _insertPending(entry);
    _pump();
  }

  /// Terminal path for jobs cancelled before they ever started.
  void _settlePreStartCancellation(_JobEntry entry, String reason) {
    _transition(entry, JobLifecycle.cancelled);
    entry.job = entry.job.copyWith(
      progress: 0,
      error: const CoreError(
        category: CoreErrorCategory.cancelled,
        message: 'Cancelled before start',
        retryable: false,
      ),
    );
    _archiveFinished(entry);
    _emit(QueueJobCancelled(entry.job, reason));
    _pump();
  }

  void _archiveFinished(_JobEntry entry) {
    _finished.add(entry);
    while (_finished.length > _config.finishedCapacity) {
      final evicted = _finished.removeAt(0);
      // Only touch the index when it still points at the evicted row: a job
      // id re-used for a fresh enqueue must not have its live entry dropped
      // by the eviction of the row that previously carried the same id.
      if (identical(_index[evicted.job.id], evicted)) {
        _index.remove(evicted.job.id);
      }
    }
  }
}
