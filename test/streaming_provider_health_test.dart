import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/multi_provider_stream_service.dart';

void main() {
  final now = DateTime(2026, 1, 1, 12);

  StreamProviderHealth health({
    int successes = 0,
    int failures = 0,
    int consecutive = 0,
    DateTime? cooldownUntil,
    String? error,
  }) => StreamProviderHealth(
    provider: StreamProviderId.youtube,
    successCount: successes,
    failureCount: failures,
    consecutiveFailures: consecutive,
    cooldownUntil: cooldownUntil,
    lastError: error,
  );

  group('StreamProviderHealth', () {
    test('a never-measured provider is available and does not fail', () {
      final fresh = health();
      expect(fresh.isAvailable(now), isTrue);
      expect(fresh.successRate, 1.0);
      expect(fresh.cooldownRemainingSeconds(now), 0);
    });

    test('a single failure records but does not quarantine the provider', () {
      final failed = health().recordFailure(error: 'HTTP 500', now: now);
      expect(failed.consecutiveFailures, 1);
      expect(failed.failureCount, 1);
      expect(failed.lastError, 'HTTP 500');
      // One transient error must not take a provider offline: a flaky CDN
      // would otherwise disappear from the chain after a single blip.
      expect(failed.isAvailable(now), isTrue);
      expect(failed.cooldownUntil, isNull);
    });

    test('repeated failures arm a growing cooldown', () {
      var state = health();
      state = state.recordFailure(error: 'a', now: now);
      state = state.recordFailure(error: 'b', now: now);
      expect(state.isAvailable(now), isFalse);

      // Later failures back off further.
      final firstCooldown = state.cooldownRemainingSeconds(now);
      final worse = state.recordFailure(error: 'c', now: now);
      expect(
        worse.cooldownRemainingSeconds(now),
        greaterThanOrEqualTo(firstCooldown),
      );
    });

    test('the cooldown is bounded (a dead provider is retried, not buried)', () {
      var state = health();
      for (var i = 0; i < 12; i++) {
        state = state.recordFailure(error: 'fail $i', now: now);
      }
      expect(state.consecutiveFailures, 12);
      expect(state.cooldownRemainingSeconds(now), lessThanOrEqualTo(15 * 60));
      expect(state.isAvailable(now.add(const Duration(minutes: 16))), isTrue);
    });

    test('a success clears the cooldown and the failure streak', () {
      var state = health();
      state = state.recordFailure(error: 'a', now: now);
      state = state.recordFailure(error: 'b', now: now);
      expect(state.isAvailable(now), isFalse);

      final recovered = state.recordSuccess(latencyMs: 120, now: now);
      expect(recovered.isAvailable(now), isTrue);
      expect(recovered.consecutiveFailures, 0);
      expect(recovered.lastError, isNull);
      expect(recovered.failureCount, 2); // history is preserved
      expect(recovered.successCount, 1);
      expect(recovered.lastLatencyMs, 120);
    });

    test('success rate is the observed reliability', () {
      var state = health();
      state = state.recordSuccess(latencyMs: 10, now: now);
      state = state.recordFailure(error: 'x', now: now);
      expect(state.successRate, closeTo(0.5, 0.0001));
    });

    test('toJson exposes the counters for diagnostics', () {
      final json = health(
        successes: 3,
        failures: 1,
        consecutive: 1,
        error: 'boom',
        cooldownUntil: now,
      ).toJson();
      expect(json['provider'], 'youtube');
      expect(json['success_count'], 3);
      expect(json['failure_count'], 1);
      expect(json['consecutive_failures'], 1);
      expect(json['last_error'], 'boom');
      expect(json['cooldown_until'], isNotNull);
    });
  });

  group('StreamProviderHealthRegistry', () {
    test('unknown providers start healthy', () {
      final registry = StreamProviderHealthRegistry();
      expect(registry.isAvailable(StreamProviderId.tidal, now: now), isTrue);
      expect(registry.consecutiveFailures(StreamProviderId.tidal), 0);
      expect(registry.snapshot(), isEmpty);
    });

    test('a failure only quarantines the failing provider', () {
      final registry = StreamProviderHealthRegistry();
      registry.recordFailure(
        StreamProviderId.youtube,
        error: 'timeout',
        now: now,
      );
      registry.recordFailure(
        StreamProviderId.youtube,
        error: 'timeout',
        now: now,
      );
      expect(registry.isAvailable(StreamProviderId.youtube, now: now), isFalse);
      expect(
        registry.isAvailable(StreamProviderId.soundCloud, now: now),
        isTrue,
      );
    });

    test('reset restores a provider immediately', () {
      final registry = StreamProviderHealthRegistry();
      registry.recordFailure(
        StreamProviderId.deezer,
        error: 'x',
        now: now,
      );
      registry.recordFailure(
        StreamProviderId.deezer,
        error: 'y',
        now: now,
      );
      registry.reset(StreamProviderId.deezer);
      expect(registry.isAvailable(StreamProviderId.deezer, now: now), isTrue);
      expect(registry.consecutiveFailures(StreamProviderId.deezer), 0);
    });

    test('snapshot is ordered by provider name and resetAll clears it', () {
      final registry = StreamProviderHealthRegistry();
      registry.recordSuccess(StreamProviderId.tidal, latencyMs: 5, now: now);
      registry.recordSuccess(StreamProviderId.qobuz, latencyMs: 5, now: now);
      registry.recordSuccess(StreamProviderId.deezer, latencyMs: 5, now: now);

      final names = registry.snapshot().map((h) => h.provider.name).toList();
      expect(names, <String>['deezer', 'qobuz', 'tidal']);

      registry.resetAll();
      expect(registry.snapshot(), isEmpty);
    });

    test('toJson reports every tracked provider', () {
      final registry = StreamProviderHealthRegistry();
      registry.recordSuccess(StreamProviderId.youtube, latencyMs: 9, now: now);
      final json = registry.toJson();
      final providers = json['providers'] as List<dynamic>;
      expect(providers, hasLength(1));
      expect(
        (providers.first as Map<String, dynamic>)['provider'],
        'youtube',
      );
    });
  });
}
