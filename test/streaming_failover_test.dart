import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:spotiflac_android/services/multi_provider_stream_service.dart';

/// Handler that records every call and answers with a scripted result.
class _FakeHandler extends StreamProviderHandler {
  _FakeHandler(this.id, {this.stream, this.error});

  @override
  final StreamProviderId id;
  final ResolvedStream? stream;
  final Object? error;

  int calls = 0;

  @override
  StreamProviderInfo get info => StreamProviderInfo.of(id);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    calls++;
    if (error != null) throw error!;
    return stream;
  }
}

ResolvedStream _stream(StreamProviderId id, String uri) => ResolvedStream(
  uri: Uri.parse(uri),
  provider: id,
  qualityLabel: 'Opus 160kbps',
  matchedTitle: 'Song',
);

const _request = StreamTrackRequest(title: 'Song', artist: 'Artist');

/// Builds a service whose whole chain is fakes — no network, no YouTube
/// client traffic.
MultiProviderStreamService _service(
  Map<StreamProviderId, _FakeHandler> handlers, {
  StreamProviderHealthRegistry? health,
  StreamResolutionCache? cache,
}) => MultiProviderStreamService(
  overrides: <StreamProviderId, StreamProviderHandler>{
    for (final entry in handlers.entries) entry.key: entry.value,
  },
  validateResolutions: false,
  health: health,
  cache: cache,
  httpClient: _NoopHttpClient(),
);

/// An HTTP client that can never be reached: every test in this file drives
/// the chain through injected handlers only, so any real traffic is a bug.
class _NoopHttpClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    throw StateError('no HTTP traffic is allowed in this test: $request');
  }
}

void main() {
  group('failover chain', () {
    test('answers from the preferred provider when it resolves', () async {
      final youtube = _FakeHandler(
        StreamProviderId.youtube,
        stream: _stream(StreamProviderId.youtube, 'https://yt/a'),
      );
      final soundCloud = _FakeHandler(
        StreamProviderId.soundCloud,
        stream: _stream(StreamProviderId.soundCloud, 'https://sc/a'),
      );
      final service = _service({
        StreamProviderId.youtube: youtube,
        StreamProviderId.soundCloud: soundCloud,
      });
      addTearDown(service.dispose);

      final resolved = await service.resolveStream(_request);
      expect(resolved.provider, StreamProviderId.youtube);
      expect(youtube.calls, 1);
      expect(soundCloud.calls, 0);
    });

    test('falls through the chain when the preferred provider misses',
        () async {
      final tidal = _FakeHandler(StreamProviderId.tidal); // no result
      final youtube = _FakeHandler(
        StreamProviderId.youtube,
        stream: _stream(StreamProviderId.youtube, 'https://yt/a'),
      );
      final service = _service({
        StreamProviderId.tidal: tidal,
        StreamProviderId.youtube: youtube,
      });
      addTearDown(service.dispose);

      final resolved = await service.resolveStream(
        _request,
        preferredProvider: StreamProviderId.tidal,
      );
      expect(resolved.provider, StreamProviderId.youtube);
      // Served by another provider: the UI must be able to say so.
      expect(resolved.viaFallback, isTrue);
      expect(resolved.qualityLabel, contains('fallback'));
    });

    test('a throwing provider does not abort the chain', () async {
      final qobuz = _FakeHandler(
        StreamProviderId.qobuz,
        error: StateError('gateway down'),
      );
      final soundCloud = _FakeHandler(
        StreamProviderId.soundCloud,
        stream: _stream(StreamProviderId.soundCloud, 'https://sc/a'),
      );
      final service = _service({
        StreamProviderId.qobuz: qobuz,
        StreamProviderId.youtube: _FakeHandler(StreamProviderId.youtube),
        StreamProviderId.soundCloud: soundCloud,
      });
      addTearDown(service.dispose);

      final resolved = await service.resolveStream(
        _request,
        preferredProvider: StreamProviderId.qobuz,
      );
      expect(resolved.provider, StreamProviderId.soundCloud);
      expect(qobuz.calls, 1);
    });

    test('throws StreamResolutionException when every provider misses',
        () async {
      final service = _service({
        StreamProviderId.youtube: _FakeHandler(StreamProviderId.youtube),
        StreamProviderId.soundCloud: _FakeHandler(StreamProviderId.soundCloud),
      });
      addTearDown(service.dispose);

      await expectLater(
        service.resolveStream(_request),
        throwsA(isA<StreamResolutionException>()),
      );
    });

    test('previews are rejected unless they are explicitly allowed', () async {
      final deezer = _FakeHandler(
        StreamProviderId.deezer,
        stream: ResolvedStream(
          uri: Uri.parse('https://cdns-preview.deezer.com/a'),
          provider: StreamProviderId.deezer,
          qualityLabel: 'MP3 128kbps preview',
          matchedTitle: 'Song',
          isPreview: true,
        ),
      );
      final youtube = _FakeHandler(
        StreamProviderId.youtube,
        stream: _stream(StreamProviderId.youtube, 'https://yt/a'),
      );
      final service = _service({
        StreamProviderId.deezer: deezer,
        StreamProviderId.youtube: youtube,
      });
      addTearDown(service.dispose);

      final full = await service.resolveStream(
        _request,
        preferredProvider: StreamProviderId.deezer,
      );
      expect(full.provider, StreamProviderId.youtube);
      expect(full.viaFallback, isTrue);

      // The cached full stream wins: allowing previews must never displace
      // real audio that is already resolved.
      final warm = await service.resolveStream(
        _request,
        preferredProvider: StreamProviderId.deezer,
        allowPreview: true,
      );
      expect(warm.provider, StreamProviderId.youtube);

      // On a cold cache the preview is used when the caller opts in.
      final cold = _service({
        StreamProviderId.deezer: _FakeHandler(
          StreamProviderId.deezer,
          stream: ResolvedStream(
            uri: Uri.parse('https://cdns-preview.deezer.com/a'),
            provider: StreamProviderId.deezer,
            qualityLabel: 'MP3 128kbps preview',
            matchedTitle: 'Song',
            isPreview: true,
          ),
        ),
        StreamProviderId.youtube: _FakeHandler(StreamProviderId.youtube),
      });
      addTearDown(cold.dispose);
      final preview = await cold.resolveStream(
        _request,
        preferredProvider: StreamProviderId.deezer,
        allowPreview: true,
      );
      expect(preview.provider, StreamProviderId.deezer);
      expect(preview.isPreview, isTrue);
    });
  });

  group('health-aware failover', () {
    test('skips a provider that is in its cooldown window', () async {
      final now = DateTime.now();
      final health = StreamProviderHealthRegistry()
        ..recordFailure(StreamProviderId.youtube, error: 'x', now: now)
        ..recordFailure(StreamProviderId.youtube, error: 'y', now: now);
      final youtube = _FakeHandler(
        StreamProviderId.youtube,
        stream: _stream(StreamProviderId.youtube, 'https://yt/a'),
      );
      final soundCloud = _FakeHandler(
        StreamProviderId.soundCloud,
        stream: _stream(StreamProviderId.soundCloud, 'https://sc/a'),
      );
      final service = _service({
        StreamProviderId.youtube: youtube,
        StreamProviderId.soundCloud: soundCloud,
      }, health: health);
      addTearDown(service.dispose);

      final resolved = await service.resolveStream(_request);
      expect(resolved.provider, StreamProviderId.soundCloud);
      expect(youtube.calls, 0);
    });

    test('retries every provider when the whole chain is cooling down',
        () async {
      final now = DateTime.now();
      final health = StreamProviderHealthRegistry();
      // Every provider in the chain is cooling down, not just the preferred
      // one: that is the state in which "skip unhealthy providers" would
      // otherwise leave nothing to try.
      for (final id in StreamProviderId.values) {
        health.recordFailure(id, error: 'a', now: now);
        health.recordFailure(id, error: 'b', now: now);
      }
      final youtube = _FakeHandler(
        StreamProviderId.youtube,
        stream: _stream(StreamProviderId.youtube, 'https://yt/a'),
      );
      final service = _service(
        {StreamProviderId.youtube: youtube},
        health: health,
      );
      addTearDown(service.dispose);

      // A provider that failed twice must not take the whole app offline:
      // with nothing healthy left, the chain is retried end to end.
      final resolved = await service.resolveStream(_request);
      expect(resolved.provider, StreamProviderId.youtube);
      expect(youtube.calls, 1);
    });

    test('records health on success and on failure', () async {
      final health = StreamProviderHealthRegistry();
      final youtube = _FakeHandler(
        StreamProviderId.youtube,
        stream: _stream(StreamProviderId.youtube, 'https://yt/a'),
      );
      final service = _service(
        {StreamProviderId.youtube: youtube},
        health: health,
      );
      addTearDown(service.dispose);

      await service.resolveStream(_request);
      expect(health.of(StreamProviderId.youtube).successCount, 1);

      // A hard failure (exception) is a provider failure; a clean "no match"
      // (null) is not.
      final failing = _service({
        StreamProviderId.youtube: _FakeHandler(
          StreamProviderId.youtube,
          error: StateError('boom'),
        ),
      }, health: health);
      addTearDown(failing.dispose);
      await expectLater(
        failing.resolveStream(_request),
        throwsA(isA<StreamResolutionException>()),
      );
      expect(health.of(StreamProviderId.youtube).failureCount, 1);

      final missing = _service(
        {StreamProviderId.youtube: _FakeHandler(StreamProviderId.youtube)},
        health: health,
      );
      addTearDown(missing.dispose);
      await expectLater(
        missing.resolveStream(_request),
        throwsA(isA<StreamResolutionException>()),
      );
      expect(health.of(StreamProviderId.youtube).failureCount, 1);
    });
  });

  group('caching and coalescing', () {
    test('serves a repeat request from the cache', () async {
      final youtube = _FakeHandler(
        StreamProviderId.youtube,
        stream: _stream(StreamProviderId.youtube, 'https://yt/a'),
      );
      final service = _service({StreamProviderId.youtube: youtube});
      addTearDown(service.dispose);

      await service.resolveStream(_request);
      await service.resolveStream(_request);
      expect(youtube.calls, 1);
    });

    test('coalesces concurrent resolutions of the same track', () async {
      final youtube = _FakeHandler(
        StreamProviderId.youtube,
        stream: _stream(StreamProviderId.youtube, 'https://yt/a'),
      );
      final service = _service({StreamProviderId.youtube: youtube});
      addTearDown(service.dispose);

      final results = await Future.wait(<Future<ResolvedStream>>[
        service.resolveStream(_request),
        service.resolveStream(_request),
      ]);
      expect(results.map((r) => r.uri.toString()).toSet(), hasLength(1));
      expect(youtube.calls, 1);
    });

    test('a failed resolution is negatively cached and then retried',
        () async {
      var now = DateTime.now();
      final cache = StreamResolutionCache(clock: () => now);
      final youtube = _FakeHandler(StreamProviderId.youtube);
      final service = _service(
        {StreamProviderId.youtube: youtube},
        cache: cache,
      );
      addTearDown(service.dispose);

      await expectLater(
        service.resolveStream(_request),
        throwsA(isA<StreamResolutionException>()),
      );
      await expectLater(
        service.resolveStream(_request),
        throwsA(isA<StreamResolutionException>()),
      );
      // The second call never reached the provider: the negative entry served
      // it, so a scrolling list cannot hammer a dead provider.
      expect(youtube.calls, 1);

      now = now.add(const Duration(minutes: 5));
      await expectLater(
        service.resolveStream(_request),
        throwsA(isA<StreamResolutionException>()),
      );
      expect(youtube.calls, 2);
    });

    test('invalidate forces a fresh resolution', () async {
      final youtube = _FakeHandler(
        StreamProviderId.youtube,
        stream: _stream(StreamProviderId.youtube, 'https://yt/a'),
      );
      final service = _service({StreamProviderId.youtube: youtube});
      addTearDown(service.dispose);

      await service.resolveStream(_request);
      service.invalidate(_request, StreamProviderId.youtube);
      await service.resolveStream(_request);
      expect(youtube.calls, 2);
    });
  });

  group('failover chain shape', () {
    test('preferred leads, then the anonymous providers', () {
      final service = _service({});
      addTearDown(service.dispose);
      final chain = service.failoverChain(StreamProviderId.tidal);
      expect(chain.first, StreamProviderId.tidal);
      expect(chain[1], StreamProviderId.youtube);
      expect(chain[2], StreamProviderId.soundCloud);
      // Every provider appears exactly once.
      expect(chain.toSet(), hasLength(chain.length));
      expect(chain.toSet(), StreamProviderId.values.toSet());
    });
  });
}
