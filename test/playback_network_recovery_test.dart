// Network resilience: safe auto-pause on connectivity loss, resume on
// reconnect, and offline stream gating (cache stays playable).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/data/network_switch_policy.dart'
    show NetworkTransport;
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
  int pauses = 0;
  int resumes = 0;

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
  Future<void> pause() async {
    pauses++;
  }

  @override
  Future<void> resume() async {
    resumes++;
  }

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
  final root = Directory.systemTemp.createTempSync('upm-network');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

PlaybackManager _manager({
  required _FakeBackend backend,
  PlaybackCacheManager? cache,
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
      cache: cache ?? PlaybackCacheManager.atRoot(_tempRoot()),
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

  group('auto pause and resume', () {
    test('connectivity loss pauses; reconnect resumes at the same position',
        () async {
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
      backend.position = const Duration(seconds: 42);
      backend.emitState(PlaybackSourceStatus.playing, media: 's', track: 's');
      await _flush();

      final transports = StreamController<Iterable<String>>();
      addTearDown(transports.close);
      manager.watchNetwork(transports.stream);
      transports.add(const <String>[NetworkTransport.wifi]);
      await _flush();
      expect(manager.networkOffline, isFalse);

      transports.add(const <String>[NetworkTransport.none]);
      await _flush();
      expect(manager.networkOffline, isTrue);
      expect(backend.pauses, 1);
      expect(manager.autoPaused, isTrue);

      // Repeated offline emissions do not stack pauses.
      transports.add(const <String>[NetworkTransport.none]);
      await _flush();
      expect(backend.pauses, 1);

      backend.emitState(PlaybackSourceStatus.paused, media: 's', track: 's');
      transports.add(const <String>[NetworkTransport.wifi]);
      await _flush();
      expect(manager.networkOffline, isFalse);
      expect(manager.autoPaused, isFalse);
      expect(backend.resumes, 1);
      expect(backend.position, const Duration(seconds: 42));
    });

    test('user-paused sessions are never auto-resumed', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();
      backend.emitState(PlaybackSourceStatus.paused);
      await _flush();

      final transports = StreamController<Iterable<String>>();
      addTearDown(transports.close);
      manager.watchNetwork(transports.stream);
      transports.add(const <String>[NetworkTransport.wifi]);
      await _flush();
      transports.add(const <String>[NetworkTransport.none]);
      await _flush();

      expect(backend.pauses, 0);
      expect(manager.autoPaused, isFalse);

      transports.add(const <String>[NetworkTransport.mobile]);
      await _flush();
      expect(backend.resumes, 0);
    });

    test('manual resume while offline suppresses the auto-resume', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();
      backend.emitState(PlaybackSourceStatus.playing);
      await _flush();

      final transports = StreamController<Iterable<String>>();
      addTearDown(transports.close);
      manager.watchNetwork(transports.stream);
      transports.add(const <String>[NetworkTransport.wifi]);
      await _flush();
      transports.add(const <String>[NetworkTransport.none]);
      await _flush();
      expect(manager.autoPaused, isTrue);

      // The user pressed play during the outage (the stream fails, but the
      // state says playing when connectivity returns).
      backend.emitState(PlaybackSourceStatus.playing);
      await _flush();
      transports.add(const <String>[NetworkTransport.wifi]);
      await _flush();

      expect(backend.resumes, 0);
      expect(manager.autoPaused, isFalse);
    });

    test('cancelled watcher ignores further emissions', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final manager = _manager(backend: backend);
      addTearDown(manager.dispose);
      await manager.initialize();
      backend.emitState(PlaybackSourceStatus.playing);
      await _flush();

      final transports = StreamController<Iterable<String>>();
      addTearDown(transports.close);
      manager.watchNetwork(transports.stream);
      manager.cancelNetworkWatch();
      transports.add(const <String>[NetworkTransport.none]);
      await _flush();

      expect(backend.pauses, 0);
      expect(manager.networkOffline, isFalse);
    });
  });

  group('offline gating', () {
    test('offline blocks streams but keeps cache playable', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      final stored = await cache.storeBytes(
        track: _track('cached'),
        bytes: const <int>[1, 2, 3],
        format: 'MP3',
      );
      var fetches = 0;
      final manager = _manager(
        backend: backend,
        cache: cache,
        candidates: <String, List<StreamSource>>{
          'stream': <StreamSource>[_source('https://cdn.example/s.mp3')],
        },
        onFetch: () => fetches++,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      await manager.playTracks(
        <Track>[_track('stream'), _track('cached')],
      );

      final transports = StreamController<Iterable<String>>();
      addTearDown(transports.close);
      manager.watchNetwork(transports.stream);
      transports.add(const <String>[NetworkTransport.wifi]);
      await _flush();
      transports.add(const <String>[NetworkTransport.none]);
      await _flush();

      expect(
        (await manager.decide(_track('stream'))).kind,
        PlaybackSourceKind.unavailable,
      );
      expect(
        (await manager.decide(_track('cached'))).kind,
        PlaybackSourceKind.streamCache,
      );
      expect(
        await manager.resolveDeferred(backend.queue[0]),
        isNull,
      );
      expect(fetches, 0);
      expect(
        await manager.resolveDeferred(backend.queue[1]),
        stored.filePath,
      );

      transports.add(const <String>[NetworkTransport.wifi]);
      await _flush();
      expect(
        await manager.resolveDeferred(backend.queue[0]),
        'https://cdn.example/s.mp3',
      );
      expect(fetches, 1);
    });
  });
}
