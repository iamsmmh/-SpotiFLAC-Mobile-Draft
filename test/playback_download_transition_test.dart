// Download completion: stream-URL invalidation, live hot-swap to the
// downloaded file, and future plays routing locally.
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
  final List<PlayableMedia> played = <PlayableMedia>[];
  List<PlayableMedia> queue = const <PlayableMedia>[];
  final List<PlayableMedia> replaced = <PlayableMedia>[];
  final List<Duration> replacedAt = <Duration>[];

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
    queue = <PlayableMedia>[media];
    mediaId = media.id;
    position = startPosition;
  }

  @override
  Future<void> setQueue(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    queue = List<PlayableMedia>.of(items);
    if (items.isNotEmpty) {
      mediaId = items[initialIndex.clamp(0, items.length - 1)].id;
    }
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
    replaced.add(media);
    replacedAt.add(resumeAt);
    mediaId = media.id;
    position = resumeAt;
  }

  @override
  Future<void> persistSession() async {}

  @override
  void noteSourceExpiry(String mediaId, DateTime? expiresAt) {}

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    await states.close();
    await ticks.close();
  }
}

Track _track(String id, {String? isrc}) => Track(
  id: id,
  name: 'Title $id',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 200,
  isrc: isrc,
);

StreamSource _source(String url) =>
    StreamSource(url: url, format: 'MP3', bitrate: 320);

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('upm-download');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

PlaybackManager _manager({
  required _FakeBackend backend,
  Map<String, String> localPaths = const <String, String>{},
  Map<String, List<StreamSource>> candidates =
      const <String, List<StreamSource>>{},
  void Function()? onFetch,
}) {
  return PlaybackManager(
    backend: backend,
    localSource: LocalPlaybackSource(
      backend: backend,
      resolvePath: (Track track) async => localPaths[track.id],
    ),
    cacheSource: CachePlaybackSource(
      backend: backend,
      cache: PlaybackCacheManager.atRoot(_tempRoot()),
    ),
    streamingSource: StreamingPlaybackSource(
      backend: backend,
      urlResolver: StreamUrlResolver(
        fetchCandidates: (Track track) async {
          onFetch?.call();
          return candidates[track.id] ?? const <StreamSource>[];
        },
        validateSource: (_) async => true,
        retryDelay: (_) async {},
      ),
    ),
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

  group('completion hook', () {
    test('current stream hot-swaps to the downloaded file in place',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final localPaths = <String, String>{};
      final manager = _manager(
        backend: backend,
        localPaths: localPaths,
        candidates: <String, List<StreamSource>>{
          's': <StreamSource>[_source('https://cdn.example/s.mp3')],
          'next': <StreamSource>[_source('https://cdn.example/n.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s'), _track('next')]);
      backend.position = const Duration(seconds: 87);

      localPaths['s'] = '/music/s.flac';
      await manager.notifyDownloadCompleted(
        trackId: 's',
        filePath: '/music/s.flac',
      );

      expect(backend.replaced, hasLength(1));
      expect(backend.replaced.single.id, '/music/s.flac');
      expect(backend.replaced.single.source, '/music/s.flac');
      expect(backend.replacedAt.single, const Duration(seconds: 87));
      expect(manager.currentKind, PlaybackSourceKind.localLibrary);
      expect(manager.currentTrack?.id, 's');
      expect(
        manager.queueMediaIds,
        <String>['/music/s.flac', 'next'],
      );
    });

    test('swap resolves the path when the event carries none', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final localPaths = <String, String>{};
      final manager = _manager(
        backend: backend,
        localPaths: localPaths,
        candidates: <String, List<StreamSource>>{
          's': <StreamSource>[_source('https://cdn.example/s.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s')]);

      localPaths['s'] = '/music/s.flac';
      await manager.notifyDownloadCompleted(trackId: 's');
      expect(backend.replaced, hasLength(1));
      expect(backend.replaced.single.id, '/music/s.flac');
    });

    test('ISRC match swaps when ids differ across providers', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'provider-id': <StreamSource>[
            _source('https://cdn.example/s.mp3'),
          ],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(
        <Track>[_track('provider-id', isrc: 'USRC12345678')],
      );

      await manager.notifyDownloadCompleted(
        trackId: 'other-provider-id',
        isrc: 'USRC12345678',
        filePath: '/music/s.flac',
      );
      expect(backend.replaced, hasLength(1));
      expect(manager.currentKind, PlaybackSourceKind.localLibrary);
    });

    test('unrelated downloads never swap the current item', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          's': <StreamSource>[_source('https://cdn.example/s.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s')]);

      await manager.notifyDownloadCompleted(
        trackId: 'other',
        filePath: '/music/other.flac',
      );
      expect(backend.replaced, isEmpty);
      expect(manager.currentMediaId, 's');
    });

    test('already-local current item is left alone', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'l': '/music/l.flac'},
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('l')]);

      await manager.notifyDownloadCompleted(
        trackId: 'l',
        filePath: '/music/l.flac',
      );
      expect(backend.replaced, isEmpty);
    });

    test('missing file resolves to no swap and no throw', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          's': <StreamSource>[_source('https://cdn.example/s.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s')]);

      await manager.notifyDownloadCompleted(trackId: 's');
      expect(backend.replaced, isEmpty);
      expect(manager.currentMediaId, 's');
    });

    test('stale stream-URL cache is invalidated for future plays', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      var fetches = 0;
      final localPaths = <String, String>{};
      final manager = _manager(
        backend: backend,
        localPaths: localPaths,
        candidates: <String, List<StreamSource>>{
          's': <StreamSource>[_source('https://cdn.example/s.mp3')],
        },
        onFetch: () => fetches++,
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      // Warm the URL cache through the streaming source directly.
      await manager.streamingSource.preload(_track('s'));
      expect(fetches, 1);

      // The download lands while something else plays: no swap, but the
      // cached URL is dropped so the next resolve revalidates.
      await manager.playTracks(<Track>[_track('other')]);
      localPaths['s'] = '/music/s.flac';
      await manager.notifyDownloadCompleted(
        trackId: 's',
        filePath: '/music/s.flac',
      );
      expect(backend.replaced, isEmpty);

      // Future plays route locally without touching the network.
      final decision = await manager.decide(_track('s'));
      expect(decision.kind, PlaybackSourceKind.localLibrary);
      expect(fetches, 1);

      // And the stale URL is gone: with the file removed again, warming
      // the track revalidates over the network instead of serving the
      // pre-download URL.
      localPaths.remove('s');
      await manager.streamingSource.preload(_track('s'));
      expect(fetches, 2);
    });

    test('hook never throws, even when resolution explodes', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = PlaybackManager(
        backend: backend,
        localSource: LocalPlaybackSource(
          backend: backend,
          resolvePath: (_) => throw StateError('store on fire'),
        ),
        cacheSource: CachePlaybackSource(
          backend: backend,
          cache: PlaybackCacheManager.atRoot(_tempRoot()),
        ),
        streamingSource: StreamingPlaybackSource(
          backend: backend,
          urlResolver: StreamUrlResolver(
            fetchCandidates: (_) async => const <StreamSource>[],
            validateSource: (_) async => true,
            retryDelay: (_) async {},
          ),
        ),
        gaplessApplier: (_) {},
        crossfadeApplier: (_) {},
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.notifyDownloadCompleted(trackId: 's');
      await manager.notifyDownloadCompleted(trackId: '');
    });
  });

  group('download listener wiring', () {
    test('initialize installs the global listener; dispose removes it',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);

      expect(playbackDownloadListener, isNull);
      await manager.initialize();
      expect(playbackDownloadListener, isNotNull);

      // The global routes into the manager best-effort.
      playbackDownloadListener!(
        const PlaybackDownloadEvent(trackId: 'ghost'),
      );
      await _flush();

      await manager.dispose();
      expect(playbackDownloadListener, isNull);
    });
  });
}
