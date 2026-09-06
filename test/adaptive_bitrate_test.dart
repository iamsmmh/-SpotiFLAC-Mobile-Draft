import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/streaming_engine.dart';

StreamVariant _variant(int kbps, {DateTime? expiresAt}) => StreamVariant(
  uri: 'https://cdn/$kbps',
  bitrateKbps: kbps,
  codec: 'opus',
  expiresAt: expiresAt,
);

void main() {
  final ladder = <StreamVariant>[
    _variant(48),
    _variant(96),
    _variant(160),
  ];

  group('AdaptiveBitrateSelector', () {
    test('without a measurement it picks the highest rung', () {
      const selector = AdaptiveBitrateSelector();
      final decision = selector.select(ladder);
      expect(decision.targetKbps, 160);
      expect(decision.variant!.uri, 'https://cdn/160');
      expect(decision.measuredBytesPerSecond, isNull);
    });

    test('balanced mode leaves ~25% headroom for jitter', () {
      const selector = AdaptiveBitrateSelector();
      // 160kbps needs 20,000 B/s; a 20,000 B/s link leaves no headroom, so
      // the ladder must step down to 96kbps (12,000 B/s).
      final decision = selector.select(
        ladder,
        measuredBytesPerSecond: 20000,
      );
      expect(decision.targetKbps, 96);
      expect(decision.variant!.uri, 'https://cdn/96');
    });

    test('qualityFirst spends almost the whole link', () {
      const selector = AdaptiveBitrateSelector(
        mode: AdaptiveBitrateMode.qualityFirst,
      );
      final decision = selector.select(
        ladder,
        measuredBytesPerSecond: 24000,
      );
      // 0.95 × 24,000 = 22,800 B/s ≥ 20,000 B/s → the top rung fits.
      expect(decision.targetKbps, 160);
    });

    test('dataSaver stays well below the measured link', () {
      const selector = AdaptiveBitrateSelector(
        mode: AdaptiveBitrateMode.dataSaver,
      );
      final decision = selector.select(
        ladder,
        measuredBytesPerSecond: 24000,
      );
      // 0.5 × 24,000 = 12,000 B/s → 96kbps (12,000) fits, 160 does not.
      expect(decision.targetKbps, 96);
    });

    test('a saturated link degrades to the lowest rung instead of failing',
        () {
      const selector = AdaptiveBitrateSelector();
      final decision = selector.select(ladder, measuredBytesPerSecond: 1000);
      expect(decision.variant, isNotNull);
      expect(decision.targetKbps, 48);
      expect(decision.reason, contains('too slow'));
    });

    test('the requested quality level caps the ladder', () {
      const selector = AdaptiveBitrateSelector();
      final decision = selector.select(
        <StreamVariant>[_variant(128), _variant(320), _variant(1411)],
        requested: AudioQualityLevel.normal,
      );
      // Normal = 192kbps reference → 320 and 1411 are excluded.
      expect(decision.targetKbps, 128);
    });

    test('roaming is capped regardless of the measured link', () {
      const selector = AdaptiveBitrateSelector();
      final decision = selector.select(
        <StreamVariant>[_variant(320), _variant(128)],
        measuredBytesPerSecond: 10 * 1000 * 1000,
        profile: NetworkProfile.roaming,
      );
      expect(decision.targetKbps, 128);
    });

    test('expired rungs are never selected', () {
      const selector = AdaptiveBitrateSelector();
      final expired = <StreamVariant>[
        _variant(160, expiresAt: DateTime(2020)),
        _variant(96),
      ];
      expect(selector.select(expired).targetKbps, 96);

      final allExpired = <StreamVariant>[
        _variant(160, expiresAt: DateTime(2020)),
      ];
      final empty = selector.select(allExpired);
      expect(empty.variant, isNull);
      expect(empty.targetKbps, isNull);
      expect(empty.reason, contains('no usable variant'));
    });

    test('an empty ladder yields an empty decision', () {
      const selector = AdaptiveBitrateSelector();
      final decision = selector.select(const <StreamVariant>[]);
      expect(decision.variant, isNull);
    });

    test('stepDown walks the ladder and stops at the bottom', () {
      const selector = AdaptiveBitrateSelector();
      expect(selector.stepDown(160, ladder), 96);
      expect(selector.stepDown(96, ladder), 48);
      expect(selector.stepDown(48, ladder), isNull);
    });

    test('variant throughput is derived from the bitrate', () {
      expect(_variant(320).bytesPerSecond, 40000);
    });
  });

  group('StreamRecoveryPolicy', () {
    const policy = StreamRecoveryPolicy();

    StreamRecoveryContext context({
      Duration stall = Duration.zero,
      bool buffering = false,
      Duration? untilExpiry,
      int attempts = 0,
      int providerFailures = 0,
    }) => StreamRecoveryContext(
      stallDuration: stall,
      buffering: buffering,
      untilExpiry: untilExpiry,
      attempts: attempts,
      providerFailures: providerFailures,
    );

    test('a brief buffering blip is tolerated', () {
      expect(
        policy.forStall(
          context(buffering: true, stall: const Duration(seconds: 2)),
        ),
        StreamRecoveryAction.wait,
      );
    });

    test('a real stall first re-resolves, then fails over', () {
      expect(
        policy.forStall(
          context(
            buffering: true,
            stall: const Duration(seconds: 30),
            attempts: 0,
          ),
        ),
        StreamRecoveryAction.reResolve,
      );
      expect(
        policy.forStall(
          context(
            buffering: true,
            stall: const Duration(seconds: 30),
            attempts: 1,
          ),
        ),
        StreamRecoveryAction.failover,
      );
    });

    test('recovery is bounded', () {
      expect(
        policy.forStall(
          context(
            buffering: true,
            stall: const Duration(seconds: 30),
            attempts: 3,
          ),
        ),
        StreamRecoveryAction.abort,
      );
    });

    test('an error on an expired URL re-resolves; a flaky provider fails over',
        () {
      expect(
        policy.forError(
          context(untilExpiry: const Duration(seconds: -1), attempts: 0),
        ),
        StreamRecoveryAction.reResolve,
      );
      expect(
        policy.forError(
          context(untilExpiry: const Duration(minutes: 5), attempts: 0),
        ),
        StreamRecoveryAction.reResolve,
      );
      expect(
        policy.forError(
          context(
            untilExpiry: const Duration(minutes: 5),
            attempts: 0,
            providerFailures: 2,
          ),
        ),
        StreamRecoveryAction.failover,
      );
      expect(
        policy.forError(
          context(untilExpiry: const Duration(minutes: 5), attempts: 3),
        ),
        StreamRecoveryAction.abort,
      );
    });

    test('expiry refresh is proactive and separately budgeted', () {
      final now = DateTime(2026, 6, 1, 12);
      expect(
        policy.forExpiry(
          context(untilExpiry: const Duration(minutes: 5)),
        ),
        StreamRecoveryAction.wait,
      );
      expect(
        policy.forExpiry(context(untilExpiry: const Duration(seconds: 30))),
        StreamRecoveryAction.reResolve,
      );
      expect(
        policy.forExpiry(
          context(untilExpiry: const Duration(seconds: 30)),
          previousExpiryRefreshes: 2,
        ),
        StreamRecoveryAction.wait,
      );

      final refreshAt = policy.nextRefreshAt(
        now.add(const Duration(hours: 1)),
        now: now,
      );
      expect(refreshAt, now.add(const Duration(minutes: 58)));
      expect(policy.nextRefreshAt(null), isNull);
      expect(
        policy.nextRefreshAt(
          now.add(const Duration(hours: 1)),
          previousExpiryRefreshes: 2,
        ),
        isNull,
      );
    });
  });

  group('StreamRecoveryBudget', () {
    test('counts attempts inside the window and forgets old ones', () {
      var clock = DateTime(2026, 6, 1, 12);
      final budget = StreamRecoveryBudget(
        policy: const StreamRecoveryPolicy(),
        clock: () => clock,
      );
      expect(budget.attempts, 0);
      expect(budget.record(), 1);
      expect(budget.record(), 2);

      clock = clock.add(const Duration(minutes: 6));
      expect(budget.attempts, 0);
    });

    test('expiry refreshes do not consume the failure budget', () {
      final budget = StreamRecoveryBudget(
        policy: const StreamRecoveryPolicy(),
      );
      expect(budget.recordExpiryRefresh(), 1);
      expect(budget.attempts, 0);
      budget.record();
      expect(budget.attempts, 1);
      budget.reset();
      expect(budget.attempts, 0);
      expect(budget.expiryRefreshes, 0);
    });

    test('builds a context from the live attempt count', () {
      final budget = StreamRecoveryBudget(
        policy: const StreamRecoveryPolicy(),
      );
      budget.record();
      final context = budget.context(buffering: true);
      expect(context.attempts, 1);
      expect(context.buffering, isTrue);
    });
  });
}
