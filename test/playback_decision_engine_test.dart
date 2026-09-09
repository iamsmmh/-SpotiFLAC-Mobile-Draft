// Routing verdicts (local → cache → stream), mixed-queue construction, and
// the single-backend invariant of the unified hybrid playback layer.
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

  // The SDK's `controller.stream` returns a fresh wrapper on every access;
  // the tests pin the "one shared state stream" identity, so cache it.
  late final Stream<PlaybackSourceState> stateStream = states.stream;
  late final Stream<PlaybackProgress> progressStream = ticks.stream;

  bool ready = false;
  bool disposed = false;
  final List<PlayableMedia> played = <PlayableMedia>[];
  List<PlayableMedia> queue = const <PlayableMedia>[];
  int initialIndex = 0;
  int pauses = 0;
  int resumes = 0;
  int stops = 0;
  final List<Duration> seeks = <Duration>[];
  final List<PlayableMedia> replaced = <PlayableMedia>[];
  final List<Duration> replacedAt = <Duration>[];
  int persists = 0;
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
  Stream<PlaybackSourceState> get state => stateStream;

  @override
  Stream<PlaybackProgress> get progress => progressStream;

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
    this.initialIndex = initialIndex;
    if (items.isNotEmpty) {
      mediaId = items[initialIndex.clamp(0, items.length - 1)].id;
    }
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> resume() async {
    resumes++;
  }

  @override
  Future<void> stop() async {
    stops++;
    mediaId = '';
    trackId = '';
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    this.position = position;
  }

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
  Future<void> persistSession() async {
    persists++;
  }

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

  void emitProgress({
    String? media,
    String? track,
    Duration? pos,
    Duration? dur,
  }) {
    ticks.add(
      PlaybackProgress(
        trackId: track ?? trackId,
        mediaId: media ?? mediaId,
        position: pos ?? position,
        duration: dur ?? total,
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

StreamSource _source(String url, {int bitrate = 320}) =>
    StreamSource(url: url, format: 'MP3', bitrate: bitrate);

Directory _tempRoot(String prefix) {
  final root = Directory.systemTemp.createTempSync(prefix);
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
  PlaybackPolicy policy = const PlaybackPolicy(),
  LocalTrackPathBatchResolver? batch,
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
      cache:
          cache ?? PlaybackCacheManager.atRoot(_tempRoot('upm-decide')),
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
    policy: policy,
    batchPathResolver: batch,
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

  group('routing verdicts', () {
    test('downloaded file wins over cache and stream', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot('upm-decide'));
      await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1, 2, 3],
        format: 'FLAC',
      );

      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'t': '/music/t.flac'},
        cache: cache,
        candidates: <String, List<StreamSource>>{
          't': <StreamSource>[_source('https://cdn.example/t.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      final decision = await manager.decide(_track('t'));
      expect(decision.kind, PlaybackSourceKind.localLibrary);
      expect(decision.localPath, '/music/t.flac');
      expect(decision.reason, isNotEmpty);
      expect(decision.isPlayable, isTrue);
    });

    test('verified cache wins over stream', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot('upm-decide'));
      await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1, 2, 3],
        format: 'FLAC',
      );

      final manager = _manager(
        backend: backend,
        cache: cache,
        candidates: <String, List<StreamSource>>{
          't': <StreamSource>[_source('https://cdn.example/t.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      final decision = await manager.decide(_track('t'));
      expect(decision.kind, PlaybackSourceKind.streamCache);
      expect(decision.cacheHit, isNotNull);
      expect(decision.cacheHit!.filePath, endsWith('.flac'));
    });

    test('falls through to provider stream when nothing local', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          't': <StreamSource>[_source('https://cdn.example/t.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      final decision = await manager.decide(_track('t'));
      expect(decision.kind, PlaybackSourceKind.providerStream);
    });

    test('deciding never probes the network', () async {
      var fetches = 0;
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          't': <StreamSource>[_source('https://cdn.example/t.mp3')],
        },
        onFetch: () => fetches++,
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.decide(_track('t'));
      expect(fetches, 0);
    });

    test('offline mode keeps local and cache but drops streams', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot('upm-decide'));
      await cache.storeBytes(
        track: _track('cached'),
        bytes: const <int>[1, 2, 3],
      );
      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'local': '/music/l.flac'},
        cache: cache,
        candidates: <String, List<StreamSource>>{
          'stream': <StreamSource>[_source('https://cdn.example/s.mp3')],
        },
        policy: const PlaybackPolicy(offlineMode: true),
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      expect(
        (await manager.decide(_track('local'))).kind,
        PlaybackSourceKind.localLibrary,
      );
      expect(
        (await manager.decide(_track('cached'))).kind,
        PlaybackSourceKind.streamCache,
      );
      final stream = await manager.decide(_track('stream'));
      expect(stream.kind, PlaybackSourceKind.unavailable);
      expect(stream.reason, contains('Offline'));
    });

    test('disabled streaming yields unavailable without local or cache',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          't': <StreamSource>[_source('https://cdn.example/t.mp3')],
        },
        policy: const PlaybackPolicy(streamingEnabled: false),
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      final decision = await manager.decide(_track('t'));
      expect(decision.kind, PlaybackSourceKind.unavailable);
      expect(decision.isPlayable, isFalse);
    });

    test('disabled cache skips cache hits', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot('upm-decide'));
      await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1, 2, 3],
      );
      final manager = _manager(
        backend: backend,
        cache: cache,
        candidates: <String, List<StreamSource>>{
          't': <StreamSource>[_source('https://cdn.example/t.mp3')],
        },
        policy: const PlaybackPolicy(cacheEnabled: false),
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      expect(
        (await manager.decide(_track('t'))).kind,
        PlaybackSourceKind.providerStream,
      );
    });

    test('corrupt cache entry self-heals and falls through to stream',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final root = _tempRoot('upm-decide');
      final cache = PlaybackCacheManager.atRoot(root);
      await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1, 2, 3],
      );
      await for (final entity in Directory('${root.path}/tracks').list()) {
        await entity.delete();
      }
      final manager = _manager(
        backend: backend,
        cache: cache,
        candidates: <String, List<StreamSource>>{
          't': <StreamSource>[_source('https://cdn.example/t.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      expect(
        (await manager.decide(_track('t'))).kind,
        PlaybackSourceKind.providerStream,
      );
      expect(await cache.lookup(_track('t')), isNull);
    });

    test('knownLocalPath fast path skips resolution', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();

      final decision = await manager.decide(
        _track('t'),
        knownLocalPath: '/music/t.flac',
      );
      expect(decision.kind, PlaybackSourceKind.localLibrary);
      expect(decision.localPath, '/music/t.flac');
    });

    test('sourceForKind routes each kind to its owner', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();

      expect(
        manager.sourceForKind(PlaybackSourceKind.localLibrary),
        same(manager.localSource),
      );
      expect(
        manager.sourceForKind(PlaybackSourceKind.streamCache),
        same(manager.cacheSource),
      );
      expect(
        manager.sourceForKind(PlaybackSourceKind.providerStream),
        same(manager.streamingSource),
      );
      expect(
        manager.sourceForKind(PlaybackSourceKind.previewStream),
        same(manager.streamingSource),
      );
      expect(
        manager.sourceForKind(PlaybackSourceKind.unavailable),
        isNull,
      );
    });
  });

  group('playback entry points', () {
    test('playTrack plays through the routed source', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'t': '/music/t.flac'},
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.playTrack(_track('t'));
      expect(backend.played, hasLength(1));
      expect(backend.played.single.id, '/music/t.flac');
      expect(manager.currentTrack?.id, 't');
      expect(manager.currentKind, PlaybackSourceKind.localLibrary);
      expect(manager.queueMediaIds, <String>['/music/t.flac']);
    });

    test('playTrack throws a typed error when unavailable', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        policy: const PlaybackPolicy(offlineMode: true),
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await expectLater(
        manager.playTrack(_track('t')),
        throwsA(
          isA<PlaybackSourceException>().having(
            (error) => error.kind,
            'kind',
            'unavailable',
          ),
        ),
      );
      expect(backend.played, isEmpty);
    });

    test('playback before initialize throws StateError', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);

      await expectLater(
        manager.playTrack(_track('t')),
        throwsStateError,
      );
    });
  });

  group('mixed queue', () {
    test('local, cached, and streaming items keep order and routing',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot('upm-decide'));
      final cachedHit = await cache.storeBytes(
        track: _track('cached'),
        bytes: const <int>[1, 2, 3],
        format: 'FLAC',
      );
      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'local': '/music/l.flac'},
        cache: cache,
        candidates: <String, List<StreamSource>>{
          'stream': <StreamSource>[_source('https://cdn.example/s.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.playTracks(
        <Track>[_track('local'), _track('cached'), _track('stream')],
      );

      expect(backend.queue, hasLength(3));
      expect(backend.queue[0].id, '/music/l.flac');
      expect(backend.queue[0].playbackMode, 'local');
      expect(backend.queue[0].source, '/music/l.flac');
      expect(backend.queue[1].id, cachedHit.entry.key);
      expect(backend.queue[1].playbackMode, 'local');
      expect(backend.queue[1].source, cachedHit.filePath);
      expect(backend.queue[1].sourceLabel, 'Stream cache');
      expect(backend.queue[2].id, 'stream');
      expect(backend.queue[2].isDeferredStream, isTrue);
      expect(manager.currentMediaId, '/music/l.flac');
      expect(manager.queueMediaIds, hasLength(3));
    });

    test('startIndex rotates the queue', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
          'b': <StreamSource>[_source('https://cdn.example/b.mp3')],
          'c': <StreamSource>[_source('https://cdn.example/c.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.playTracks(
        <Track>[_track('a'), _track('b'), _track('c')],
        startIndex: 1,
      );
      expect(
        backend.queue.map((item) => item.id),
        <String>['b', 'c', 'a'],
      );
      expect(manager.currentMediaId, 'b');
    });

    test('startIndex clamps into range', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.playTracks(<Track>[_track('a')], startIndex: 99);
      expect(backend.queue.map((item) => item.id), <String>['a']);
    });

    test('unplayable items are skipped inside a mixed queue', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'local': '/music/l.flac'},
        policy: const PlaybackPolicy(streamingEnabled: false),
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.playTracks(
        <Track>[_track('local'), _track('nope')],
      );
      expect(
        backend.queue.map((item) => item.id),
        <String>['/music/l.flac'],
      );
    });

    test('all-unplayable queue throws and never touches the backend',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        policy: const PlaybackPolicy(streamingEnabled: false),
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await expectLater(
        manager.playTracks(<Track>[_track('a'), _track('b')]),
        throwsA(isA<PlaybackSourceException>()),
      );
      expect(backend.queue, isEmpty);
    });

    test('empty list is a no-op', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.playTracks(const <Track>[]);
      expect(backend.queue, isEmpty);
    });

    test('mismatched batch result falls back to per-track resolution',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        localPaths: const <String, String>{'a': '/music/a.flac'},
        batch: (_) async => const <String?>[],
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.playTracks(<Track>[_track('a'), _track('b')]);
      expect(backend.queue.map((item) => item.id), <String>[
        '/music/a.flac',
        'b',
      ]);
    });
  });

  group('single shared player', () {
    test('manager and all sources share one state stream', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();

      expect(manager.state, same(backend.state));
      expect(manager.localSource.state, same(backend.state));
      expect(manager.cacheSource.state, same(backend.state));
      expect(manager.streamingSource.state, same(backend.state));
    });

    test('backend state advances the current item', () async {
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
      expect(manager.currentMediaId, 'a');

      backend.emitState(PlaybackSourceStatus.playing, media: 'b', track: 'b');
      await _flush();

      expect(manager.currentMediaId, 'b');
      expect(manager.currentTrack?.id, 'b');
    });

    test('foreign backend items do not hijack current tracking', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
        },
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('a')]);

      backend.emitState(
        PlaybackSourceStatus.playing,
        media: 'engine-owned',
        track: 'engine-owned',
      );
      await _flush();

      expect(manager.currentMediaId, 'a');
      expect(manager.trackIdForMediaId('engine-owned'), isEmpty);
      expect(manager.trackIdForMediaId('a'), 'a');
    });
  });
}
