import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/now_playing_lyrics_provider.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';

void main() {
  MediaItem item({
    required String id,
    required String source,
    String? resolvedSource,
    String title = 'Song',
    String artist = 'Artist',
  }) => MediaItem(
    id: id,
    title: title,
    artist: artist,
    duration: const Duration(minutes: 3),
    extras: {'source': source, 'resolvedSource': ?resolvedSource},
  );

  group('isStreamedMediaItem', () {
    test('recognises http(s) sources and deferred engine items', () {
      expect(
        isStreamedMediaItem(item(id: 'a', source: 'https://cdn/x.m4a')),
        isTrue,
      );
      expect(
        isStreamedMediaItem(
          item(id: 'b', source: PlayableMedia.deferredStreamUriFor('b')),
        ),
        isTrue,
      );
      expect(
        isStreamedMediaItem(item(id: 'c', source: '/music/c.flac')),
        isFalse,
      );
      expect(
        isStreamedMediaItem(item(id: 'd', source: 'content://saf/d.flac')),
        isFalse,
      );
    });

    test('a deferred item resolved to a local file is treated as local', () {
      final media = item(
        id: 'e',
        source: PlayableMedia.deferredStreamUriFor('e'),
        resolvedSource: '/music/e.flac',
      );
      expect(isStreamedMediaItem(media), isFalse);
      expect(sourcePathForLyrics(media), '/music/e.flac');
    });
  });

  group('loadStreamedLyrics', () {
    test('parses provider LRC and memoizes per track across URL swaps',
        () async {
      var calls = 0;
      Future<String> fetch({
        required String trackId,
        required String title,
        required String artist,
        required int durationMs,
      }) async {
        calls++;
        expect(trackId, 't1');
        expect(durationMs, 180000);
        return '[00:01.00]First line\n[00:02.50]Second line';
      }

      final cache = OnlineLyricsCache();
      final first = await loadStreamedLyrics(
        item(id: 't1', source: 'https://a.example/1'),
        offline: false,
        cache: cache,
        fetch: fetch,
      );
      expect(first.synced, isTrue);
      expect(first.lines.map((l) => l.text), ['First line', 'Second line']);

      // Failover swaps the URL but keeps the track: no second lookup.
      final second = await loadStreamedLyrics(
        item(id: 't1', source: 'https://b.example/2'),
        offline: false,
        cache: cache,
        fetch: fetch,
      );
      expect(identical(first, second), isTrue);
      expect(calls, 1);
    });

    test('coalesces concurrent lookups of the same track', () async {
      var calls = 0;
      final gate = Completer<void>();
      Future<String> fetch({
        required String trackId,
        required String title,
        required String artist,
        required int durationMs,
      }) async {
        calls++;
        await gate.future;
        return 'Plain lyrics';
      }

      final cache = OnlineLyricsCache();
      final media = item(id: 't2', source: 'https://a.example/2');
      final a = loadStreamedLyrics(
        media,
        offline: false,
        cache: cache,
        fetch: fetch,
      );
      final b = loadStreamedLyrics(
        media,
        offline: false,
        cache: cache,
        fetch: fetch,
      );
      gate.complete();
      final results = await Future.wait([a, b]);
      expect(calls, 1);
      expect(results[0].plainText, 'Plain lyrics');
      expect(results[1].plainText, 'Plain lyrics');
    });

    test('offline mode never calls the provider', () async {
      var calls = 0;
      Future<String> fetch({
        required String trackId,
        required String title,
        required String artist,
        required int durationMs,
      }) async {
        calls++;
        return '[00:01.00]x';
      }

      final result = await loadStreamedLyrics(
        item(id: 't3', source: 'https://a.example/3'),
        offline: true,
        cache: OnlineLyricsCache(),
        fetch: fetch,
      );
      expect(result.isEmpty, isTrue);
      expect(calls, 0);
    });

    test('provider errors, timeouts and instrumental markers yield empty',
        () async {
      Future<String> throwing({
        required String trackId,
        required String title,
        required String artist,
        required int durationMs,
      }) async => throw StateError('boom');
      Future<String> instrumental({
        required String trackId,
        required String title,
        required String artist,
        required int durationMs,
      }) async => '[instrumental:true]';

      final failed = await fetchOnlineLyrics(
        item(id: 't4', source: 'https://a.example/4'),
        throwing,
      );
      expect(failed, same(ParsedLyrics.empty));
      final instr = await fetchOnlineLyrics(
        item(id: 't5', source: 'https://a.example/5'),
        instrumental,
      );
      expect(instr.isEmpty, isTrue);
    });

    test('negative results are cached and the cache is bounded', () async {
      var calls = 0;
      Future<String> fetch({
        required String trackId,
        required String title,
        required String artist,
        required int durationMs,
      }) async {
        calls++;
        return '';
      }

      final cache = OnlineLyricsCache(maxEntries: 2);
      for (final id in ['a', 'a', 'b', 'c']) {
        await loadStreamedLyrics(
          item(id: id, source: 'https://a.example/$id'),
          offline: false,
          cache: cache,
          fetch: fetch,
        );
      }
      expect(calls, 3);
      expect(cache.length, 2);
      // 'a' was evicted (LRU), so it is fetched again.
      await loadStreamedLyrics(
        item(id: 'a', source: 'https://a.example/a'),
        offline: false,
        cache: cache,
        fetch: fetch,
      );
      expect(calls, 4);
    });
  });
}
