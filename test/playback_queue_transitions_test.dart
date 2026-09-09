// Mixed-queue transitions: lazy stream resolution at advance time,
// re-decision when availability changes, and queue rebuild hygiene.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/streaming/stream_provider.dart'
    show StreamSource;
import 'package:spotiflac_android/models/track.dart';
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
  void noteSourceExpiry(String mediaId, DateTime? expiresAt) {
    expiries[mediaId] = expiresAt;
  }

  void emitState(
    PlaybackSourceStatus status, {
    String? media,
    String? track,
    Duration? pos,
    Duration? dur,
  }) {
    if (media != null) mediaId = media;
    if (track != null) trackId = track;
    if (pos != null) position = pos;
    if (dur != null) total = dur;
    states.add(
      PlaybackSourceState(
        status: status,
        trackId: trackId,
        mediaId: mediaId,
        position: position,
        duration: total,
      ),
    );
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
  DateTime? expiresAt,
}) => StreamSource(url: url, format: 'MP3', bitrate: bitrate, expiresAt: expiresAt);

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('upm-queue');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

PlaybackManager _manager({
  required _FakeBackend backend,
  Map<String, String> localPaths = const <String, String>{},
  PlaybackCacheManager? cache,
  Map<String, List<StreamSource>> candidates =
      const <String, List<StreamSource>>{},
  void Function(Track track)? registrar,
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
        fetchCandidates: (Track track) async =>
            candidates[track.id] ?? const <StreamSource>[],
        validateSource: (_) async => true,
        retryDelay: (_) async {},
      ),
    ),
    gaplessApplier: (_) {},
    crossfadeApplier: (_) {},
    engineTrackRegistrar: registrar,
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

  group('deferred resolution', () {
    test('stream items resolve to a fresh URL with expiry noted', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final expiry = DateTime.now().add(const Duration(hours: 1));
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          's': <StreamSource>[
            _source('https://cdn.example/s.mp3', expiresAt: expiry),
          ],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s')]);

      final media = backend.queue.single;
      expect(media.isDeferredStream, isTrue);
      expect(await manager.resolveDeferred(media), 'https://cdn.example/s.mp3');
      expect(backend.expiries['s'], expiry);
    });

    test('local items resolve to their file path and clear expiry',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      backend.expiries['/music/l.flac'] =
          DateTime.now().add(const Duration(hours: 1));
      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'l': '/music/l.flac'},
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('l')]);

      expect(
        await manager.resolveDeferred(backend.queue.single),
        '/music/l.flac',
      );
      expect(backend.expiries.containsKey('/music/l.flac'), isTrue);
      expect(backend.expiries['/music/l.flac'], isNull);
    });

    test('cache items resolve to the cached file and register a play',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      final stored = await cache.storeBytes(
        track: _track('c'),
        bytes: const <int>[1, 2, 3],
        format: 'MP3',
      );
      final manager = _manager(backend: backend, cache: cache);
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('c')]);

      expect(
        await manager.resolveDeferred(backend.queue.single),
        stored.filePath,
      );
      expect((await cache.lookup(_track('c')))?.entry.playCount, 1);
    });

    test('foreign items resolve to null for chained delegation', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();

      const foreign = PlayableMedia(
        id: 'engine-owned',
        source: 'https://engine.example/x.mp3',
        title: 'Engine item',
        artist: 'Engine',
      );
      expect(await manager.resolveDeferred(foreign), isNull);
    });

    test('unresolvable streams resolve to null without throwing', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('s')]);

      // 's' queued lazily (streaming enabled); no candidates exist.
      expect(await manager.resolveDeferred(backend.queue.single), isNull);
    });

    test('resolution re-decides: downloads that land mid-queue go local',
        () async {
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
      expect(backend.queue.single.isDeferredStream, isTrue);

      localPaths['s'] = '/music/s.flac';
      expect(
        await manager.resolveDeferred(backend.queue.single),
        '/music/s.flac',
      );
    });
  });

  group('queue transitions', () {
    test('natural advance keeps later items resolvable', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
          'b': <StreamSource>[_source('https://cdn.example/b.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('a'), _track('b')]);

      backend.emitState(PlaybackSourceStatus.playing, media: 'b', track: 'b');
      await _flush();

      expect(manager.currentMediaId, 'b');
      expect(await manager.resolveDeferred(backend.queue[1]),
          'https://cdn.example/b.mp3');
    });

    test('rebuilding the queue drops the stale registry', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
          'b': <StreamSource>[_source('https://cdn.example/b.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('a')]);
      final stale = backend.queue.single;

      await manager.playTracks(<Track>[_track('b')]);
      expect(manager.queueMediaIds, <String>['b']);
      expect(await manager.resolveDeferred(stale), isNull);
      expect(await manager.resolveDeferred(backend.queue.single),
          'https://cdn.example/b.mp3');
    });

    test('every queued track is registered for engine fallback', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      await cache.storeBytes(track: _track('c'), bytes: const <int>[1]);
      final registered = <String>[];
      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'l': '/music/l.flac'},
        cache: cache,
        candidates: <String, List<StreamSource>>{
          's': <StreamSource>[_source('https://cdn.example/s.mp3')],
        },
        registrar: (Track track) => registered.add(track.id),
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.playTracks(
        <Track>[_track('l'), _track('c'), _track('s')],
      );
      expect(registered, <String>['l', 'c', 's']);
    });

    test('single-track play registers for engine fallback too', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final registered = <String>[];
      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'l': '/music/l.flac'},
        registrar: (Track track) => registered.add(track.id),
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.playTrack(_track('l'));
      expect(registered, <String>['l']);
    });
  });
}
