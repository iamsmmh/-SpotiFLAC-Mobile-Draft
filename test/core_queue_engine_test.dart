import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/application/queue_engine.dart';
import 'package:spotiflac_android/core/application/retry_policy.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';

DownloadJobSpec spec(
  String id, {
  JobPriority priority = JobPriority.normal,
}) {
  return DownloadJobSpec(
    jobId: id,
    track: TrackRef(id: id, name: 'Track $id', artistName: 'Artist'),
    finalPath: '/out/$id.flac',
    priority: priority,
  );
}

/// Runner whose executions park on completers until the test releases them.
class _ControllableRunner {
  final opened = <QueueJobExecution>[];
  final gates = <String, Completer<QueueJobResult>>{};
  JobRunnerBehavior behavior = JobRunnerBehavior.waitForGate;

  Future<QueueJobResult> call(QueueJobExecution execution) async {
    opened.add(execution);
    switch (behavior) {
      case JobRunnerBehavior.waitForGate:
        final gate = Completer<QueueJobResult>();
        gates[execution.job.id] = gate;
        return gate.future;
      case JobRunnerBehavior.succeed:
        return const QueueJobResult.success();
      case JobRunnerBehavior.failNetwork:
        throw const CoreError(
          category: CoreErrorCategory.network,
          message: 'offline',
        );
    }
  }

  void finish(String jobId, QueueJobResult result) {
    gates.remove(jobId)?.complete(result);
  }

  void fail(String jobId, Object error) {
    gates.remove(jobId)?.completeError(error);
  }
}

enum JobRunnerBehavior { waitForGate, succeed, failNetwork }

void main() {
  group('priority scheduling and concurrency', () {
    test('runs immediate before low regardless of enqueue order', () async {
      final runner = _ControllableRunner();
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 1, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);

      engine.pauseAll(); // gate closed: nothing starts while we enqueue
      engine.enqueue(spec('low', priority: JobPriority.low));
      engine.enqueue(spec('hot', priority: JobPriority.immediate));
      engine.enqueue(spec('normal'));

      expect(
        engine.pendingJobs.map((j) => j.id),
        <String>['hot', 'normal', 'low'],
      );

      engine.resumeAll();
      expect(runner.opened.map((e) => e.job.id), <String>['hot']);
      runner.finish('hot', const QueueJobResult.success());
      await flushQueue();
      expect(runner.opened.map((e) => e.job.id), <String>['hot', 'normal']);
    });

    test('respects the concurrency cap and refills capacity on completion',
        () async {
      final runner = _ControllableRunner();
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 2, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);

      for (var i = 0; i < 4; i++) {
        engine.enqueue(spec('j$i'));
      }
      expect(engine.runningCount, 2);
      expect(engine.pendingCount, 2);

      runner.finish('j0', const QueueJobResult.success());
      await flushQueue();
      expect(engine.runningCount, 2, reason: 'j2 should refill the slot');
      expect(
        engine.runningJobs.map((j) => j.id),
        containsAll(<String>['j1', 'j2']),
      );
    });

    test('live updateConcurrency opens more slots immediately', () async {
      final runner = _ControllableRunner();
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 1, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);

      engine.enqueue(spec('a'));
      engine.enqueue(spec('b'));
      engine.enqueue(spec('c'));
      expect(engine.runningCount, 1);

      engine.updateConcurrency(3);
      expect(engine.runningCount, 3);
      expect(engine.config.maxConcurrent, 3);
    });
  });

  group('cancellation', () {
    test('cancelling a pending job removes it without touching workers',
        () async {
      final runner = _ControllableRunner();
      final events = <QueueEvent>[];
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 1, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);
      engine.events.listen(events.add);

      engine.enqueue(spec('running'));
      engine.enqueue(spec('queued'));
      engine.cancel('queued');
      await flushQueue();

      expect(runner.opened, hasLength(1));
      expect(engine.jobById('queued')?.lifecycle, JobLifecycle.cancelled);
      expect(
        events.whereType<QueueJobCancelled>().single.job.id,
        'queued',
      );
    });

    test('cancelling a running job aborts its token and settles cancelled',
        () async {
      final runner = _ControllableRunner();
      final hooks = <String>[];
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 1, shutdownGrace: Duration(milliseconds: 50)),
        cancellationHook: hooks.add,
      );
      addTearDown(engine.dispose);

      engine.enqueue(spec('victim'));
      final execution = runner.opened.single;
      expect(execution.cancellation.isCancelled, isFalse);

      engine.cancel('victim');
      expect(
        hooks,
        <String>['victim'],
        reason: 'cancellation hook must fire synchronously',
      );
      expect(execution.cancellation.isCancelled, isTrue);

      // Worker unwinds by throwing the cooperative exception.
      runner.fail(
        'victim',
        const JobCancelledException(jobId: 'victim'),
      );
      await flushQueue();

      final job = engine.jobById('victim');
      expect(job?.lifecycle, JobLifecycle.cancelled);
      expect(job?.error?.category, CoreErrorCategory.cancelled);
      expect(engine.runningCount, 0);
    });

    test('dispose cancels running work and closes the event stream', () async {
      final runner = _ControllableRunner();
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 2, shutdownGrace: Duration(milliseconds: 50)),
      );
      var streamClosed = false;
      engine.events.listen((_) {}, onDone: () => streamClosed = true);

      engine.enqueue(spec('x'));
      engine.enqueue(spec('y'));
      expect(engine.runningCount, 2);

      runner.fail('x', const JobCancelledException(reason: 'shutdown'));
      runner.fail('y', const JobCancelledException(reason: 'shutdown'));
      await engine.dispose();
      await flushQueue();

      expect(engine.runningCount, 0);
      expect(streamClosed, isTrue);
      expect(() => engine.enqueue(spec('late')), throwsStateError);
    });
  });

  group('pause and resume', () {
    test('pausing a running job re-parks it as held without failing it',
        () async {
      final runner = _ControllableRunner();
      final events = <QueueEvent>[];
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 1, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);
      engine.events.listen(events.add);

      engine.enqueue(spec('pausable'));
      engine.pause('pausable');
      final execution = runner.opened.single;
      expect(
        execution.cancellation.reason,
        kQueuePauseCancelReason,
        reason: 'pause must abort the transfer cooperatively',
      );

      // Worker unwinds; engine must NOT settle this as a failure/cancel.
      runner.fail(
        'pausable',
        const JobCancelledException(reason: kQueuePauseCancelReason),
      );
      await flushQueue();

      final job = engine.jobById('pausable');
      expect(job?.lifecycle, JobLifecycle.held);
      expect(job?.error, isNull);
      final held = events.whereType<QueueJobHeld>().single;
      expect(held.byUser, isTrue);
    });

    test('resuming a held job re-executes it with a fresh attempt', () async {
      final runner = _ControllableRunner();
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 1, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);

      engine.enqueue(spec('job'));
      engine.pause('job');
      runner.fail('job', const JobCancelledException());
      await flushQueue();
      expect(engine.jobById('job')?.lifecycle, JobLifecycle.held);

      engine.resume('job');
      await flushQueue();
      expect(runner.opened, hasLength(2));
      expect(runner.opened.last.job.attempt, 2);
      expect(engine.jobById('job')?.lifecycle, JobLifecycle.running);
    });

    test('pauseAll auto-resumes the interrupted running jobs', () async {
      final runner = _ControllableRunner();
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 1, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);

      engine.enqueue(spec('job'));
      engine.pauseAll();
      runner.fail('job', const JobCancelledException());
      await flushQueue();

      expect(engine.jobById('job')?.lifecycle, JobLifecycle.held);

      engine.resumeAll();
      await flushQueue();
      expect(
        engine.jobById('job')?.lifecycle,
        JobLifecycle.running,
        reason: 'auto-held jobs resume with the gate',
      );
    });
  });

  group('reorder and retries', () {
    test('reordering changes start order for pending jobs only', () async {
      final runner = _ControllableRunner();
      final events = <QueueEvent>[];
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 1, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);
      engine.events.listen(events.add);

      engine.enqueue(spec('first'));
      engine.enqueue(spec('second'));
      engine.enqueue(spec('third', priority: JobPriority.low));

      engine.reorder('third', JobPriority.immediate);
      await flushQueue();
      expect(
        engine.pendingJobs.map((j) => j.id),
        <String>['third', 'second'],
      );
      expect(events.whereType<QueueJobReordered>().single.job.id, 'third');

      // Running jobs are never re-laned.
      engine.reorder('first', JobPriority.low);
      await flushQueue();
      expect(
        events.whereType<QueueJobReordered>().where((e) => e.job.id == 'first'),
        isEmpty,
      );
    });

    test('retryable failure requeues after backoff, then succeeds', () async {
      var calls = 0;
      final engine = QueueEngine(
        runner: (execution) async {
          calls++;
          if (calls == 1) {
            return const QueueJobResult.failure(
              CoreError(
                category: CoreErrorCategory.network,
                message: 'temporary',
              ),
            );
          }
          return const QueueJobResult.success(outputPath: '/out/ok.flac');
        },
        config: QueueEngineConfig(
          maxConcurrent: 1,
          retryPolicy: const RetryPolicy(maxAttempts: 2),
          sleeper: (_) async {}, // instant backoff for determinism
          shutdownGrace: const Duration(milliseconds: 50),
        ),
      );
      addTearDown(engine.dispose);
      final events = <QueueEvent>[];
      engine.events.listen(events.add);

      engine.enqueue(spec('flaky'));
      await flushQueue();
      await flushQueue();

      expect(calls, 2);
      expect(events.whereType<QueueJobRetryScheduled>(), hasLength(1));
      final job = engine.jobById('flaky');
      expect(job?.lifecycle, JobLifecycle.completed);
      expect(job?.attempt, 2);
    });

    test('cancelling during the retry backoff vetoes the retry', () async {
      var calls = 0;
      final backoff = Completer<void>();
      final engine = QueueEngine(
        runner: (execution) async {
          calls++;
          return const QueueJobResult.failure(
            CoreError(category: CoreErrorCategory.network, message: 'flaky'),
          );
        },
        config: QueueEngineConfig(
          maxConcurrent: 1,
          retryPolicy: const RetryPolicy(maxAttempts: 3),
          sleeper: (_) => backoff.future,
          shutdownGrace: const Duration(milliseconds: 50),
        ),
      );
      addTearDown(engine.dispose);

      engine.enqueue(spec('flaky'));
      await flushQueue();
      expect(calls, 1);

      engine.cancel('flaky');
      backoff.complete();
      await flushQueue();

      expect(calls, 1, reason: 'cancel during backoff vetoes the retry');
      expect(engine.jobById('flaky')?.lifecycle, JobLifecycle.cancelled);
    });
  });

  group('events and drain', () {
    test('reports progress and completes drained', () async {
      final runner = _ControllableRunner();
      final events = <QueueEvent>[];
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 2, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);
      engine.events.listen(events.add);

      engine.enqueue(spec('j1'));
      engine.enqueue(spec('j2'));
      final drained = engine.drained;

      runner.opened[0].reportProgress(0.5);
      await flushQueue();
      final progress = events.whereType<QueueJobProgress>().single;
      expect(progress.jobId, 'j1');
      expect(progress.progress, 0.5);

      runner.finish('j1', const QueueJobResult.success());
      runner.finish('j2', const QueueJobResult.success());
      await drained; // must complete once nothing is pending/running
      await flushQueue();
      expect(
        events.whereType<QueueEmptied>(),
        hasLength(1),
        reason: 'emptied is emitted once per drain cycle',
      );
    });

    test('re-enqueueing the same live job id is idempotent', () {
      final runner = _ControllableRunner();
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 1, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);

      final first = engine.enqueue(spec('dup'));
      final second = engine.enqueue(spec('dup'));
      expect(identical(first.id, second.id), isTrue);
      expect(runner.opened, hasLength(1));
    });

    test('drained waits for the current batch, not a previous work cycle',
        () async {
      final runner = _ControllableRunner();
      final engine = QueueEngine(
        runner: runner.call,
        config: const QueueEngineConfig(maxConcurrent: 1, shutdownGrace: Duration(milliseconds: 50)),
      );
      addTearDown(engine.dispose);

      // Drain the first work cycle completely.
      engine.enqueue(spec('first'));
      runner.finish('first', const QueueJobResult.success());
      await engine.drained;

      // A second cycle must hand out a fresh, uncompleted drain future.
      engine.enqueue(spec('second'));
      await flushQueue();
      expect(
        runner.opened.map((e) => e.job.id),
        contains('second'),
      );

      var secondDrainedCompleted = false;
      final secondDrained = engine.drained;
      unawaited(
        secondDrained.then((_) => secondDrainedCompleted = true),
      );
      await flushQueue();

      expect(
        secondDrainedCompleted,
        isFalse,
        reason: 'drained must not resolve while the second batch is running',
      );

      runner.finish('second', const QueueJobResult.success());
      await secondDrained;
      expect(secondDrainedCompleted, isTrue);
    });
  });
}


/// Binding-free async flush: each zero-delay timer lets one round of queued
/// microtasks run, so a few rounds drain the whole event chain.
Future<void> flushQueue([int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
