// Audio policy: gapless and crossfade flow from PlaybackPolicy to the
// player exactly once per change, clamped to the supported range.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/crossfade_policy.dart'
    show CrossfadeSettings;
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

  @override
  Future<void> ensureReady() async {}

  @override
  Stream<PlaybackSourceState> get state => states.stream;

  @override
  Stream<PlaybackProgress> get progress => ticks.stream;

  @override
  Duration get currentPosition => Duration.zero;

  @override
  Duration get duration => Duration.zero;

  @override
  String get currentTrackId => '';

  @override
  String get currentMediaId => '';

  @override
  Future<void> playMedia(
    PlayableMedia media, {
    Duration startPosition = Duration.zero,
  }) async {}

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
  void noteSourceExpiry(String mediaId, DateTime? expiresAt) {}

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
  final root = Directory.systemTemp.createTempSync('upm-policy');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

PlaybackManager _manager({
  required _FakeBackend backend,
  PlaybackPolicy policy = const PlaybackPolicy(),
  void Function(bool enabled)? gaplessApplier,
  void Function(CrossfadeSettings settings)? crossfadeApplier,
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
        fetchCandidates: (_) async => const <StreamSource>[],
        validateSource: (_) async => true,
        retryDelay: (_) async {},
      ),
    ),
    policy: policy,
    gaplessApplier: gaplessApplier,
    crossfadeApplier: crossfadeApplier,
  );
}

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

  group('policy application', () {
    test('initialize applies gapless and crossfade once', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final gaplessCalls = <bool>[];
      final crossfadeCalls = <CrossfadeSettings>[];
      final manager = _manager(
        backend: backend,
        policy: const PlaybackPolicy(
          gaplessEnabled: true,
          crossfadeSeconds: 5,
          crossfadeSmart: false,
        ),
        gaplessApplier: gaplessCalls.add,
        crossfadeApplier: crossfadeCalls.add,
      );
      addTearDown(manager.dispose);

      await manager.initialize();
      expect(gaplessCalls, <bool>[true]);
      expect(crossfadeCalls, hasLength(1));
      expect(crossfadeCalls.single.seconds, 5);
      expect(crossfadeCalls.single.smart, isFalse);
    });

    test('policy updates re-apply; identical policies do not', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      var gaplessCalls = 0;
      var crossfadeCalls = 0;
      final manager = _manager(
        backend: backend,
        gaplessApplier: (_) => gaplessCalls++,
        crossfadeApplier: (_) => crossfadeCalls++,
      );
      addTearDown(manager.dispose);
      await manager.initialize();
      expect(gaplessCalls, 1);

      manager.updatePolicy(const PlaybackPolicy(gaplessEnabled: false));
      expect(gaplessCalls, 2);
      expect(crossfadeCalls, 2);

      manager.updatePolicy(const PlaybackPolicy(gaplessEnabled: false));
      expect(gaplessCalls, 2);
      expect(crossfadeCalls, 2);
      expect(manager.policy.gaplessEnabled, isFalse);
    });

    test('updates before initialize apply once at boot with the latest',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final gaplessCalls = <bool>[];
      final manager = _manager(
        backend: backend,
        gaplessApplier: gaplessCalls.add,
        crossfadeApplier: (_) {},
      );
      addTearDown(manager.dispose);

      manager.updatePolicy(const PlaybackPolicy(gaplessEnabled: false));
      manager.updatePolicy(const PlaybackPolicy(gaplessEnabled: true));
      expect(gaplessCalls, isEmpty);

      await manager.initialize();
      expect(gaplessCalls, <bool>[true]);
    });

    test('explicit applyAudioPolicy re-applies the current policy', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      var calls = 0;
      final manager = _manager(
        backend: backend,
        gaplessApplier: (_) => calls++,
        crossfadeApplier: (_) {},
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      manager.applyAudioPolicy();
      manager.applyAudioPolicy();
      expect(calls, 3);
    });
  });

  group('crossfade range', () {
    test('seconds clamp to 0..12', () {
      expect(
        const PlaybackPolicy(crossfadeSeconds: 5).effectiveCrossfadeSeconds,
        5,
      );
      expect(
        const PlaybackPolicy(crossfadeSeconds: 0).effectiveCrossfadeSeconds,
        0,
      );
      expect(
        const PlaybackPolicy(crossfadeSeconds: 12).effectiveCrossfadeSeconds,
        12,
      );
      expect(
        const PlaybackPolicy(crossfadeSeconds: 20).effectiveCrossfadeSeconds,
        12,
      );
      expect(
        const PlaybackPolicy(crossfadeSeconds: -3).effectiveCrossfadeSeconds,
        0,
      );
    });

    test('clamped values reach the player', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final applied = <CrossfadeSettings>[];
      final manager = _manager(
        backend: backend,
        policy: const PlaybackPolicy(crossfadeSeconds: 99),
        gaplessApplier: (_) {},
        crossfadeApplier: applied.add,
      );
      addTearDown(manager.dispose);

      await manager.initialize();
      expect(applied.single.seconds, 12);

      manager.updatePolicy(const PlaybackPolicy(crossfadeSeconds: -5));
      expect(applied.last.seconds, 0);
    });
  });

  group('policy value', () {
    test('copyWith and equality behave', () {
      const base = PlaybackPolicy();
      expect(base, const PlaybackPolicy());
      expect(base.hashCode, const PlaybackPolicy().hashCode);
      expect(
        base.copyWith(),
        base,
      );
      expect(
        base.copyWith(crossfadeSeconds: 4),
        const PlaybackPolicy(crossfadeSeconds: 4),
      );
      expect(
        base.copyWith(preloadThreshold: 0.5).preloadThreshold,
        0.5,
      );
    });

    test('unused track helper keeps the suite honest', () {
      expect(_track('t').name, 'Title t');
    });
  });
}
