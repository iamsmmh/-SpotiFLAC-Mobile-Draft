/// Isolate offload (Phase 16).
///
/// Heavy ranking / hashing work runs in [Isolate.run] on devices; tests pass
/// [useIsolate] = false so they stay single-threaded and deterministic.
library;

import 'dart:isolate';

/// Work submitted to [IsolateCompute.run].
typedef IsolateWork<Q, R> = R Function(Q message);

/// Tiny wrapper around [Isolate.run] with a sync fallback.
class IsolateCompute {
  const IsolateCompute({this.useIsolate = true});

  final bool useIsolate;

  Future<R> run<Q, R>(IsolateWork<Q, R> work, Q message) async {
    if (!useIsolate) return work(message);
    return Isolate.run(() => work(message));
  }
}
