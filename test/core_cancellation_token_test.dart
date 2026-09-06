import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';

void main() {
  group('CancellationTokenSource', () {
    test('starts alive and cancels once', () {
      final source = CancellationTokenSource();
      expect(source.token.isCancelled, isFalse);
      expect(source.token.reason, isNull);

      source.cancel('user');
      expect(source.token.isCancelled, isTrue);
      expect(source.token.reason, 'user');

      // Idempotent: second cancel keeps the original reason.
      source.cancel('other');
      expect(source.token.reason, 'user');
    });

    test('listeners fire synchronously at cancel time, exactly once', () {
      final source = CancellationTokenSource();
      var calls = 0;
      source.token.addListener(() => calls++);
      source.cancel();
      expect(calls, 1, reason: 'listener must fire synchronously, not awaited');
      source.cancel();
      expect(calls, 1);
    });

    test('listener added after cancellation fires immediately', () {
      final source = CancellationTokenSource()..cancel('shutdown');
      var fired = false;
      source.token.addListener(() => fired = true);
      expect(fired, isTrue);
    });

    test('removed listeners do not fire', () {
      final source = CancellationTokenSource();
      var calls = 0;
      void listener() => calls++;
      source.token.addListener(listener);
      source.token.removeListener(listener);
      source.cancel();
      expect(calls, 0);
    });

    test('a throwing listener does not veto sibling aborts', () {
      final source = CancellationTokenSource();
      var sibling = false;
      source.token.addListener(() => throw StateError('boom'));
      source.token.addListener(() => sibling = true);
      // Capture the zone-handled error from the throwing listener.
      Object? observed;
      runZonedGuardedForTest(() {
        source.cancel();
      }, (error, _) => observed = error);
      expect(sibling, isTrue);
      expect(observed, isA<StateError>());
    });

    test('cancelled future completes on cancel', () async {
      final source = CancellationTokenSource();
      var completed = false;
      source.token.cancelled.then((_) => completed = true);
      expect(completed, isFalse);
      source.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(completed, isTrue);
    });

    test('throwIfCancelled only throws once cancelled', () {
      final source = CancellationTokenSource();
      expect(() => source.token.throwIfCancelled(), returnsNormally);
      source.cancel('queue-paused');
      expect(
        () => source.token.throwIfCancelled(jobId: 'job-1'),
        throwsA(
          isA<JobCancelledException>()
              .having((e) => e.reason, 'reason', 'queue-paused')
              .having((e) => e.jobId, 'jobId', 'job-1'),
        ),
      );
    });

    test('dispose clears listeners but keeps cancellation sticky', () {
      final source = CancellationTokenSource();
      var calls = 0;
      source.token.addListener(() => calls++);
      source.dispose();
      source.cancel();
      expect(calls, 0);
      expect(source.token.isCancelled, isTrue);
      // dispose is idempotent
      expect(() => source.dispose(), returnsNormally);
    });
  });
}

/// Runs [body] in a child zone so uncaught errors from token listeners are
/// observable by the test instead of failing it.
void runZonedGuardedForTest(
  void Function() body,
  void Function(Object error, StackTrace stackTrace) onError,
) {
  final zone = Zone.current.fork(
    specification: ZoneSpecification(
      handleUncaughtError: (self, parent, zone, error, stackTrace) {
        onError(error, stackTrace);
      },
    ),
  );
  zone.run(body);
}
