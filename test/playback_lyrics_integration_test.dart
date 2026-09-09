// Unified lyrics: local, cached, deferred, and streamed queue items all
// route through the one lyrics pipeline with stable per-track caching.
import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/streaming/stream_provider.dart'
    show StreamSource;
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/now_playing_lyrics_provider.dart'
    show
        OnlineLyricsCache,
        fetchOnlineLyrics,
        isStreamedMediaItem,
        loadStreamedLyrics,
        lyricsCacheKeyFor,
        sourcePathForLyrics;
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia;
import 'package:spotiflac_android/services/playback/playback.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart'
    show LyricsParser, ParsedLyrics;

class _FakeBackend implements PlaybackBackend {
  final StreamController<PlaybackSourceState> states =
      StreamController<PlaybackSourceState>.broadcast();
  final StreamController<PlaybackProgress> ticks =
      StreamController<PlaybackProgress>.broadcast();

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
  final root = Directory.systemTemp.createTempSync('upm-lyrics');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

const _lrc = '[00:01.00] first line\n[00:05.50] second line\n';

void main() {
  group('lyrics routing per origin', () {
    test('local items resolve to their file path (embedded lyrics)', () {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final media = LocalPlaybackSource(
        backend: backend,
        resolvePath: (_) async => '/music/t.flac',
      ).mediaFor(_track('t'), '/music/t.flac');

      final item = media.toMediaItem();
      expect(isStreamedMediaItem(item), isFalse);
      expect(sourcePathForLyrics(item), '/music/t.flac');
    });

    test('cache items resolve to the cached file', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      final hit = await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1],
        format: 'MP3',
      );
      final media =
          CachePlaybackSource(backend: backend, cache: cache).mediaFor(
        _track('t'),
        hit,
      );

      final item = media.toMediaItem();
      expect(isStreamedMediaItem(item), isFalse);
      expect(sourcePathForLyrics(item), hit.filePath);
    });

    test('deferred items count as streamed before resolution', () {
      final item = deferredMediaForTrack(_track('t')).toMediaItem();
      expect(isStreamedMediaItem(item), isTrue);
      expect(
        sourcePathForLyrics(item),
        startsWith('deferred-stream://'),
      );
    });

    test('resolved streams prefer the concrete URL', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = StreamingPlaybackSource(
        backend: backend,
        urlResolver: StreamUrlResolver(
          fetchCandidates: (_) async => const <StreamSource>[],
          validateSource: (_) async => true,
        ),
      );
      final media = source.mediaFor(
        _track('t'),
        ResolvedStreamUrl(
          trackId: 't',
          source: StreamSource(
            url: 'https://cdn.example/t.mp3',
            format: 'MP3',
            bitrate: 320,
          ),
          resolvedAt: DateTime.now(),
        ),
      );

      final item = media.toMediaItem();
      expect(isStreamedMediaItem(item), isTrue);
      expect(sourcePathForLyrics(item), 'https://cdn.example/t.mp3');
    });
  });

  group('streamed lyrics loading', () {
    test('cache key is stable across stream URL swaps', () {
      MediaItem itemFor(String source) => MediaItem(
        id: 't',
        title: 'Title t',
        artist: 'Artist',
        extras: <String, dynamic>{'source': source},
      );

      final before = itemFor('https://cdn.example/v1.mp3');
      final after = itemFor('https://cdn.example/v2.mp3');
      expect(lyricsCacheKeyFor(before), lyricsCacheKeyFor(after));
    });

    test('session cache memoizes one lookup per track', () async {
      final cache = OnlineLyricsCache();
      var fetches = 0;
      final item = deferredMediaForTrack(_track('t')).toMediaItem();

      Future<ParsedLyrics> load() => loadStreamedLyrics(
        item,
        offline: false,
        cache: cache,
        fetch: ({
          required String trackId,
          required String title,
          required String artist,
          required int durationMs,
        }) async {
          fetches++;
          return _lrc;
        },
      );

      final first = await load();
      final second = await load();
      expect(fetches, 1);
      expect(first.synced, isTrue);
      expect(first.lines, hasLength(2));
      expect(second.plainText, first.plainText);
    });

    test('offline mode short-circuits without fetching', () async {
      final cache = OnlineLyricsCache();
      var fetches = 0;
      final item = deferredMediaForTrack(_track('t')).toMediaItem();

      final result = await loadStreamedLyrics(
        item,
        offline: true,
        cache: cache,
        fetch: ({
          required String trackId,
          required String title,
          required String artist,
          required int durationMs,
        }) async {
          fetches++;
          return _lrc;
        },
      );
      expect(result, ParsedLyrics.empty);
      expect(fetches, 0);
    });

    test('every dead end yields empty lyrics, never throws', () async {
      const item = MediaItem(id: 't', title: 'Title t', artist: 'Artist');

      Future<ParsedLyrics> loadWith(String Function() body) =>
          fetchOnlineLyrics(
            item,
            ({
              required String trackId,
              required String title,
              required String artist,
              required int durationMs,
            }) async => body(),
          );

      expect((await loadWith(() => '')).isEmpty, isTrue);
      expect((await loadWith(() => '   ')).isEmpty, isTrue);
      expect(
        (await loadWith(() => '[Instrumental]')).isEmpty,
        isTrue,
      );
      expect(
        (await loadWith(() => throw StateError('providers down'))).isEmpty,
        isTrue,
      );
      const untitled = MediaItem(id: 't', title: '  ');
      expect(
        (await fetchOnlineLyrics(
          untitled,
          ({
            required String trackId,
            required String title,
            required String artist,
            required int durationMs,
          }) async => _lrc,
        )).isEmpty,
        isTrue,
      );
    });
  });

  group('unified output', () {
    test('embedded and online paths parse through the same parser', () async {
      // The local branch parses bridge metadata with LyricsParser; the
      // streamed branch parses provider payloads with the same parser.
      final embedded = LyricsParser.parse(_lrc);
      const item = MediaItem(id: 't', title: 'Title t', artist: 'Artist');
      final online = await fetchOnlineLyrics(
        item,
        ({
          required String trackId,
          required String title,
          required String artist,
          required int durationMs,
        }) async => _lrc,
      );
      expect(online.synced, embedded.synced);
      expect(online.lines.length, embedded.lines.length);
      expect(online.plainText, embedded.plainText);
    });

    test('plain-text lyrics stay unsynced but present', () async {
      const item = MediaItem(id: 't', title: 'Title t', artist: 'Artist');
      final result = await fetchOnlineLyrics(
        item,
        ({
          required String trackId,
          required String title,
          required String artist,
          required int durationMs,
        }) async => 'just words, no tags',
      );
      expect(result.isEmpty, isFalse);
      expect(result.synced, isFalse);
      expect(result.plainText, contains('just words'));
    });
  });
}
