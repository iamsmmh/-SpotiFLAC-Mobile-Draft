// Local file playback: resolution, media shaping, transport delegation,
// and the error contract when no download exists.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia;
import 'package:spotiflac_android/services/playback/playback.dart';

class _FakeBackend implements PlaybackBackend {
  final StreamController<PlaybackSourceState> states =
      StreamController<PlaybackSourceState>.broadcast();
  final StreamController<PlaybackProgress> ticks =
      StreamController<PlaybackProgress>.broadcast();

  // The SDK's `controller.stream` returns a fresh wrapper on every access;
  // the tests pin the "one shared state stream" identity, so cache it.
  final Stream<PlaybackSourceState> stateStream = states.stream;
  final Stream<PlaybackProgress> progressStream = ticks.stream;

  bool ready = false;
  bool disposed = false;
  final List<PlayableMedia> played = <PlayableMedia>[];
  List<PlayableMedia> queue = const <PlayableMedia>[];
  int pauses = 0;
  int resumes = 0;
  int stops = 0;
  final List<Duration> seeks = <Duration>[];
  final List<PlayableMedia> replaced = <PlayableMedia>[];
  int persists = 0;
  final Map<String, DateTime?> expiries = <String, DateTime?>{};

  /// Media-id → track-id mapping the fake backend projects (the production
  /// backend maps queue media ids back to tracks the same way).
  final Map<String, String> trackIds = <String, String>{};

  Duration position = Duration.zero;
  Duration total = const Duration(seconds: 200);
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
    trackId = trackIds[media.id] ?? trackId;
    position = startPosition;
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

LocalPlaybackSource _source(
  _FakeBackend backend, {
  Map<String, String> paths = const <String, String>{},
}) {
  return LocalPlaybackSource(
    backend: backend,
    resolvePath: (Track track) async => paths[track.id],
  );
}

void main() {
  group('resolution and playback', () {
    test('play uses the resolved file with the path as media id', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      backend.trackIds['/music/t.flac'] = 't';
      final source = _source(
        backend,
        paths: const <String, String>{'t': '/music/t.flac'},
      );
      addTearDown(source.dispose);
      await source.initialize();

      await source.play(_track('t'));
      expect(backend.played, hasLength(1));
      final media = backend.played.single;
      expect(media.id, '/music/t.flac');
      expect(media.source, '/music/t.flac');
      expect(media.playbackMode, 'local');
      expect(media.title, 'Title t');
      expect(media.duration, const Duration(seconds: 200));
      expect(source.currentTrackId, 't');
    });

    test('play throws a typed error when no download exists', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = _source(backend);
      addTearDown(source.dispose);
      await source.initialize();

      await expectLater(
        source.play(_track('missing')),
        throwsA(
          isA<PlaybackSourceException>().having(
            (error) => error.kind,
            'kind',
            'unavailable',
          ),
        ),
      );
      expect(backend.played, isEmpty);
      expect(source.currentTrackId, isEmpty);
    });

    test('blank resolved paths count as missing', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = _source(
        backend,
        paths: const <String, String>{'t': '   '},
      );
      addTearDown(source.dispose);
      await source.initialize();

      await expectLater(
        source.play(_track('t')),
        throwsA(isA<PlaybackSourceException>()),
      );
      expect(backend.played, isEmpty);
    });

    test('media ids are the file paths themselves', () {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = _source(backend);

      final first = source.mediaFor(_track('t'), '/music/t.flac');
      final second = source.mediaFor(_track('t'), '/music/t.flac');
      expect(first.id, second.id);
      expect(first.id, '/music/t.flac');
      expect(LocalPlaybackSource.mediaIdForPath('/music/t.flac'),
          '/music/t.flac');
    });
  });

  group('transport delegation', () {
    test('pause, resume, stop, and seek reach the backend', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = _source(
        backend,
        paths: const <String, String>{'t': '/music/t.flac'},
      );
      addTearDown(source.dispose);
      await source.initialize();
      await source.play(_track('t'));

      await source.pause();
      await source.resume();
      await source.seek(const Duration(seconds: 42));
      expect(backend.pauses, 1);
      expect(backend.resumes, 1);
      expect(backend.seeks, <Duration>[const Duration(seconds: 42)]);

      await source.stop();
      expect(backend.stops, 1);
      expect(source.currentTrackId, isEmpty);
    });

    test('state, position, and duration project the backend', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = _source(backend);
      addTearDown(source.dispose);
      await source.initialize();

      expect(source.state, same(backend.state));
      backend.position = const Duration(seconds: 7);
      expect(source.currentPosition, const Duration(seconds: 7));
      expect(source.duration, const Duration(seconds: 200));
    });

    test('preload verifies resolvability without playing', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = _source(
        backend,
        paths: const <String, String>{'t': '/music/t.flac'},
      );
      addTearDown(source.dispose);
      await source.initialize();

      await source.preload(_track('t'));
      await expectLater(
        source.preload(_track('missing')),
        throwsA(isA<PlaybackSourceException>()),
      );
      expect(backend.played, isEmpty);
    });

    test('initialize and dispose are idempotent', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = _source(backend);

      await source.initialize();
      await source.initialize();
      expect(backend.ready, isTrue);
      await source.dispose();
      await source.dispose();
    });
  });

  group('default resolvers', () {
    test('default resolvers degrade to null when stores are unavailable',
        () async {
      // No native plugins in unit tests, so both SQLite stores fail; the
      // resolvers must report "no local file", never throw.
      expect(await defaultLocalTrackPathResolver(_track('t')), isNull);
      expect(
        await defaultLocalTrackPathBatchResolver(
          <Track>[_track('a'), _track('b')],
        ),
        <String?>[null, null],
      );
    });
  });
}
