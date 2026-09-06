import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/application/retry_policy.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';

void main() {
  group('RetryPolicy.delayFor', () {
    test('grows exponentially from the initial delay and clamps at max', () {
      const policy = RetryPolicy(
        maxAttempts: 10,
        initialDelay: Duration(milliseconds: 250),
        backoffFactor: 2,
        maxDelay: Duration(seconds: 2),
      );
      expect(policy.delayFor(1), const Duration(milliseconds: 250));
      expect(policy.delayFor(2), const Duration(milliseconds: 500));
      expect(policy.delayFor(3), const Duration(seconds: 1));
      expect(policy.delayFor(4), const Duration(seconds: 2));
      expect(policy.delayFor(5), const Duration(seconds: 2));
    });

    test('attempt 0 yields zero delay', () {
      const policy = RetryPolicy();
      expect(policy.delayFor(0), Duration.zero);
    });
  });

  group('RetryPolicy.shouldRetry', () {
    const policy = RetryPolicy(maxAttempts: 3);

    test('retries retryable categories until maxAttempts', () {
      const error = CoreError(
        category: CoreErrorCategory.network,
        message: 'socket closed',
      );
      expect(policy.shouldRetry(error, failedAttempt: 1), isTrue);
      expect(policy.shouldRetry(error, failedAttempt: 2), isTrue);
      expect(policy.shouldRetry(error, failedAttempt: 3), isFalse);
    });

    test('never retries non-retryable categories', () {
      for (final category in CoreErrorCategory.values) {
        final error = CoreError(category: category, message: 'x');
        final expected =
            category == CoreErrorCategory.network ||
            category == CoreErrorCategory.rateLimited;
        expect(
          policy.shouldRetry(error, failedAttempt: 1),
          expected,
          reason: 'category $category',
        );
      }
    });

    test('respects explicit retryable overrides', () {
      const transient = CoreError(
        category: CoreErrorCategory.storage,
        message: 'locked',
        retryable: true,
      );
      // Retryable override but wrong category: excluded by category filter.
      expect(policy.shouldRetry(transient, failedAttempt: 1), isFalse);

      const hardNetwork = CoreError(
        category: CoreErrorCategory.network,
        message: 'permanent',
        retryable: false,
      );
      expect(policy.shouldRetry(hardNetwork, failedAttempt: 1), isFalse);
    });

    test('RetryPolicy.never performs no retries', () {
      const error = CoreError(
        category: CoreErrorCategory.network,
        message: 'down',
      );
      expect(RetryPolicy.never.shouldRetry(error, failedAttempt: 1), isFalse);
    });
  });

  group('RetryPolicy.run', () {
    Future<void> noSleep(Duration _) async {}

    test('succeeds after transient failures with injected sleeper', () async {
      var attempts = 0;
      final retries = <Duration>[];
      const policy = RetryPolicy(maxAttempts: 3);
      final value = await policy.run<String>(
        (attempt) async {
          attempts++;
          if (attempts < 3) {
            throw const CoreError(
              category: CoreErrorCategory.network,
              message: 'flaky',
            );
          }
          return 'ok';
        },
        sleeper: noSleep,
        onRetry: (attempt, error, delay) => retries.add(delay),
      );
      expect(value, 'ok');
      expect(attempts, 3);
      expect(retries, hasLength(2));
    });

    test('throws normalized CoreError when attempts are exhausted', () async {
      var attempts = 0;
      const policy = RetryPolicy(maxAttempts: 2);
      await expectLater(
        policy.run<void>((attempt) async {
          attempts++;
          throw FormatException('still broken');
        }, sleeper: noSleep),
        throwsA(isA<CoreError>()),
      );
      // FormatException is not retryable (unknown category) → single attempt.
      expect(attempts, 1);
    });

    test('extraFilter can veto an otherwise retryable error', () async {
      var attempts = 0;
      const policy = RetryPolicy(maxAttempts: 5);
      await expectLater(
        policy.run<void>(
          (attempt) async {
            attempts++;
            throw const CoreError(
              category: CoreErrorCategory.network,
              message: 'offline',
            );
          },
          sleeper: noSleep,
          extraFilter: (error) => false,
        ),
        throwsA(isA<CoreError>()),
      );
      expect(attempts, 1);
    });
  });
}
