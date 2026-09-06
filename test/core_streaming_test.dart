import 'package:flutter_test/flutter_test.dart';
import 'package:spotimusic/core/streaming/stream_provider.dart';
import 'package:spotimusic/core/streaming/stream_resolver.dart';
import 'package:spotimusic/core/streaming/stream_session.dart';
import 'package:spotimusic/core/streaming/streaming_service.dart';
import 'package:spotimusic/models/track.dart';

Track _track() => const Track(
  id: 't1',
  name: 'Test Track',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);

void main() {
  group('StreamProtocolDetector', () {
    test('URL extension wins', () {
      expect(
        StreamProtocolDetector.detect('https://x/y/audio.m3u8'),
        StreamProtocol.hls,
      );
      expect(
        StreamProtocolDetector.detect('https://x/y/manifest.mpd'),
        StreamProtocol.dash,
      );
      expect(
        StreamProtocolDetector.detect('https://x/y/file.flac?token=1'),
        StreamProtocol.progressive,
      );
    });

    test('content type breaks ties', () {
      expect(
        StreamProtocolDetector.detect('https://x/y/stream', contentType: 'application/vnd.apple.mpegurl'),
        StreamProtocol.hls,
      );
      expect(
        StreamProtocolDetector.detect('https://x/y/stream', contentType: 'application/dash+xml'),
        StreamProtocol.dash,
      );
      expect(
        StreamProtocolDetector.detect('https://x/y/stream', contentType: 'audio/flac'),
        StreamProtocol.progressive,
      );
    });
  });

  group('HlsMasterPlaylist', () {
    const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=1280000,CODECS="avc1.42e00a,mp4a.40.2",RESOLUTION=1280x720
video_720.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"
audio_128.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=320000,CODECS="mp4a.40.2"
audio_320.m3u8
''';

    test('parses variants and flags audio-only', () {
      final playlist = HlsMasterPlaylist.parse(
        master,
        baseUrl: Uri.parse('https://cdn.example.com/index.m3u8'),
      );
      expect(playlist.variants, hasLength(3));
      final audio = playlist.variants
          .where((variant) => variant.isAudioOnly)
          .toList();
      expect(audio, hasLength(2));
      expect(audio.first.uri, 'https://cdn.example.com/audio_320.m3u8');
    });

    test('best variant respects the bandwidth budget', () {
      final playlist = HlsMasterPlaylist.parse(
        master,
        baseUrl: Uri.parse('https://cdn.example.com/index.m3u8'),
      );
      expect(playlist.bestVariant(null)!.bitrateKbps, 320);
      expect(playlist.bestVariant(400000)!.bitrateKbps, 320);
      expect(playlist.bestVariant(330000)!.bitrateKbps, 320);
      // Below the smallest audio tier the smallest still wins (never null).
      expect(playlist.bestVariant(100000)!.bitrateKbps, 128);
    });

    test('media playlists parse to empty (pass-through)', () {
      const media = '#EXTM3U\n#EXTINF:120,\nseg0.ts\n#EXT-X-ENDLIST\n';
      final playlist = HlsMasterPlaylist.parse(
        media,
        baseUrl: Uri.parse('https://cdn.example.com/media.m3u8'),
      );
      expect(playlist.isEmpty, isTrue);
      expect(playlist.bestVariant(null), isNull);
    });
  });

  group('DashManifest', () {
    const mpd = '''
<MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT3M">
  <Period>
    <AdaptationSet mimeType="audio/mp4" codecs="mp4a.40.2">
      <Representation id="128" bandwidth="128000" mimeType="audio/mp4" codecs="mp4a.40.2">
        <BaseURL>track-128.m4a</BaseURL>
      </Representation>
      <Representation id="flac" bandwidth="900000" mimeType="audio/flac" codecs="flac">
        <BaseURL>track-9.flac</BaseURL>
      </Representation>
    </AdaptationSet>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="v1" bandwidth="5000000" mimeType="video/mp4" codecs="avc1"/>
    </AdaptationSet>
  </Period>
</MPD>
''';

    test('parses audio representations with BaseURL, skips video', () {
      final manifest = DashManifest.parse(
        mpd,
        manifestUrl: Uri.parse('https://srv.example.com/stream/manifest.mpd'),
      );
      expect(manifest.isStatic, isTrue);
      expect(manifest.representations, hasLength(2));
      final flac = manifest.bestFileRepresentation(null)!;
      expect(flac.isLossless, isTrue);
      expect(
        flac.baseUrl,
        'https://srv.example.com/stream/track-9.flac',
      );
    });

    test('budget selects the affordable representation', () {
      final manifest = DashManifest.parse(
        mpd,
        manifestUrl: Uri.parse('https://srv.example.com/stream/manifest.mpd'),
      );
      expect(
        manifest.bestFileRepresentation(200000)!.id,
        '128',
      );
      expect(manifest.bestFileRepresentation(null)!.id, 'flac');
    });

    test('dynamic manifests are marked not static', () {
      const dynamic = '<MPD type="dynamic"></MPD>';
      final manifest = DashManifest.parse(
        dynamic,
        manifestUrl: Uri.parse('https://x/y.mpd'),
      );
      expect(manifest.isStatic, isFalse);
    });
  });

  group('StreamProtocolResolver', () {
    test('orders progressive before HLS before DASH at equal quality', () {
      const resolver = StreamProtocolResolver();
      final ordered = resolver.orderCandidates(
        const StreamResolverRequest(
          candidates: <StreamSource>[
            StreamSource(
              url: 'https://x/hls.m3u8',
              format: 'AAC',
              bitrate: 320,
              protocol: StreamProtocol.hls,
            ),
            StreamSource(
              url: 'https://x/file.flac',
              format: 'FLAC',
              bitrate: 900,
              protocol: StreamProtocol.progressive,
            ),
            StreamSource(
              url: 'https://x/manifest.mpd',
              format: 'AAC',
              bitrate: 320,
              protocol: StreamProtocol.dash,
            ),
          ],
          bandwidthBps: 2000000,
        ),
      );
      expect(ordered.first.url, 'https://x/file.flac');
      expect(ordered[1].url, 'https://x/hls.m3u8');
      expect(ordered[2].url, 'https://x/manifest.mpd');
    });

    test('respects protocol toggles', () {
      const resolver = StreamProtocolResolver();
      final ordered = resolver.orderCandidates(
        const StreamResolverRequest(
          candidates: <StreamSource>[
            StreamSource(
              url: 'https://x/hls.m3u8',
              format: 'AAC',
              bitrate: 320,
              protocol: StreamProtocol.hls,
            ),
            StreamSource(
              url: 'https://x/file.mp3',
              format: 'MP3',
              bitrate: 192,
              protocol: StreamProtocol.progressive,
            ),
          ],
          allowHls: false,
        ),
      );
      expect(ordered, hasLength(1));
      expect(ordered.first.protocol, StreamProtocol.progressive);
    });

    test('narrow rewrites HLS masters to the best audio variant', () async {
      const resolver = StreamProtocolResolver();
      const source = StreamSource(
        url: 'https://cdn.example.com/index.m3u8',
        format: 'AAC',
        bitrate: 0,
        protocol: StreamProtocol.hls,
      );
      final narrowed = await resolver.narrow(
        source,
        fetch: (uri) async => '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=320000,CODECS="mp4a.40.2"
audio_320.m3u8
''',
      );
      expect(narrowed.url, 'https://cdn.example.com/audio_320.m3u8');
      expect(narrowed.bitrate, 320);
      expect(narrowed.protocol, StreamProtocol.hls);
    });

    test('narrow rewrites static DASH to the direct file', () async {
      const resolver = StreamProtocolResolver();
      const source = StreamSource(
        url: 'https://srv.example.com/stream/manifest.mpd',
        format: 'MP4',
        bitrate: 0,
        protocol: StreamProtocol.dash,
      );
      final narrowed = await resolver.narrow(
        source,
        fetch: (uri) async => '''
<MPD type="static"><Period><AdaptationSet mimeType="audio/flac">
<Representation id="f" bandwidth="900000"><BaseURL>t.flac</BaseURL></Representation>
</AdaptationSet></Period></MPD>
''',
      );
      expect(narrowed.url, 'https://srv.example.com/stream/t.flac');
      expect(narrowed.protocol, StreamProtocol.progressive);
      expect(narrowed.format, 'FLAC');
    });

    test('narrow keeps segmented DASH manifests as dash', () async {
      const resolver = StreamProtocolResolver();
      const source = StreamSource(
        url: 'https://srv.example.com/live.mpd',
        format: 'AAC',
        bitrate: 128,
        protocol: StreamProtocol.dash,
      );
      final narrowed = await resolver.narrow(
        source,
        fetch: (uri) async =>
            '<MPD type="static"><Period><AdaptationSet mimeType="audio/mp4">'
            '<Representation id="a" bandwidth="1"/></AdaptationSet></Period></MPD>',
      );
      expect(narrowed.url, source.url);
      expect(narrowed.protocol, StreamProtocol.dash);
    });
  });

  group('StreamingService', () {
    test('fails over across providers until one validates', () async {
      final service = StreamingService(
        validator: _ScriptedValidator(<bool>[false, true]),
        manifestFetch: (_) async => null,
        providers: <StreamProvider>[
          _FakeProvider('p1', enabled: true, source: const StreamSource(
            url: 'https://x/one.flac',
            format: 'FLAC',
            bitrate: 900,
          )),
          _FakeProvider('p2', enabled: true, source: const StreamSource(
            url: 'https://x/two.mp3',
            format: 'MP3',
            bitrate: 320,
          )),
        ],
      );
      final resolution = await service.resolveTrack(_track());
      expect(resolution.succeeded, isTrue);
      expect(resolution.source!.url, 'https://x/two.mp3');
      expect(resolution.attempts.first.succeeded, isFalse);
      expect(resolution.session!.retries, isNotEmpty);
    });

    test('respects the total attempt budget', () async {
      final service = StreamingService(
        validator: _ScriptedValidator(<bool>[false, false, false, false]),
        manifestFetch: (_) async => null,
        providers: <StreamProvider>[
          _FakeProvider('p1', enabled: true, source: const StreamSource(
            url: 'https://x/one.flac',
            format: 'FLAC',
            bitrate: 900,
          )),
          _FakeProvider('p2', enabled: true, source: const StreamSource(
            url: 'https://x/two.mp3',
            format: 'MP3',
            bitrate: 320,
          )),
        ],
        resolver: const StreamProtocolResolver(),
      );
      final resolution = await service.resolveTrack(
        _track(),
        options: const StreamingServiceOptions(totalAttemptBudget: 2),
      );
      expect(resolution.succeeded, isFalse);
      expect(resolution.attempts, hasLength(2));
      expect(resolution.failureSummary, contains('p1'));
    });

    test('skips expired sources', () async {
      final expired = DateTime.now().subtract(const Duration(minutes: 1));
      final service = StreamingService(
        validator: _ScriptedValidator(<bool>[true]),
        manifestFetch: (_) async => null,
        providers: <StreamProvider>[
          _FakeProvider('p1', enabled: true, source: StreamSource(
            url: 'https://x/expired.flac',
            format: 'FLAC',
            bitrate: 900,
            expiresAt: expired,
          )),
        ],
      );
      final resolution = await service.resolveTrack(_track());
      expect(resolution.succeeded, isFalse);
      expect(resolution.attempts.single.reason, 'url expired');
    });

    test('disabled providers are never asked', () async {
      final provider = _FakeProvider('p1', enabled: false, source: null);
      final service = StreamingService(
        validator: _ScriptedValidator(const <bool>[]),
        manifestFetch: (_) async => null,
        providers: <StreamProvider>[provider],
      );
      await service.resolveTrack(_track());
      expect(provider.calls, 0);
    });
  });

  group('StreamSession', () {
    test('walks the hybrid lifecycle to local', () {
      final session = StreamSession(trackId: 't1');
      final phases = <StreamSessionPhase>[];
      session.addListener((_, event) => phases.add(event.phase));
      session.beginResolving();
      session.markValidating(const StreamSource(
        url: 'https://x/a.flac',
        format: 'FLAC',
        bitrate: 900,
      ));
      session.markPlaying();
      session.markCaching();
      session.planHandoff(const StreamHandoffPlan(
        mediaId: 'm',
        localPath: '/tmp/a.flac',
        sourceUrl: 'https://x/a.flac',
      ));
      session.completeHandoff();
      expect(phases, contains(StreamSessionPhase.local));
      expect(session.isActive, isTrue); // hybrid completion keeps it live
      session.stop();
      expect(session.isActive, isFalse);
      expect(session.phase, StreamSessionPhase.stopped);
      expect(session.elapsed(), isNotNull);
    });

    test('terminal phases reject further transitions', () {
      final session = StreamSession(trackId: 't1');
      session.beginResolving();
      session.fail('dead');
      session.markPlaying();
      expect(session.phase, StreamSessionPhase.failed);
      expect(session.endedAt, isNotNull);
    });

    test('retries are bounded', () {
      final session = StreamSession(trackId: 't1');
      for (var i = 0; i < 100; i++) {
        session.recordRetry('r$i');
      }
      expect(session.retries.length, 32);
      expect(session.retries.last, 'r99');
    });
  });
}

class _ScriptedValidator implements StreamSourceValidator {
  _ScriptedValidator(this.results);

  final List<bool> results;
  var _index = 0;

  @override
  Future<StreamValidationOutcome> validate(
    StreamSource source, {
    Map<String, String> extraHeaders = const <String, String>{},
  }) async {
    final ok = _index < results.length ? results[_index] : true;
    _index += 1;
    return StreamValidationOutcome(
      source: source,
      ok: ok,
      reason: ok ? '' : 'preflight rejected',
    );
  }
}

class _FakeProvider implements StreamProvider {
  _FakeProvider(this.id, {required this.enabled, this.source});

  @override
  final String id;

  @override
  final bool enabled;
  final StreamSource? source;
  int calls = 0;

  @override
  String get displayName => 'Fake $id';

  @override
  int get priority => 0;

  @override
  Future<StreamSource?> resolveTrack(Track track) async {
    calls += 1;
    return source;
  }
}
