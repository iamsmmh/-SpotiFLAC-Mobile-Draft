// Background and lifecycle behavior: session persistence delegation,
// clean teardown (hooks/listeners/watchers restored), and stop semantics.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/data/network_switch_policy.dart'
    show NetworkTransport;
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

  bool disposed = false;
  List<PlayableMedia> queue = const <PlayableMedia>[];
  int stops = 0;
  int pauses = 0;
  int persists = 0;

  Duration position = Duration.zero;
  Duration total = Duration.zero;
  String trackId = '';
  String mediaId = '';

  @override
  Future<void> ensureReady() async {}

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
    queue = <PlayableMedia>[media];
    mediaId = media.id;
  }

  @override
  Future<void> setQueue(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    queue = List<PlayableMedia>.of(items);
  }

  @override
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async {
    stops++;
    mediaId = '';
    trackId = '';
  }

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> replaceCurrent(
    PlayableMedia media, {
    Duration resumeAt = Duration.zero,
  }) async {}

  @override
  Future<void> persistSession() async {
    persists++;
  }

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

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('upm-lifecycle');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

PlaybackManager _manager({
  required _FakeBackend backend,
  Map<String, List<StreamSource>> candidates =
      const <String, List<StreamSource>>{},
  void Function()? onFetch,
}) {
  return PlaybackManager(
    backend: backend,
    localSource: LocalPlaybackSource(
      backend: backend,
      resolvePath: (_) async => null,
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

  group('session persistence', () {
    test('persistSession delegates to the backend', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.persistSession();
      expect(backend.persists, 1);
    });
  });

  group('stop semantics', () {
    test('source stop clears the backend session', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();

      await manager.localSource.stop();
      expect(backend.stops, 1);
      expect(backend.currentMediaId, isEmpty);
      expect(manager.currentTrackId, isEmpty);

      backend.emitState(PlaybackSourceStatus.idle);
      await _flush();
      expect(manager.latestState.status, PlaybackSourceStatus.idle);
    });
  });

  group('teardown', () {
    test('dispose detaches listeners, hooks, and watchers', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      var fetches = 0;
      final manager = _manager(
        backend: backend,
        candidates: <String, List<StreamSource>>{
          'a': <StreamSource>[
            StreamSource(url: 'https://cdn.example/a.mp3', format: 'MP3', bitrate: 320),
          ],
          'b': <StreamSource>[
            StreamSource(url: 'https://cdn.example/b.mp3', format: 'MP3', bitrate: 320),
          ],
        },
        onFetch: () => fetches++,
      );
      await manager.initialize();
      await manager.playTracks(<Track>[_track('a'), _track('b')]);
      backend.emitState(PlaybackSourceStatus.playing, media: 'a', track: 'a');
      await _flush();

      final transports = StreamController<Iterable<String>>();
      addTearDown(transports.close);
      manager.watchNetwork(transports.stream);
      expect(playbackFailureListener, isNotNull);
      expect(deferredStreamResolver, isNotNull);
      expect(playbackDownloadListener, isNotNull);

      await manager.dispose();
      expect(playbackFailureListener, savedFailure);
      expect(
        identical(deferredStreamResolver, savedDeferred),
        isTrue,
      );
      expect(playbackDownloadListener, savedDownload);

      // Everything post-dispose is inert: no preloads, no pauses, and the
      // manager refuses new playback.
      backend.emitProgress(
        media: 'a',
        track: 'a',
        pos: const Duration(seconds: 190),
        dur: const Duration(seconds: 200),
      );
      transports.add(const <String>[NetworkTransport.none]);
      await _flush();
      expect(fetches, 0);
      expect(backend.pauses, 0);
      await expectLater(manager.playTrack(_track('a')), throwsStateError);
      await manager.dispose(); // idempotent
    });

    test('repeated watchNetwork calls replace the previous watcher', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();
      backend.emitState(PlaybackSourceStatus.playing);
      await _flush();

      final first = StreamController<Iterable<String>>();
      addTearDown(first.close);
      final second = StreamController<Iterable<String>>();
      addTearDown(second.close);
      manager.watchNetwork(first.stream);
      manager.watchNetwork(second.stream);

      first.add(const <String>[NetworkTransport.none]);
      await _flush();
      expect(backend.pauses, 0);

      second.add(const <String>[NetworkTransport.wifi]);
      await _flush();
      second.add(const <String>[NetworkTransport.none]);
      await _flush();
      expect(backend.pauses, 1);
    });
  });

  group('initialization', () {
    test('initialize is idempotent and installs hooks once', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);

      await manager.initialize();
      await manager.initialize();
      expect(manager.isInitialized, isTrue);

      // A single uninstall restores the pre-init globals: the second
      // initialize must not have wrapped the hooks around themselves.
      manager.uninstallHooks();
      expect(playbackFailureListener, savedFailure);
      expect(
        identical(deferredStreamResolver, savedDeferred),
        isTrue,
      );
    });

    test('latestState tracks the backend state stream', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();

      expect(manager.latestState, PlaybackSourceState.idle);
      backend.emitState(PlaybackSourceStatus.playing, media: 'a', track: 'a');
      await _flush();
      expect(manager.latestState.status, PlaybackSourceStatus.playing);
      expect(manager.latestState.mediaId, 'a');
    });
  });
}
