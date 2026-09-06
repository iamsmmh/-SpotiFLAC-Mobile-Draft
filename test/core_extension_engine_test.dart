import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/application/extension_engine.dart';
import 'package:spotiflac_android/core/application/retry_policy.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';

class _FakeDriver implements ExtensionDriver {
  _FakeDriver(this.providerId, {this.responder});

  @override
  final String providerId;

  /// Responder receives the attempt counter (1-based) and may throw.
  Future<ExtensionPayload> Function(int attempt)? responder;
  final calls = <int>[];

  @override
  Future<ExtensionPayload> resolve(
    ExtensionRequest request,
    CancellationToken cancellation,
  ) async {
    final attempt = calls.length + 1;
    calls.add(attempt);
    final fn = responder;
    if (fn == null) {
      return ExtensionPayload(<String, Object?>{'by': providerId});
    }
    return fn(attempt);
  }
}

ExtensionRequest requestFor(String id) => ExtensionRequest(
  kind: ExtensionRequestKind.downloadUrl,
  track: TrackRef(id: id, name: 'Song', artistName: 'Artist'),
  quality: 'LOSSLESS',
);

void main() {
  group('PriorityExtensionEngine resolution', () {
    test('resolves through the highest-priority provider', () async {
      final engine = PriorityExtensionEngine(
        drivers: <ExtensionDriver>[
          _FakeDriver('deezer'),
          _FakeDriver('qobuz'),
        ],
        providerOrder: const <String>['qobuz', 'deezer'],
        sleeper: (_) async {},
      );

      final resolution = await engine.resolve(requestFor('t1'));
      expect(resolution.providerId, 'qobuz');
      expect(resolution.payload['by'], 'qobuz');
      expect(resolution.priorFailures, isEmpty);
      expect(engine.healthOf('qobuz').totalSuccesses, 1);
    });

    test('switches to the next provider after terminal provider failure',
        () async {
      final failing = _FakeDriver(
        'deezer',
        responder: (attempt) async {
          throw const CoreError(
            category: CoreErrorCategory.notFound,
            message: 'gone',
            retryable: false,
          );
        },
      );
      final engine = PriorityExtensionEngine(
        drivers: <ExtensionDriver>[failing, _FakeDriver('qobuz')],
        providerOrder: const <String>['deezer', 'qobuz'],
        sleeper: (_) async {},
      );

      final resolution = await engine.resolve(requestFor('t2'));
      expect(resolution.providerId, 'qobuz');
      expect(resolution.priorFailures, hasLength(1));
      expect(resolution.priorFailures.single.providerId, 'deezer');
      expect(
        engine.healthOf('deezer').consecutiveFailures,
        1,
        reason: 'provider health tracks terminal failures',
      );
      expect(failing.calls, hasLength(1), reason: 'notFound is not retried');
    });

    test('retries transient provider failures before switching', () async {
      final flaky = _FakeDriver(
        'deezer',
        responder: (attempt) async {
          if (attempt < 3) {
            throw const CoreError(
              category: CoreErrorCategory.network,
              message: 'flaky',
            );
          }
          return ExtensionPayload(const <String, Object?>{'attempt': 3});
        },
      );
      final engine = PriorityExtensionEngine(
        drivers: <ExtensionDriver>[flaky],
        providerOrder: const <String>['deezer'],
        retryPolicy: const RetryPolicy(maxAttempts: 3),
        sleeper: (_) async {},
      );

      final resolution = await engine.resolve(requestFor('t3'));
      expect(resolution.providerId, 'deezer');
      expect(flaky.calls, hasLength(3));
      expect(resolution.priorFailures, hasLength(2));
      expect(engine.healthOf('deezer').consecutiveFailures, 0);
    });

    test('exhaustion throws aggregated ExtensionExhaustedError', () async {
      final engine = PriorityExtensionEngine(
        drivers: <ExtensionDriver>[
          _FakeDriver(
            'a',
            responder: (_) async => throw const CoreError(
              category: CoreErrorCategory.rateLimited,
              message: 'slow down',
            ),
          ),
          _FakeDriver(
            'b',
            responder: (_) async => throw StateError('js runtime exploded'),
          ),
        ],
        providerOrder: const <String>['a', 'b'],
        sleeper: (_) async {}, // instant backoff: deterministic + fast
      );

      final resolution = engine.resolve(requestFor('t4'));
      await expectLater(
        resolution,
        throwsA(
          isA<ExtensionExhaustedError>()
              .having((e) => e.failures, 'failures', hasLength(2))
              .having(
                (e) => e.failures[1].cause,
                'second failure cause',
                isA<StateError>(),
              )
              .having(
                (e) => e.failures[1].providerId,
                'second failure provider',
                'b',
              )
              .having((e) => e.category, 'category',
                  CoreErrorCategory.rateLimited)
              .having((e) => e.isRetryable, 'retryable', isTrue),
        ),
      );
      // The raw StateError above is asserted via `failures[1].cause`: the
      // engine normalizes it into the aggregated error, never rethrowing it.
    });

    test('no registered provider yields a normalized provider error', () async {
      final engine = PriorityExtensionEngine(
        providerOrder: const <String>['ghost'],
      );
      await expectLater(
        engine.resolve(requestFor('t5')),
        throwsA(
          isA<CoreError>().having(
            (e) => e.category,
            'category',
            CoreErrorCategory.provider,
          ),
        ),
      );
    });

    test('cancellation aborts without counting as a provider failure',
        () async {
      final source = CancellationTokenSource();
      final engine = PriorityExtensionEngine(
        drivers: <ExtensionDriver>[
          _FakeDriver(
            'slow',
            responder: (_) async {
              source.cancel('cancelled');
              await Future<void>.delayed(Duration.zero);
              return ExtensionPayload(const <String, Object?>{});
            },
          ),
          _FakeDriver('next'),
        ],
        providerOrder: const <String>['slow', 'next'],
      );

      await expectLater(
        engine.resolve(requestFor('t6'), cancellation: source.token),
        throwsA(isA<JobCancelledException>()),
      );
      expect(
        engine.healthOf('slow').consecutiveFailures,
        0,
        reason: 'cancellation must not pollute provider health',
      );
    });
  });

  group('dynamic provider updates', () {
    test('register/unregister updates the chain at runtime', () async {
      final engine = PriorityExtensionEngine(
        providerOrder: const <String>['primary'],
      );
      expect(engine.providerOrder, <String>['primary']);

      // A hot-installed extension joins the chain even when its id is new.
      engine.registerDriver(_FakeDriver('primary'));
      engine.registerDriver(_FakeDriver('hotfix'));
      expect(
        engine.providerOrder,
        <String>['primary', 'hotfix'],
      );

      final resolution = await engine.resolve(requestFor('t7'));
      expect(resolution.providerId, 'primary');

      engine.unregisterDriver('primary');
      expect(engine.providerOrder, <String>['hotfix']);
      final fallback = await engine.resolve(requestFor('t8'));
      expect(fallback.providerId, 'hotfix');
    });

    test('updateProviderOrder re-lanes without dropping registered drivers',
        () async {
      final engine = PriorityExtensionEngine(
        drivers: <ExtensionDriver>[
          _FakeDriver('a'),
          _FakeDriver('b'),
          _FakeDriver('c'),
        ],
        providerOrder: const <String>['a', 'b', 'c'],
      );
      engine.updateProviderOrder(const <String>['c', 'a']);
      expect(
        engine.providerOrder,
        <String>['c', 'a', 'b'],
        reason: 'unlisted-but-registered drivers keep a tail slot',
      );
      engine.updateProviderOrder(const <String>['a', 'a', 'b']);
      expect(engine.providerOrder, <String>['a', 'b', 'c']);
    });
  });
}
