// Stream URL lifecycle (resolve/refresh/validate/retry) and streaming
// playback on the shared player.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/streaming/stream_provider.dart'
    show StreamProtocol, StreamSource;
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/cache/playback_source_ladder.dart'
    show PlaybackSourceKind;
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia;
import 'package:spotiflac_android/services/playback/playback.dart';

class _FakeBackend implements PlaybackBackend {
  final StreamController<PlaybackSourceState> states =
      StreamController<PlaybackSourceState>.broadcast();
  final StreamController<PlaybackProgress> ticks =
      StreamController<PlaybackProgress>.broadcast();

  bool ready = false;
  bool disposed = false;
  final List<PlayableMedia> played = <PlayableMedia>[];
  final Map<String, DateTime?> expiries = <String, DateTime?>{};

  Duration position = Duration.zero;
  Duration total = Duration.zero;
  String trackId = '';
  String mediaId = '';

  @override
  Future<void> ensureReady() async {
    ready = true;
  }

  @override
  Stream<PlaybackSourceState> get state => states.stream;

  @override
  Stream<PlaybackProgress> get progress => ticks.stream;

  @override
  Duration get currentPosition => position;

  @override
  Duration get duration => total;

  @override
  String get currentTrackId => trackId;

  @override
  String get currentMediaId => mediaId;

  @override
  Future<void> playMedia(
    PlayableMedia media, {
    Duration startPosition = Duration.zero,
  }) async {
    played.add(media);
    mediaId = media.id;
    position = startPosition;
  }

  @override
  Future<void> setQueue(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> replaceCurrent(
    PlayableMedia media, {
    Duration resumeAt = Duration.zero,
  }) async {}

  @override
  Future<void> persistSession() async {}

  @override
  void noteSourceExpiry(String mediaId, DateTime? expiresAt) {
    expiries[mediaId] = expiresAt;
  }

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await states.close();
    await ticks.close();
  }
}

Track _track(String id) => Track(
  id: id,
  name: 'Title $id',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 200,
);

StreamSource _source(
  String url, {
  int bitrate = 320,
  String format = 'MP3',
  String provider = 'p1',
  StreamProtocol protocol = StreamProtocol.progressive,
  DateTime? expiresAt,
}) => StreamSource(
  url: url,
  format: format,
  bitrate: bitrate,
  providerId: provider,
  protocol: protocol,
  expiresAt: expiresAt,
);

void main() {
  group('ranking and validation', () {
    test('resolves the best validated candidate and stops probing',
        () async {
      var validations = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source('https://cdn.example/low.mp3', bitrate: 128),
          _source('https://cdn.example/high.mp3', bitrate: 320),
          _source('https://cdn.example/mid.mp3', bitrate: 256),
        ],
        validateSource: (_) async {
          validations++;
          return true;
        },
        retryDelay: (_) async {},
      );

      final resolved = await resolver.resolve(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/high.mp3');
      expect(resolved?.trackId, 't');
      expect(validations, 1);
    });

    test('skips rejected candidates until one validates', () async {
      final probed = <String>[];
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source('https://cdn.example/high.mp3', bitrate: 320),
          _source('https://cdn.example/mid.mp3', bitrate: 256),
          _source('https://cdn.example/low.mp3', bitrate: 128),
        ],
        validateSource: (StreamSource source) async {
          probed.add(source.url);
          return source.url.contains('low');
        },
        retryDelay: (_) async {},
      );

      final resolved = await resolver.resolve(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/low.mp3');
      expect(probed, <String>[
        'https://cdn.example/high.mp3',
        'https://cdn.example/mid.mp3',
        'https://cdn.example/low.mp3',
      ]);
    });

    test('expired candidates are skipped before validation', () async {
      var validations = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source(
            'https://cdn.example/old.mp3',
            bitrate: 320,
            expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
          ),
          _source('https://cdn.example/live.mp3', bitrate: 128),
        ],
        validateSource: (_) async {
          validations++;
          return true;
        },
        retryDelay: (_) async {},
      );

      final resolved = await resolver.resolve(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/live.mp3');
      expect(validations, 1);
    });

    test('empty URLs never validate', () async {
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source('', bitrate: 999),
          _source('https://cdn.example/live.mp3', bitrate: 128),
        ],
        validateSource: (_) async => true,
        retryDelay: (_) async {},
      );

      final resolved = await resolver.resolve(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/live.mp3');
      expect(await resolver.validate(_source('   ')), isFalse);
    });

    test('all rejected yields null', () async {
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source('https://cdn.example/a.mp3'),
        ],
        validateSource: (_) async => false,
        retryDelay: (_) async {},
      );

      expect(await resolver.resolve(_track('t')), isNull);
    });

    test('no candidates yields null without validating', () async {
      var validations = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => const <StreamSource>[],
        validateSource: (_) async {
          validations++;
          return true;
        },
        retryDelay: (_) async {},
      );

      expect(await resolver.resolve(_track('t')), isNull);
      expect(validations, 0);
    });

    test('fetch failures resolve to null instead of throwing', () async {
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) => throw StateError('adapters down'),
        validateSource: (_) async => true,
        retryDelay: (_) async {},
      );

      expect(await resolver.resolve(_track('t')), isNull);
    });

    test('throwing validators count as rejections', () async {
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source('https://cdn.example/a.mp3'),
        ],
        validateSource: (_) => throw StateError('probe crashed'),
        retryDelay: (_) async {},
      );

      expect(await resolver.resolve(_track('t')), isNull);
      expect(
        await resolver.validate(_source('https://cdn.example/a.mp3')),
        isFalse,
      );
    });

    test('bandwidth budget prefers the best affordable candidate', () async {
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source('https://cdn.example/high.mp3', bitrate: 320),
          _source('https://cdn.example/low.mp3', bitrate: 128),
        ],
        validateSource: (_) async => true,
        bandwidthProvider: () => 200 * 1000,
        retryDelay: (_) async {},
      );

      final resolved = await resolver.resolve(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/low.mp3');
    });

    test('progressive wins over HLS at comparable quality', () async {
      final probed = <String>[];
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source(
            'https://cdn.example/master.m3u8',
            bitrate: 512,
            protocol: StreamProtocol.hls,
          ),
          _source('https://cdn.example/file.mp3', bitrate: 320),
        ],
        validateSource: (StreamSource source) async {
          probed.add(source.url);
          return true;
        },
        retryDelay: (_) async {},
      );

      final resolved = await resolver.resolve(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/file.mp3');
      expect(probed, <String>['https://cdn.example/file.mp3']);
    });

    test('disallowed protocols are excluded from ranking', () async {
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source(
            'https://cdn.example/master.m3u8',
            bitrate: 512,
            protocol: StreamProtocol.hls,
          ),
        ],
        validateSource: (_) async => true,
        allowHls: false,
        retryDelay: (_) async {},
      );

      expect(await resolver.resolve(_track('t')), isNull);
    });
  });

  group('HLS narrowing', () {
    const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="mp4a.40.2"
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2000000,CODECS="mp4a.40.2"
high.m3u8
''';

    test('master playlist narrows to the affordable variant', () async {
      var manifests = 0;
      String? validatedUrl;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source(
            'https://cdn.example/hls/master.m3u8',
            bitrate: 2000,
            protocol: StreamProtocol.hls,
          ),
        ],
        validateSource: (StreamSource source) async {
          validatedUrl = source.url;
          return true;
        },
        manifestFetch: (_) async {
          manifests++;
          return master;
        },
        bandwidthProvider: () => 1000 * 1000,
        retryDelay: (_) async {},
      );

      final resolved = await resolver.resolve(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/hls/low.m3u8');
      expect(resolved?.source.bitrate, 800);
      expect(validatedUrl, 'https://cdn.example/hls/low.m3u8');
      expect(manifests, 1);
    });

    test('unknown bandwidth narrows to the top variant', () async {
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source(
            'https://cdn.example/hls/master.m3u8',
            bitrate: 2000,
            protocol: StreamProtocol.hls,
          ),
        ],
        validateSource: (_) async => true,
        manifestFetch: (_) async => master,
        retryDelay: (_) async {},
      );

      final resolved = await resolver.resolve(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/hls/high.m3u8');
    });

    test('media playlists pass through untouched', () async {
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source(
            'https://cdn.example/hls/media.m3u8',
            bitrate: 256,
            protocol: StreamProtocol.hls,
          ),
        ],
        validateSource: (_) async => true,
        manifestFetch: (_) async => '#EXTM3U\n#EXTINF:200,\nseg1.ts\n',
        retryDelay: (_) async {},
      );

      final resolved = await resolver.resolve(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/hls/media.m3u8');
    });

    test('manifest fetch failures fall back to the original URL', () async {
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => <StreamSource>[
          _source(
            'https://cdn.example/hls/master.m3u8',
            bitrate: 256,
            protocol: StreamProtocol.hls,
          ),
        ],
        validateSource: (_) async => true,
        manifestFetch: (_) async => null,
        retryDelay: (_) async {},
      );

      final resolved = await resolver.resolve(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/hls/master.m3u8');
    });
  });

  group('caching', () {
    test('second resolve serves the cache without network', () async {
      var fetches = 0;
      var validations = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[_source('https://cdn.example/a.mp3')];
        },
        validateSource: (_) async {
          validations++;
          return true;
        },
        retryDelay: (_) async {},
      );

      final first = await resolver.resolve(_track('t'));
      final second = await resolver.resolve(_track('t'));
      expect(first?.source.url, second?.source.url);
      expect(fetches, 1);
      expect(validations, 1);
      expect(resolver.cachedUrlCount, 1);
    });

    test('refresh bypasses the cache', () async {
      var fetches = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[
            _source('https://cdn.example/v$fetches.mp3'),
          ];
        },
        validateSource: (_) async => true,
        retryDelay: (_) async {},
      );

      expect(
        (await resolver.resolve(_track('t')))?.source.url,
        'https://cdn.example/v1.mp3',
      );
      expect(
        (await resolver.refresh(_track('t')))?.source.url,
        'https://cdn.example/v2.mp3',
      );
      expect(fetches, 2);
    });

    test('invalidate drops the entry; clear drops all', () async {
      var fetches = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[_source('https://cdn.example/a.mp3')];
        },
        validateSource: (_) async => true,
        retryDelay: (_) async {},
      );

      await resolver.resolve(_track('a'));
      await resolver.resolve(_track('b'));
      expect(resolver.cachedUrlCount, 2);

      resolver.invalidate('a');
      expect(resolver.cachedUrlCount, 1);
      await resolver.resolve(_track('a'));
      expect(fetches, 3);

      resolver.clear();
      expect(resolver.cachedUrlCount, 0);
    });

    test('near-expiry entries regenerate in the background', () async {
      var fetches = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[
            _source(
              'https://cdn.example/v$fetches.mp3',
              expiresAt: DateTime.now().add(
                fetches == 1
                    ? const Duration(seconds: 30)
                    : const Duration(hours: 1),
              ),
            ),
          ];
        },
        validateSource: (_) async => true,
        refreshLeadTime: const Duration(minutes: 2),
        retryDelay: (_) async {},
      );

      expect(
        (await resolver.resolve(_track('t')))?.source.url,
        'https://cdn.example/v1.mp3',
      );
      // Inside the 2-minute lead time: regenerates instead of serving.
      expect(
        (await resolver.resolve(_track('t')))?.source.url,
        'https://cdn.example/v2.mp3',
      );
      // Fresh 1-hour URL: served from the cache.
      expect(
        (await resolver.resolve(_track('t')))?.source.url,
        'https://cdn.example/v2.mp3',
      );
      expect(fetches, 2);
    });

    test('expired entries regenerate instead of serving', () async {
      var now = DateTime(2026, 1, 1, 12);
      var fetches = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[
            _source(
              'https://cdn.example/v$fetches.mp3',
              expiresAt: now.add(const Duration(seconds: 30)),
            ),
          ];
        },
        validateSource: (_) async => true,
        refreshLeadTime: Duration.zero,
        clock: () => now,
        retryDelay: (_) async {},
      );

      expect(
        (await resolver.resolve(_track('t')))?.source.url,
        'https://cdn.example/v1.mp3',
      );
      now = now.add(const Duration(minutes: 5));
      expect(
        (await resolver.resolve(_track('t')))?.source.url,
        'https://cdn.example/v2.mp3',
      );
      expect(fetches, 2);
    });

    test('cache is bounded and evicts oldest first', () async {
      final resolver = StreamUrlResolver(
        fetchCandidates: (Track track) async => <StreamSource>[
          _source('https://cdn.example/${track.id}.mp3'),
        ],
        validateSource: (_) async => true,
        retryDelay: (_) async {},
        maxCacheEntries: 2,
      );

      await resolver.resolve(_track('a'));
      await resolver.resolve(_track('b'));
      await resolver.resolve(_track('c'));
      expect(resolver.cachedUrlCount, 2);
    });
  });

  group('offline', () {
    test('offline resolution serves only fresh cache hits', () async {
      var fetches = 0;
      var offline = false;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[_source('https://cdn.example/a.mp3')];
        },
        validateSource: (_) async => true,
        retryDelay: (_) async {},
        isOffline: () => offline,
      );

      await resolver.resolve(_track('cached'));
      expect(fetches, 1);

      offline = true;
      expect(
        (await resolver.resolve(_track('cached')))?.source.url,
        'https://cdn.example/a.mp3',
      );
      expect(await resolver.resolve(_track('uncached')), isNull);
      expect(fetches, 1);
    });

    test('offline retry aborts without sleeping', () async {
      final sleeps = <Duration>[];
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async => const <StreamSource>[],
        validateSource: (_) async => true,
        retryDelay: (Duration delay) async => sleeps.add(delay),
        isOffline: () => true,
      );

      expect(await resolver.retry(_track('t')), isNull);
      expect(sleeps, isEmpty);
    });
  });

  group('retry', () {
    test('retry waits 1s, 2s, 4s across three rounds', () async {
      expect(StreamUrlResolver.retryDelays, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
      expect(StreamUrlResolver.maxRetries, 3);

      final sleeps = <Duration>[];
      var fetches = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async {
          fetches++;
          throw StateError('adapters down');
        },
        validateSource: (_) async => true,
        retryDelay: (Duration delay) async => sleeps.add(delay),
      );

      expect(await resolver.retry(_track('t')), isNull);
      expect(fetches, 4);
      expect(sleeps, StreamUrlResolver.retryDelays);
    });

    test('retry succeeds mid-chain without further sleeps', () async {
      final sleeps = <Duration>[];
      var fetches = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async {
          fetches++;
          if (fetches < 3) throw StateError('flaky adapters');
          return <StreamSource>[_source('https://cdn.example/a.mp3')];
        },
        validateSource: (_) async => true,
        retryDelay: (Duration delay) async => sleeps.add(delay),
      );

      final resolved = await resolver.retry(_track('t'));
      expect(resolved?.source.url, 'https://cdn.example/a.mp3');
      expect(fetches, 3);
      expect(sleeps, <Duration>[
        const Duration(seconds: 1),
        const Duration(seconds: 2),
      ]);
    });
  });

  group('streaming source', () {
    test('play resolves and plays with the track id', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final expiry = DateTime.now().add(const Duration(hours: 1));
      final source = StreamingPlaybackSource(
        backend: backend,
        urlResolver: StreamUrlResolver(
          fetchCandidates: (_) async => <StreamSource>[
            _source(
              'https://cdn.example/a.mp3',
              expiresAt: expiry,
              provider: 'cdn',
            ),
          ],
          validateSource: (_) async => true,
          retryDelay: (_) async {},
        ),
      );
      addTearDown(source.dispose);
      await source.initialize();

      expect(source.kind, PlaybackSourceKind.providerStream);
      await source.play(_track('t'));

      expect(backend.played, hasLength(1));
      final media = backend.played.single;
      expect(media.id, 't');
      expect(media.source, 'https://cdn.example/a.mp3');
      expect(media.playbackMode, 'stream');
      expect(media.qualityLabel, 'MP3 320kbps');
      expect(media.providerId, 'cdn');
      expect(media.expiresAt, expiry);
    });

    test('play throws a typed retryable error when unresolvable', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = StreamingPlaybackSource(
        backend: backend,
        urlResolver: StreamUrlResolver(
          fetchCandidates: (_) async => const <StreamSource>[],
          validateSource: (_) async => true,
          retryDelay: (_) async {},
        ),
      );
      addTearDown(source.dispose);
      await source.initialize();

      await expectLater(
        source.play(_track('t')),
        throwsA(
          isA<PlaybackSourceException>()
              .having((error) => error.kind, 'kind', 'unavailable')
              .having((error) => error.retryable, 'retryable', isTrue),
        ),
      );
      expect(backend.played, isEmpty);
    });

    test('preload warms the URL without playing', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      var fetches = 0;
      final resolver = StreamUrlResolver(
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[_source('https://cdn.example/a.mp3')];
        },
        validateSource: (_) async => true,
        retryDelay: (_) async {},
      );
      final source = StreamingPlaybackSource(
        backend: backend,
        urlResolver: resolver,
      );
      addTearDown(source.dispose);
      await source.initialize();

      await source.preload(_track('t'));
      expect(fetches, 1);
      expect(backend.played, isEmpty);
      expect(resolver.cachedUrlCount, 1);
    });

    test('preload throws when the track cannot warm', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = StreamingPlaybackSource(
        backend: backend,
        urlResolver: StreamUrlResolver(
          fetchCandidates: (_) async => const <StreamSource>[],
          validateSource: (_) async => true,
          retryDelay: (_) async {},
        ),
      );
      addTearDown(source.dispose);
      await source.initialize();

      await expectLater(
        source.preload(_track('t')),
        throwsA(isA<PlaybackSourceException>()),
      );
    });

    test('mediaIdForTrack is the track id', () {
      expect(StreamingPlaybackSource.mediaIdForTrack(_track('abc')), 'abc');
    });
  });
}
