import 'dart:async';

import 'package:spotiflac_android/core/domain/core_errors.dart';

/// Thrown by cooperative pipeline stages when their [CancellationToken] is
/// cancelled. The queue engine maps this to [CoreErrorCategory.cancelled] and,
/// for the paused reason, re-queues the job instead of failing it.
class JobCancelledException implements Exception {
  const JobCancelledException({this.jobId, this.reason = 'cancelled'});

  /// Job being aborted, when known.
  final String? jobId;

  /// Why the cancellation happened (`cancelled`, `queue-paused`, `shutdown`…).
  final String reason;

  @override
  String toString() => 'JobCancelledException(reason: $reason)';
}

/// Reason used when a running job is aborted because the user (or the engine
/// gate) paused it. The scheduler treats this reason as "return to queue"
/// instead of a terminal cancellation.
const String kQueuePauseCancelReason = 'queue-paused';

/// Cooperative cancellation token threaded through download workers, FFmpeg
/// conversion steps, and bridge invocations.
///
/// Tokens are single-shot: once cancelled they never un-cancel. Listeners fan
/// out synchronously at cancel time so data-layer adaptors can abort the
/// underlying HTTP transfer / native worker exactly once, before the owning
/// coroutine observes `isCancelled` — nothing waits on the event loop to
/// propagate an abort.
class CancellationToken {
  CancellationToken._(this._state);

  final _CancellationState _state;

  bool get isCancelled => _state.isCancelled;

  /// Reason passed to [CancellationTokenSource.cancel]; null while alive.
  String? get reason => _state.reason;

  /// Completes when the token is cancelled. Used by futures that want to race
  /// an operation against cancellation without polling.
  Future<void> get cancelled => _state.cancelled;

  /// Registers [listener] to fire synchronously on cancellation.
  ///
  /// If the token is already cancelled the listener fires immediately, so
  /// adaptors attached late still abort their resource.
  void addListener(void Function() listener) {
    _state.addListener(listener);
  }

  void removeListener(void Function() listener) {
    _state.removeListener(listener);
  }

  /// Throws [JobCancelledException] when cancelled; cheap enough to call
  /// before and after every await boundary inside a pipeline stage.
  void throwIfCancelled({String? jobId}) {
    if (_state.isCancelled) {
      throw JobCancelledException(jobId: jobId, reason: _state.reason ?? 'cancelled');
    }
  }
}

/// Source/owner pair for [CancellationToken]; one per running job.
class CancellationTokenSource {
  CancellationTokenSource() : _state = _CancellationState();

  final _CancellationState _state;
  bool _disposed = false;

  CancellationToken? _token;

  CancellationToken get token => _token ??= CancellationToken._(_state);

  bool get isCancelled => _state.isCancelled;

  /// Cancels the token. Idempotent. Listener exceptions never escape: a
  /// misbehaving adaptor must not veto the abort of sibling resources.
  void cancel([String reason = 'cancelled']) {
    if (_state.isCancelled) return;
    _state.cancel(reason);
  }

  /// Releases listener registrations. Cancellation itself stays sticky —
  /// disposing a source never un-cancels it.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _state.clearListeners();
  }
}

class _CancellationState {
  final Completer<void> _completer = Completer<void>();
  List<void Function()> _listeners = <void Function()>[];
  bool isCancelled = false;
  String? _reason;

  String? get reason => _reason;

  Future<void> get cancelled => _completer.future;

  void addListener(void Function() listener) {
    if (isCancelled) {
      _notifySafely(listener);
      return;
    }
    _listeners = List<void Function()>.of(_listeners)..add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners = List<void Function()>.of(_listeners)..remove(listener);
  }

  void clearListeners() {
    _listeners = <void Function()>[];
  }

  void cancel(String reason) {
    if (isCancelled) return;
    isCancelled = true;
    _reason = reason;
    final pending = _listeners;
    _listeners = <void Function()>[];
    for (final listener in pending) {
      _notifySafely(listener);
    }
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }

  void _notifySafely(void Function() listener) {
    try {
      listener();
    } catch (error, stackTrace) {
      Zone.current.handleUncaughtError(error, stackTrace);
    }
  }
}
