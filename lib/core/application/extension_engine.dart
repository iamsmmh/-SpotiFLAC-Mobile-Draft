import 'dart:async';

import 'package:spotiflac_android/core/application/retry_policy.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';

/// Application-layer [ExtensionEngine]: provider priority chain with
/// per-provider retries and normalized errors.
///
/// Driver isolation contract (Stage 2): dynamic plugins register as
/// [ExtensionDriver]s at runtime (install/update/uninstall events call
/// [registerDriver]/[unregisterDriver]/[updateProviderOrder]) without the
/// core queue ever touching plugin machinery. Every object leaving this
/// class is normalized: resolution failures surface as
/// [ExtensionExhaustedError] with one [CoreError] per failed provider —
/// nothing raw (JS runtime errors, gomobile panics wrapped by the bridge,
/// decoding mistakes) escapes unhandled.
class PriorityExtensionEngine implements ExtensionEngine {
  PriorityExtensionEngine({
    List<ExtensionDriver> drivers = const <ExtensionDriver>[],
    List<String> providerOrder = const <String>[],
    RetryPolicy retryPolicy = RetryPolicy.transientProviderRetry,
    Future<void> Function(Duration delay)? sleeper,
  }) : _retryPolicy = retryPolicy,
       _sleeper = sleeper ?? Future<void>.delayed {
    for (final driver in drivers) {
      _drivers[driver.providerId] = driver;
    }
    updateProviderOrder(providerOrder);
  }

  final Map<String, ExtensionDriver> _drivers = <String, ExtensionDriver>{};
  final Map<String, ExtensionProviderHealth> _health =
      <String, ExtensionProviderHealth>{};
  final RetryPolicy _retryPolicy;
  final Future<void> Function(Duration delay) _sleeper;
  List<String> _order = <String>[];

  @override
  List<String> get providerOrder => List<String>.unmodifiable(_order);

  @override
  void updateProviderOrder(List<String> order) {
    final seen = <String>{};
    final next = <String>[];
    for (final id in order) {
      if (seen.add(id)) next.add(id);
    }
    // Registered drivers missing from the explicit order keep their previous
    // relative placement at the tail so a repo update never silently drops a
    // working provider from the chain.
    for (final id in _order) {
      if (_drivers.containsKey(id) && seen.add(id)) next.add(id);
    }
    for (final id in _drivers.keys) {
      if (seen.add(id)) next.add(id);
    }
    _order = next;
  }

  @override
  void registerDriver(ExtensionDriver driver) {
    _drivers[driver.providerId] = driver;
    _health.putIfAbsent(
      driver.providerId,
      () => ExtensionProviderHealth(providerId: driver.providerId),
    );
    if (!_order.contains(driver.providerId)) {
      _order = List<String>.of(_order)..add(driver.providerId);
    }
  }

  @override
  void unregisterDriver(String providerId) {
    _drivers.remove(providerId);
    _order = List<String>.of(_order)..remove(providerId);
  }

  @override
  ExtensionProviderHealth healthOf(String providerId) {
    return _health[providerId] ??
        ExtensionProviderHealth(providerId: providerId);
  }

  @override
  Future<ExtensionResolution> resolve(
    ExtensionRequest request, {
    CancellationToken? cancellation,
  }) async {
    final failures = <CoreError>[];
    final audit = <ProviderAttemptFailure>[];
    var visitedAny = false;

    for (final providerId in List<String>.of(_order)) {
      cancellation?.throwIfCancelled();
      final driver = _drivers[providerId];
      if (driver == null) continue; // Not (yet) registered on this device.
      visitedAny = true;

      try {
        final payload = await _resolveThroughProvider(
          driver,
          request,
          cancellation,
          audit,
        );
        _recordSuccess(providerId);
        return ExtensionResolution(
          providerId: providerId,
          payload: payload,
          priorFailures: List<ProviderAttemptFailure>.unmodifiable(audit),
        );
      } on JobCancelledException {
        rethrow; // Cancellation is not a provider failure; unwind as-is.
      } on CoreError catch (error) {
        failures.add(error.providerId == null
            ? error.copyWith(providerId: providerId)
            : error);
        _recordFailure(providerId, failures.last);
      }
    }

    if (!visitedAny) {
      throw const CoreError(
        category: CoreErrorCategory.provider,
        message: 'No extension providers are registered in the engine',
        retryable: false,
      );
    }
    throw ExtensionExhaustedError(
      failures: failures,
      message:
          'All ${failures.length} provider(s) rejected the request; '
          'first failure: ${failures.isEmpty ? 'unknown' : failures.first.message}',
    );
  }

  /// Runs one provider through the retry policy. Throws [CoreError] after the
  /// policy is exhausted (attempts recorded into [audit]).
  Future<ExtensionPayload> _resolveThroughProvider(
    ExtensionDriver driver,
    ExtensionRequest request,
    CancellationToken? cancellation,
    List<ProviderAttemptFailure> audit,
  ) async {
    var attempt = 0;
    while (true) {
      attempt++;
      cancellation?.throwIfCancelled();
      try {
        final payload = await driver.resolve(
          request,
          cancellation ?? _detachedToken,
        );
        // Drivers may cancel internally (e.g. an auth abort); honour it
        // before turning the payload into a success.
        cancellation?.throwIfCancelled();
        return payload;
      } on JobCancelledException {
        rethrow;
      } catch (error) {
        final normalized = normalizeCoreError(
          error,
          providerId: driver.providerId,
          fallback: CoreErrorCategory.provider,
        );
        audit.add(
          ProviderAttemptFailure(
            providerId: driver.providerId,
            attempt: attempt,
            error: normalized,
          ),
        );
        if (!_retryPolicy.shouldRetry(normalized, failedAttempt: attempt)) {
          throw normalized;
        }
        final delay = _retryPolicy.delayFor(attempt);
        if (delay > Duration.zero) {
          await _sleeper(delay);
        }
      }
    }
  }

  void _recordSuccess(String providerId) {
    final previous = healthOf(providerId);
    _health[providerId] = previous.copyWith(
      consecutiveFailures: 0,
      totalSuccesses: previous.totalSuccesses + 1,
      lastError: null,
    );
  }

  void _recordFailure(String providerId, CoreError error) {
    final previous = healthOf(providerId);
    _health[providerId] = previous.copyWith(
      consecutiveFailures: previous.consecutiveFailures + 1,
      lastError: error,
    );
  }
}

/// Used when the caller resolves without a token: an inert token that the
/// driver can still observe on the cancellation path taken by the engine.
final CancellationToken _detachedToken = CancellationTokenSource().token;
