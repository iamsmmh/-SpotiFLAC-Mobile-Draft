import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/cache/cache_policy.dart';

CachePolicyEntry _entry(
  String key, {
  int bytes = 10,
  DateTime? at,
  bool complete = true,
  bool pinned = false,
}) =>
    CachePolicyEntry(
      key: key,
      bytes: bytes,
      lastAccessedAt: at ?? DateTime.utc(2026, 9, 1, 12),
      complete: complete,
      pinned: pinned,
    );

void main() {
  final now = DateTime.utc(2026, 9, 6, 12);

  group('SmartCacheConfig', () {
    test('defaults are production-sane', () {
      const config = SmartCacheConfig();
      expect(config.maxBytes, 512 * 1024 * 1024);
      expect(config.ttl, const Duration(days: 30));
      expect(config.warmLookahead, 2);
      expect(config.allowMeteredCapture, isFalse);
      expect(config.allowMeteredWarm, isFalse);
    });

    test('copyWith keeps unspecified fields', () {
      const config = SmartCacheConfig();
      final tuned = config.copyWith(maxBytes: 1024, warmLookahead: 4);
      expect(tuned.maxBytes, 1024);
      expect(tuned.warmLookahead, 4);
      expect(tuned.ttl, config.ttl);
    });
  });

  group('admission', () {
    test('denies when capture is disabled', () {
      const policy = SmartCachePolicy();
      final decision = policy.admission(
        captureEnabled: false,
        network: CacheNetworkState.wifi,
        currentBytes: 0,
      );
      expect(decision.isAllowed, isFalse);
    });

    test('denies offline', () {
      const policy = SmartCachePolicy();
      expect(
        policy
            .admission(
              captureEnabled: true,
              network: CacheNetworkState.offline,
              currentBytes: 0,
            )
            .isAllowed,
        isFalse,
      );
    });

    test('denies metered unless allowed', () {
      const policy = SmartCachePolicy();
      expect(
        policy
            .admission(
              captureEnabled: true,
              network: CacheNetworkState.cellular,
              currentBytes: 0,
            )
            .isAllowed,
        isFalse,
      );
      final meteredOk = SmartCachePolicy(
        config: SmartCacheConfig(allowMeteredCapture: true),
      ).admission(
        captureEnabled: true,
        network: CacheNetworkState.cellular,
        currentBytes: 0,
      );
      expect(meteredOk.isAllowed, isTrue);
    });

    test('denies artifacts beyond the size cap', () {
      const policy = SmartCachePolicy(
        config: SmartCacheConfig(maxArtifactBytes: 100),
      );
      expect(
        policy
            .admission(
              captureEnabled: true,
              network: CacheNetworkState.wifi,
              currentBytes: 0,
              bytes: 101,
            )
            .isAllowed,
        isFalse,
      );
      expect(
        policy
            .admission(
              captureEnabled: true,
              network: CacheNetworkState.wifi,
              currentBytes: 0,
              bytes: 100,
            )
            .isAllowed,
        isTrue,
      );
    });

    test('denies when the byte budget would overflow', () {
      const policy = SmartCachePolicy(config: SmartCacheConfig(maxBytes: 100));
      expect(
        policy
            .admission(
              captureEnabled: true,
              network: CacheNetworkState.wifi,
              currentBytes: 90,
              bytes: 20,
            )
            .isAllowed,
        isFalse,
      );
      // Unknown size is admitted while there is headroom at all.
      expect(
        policy
            .admission(
              captureEnabled: true,
              network: CacheNetworkState.wifi,
              currentBytes: 99,
            )
            .isAllowed,
        isTrue,
      );
      expect(
        policy
            .admission(
              captureEnabled: true,
              network: CacheNetworkState.wifi,
              currentBytes: 100,
            )
            .isAllowed,
        isFalse,
      );
    });
  });

  group('expiration', () {
    test('returns keys older than the TTL', () {
      const policy = SmartCachePolicy(
        config: SmartCacheConfig(ttl: Duration(days: 7)),
      );
      final expired = policy.expiredKeys([
        _entry('fresh', at: now.subtract(const Duration(hours: 1))),
        _entry('old', at: now.subtract(const Duration(days: 8))),
        _entry('edge', at: now.subtract(const Duration(days: 7))),
      ], now);
      // Strictly older than the TTL expires; the boundary entry survives.
      expect(expired, <String>['old']);
    });
  });

  group('evictionPlan', () {
    test('no eviction while under budget', () {
      const policy = SmartCachePolicy();
      final plan = policy.evictionPlan(
        [_entry('a', bytes: 10), _entry('b', bytes: 10)],
        currentBytes: 20,
        budgetBytes: 100,
        now: now,
      );
      expect(plan.evictKeys, isEmpty);
      expect(plan.isEmpty, isTrue);
    });

    test('unlimited budget never evicts', () {
      const policy = SmartCachePolicy();
      final plan = policy.evictionPlan(
        [_entry('a', bytes: 10)],
        currentBytes: 10,
        budgetBytes: 0,
        now: now,
      );
      expect(plan.evictKeys, isEmpty);
    });

    test('evicts least-recently-accessed first until under the floor', () {
      const policy = SmartCachePolicy(
        config: SmartCacheConfig(
          maxBytes: 100,
          evictionHeadroomBytes: 20,
          ttl: Duration(days: 30),
        ),
      );
      final plan = policy.evictionPlan(
        [
          _entry('oldest', bytes: 30, at: now.subtract(const Duration(days: 3))),
          _entry('middle', bytes: 30, at: now.subtract(const Duration(days: 2))),
          _entry('newest', bytes: 30, at: now.subtract(const Duration(days: 1))),
        ],
        currentBytes: 90,
        budgetBytes: 100,
        now: now,
      );
      // Floor = 80; evicting 'oldest' (30) lands at 60 ≤ 80.
      expect(plan.evictKeys, <String>['oldest']);
      expect(plan.freedBytes, 30);
    });

    test('pinned and partial entries are immune', () {
      const policy = SmartCachePolicy(
        config: SmartCacheConfig(
          maxBytes: 10,
          evictionHeadroomBytes: 0,
          ttl: Duration(days: 30),
        ),
      );
      final plan = policy.evictionPlan(
        [
          _entry('pinned', bytes: 50, pinned: true, at: now.subtract(const Duration(days: 5))),
          _entry('partial', bytes: 50, complete: false, at: now.subtract(const Duration(days: 4))),
        ],
        currentBytes: 100,
        budgetBytes: 10,
        now: now,
      );
      expect(plan.evictKeys, isEmpty);
    });

    test('expired keys are reported for deletion, not eviction', () {
      const policy = SmartCachePolicy(
        config: SmartCacheConfig(
          ttl: Duration(days: 1),
          maxBytes: 100,
          evictionHeadroomBytes: 0,
        ),
      );
      final plan = policy.evictionPlan(
        [
          _entry('old', bytes: 40, at: now.subtract(const Duration(days: 5))),
          _entry('fresh', bytes: 40, at: now.subtract(const Duration(hours: 1))),
        ],
        currentBytes: 80,
        budgetBytes: 50,
        now: now,
      );
      expect(plan.expireKeys, <String>['old']);
      // Only 'fresh' is evictable (40 bytes) — still over the floor of 50,
      // but nothing else may go.
      expect(plan.evictKeys, <String>['fresh']);
      expect(plan.freedBytes, 40);
    });
  });

  group('warmPlan', () {
    test('empty when offline or metered (unless allowed)', () {
      const policy = SmartCachePolicy();
      expect(
        policy
            .warmPlan(
              candidates: const [WarmCandidate(trackKey: 'a')],
              cachedKeys: const <String>{},
              network: CacheNetworkState.offline,
              currentBytes: 0,
            )
            .warm,
        isEmpty,
      );
      expect(
        policy
            .warmPlan(
              candidates: const [WarmCandidate(trackKey: 'a')],
              cachedKeys: const <String>{},
              network: CacheNetworkState.cellular,
              currentBytes: 0,
            )
            .warm,
        isEmpty,
      );
    });

    test('caps at the lookahead and skips cached/warming keys', () {
      const policy = SmartCachePolicy(
        config: SmartCacheConfig(warmLookahead: 2),
      );
      final plan = policy.warmPlan(
        candidates: const [
          WarmCandidate(trackKey: 'next1', priority: 2),
          WarmCandidate(trackKey: 'next2', priority: 1),
          WarmCandidate(trackKey: 'next3', priority: 0),
          WarmCandidate(trackKey: 'cached', priority: 0),
          WarmCandidate(trackKey: 'warming', priority: 0, alreadyWarming: true),
        ],
        cachedKeys: const {'cached'},
        network: CacheNetworkState.wifi,
        currentBytes: 0,
      );
      expect(plan.warm, <String>['next1', 'next2']);
      expect(plan.skipped, containsAll(<String>['next3', 'cached', 'warming']));
    });

    test('budget-aware: stops warming when items would overflow', () {
      const policy = SmartCachePolicy(config: SmartCacheConfig(maxBytes: 100));
      final plan = policy.warmPlan(
        candidates: const [
          WarmCandidate(trackKey: 'a'),
          WarmCandidate(trackKey: 'b'),
        ],
        cachedKeys: const <String>{},
        network: CacheNetworkState.wifi,
        currentBytes: 60,
        estimatedBytesPerItem: 30,
      );
      // 60 + 30 = 90 fits; 90 + 30 overflows → only 'a'.
      expect(plan.warm, <String>['a']);
      expect(plan.skipped, <String>['b']);
    });
  });

  group('CacheNetworkState', () {
    test('named states carry the right flags', () {
      expect(CacheNetworkState.offline.online, isFalse);
      expect(CacheNetworkState.wifi.metered, isFalse);
      expect(CacheNetworkState.cellular.metered, isTrue);
    });
  });
}
