// Next-track preloading: the 75% trigger, one-shot-per-queue semantics,
// and re-decision at trigger time.
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
  List<PlayableMedia> queue = const <PlayableMedia>[];

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
  }) async {}

  @override
  Future<void> persistSession() async {}

  @override
  void noteSourceExpiry(String mediaId, DateTime? expiresAt) {}

  void emitState(
    PlaybackSourceStatus status, {
    String? media,
    String? track,
  }) {
    if (media != null) mediaId = media;
    if (track != null) trackId = track;
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

StreamSource _source(String url) =>
    StreamSource(url: url, format: 'MP3', bitrate: 320);

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('upm-preload');
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
  PlaybackPolicy policy = const PlaybackPolicy(),
  void Function(String trackId)? onFetch,
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
          onFetch?.call(track.id);
          return candidates[track.id] ?? const <StreamSource>[];
        },
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

  group('shouldPreloadAt', () {
    test('default threshold is 75%', () {
      expect(PlaybackManager.defaultPreloadThreshold, 0.75);
    });

    test('triggers at and above the threshold', () {
      const duration = Duration(seconds: 200);
      expect(
        shouldPreloadAt(
          position: const Duration(seconds: 150),
          duration: duration,
        ),
        isTrue,
      );
      expect(
        shouldPreloadAt(
          position: const Duration(seconds: 199),
          duration: duration,
        ),
        isTrue,
      );
      expect(
        shouldPreloadAt(
          position: const Duration(seconds: 149),
          duration: duration,
        ),
        isFalse,
      );
    });

    test('unknown durations never trigger', () {
      expect(
        shouldPreloadAt(
          position: const Duration(seconds: 10),
          duration: Duration.zero,
        ),
        isFalse,
      );
      expect(
        shouldPreloadAt(
          position: const Duration(seconds: -1),
          duration: const Duration(seconds: 200),
        ),
        isFalse,
      );
    });

    test('custom thresholds are honored', () {
      const duration = Duration(seconds: 100);
      expect(
        shouldPreloadAt(
          position: const Duration(seconds: 50),
          duration: duration,
          threshold: 0.5,
        ),
        isTrue,
      );
      expect(
        shouldPreloadAt(
          position: const Duration(seconds: 49),
          duration: duration,
          threshold: 0.5,
        ),
        isFalse,
      );
      expect(
        shouldPreloadAt(
          position: Duration.zero,
          duration: duration,
          threshold: 0,
        ),
        isTrue,
      );
    });
  });

  group('preload trigger', () {
    test('below the threshold nothing preloads', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final fetched = <String>[];
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
          'b': <StreamSource>[_source('https://cdn.example/b.mp3')],
        },
        onFetch: fetched.add,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('a'), _track('b')]);

      backend.emitProgress(
        media: 'a',
        track: 'a',
        pos: const Duration(seconds: 100),
        dur: const Duration(seconds: 200),
      );
      await _flush();
      expect(fetched, isEmpty);
    });

    test('at the threshold the next item preloads exactly once', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final fetched = <String>[];
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
          'b': <StreamSource>[_source('https://cdn.example/b.mp3')],
        },
        onFetch: fetched.add,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('a'), _track('b')]);

      for (var i = 0; i < 3; i++) {
        backend.emitProgress(
          media: 'a',
          track: 'a',
          pos: const Duration(seconds: 160),
          dur: const Duration(seconds: 200),
        );
        await _flush();
      }
      expect(fetched, <String>['b']);
    });

    test('the last item has nothing to preload', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final fetched = <String>[];
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
          'b': <StreamSource>[_source('https://cdn.example/b.mp3')],
        },
        onFetch: fetched.add,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('a'), _track('b')]);

      backend.emitState(PlaybackSourceStatus.playing, media: 'b', track: 'b');
      backend.emitProgress(
        media: 'b',
        track: 'b',
        pos: const Duration(seconds: 190),
        dur: const Duration(seconds: 200),
      );
      await _flush();
      expect(fetched, isEmpty);
    });

    test('foreign and empty ticks are ignored', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final fetched = <String>[];
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
        },
        onFetch: fetched.add,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('a')]);

      backend.emitProgress(
        media: 'engine-owned',
        track: 'engine-owned',
        pos: const Duration(seconds: 190),
        dur: const Duration(seconds: 200),
      );
      backend.emitProgress(
        media: '',
        track: '',
        pos: const Duration(seconds: 190),
        dur: const Duration(seconds: 200),
      );
      await _flush();
      expect(fetched, isEmpty);
    });

    test('disabled preload policy silences the trigger', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final fetched = <String>[];
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
          'b': <StreamSource>[_source('https://cdn.example/b.mp3')],
        },
        policy: const PlaybackPolicy(preloadNextTrack: false),
        onFetch: fetched.add,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('a'), _track('b')]);

      backend.emitProgress(
        media: 'a',
        track: 'a',
        pos: const Duration(seconds: 190),
        dur: const Duration(seconds: 200),
      );
      await _flush();
      expect(fetched, isEmpty);
    });

    test('single-track play has no next item to preload', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final fetched = <String>[];
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
        },
        onFetch: fetched.add,
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      // Queued as a one-item queue via playTrack (local for determinism is
      // unnecessary; the point is the missing successor).
      await manager.playTracks(<Track>[_track('a')]);
      backend.emitProgress(
        media: 'a',
        track: 'a',
        pos: const Duration(seconds: 190),
        dur: const Duration(seconds: 200),
      );
      await _flush();
      expect(fetched, isEmpty);
    });

    test('trigger re-decides: fresh downloads preload locally', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final fetched = <String>[];
      final localPaths = <String, String>{'a': '/music/a.flac'};
      final manager = _manager(
        backend: backend,
        localPaths: localPaths,
        candidates: <String, List<StreamSource>>{
          'b': <StreamSource>[_source('https://cdn.example/b.mp3')],
        },
        onFetch: fetched.add,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(<Track>[_track('a'), _track('b')]);

      localPaths['b'] = '/music/b.flac';
      backend.emitProgress(
        media: '/music/a.flac',
        track: 'a',
        pos: const Duration(seconds: 190),
        dur: const Duration(seconds: 200),
      );
      await _flush();
      expect(fetched, isEmpty);
    });

    test('each queue item preloads its successor once per queue', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final fetched = <String>[];
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[_source('https://cdn.example/a.mp3')],
          'b': <StreamSource>[_source('https://cdn.example/b.mp3')],
          'c': <StreamSource>[_source('https://cdn.example/c.mp3')],
        },
        onFetch: fetched.add,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(
        <Track>[_track('a'), _track('b'), _track('c')],
      );

      backend.emitProgress(
        media: 'a',
        track: 'a',
        pos: const Duration(seconds: 190),
        dur: const Duration(seconds: 200),
      );
      await _flush();
      expect(fetched, <String>['b']);

      backend.emitState(PlaybackSourceStatus.playing, media: 'b', track: 'b');
      backend.emitProgress(
        media: 'b',
        track: 'b',
        pos: const Duration(seconds: 190),
        dur: const Duration(seconds: 200),
      );
      await _flush();
      expect(fetched, <String>['b', 'c']);

      // Replaying 'a' does not re-warm 'b' within the same queue build.
      backend.emitProgress(
        media: 'a',
        track: 'a',
        pos: const Duration(seconds: 195),
        dur: const Duration(seconds: 200),
      );
      await _flush();
      expect(fetched, <String>['b', 'c']);
    });
  });
}
