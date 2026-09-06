import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/multi_provider_stream_service.dart';
import 'package:spotiflac_android/services/provider_health_store.dart';

/// In-memory [ProviderHealthKeyValueStore] fake with optional failure
/// injection for the error-path tests.
class _FakeStore implements ProviderHealthKeyValueStore {
  _FakeStore({Map<String, String> initial = const {}})
    : _data = Map<String, String>.of(initial);

  final Map<String, String> _data;
  int writes = 0;
  Object? writeError;

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    if (writeError != null) throw writeError!;
    writes++;
    _data[key] = value;
  }

  Map<String, dynamic>? storedJson(String key) {
    final raw = _data[key];
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }
}

void main() {
  final now = DateTime.utc(2026, 1, 1, 12);

  group('StreamProviderHealth JSON round-trip', () {
    test('toJson → fromJson preserves metrics', () {
      var health = StreamProviderHealth(
        provider: StreamProviderId.tidal,
      ).recordFailure(error: 'HTTP 503', latencyMs: 900, now: now);
      health = health.recordSuccess(latencyMs: 320, now: now);
      health = health.recordFailure(error: 'timeout', latencyMs: 420, now: now);

      final restored = StreamProviderHealth.fromJson(health.toJson());
      expect(restored, isNotNull);
      expect(restored!.provider, StreamProviderId.tidal);
      expect(restored.successCount, 1);
      expect(restored.failureCount, 2);
      expect(restored.consecutiveFailures, 1);
      expect(restored.lastLatencyMs, 420);
      expect(restored.lastError, 'timeout');
      expect(restored.lastSuccessAt, now.toUtc());
      expect(restored.lastFailureAt, now.toUtc());
    });

    test('fromJson drops the cooldown (fresh session, fresh circuit)', () {
      final health = StreamProviderHealth(
        provider: StreamProviderId.youtube,
      ).recordFailure(error: 'a', now: now).recordFailure(
        error: 'b',
        now: now,
      );
      expect(health.cooldownUntil, isNotNull);

      final restored = StreamProviderHealth.fromJson(health.toJson())!;
      expect(restored.cooldownUntil, isNull);
      expect(restored.isAvailable(DateTime.now()), isTrue);
    });

    test('fromJson rejects unknown providers and hostile values', () {
      expect(StreamProviderHealth.fromJson({'provider': 'madeup'}), isNull);
      expect(StreamProviderHealth.fromJson({'provider': 42}), isNull);
      expect(StreamProviderHealth.fromJson({}), isNull);

      final hostile = StreamProviderHealth.fromJson(<String, dynamic>{
        'provider': 'spotify',
        'success_count': -5,
        'failure_count': 99999999999999,
        'consecutive_failures': 'many',
        'last_latency_ms': -1,
        'last_success_at': 'not-a-date',
        'last_error': '',
      });
      expect(hostile, isNotNull);
      expect(hostile!.successCount, 0);
      expect(hostile.failureCount, 1000000000); // clamped, not crashed
      expect(hostile.consecutiveFailures, 0);
      expect(hostile.lastLatencyMs, isNull);
      expect(hostile.lastSuccessAt, isNull);
      expect(hostile.lastError, isNull);
    });
  });

  group('StreamProviderHealthRegistry restore', () {
    test('registry toJson → mergeRestored round-trips every provider row',
        () {
      final registry = StreamProviderHealthRegistry()
        ..recordSuccess(StreamProviderId.youtube, latencyMs: 100, now: now)
        ..recordFailure(
          StreamProviderId.soundCloud,
          error: 'DNS failure',
          now: now,
        );

      final restored = StreamProviderHealthRegistry()
        ..mergeRestored(registry.toJson());
      final youtube = restored.of(StreamProviderId.youtube);
      expect(youtube.successCount, 1);
      final soundcloud = restored.of(StreamProviderId.soundCloud);
      expect(soundcloud.failureCount, 1);
      expect(soundcloud.lastError, 'DNS failure');
    });

    test('mergeRestored never overwrites live observations', () {
      final registry = StreamProviderHealthRegistry()
        ..recordSuccess(StreamProviderId.youtube, latencyMs: 100, now: now);
      final stored = <String, dynamic>{
        'providers': [
          StreamProviderHealth(
            provider: StreamProviderId.youtube,
            successCount: 99,
          ).toJson(),
          StreamProviderHealth(
            provider: StreamProviderId.qobuz,
            failureCount: 7,
          ).toJson(),
        ],
      };

      final merged = registry.mergeRestored(stored);
      expect(merged, 1); // youtube skipped (live row wins)
      expect(registry.of(StreamProviderId.youtube).successCount, 1);
      expect(registry.of(StreamProviderId.qobuz).failureCount, 7);
    });

    test('mergeRestored tolerates garbage rows', () {
      final registry = StreamProviderHealthRegistry();
      expect(registry.mergeRestored(null), 0);
      expect(registry.mergeRestored(<String, dynamic>{}), 0);
      expect(
        registry.mergeRestored(<String, dynamic>{
          'providers': [
            'not-a-map',
            42,
            <String, dynamic>{'nope': true},
          ],
        }),
        0,
      );
      expect(registry.snapshot(), isEmpty);
    });

    test('listener failures never break metric recording', () {
      final registry = StreamProviderHealthRegistry();
      registry.addListener(() => throw StateError('observer bug'));
      var seen = 0;
      registry.addListener(() => seen++);

      registry.recordSuccess(StreamProviderId.youtube, now: now);
      registry.recordFailure(
        StreamProviderId.youtube,
        error: 'x',
        now: now,
      );
      expect(seen, 2);
      expect(registry.of(StreamProviderId.youtube).successCount, 1);
    });
  });

  group('ProviderHealthStore', () {
    test('attach restores persisted metrics into the registry', () async {
      final persisted = jsonEncode(<String, dynamic>{
        'schema': ProviderHealthStore.schemaVersion,
        'saved_at': now.toIso8601String(),
        'providers': [
          StreamProviderHealth(
            provider: StreamProviderId.deezer,
            successCount: 12,
            failureCount: 3,
            lastLatencyMs: 250,
          ).toJson(),
        ],
      });
      final store = ProviderHealthStore(
        store: _FakeStore(initial: {ProviderHealthStore.prefsKey: persisted}),
      );
      final registry = StreamProviderHealthRegistry();
      await store.attach(registry);

      final deezer = registry.of(StreamProviderId.deezer);
      expect(deezer.successCount, 12);
      expect(deezer.failureCount, 3);
      // Metrics restored, circuit state fresh:
      expect(deezer.isAvailable(DateTime.now()), isTrue);
    });

    test('metric changes are debounced-persisted once', () async {
      final fake = _FakeStore();
      final store = ProviderHealthStore(
        store: fake,
        persistDebounce: Duration.zero,
      );
      final registry = StreamProviderHealthRegistry();
      await store.attach(registry);

      registry.recordSuccess(StreamProviderId.youtube, latencyMs: 80);
      registry.recordSuccess(StreamProviderId.youtube, latencyMs: 90);
      registry.recordFailure(
        StreamProviderId.tidal,
        error: 'HTTP 500',
        latencyMs: 300,
      );
      // Coalesce the zero-duration debounce timers into a single write.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(fake.writes, 1);
      final stored = fake.storedJson(ProviderHealthStore.prefsKey)!;
      expect(stored['schema'], ProviderHealthStore.schemaVersion);
      final providers = stored['providers'] as List<dynamic>;
      expect(providers.length, 2); // youtube + tidal
    });

    test('flush persists immediately and dispose writes a final snapshot',
        () async {
      final fake = _FakeStore();
      final store = ProviderHealthStore(
        store: fake,
        persistDebounce: const Duration(hours: 1),
      );
      final registry = StreamProviderHealthRegistry();
      await store.attach(registry);

      registry.recordSuccess(StreamProviderId.youtube, now: now);
      await store.flush();
      expect(fake.writes, 1);
      expect(fake.storedJson(ProviderHealthStore.prefsKey), isNotNull);

      registry.recordSuccess(StreamProviderId.youtube, now: now);
      await store.dispose();
      expect(fake.writes, 2);

      // Mutations after dispose never reach storage.
      registry.recordFailure(
        StreamProviderId.youtube,
        error: 'late',
        now: now,
      );
      await Future<void>.delayed(Duration.zero);
      expect(fake.writes, 2);
    });

    test('corrupt or foreign-schema snapshots are discarded, not fatal',
        () async {
      for (final bad in ['{not json', '', '[]', '{"schema": 99}']) {
        final store = ProviderHealthStore(
          store: _FakeStore(initial: {ProviderHealthStore.prefsKey: bad}),
        );
        final registry = StreamProviderHealthRegistry();
        await store.attach(registry);
        expect(registry.snapshot(), isEmpty, reason: 'payload: $bad');
      }
    });

    test('write failures are swallowed (persistence never breaks playback)',
        () async {
      final fake = _FakeStore()..writeError = StateError('disk full');
      final store = ProviderHealthStore(
        store: fake,
        persistDebounce: Duration.zero,
      );
      final registry = StreamProviderHealthRegistry();
      await store.attach(registry);

      registry.recordSuccess(StreamProviderId.youtube, now: now);
      await store.flush(); // must not throw
      expect(fake.writes, 0);
    });
  });
}
