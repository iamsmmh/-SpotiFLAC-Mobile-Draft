// Stream failure recovery: fresh-URL failover at the live position,
// bounded attempts, and chained delegation for foreign/local items.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/streaming/stream_provider.dart'
    show StreamSource;
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/cache/playback_source_ladder.dart'
    show PlaybackSourceKind;
import 'package:spotiflac_android/services/music_player_service.dart'
    show
        DeferredStreamResolver,
        PlayableMedia,
        PlaybackFailureListener,
        deferredStreamResolver,
        playbackFailureListener,
        setDeferredStreamResolver;
import 'package:spotiflac_android/services/playback/playback.dart';

class _FakeBackend implements PlaybackBackend {
  final StreamController<PlaybackSourceState> states =
      StreamController<PlaybackSourceState>.broadcast();
  final StreamController<PlaybackProgress> ticks =
      StreamController<PlaybackProgress>.broadcast();

  bool ready = false;
  bool disposed = false;
  List<PlayableMedia> queue = const <PlayableMedia>[];
  final List<PlayableMedia> replaced = <PlayableMedia>[];
  final List<Duration> replacedAt = <Duration>[];
  final Map<String, DateTime?> expiries = <String, DateTime?>{};
  bool failReplace = false;

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
  }) async {}

  @override
  Future<void> setQueue(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    queue = List<PlayableMedia>.of(items);
  }

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
  }) async {
    if (failReplace) throw StateError('replace failed');
    replaced.add(media);
    replacedAt.add(resumeAt);
    mediaId = media.id;
    position = resumeAt;
  }

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

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('upm-recovery');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

PlaybackManager _manager({
  required _FakeBackend backend,
  Map<String, String> localPaths = const <String, String>{},
  PlaybackCacheManager? cache,
  StreamCandidateFetcher? fetchCandidates,
  PlaybackPolicy policy = const PlaybackPolicy(),
}) {
  return PlaybackManager(
    backend: backend,
    localSource: LocalPlaybackSource(
      backend: backend,
      resolvePath: (Track track) async => localPaths[track.id],
    ),
    cacheSource: CachePlaybackSource(
      backend: backend,
      cache: cache ?? PlaybackCacheManager.atRoot(_tempRoot()),
    ),
    streamingSource: StreamingPlaybackSource(
      backend: backend,
      urlResolver: StreamUrlResolver(
        fetchCandidates:
            fetchCandidates ?? (_) async => const <StreamSource>[],
        validateSource: (_) async => true,
        retryDelay: (_) async {},
      ),
    ),
    policy: policy,
    gaplessApplier: (_) {},
    crossfadeApplier: (_) {},
  );
}

Future<void> _flush() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  PlaybackFailureListener? savedFailure;
  DeferredStreamResolver? savedDeferred;
  PlaybackDownloadListener? savedDownload;

  setUp(() {
    savedFailure = playbackFailureListener;
    savedDeferred = deferredStreamResolver;
    savedDownload = playbackDownloadListener;
  });

  tearDown(() {
    playbackFailureListener = savedFailure;
    setDeferredStreamResolver(savedDeferred);
    playbackDownloadListener = savedDownload;
  });

  group('failure recovery', () {
    test('expired stream fails over to a fresh URL at the live position',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      var fetches = 0;
      final expiry = DateTime.now().add(const Duration(hours: 1));
      final manager = _manager(
        backend: backend,
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[
            StreamSource(
              url: 'https://cdn.example/v$fetches.mp3',
              format: 'MP3',
              bitrate: 320,
              expiresAt: expiry,
            ),
          ];
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s')]);
      // Warm v1, then simulate it dying mid-play.
      expect(
        await manager.resolveDeferred(backend.queue.single),
        'https://cdn.example/v1.mp3',
      );
      backend.position = const Duration(seconds: 111);

      playbackFailureListener!(
        backend.queue.single,
        StateError('403 expired'),
      );
      await _flush();

      // Refresh bypassed the v1 cache entry: a second fetch happened.
      expect(fetches, 2);
      expect(backend.replaced, hasLength(1));
      expect(backend.replaced.single.id, 's');
      expect(backend.replaced.single.source, 'https://cdn.example/v2.mp3');
      expect(backend.replacedAt.single, const Duration(seconds: 111));
      expect(backend.expiries['s'], expiry);
      expect(manager.currentKind, PlaybackSourceKind.providerStream);
    });

    test('failed cache items fail over to streams', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      await cache.storeBytes(track: _track('c'), bytes: const <int>[1]);
      final manager = _manager(
        backend: backend,
        cache: cache,
        fetchCandidates: (_) async => <StreamSource>[
          StreamSource(
            url: 'https://cdn.example/c.mp3',
            format: 'MP3',
            bitrate: 320,
          ),
        ],
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('c')]);
      backend.position = const Duration(seconds: 5);

      playbackFailureListener!(
        backend.queue.single,
        StateError('cache bytes unreadable'),
      );
      await _flush();

      expect(backend.replaced, hasLength(1));
      expect(
        backend.replaced.single.source,
        'https://cdn.example/c.mp3',
      );
      expect(manager.currentKind, PlaybackSourceKind.providerStream);
    });

    test('attempts are bounded, then the previous hook is called', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final delegated = <String>[];
      playbackFailureListener =
          (PlayableMedia media, Object error) => delegated.add(media.id);
      var fetches = 0;
      final manager = _manager(
        backend: backend,
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[
            StreamSource(
              url: 'https://cdn.example/v$fetches.mp3',
              format: 'MP3',
              bitrate: 320,
            ),
          ];
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s')]);

      for (var i = 0; i < 3; i++) {
        playbackFailureListener!(
          backend.queue.single,
          StateError('cdn down $i'),
        );
        await _flush();
      }

      expect(fetches, 2);
      expect(backend.replaced, hasLength(2));
      expect(delegated, <String>['s']);
    });

    test('unrefreshable streams delegate immediately', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final delegated = <String>[];
      playbackFailureListener =
          (PlayableMedia media, Object error) => delegated.add(media.id);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s')]);

      playbackFailureListener!(
        backend.queue.single,
        StateError('no candidates anywhere'),
      );
      await _flush();

      expect(backend.replaced, isEmpty);
      expect(delegated, <String>['s']);
    });

    test('disabled auto-recovery delegates immediately', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final delegated = <String>[];
      playbackFailureListener =
          (PlayableMedia media, Object error) => delegated.add(media.id);
      var fetches = 0;
      final manager = _manager(
        backend: backend,
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[
            StreamSource(
              url: 'https://cdn.example/v$fetches.mp3',
              format: 'MP3',
              bitrate: 320,
            ),
          ];
        },
        policy: const PlaybackPolicy(autoRecoverStreams: false),
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s')]);

      playbackFailureListener!(
        backend.queue.single,
        StateError('cdn down'),
      );
      await _flush();

      expect(fetches, 0);
      expect(backend.replaced, isEmpty);
      expect(delegated, <String>['s']);
    });

    test('failed swaps delegate instead of crashing', () async {
      final backend = _FakeBackend()
        ..failReplace = true;
      addTearDown(backend.dispose);
      final delegated = <String>[];
      playbackFailureListener =
          (PlayableMedia media, Object error) => delegated.add(media.id);
      final manager = _manager(
        backend: backend,
        fetchCandidates: (_) async => <StreamSource>[
          StreamSource(
            url: 'https://cdn.example/v2.mp3',
            format: 'MP3',
            bitrate: 320,
          ),
        ],
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s')]);

      playbackFailureListener!(
        backend.queue.single,
        StateError('cdn down'),
      );
      await _flush();

      expect(backend.replaced, isEmpty);
      expect(delegated, <String>['s']);
    });

    test('foreign and local failures always delegate', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final delegated = <String>[];
      playbackFailureListener =
          (PlayableMedia media, Object error) => delegated.add(media.id);
      var fetches = 0;
      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'l': '/music/l.flac'},
        fetchCandidates: (_) async {
          fetches++;
          return <StreamSource>[
            StreamSource(
              url: 'https://cdn.example/x.mp3',
              format: 'MP3',
              bitrate: 320,
            ),
          ];
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('l')]);

      const foreign = PlayableMedia(
        id: 'engine-owned',
        source: 'https://engine.example/x.mp3',
        title: 'Engine item',
        artist: 'Engine',
      );
      playbackFailureListener!(foreign, StateError('engine failure'));
      playbackFailureListener!(
        backend.queue.single,
        StateError('disk hiccup'),
      );
      await _flush();

      expect(delegated, <String>['engine-owned', '/music/l.flac']);
      expect(fetches, 0);
      expect(backend.replaced, isEmpty);
    });
  });

  group('hook chaining', () {
    test('install is idempotent; uninstall restores the previous hooks',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      PlaybackFailureListener? previousFailure;
      DeferredStreamResolver? previousDeferred;
      playbackFailureListener =
          (PlayableMedia media, Object error) {};
      previousFailure = playbackFailureListener;
      setDeferredStreamResolver((PlayableMedia media) async => 'prev');
      previousDeferred = deferredStreamResolver;

      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize(); // installs once
      manager.installHooks(); // second install is a no-op
      manager.installHooks();

      expect(playbackFailureListener, isNot(previousFailure));
      expect(deferredStreamResolver, isNot(previousDeferred));

      // Chained deferred hook still serves the previous resolver.
      const foreign = PlayableMedia(
        id: 'engine-owned',
        source: 'deferred-stream://engine/engine-owned',
        title: 'Engine item',
        artist: 'Engine',
      );
      expect(await deferredStreamResolver!(foreign), 'prev');

      manager.uninstallHooks();
      expect(
        identical(playbackFailureListener, previousFailure),
        isTrue,
      );
      expect(
        identical(deferredStreamResolver, previousDeferred),
        isTrue,
      );
      manager.uninstallHooks(); // second uninstall is a no-op
    });

    test('chained hook swallows previous-resolver errors', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      setDeferredStreamResolver((PlayableMedia media) async {
        throw StateError('engine resolver down');
      });
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();

      const foreign = PlayableMedia(
        id: 'engine-owned',
        source: 'deferred-stream://engine/engine-owned',
        title: 'Engine item',
        artist: 'Engine',
      );
      expect(await deferredStreamResolver!(foreign), isNull);
    });
  });
}
