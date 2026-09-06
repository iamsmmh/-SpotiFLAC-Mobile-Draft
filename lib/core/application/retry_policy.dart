import 'dart:async';

import 'package:spotiflac_android/core/domain/core_errors.dart';

/// Deterministic exponential-backoff retry policy used by the queue engine
/// and the extension engine.
///
/// Determinism is deliberate: delays carry no jitter, so scheduling decisions
/// are fully reproducible in tests and identical across devices. Jitter for
/// server-side spreading is the transport's concern, not the scheduler's.
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 1,
    this.initialDelay = const Duration(milliseconds: 250),
    this.backoffFactor = 2,
    this.maxDelay = const Duration(seconds: 8),
    this.retryableCategories = _defaultRetryableCategories,
  });

  /// Total attempts including the first execution (1 = no retries).
  final int maxAttempts;

  /// Delay before attempt #2.
  final Duration initialDelay;

  /// Growth multiplier for each subsequent attempt.
  final double backoffFactor;

  /// Upper bound for any single backoff delay.
  final Duration maxDelay;

  /// Error categories eligible for retry. `RetryPolicy.never` uses the empty
  /// set; the default keeps network + rate-limit.
  final Set<CoreErrorCategory> retryableCategories;

  static const Set<CoreErrorCategory> _defaultRetryableCategories =
      <CoreErrorCategory>{
        CoreErrorCategory.network,
        CoreErrorCategory.rateLimited,
      };

  /// No retries at all.
  static const RetryPolicy never = RetryPolicy();

  /// Provider-resolution default: one immediate retry on transient failures.
  static const RetryPolicy transientProviderRetry = RetryPolicy(maxAttempts: 2);

  /// Whether [error] may be retried on [attempt] (1-based: the attempt that
  /// just failed).
  bool shouldRetry(CoreError error, {required int failedAttempt}) {
    if (failedAttempt >= maxAttempts) return false;
    if (!error.isRetryable) return false;
    return retryableCategories.contains(error.category);
  }

  /// Backoff before attempt `attempt + 1` made after [failedAttempt] (1-based)
  /// failed.
  Duration delayFor(int failedAttempt) {
    if (failedAttempt < 1) return Duration.zero;
    var delayMs = initialDelay.inMilliseconds.toDouble();
    for (var i = 1; i < failedAttempt; i++) {
      delayMs *= backoffFactor;
    }
    final capped = delayMs > maxDelay.inMilliseconds
        ? maxDelay.inMilliseconds.toDouble()
        : delayMs;
    return Duration(milliseconds: capped.round());
  }

  /// Executes [action] under this policy. [sleeper] is injectable for tests;
  /// the default is [Future.delayed]. The final failure is always a
  /// [CoreError] (via [normalizeCoreError]).
  Future<T> run<T>(
    Future<T> Function(int attempt) action, {
    Future<void> Function(Duration delay)? sleeper,
    bool Function(CoreError error)? extraFilter,
    void Function(int attempt, CoreError error, Duration delay)? onRetry,
  }) async {
    final sleep = sleeper ?? Future<void>.delayed;
    var attempt = 1;
    while (true) {
      try {
        return await action(attempt);
      } catch (error) {
        final normalized = normalizeCoreError(error);
        final allowed = shouldRetry(normalized, failedAttempt: attempt);
        final passes = extraFilter?.call(normalized) ?? true;
        if (!allowed || !passes) throw normalized;
        final delay = delayFor(attempt);
        onRetry?.call(attempt, normalized, delay);
        if (delay > Duration.zero) {
          await sleep(delay);
        }
        attempt++;
      }
    }
  }
}
