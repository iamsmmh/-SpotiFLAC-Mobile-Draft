// Smart playback cache: keys, atomic stores, verified lookups, LRU
// eviction with pins, maintenance, and cache playback on the shared player.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/cache/playback_source_ladder.dart'
    show PlaybackSourceKind;
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia;
import 'package:spotiflac_android/services/playback/playback.dart';

class _FakeBackend implements PlaybackBackend {
  final StreamController<PlaybackSourceState> states =
      StreamController<PlaybackSourceState>.broadcast();
  final StreamController<PlaybackProgress> ticks =
      StreamController<PlaybackProgress>.broadcast();

  bool ready = false;
  bool disposed = false;
  final List<PlayableMedia> played = <PlayableMedia>[];

  @override
  Future<void> ensureReady() async {
    ready = true;
  }

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
  }) async {
    played.add(media);
  }

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

Track _track(
  String id, {
  String artist = 'Artist',
  int duration = 200,
}) => Track(
  id: id,
  name: 'Title $id',
  artistName: artist,
  albumName: 'Album',
  duration: duration,
);

Directory _tempRoot() {
  final root = Directory.systemTemp.createTempSync('upm-cache');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

Future<void> _flush() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  group('cache keys', () {
    test('keys are stable and filesystem-safe', () {
      final first = playbackCacheKeyForTrack(_track('t'));
      final second = playbackCacheKeyForTrack(_track('t'));
      expect(first, isNotEmpty);
      expect(first, second);
      expect(first.contains('/'), isFalse);
      expect(first.contains(' '), isFalse);
    });

    test('distinct tracks map to distinct keys', () {
      final a = playbackCacheKeyForTrack(_track('a'));
      final b = playbackCacheKeyForTrack(_track('b', artist: 'Other'));
      expect(a, isNot(equals(b)));
    });

    test('degenerate tracks still get a key', () {
      const empty = Track(
        id: '',
        name: '',
        artistName: '',
        albumName: '',
        duration: 0,
      );
      expect(playbackCacheKeyForTrack(empty), isNotEmpty);
    });
  });

  group('store and lookup', () {
    test('stored bytes round-trip with a verified hit', () async {
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      final bytes = <int>[0x66, 0x4C, 0x61, 0x43, 1, 2, 3]; // 'fLaC' magic
      final stored = await cache.storeBytes(
        track: _track('t'),
        bytes: bytes,
      );

      expect(stored.filePath, endsWith('.flac'));
      expect(stored.entry.bytes, bytes.length);
      expect(stored.entry.trackId, 't');
      expect(stored.entry.playCount, 0);
      expect(stored.entry.pinned, isFalse);

      final hit = await cache.lookup(_track('t'));
      expect(hit, isNotNull);
      expect(hit!.filePath, stored.filePath);
      expect(await File(hit.filePath).readAsBytes(), bytes);
    });

    test('format hint wins over sniffing', () async {
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      final hit = await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1, 2, 3],
        format: 'mp3',
      );
      expect(hit.filePath, endsWith('.mp3'));
      expect(hit.entry.format, 'MP3');
    });

    test('lookup misses on unknown tracks', () async {
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      expect(await cache.lookup(_track('nope')), isNull);
    });

    test('lookup touches recency without bumping plays', () async {
      var now = DateTime(2026, 1, 1, 12);
      final cache = PlaybackCacheManager.atRoot(
        _tempRoot(),
        clock: () => now,
      );
      await cache.storeBytes(track: _track('t'), bytes: const <int>[1]);
      now = now.add(const Duration(hours: 1));

      final hit = await cache.lookup(_track('t'));
      expect(hit?.entry.lastAccessAt, now);
      expect(hit?.entry.playCount, 0);

      await cache.registerPlay(_track('t'));
      final after = await cache.lookup(_track('t'));
      expect(after?.entry.playCount, 1);
    });

    test('writes are atomic: no tmp leftovers, no partial entries', () async {
      final root = _tempRoot();
      final cache = PlaybackCacheManager.atRoot(root);
      await cache.storeBytes(track: _track('t'), bytes: const <int>[1, 2]);

      final tmp = Directory('${root.path}/tmp');
      expect(await tmp.list().toList(), isEmpty);
      final metadata = Directory('${root.path}/metadata');
      expect(await metadata.list().length, 1);
    });

    test('re-store keeps play count, pins, and artwork', () async {
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1],
        artworkBytes: const <int>[0xFF, 0xD8, 0xFF, 0x00],
      );
      await cache.registerPlay(_track('t'));
      await cache.setPinned(_track('t'), pinned: true);

      final second = await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1, 2, 3],
      );
      expect(second.entry.playCount, 1);
      expect(second.entry.pinned, isTrue);
      expect(second.artworkPath, isNotNull);
      expect(second.artworkPath, endsWith('.jpg'));

      await cache.setPinned(_track('t'), pinned: false);
      expect((await cache.lookup(_track('t')))?.entry.pinned, isFalse);
    });

    test('concurrent stores for distinct tracks all land', () async {
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      final hits = await Future.wait(<Future<PlaybackCacheHit>>[
        cache.storeBytes(track: _track('a'), bytes: const <int>[1]),
        cache.storeBytes(track: _track('b'), bytes: const <int>[2]),
        cache.storeBytes(track: _track('c'), bytes: const <int>[3]),
      ]);
      expect(hits, hasLength(3));
      expect(await cache.lookup(_track('a')), isNotNull);
      expect(await cache.lookup(_track('b')), isNotNull);
      expect(await cache.lookup(_track('c')), isNotNull);
      expect(await cache.sizeBytes(), 3);
    });
  });

  group('fetchAndStore', () {
    test('fetched bytes are stored and returned as a hit', () async {
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      final hit = await cache.fetchAndStore(
        track: _track('t'),
        url: 'https://cdn.example/t.mp3',
        download: (_) async => const <int>[9, 9, 9],
        format: 'MP3',
      );
      expect(hit, isNotNull);
      expect(hit!.filePath, endsWith('.mp3'));
      expect(await cache.lookup(_track('t')), isNotNull);
    });

    test('failed fetches store nothing', () async {
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      expect(
        await cache.fetchAndStore(
          track: _track('t'),
          url: 'https://cdn.example/t.mp3',
          download: (_) => throw StateError('network down'),
        ),
        isNull,
      );
      expect(
        await cache.fetchAndStore(
          track: _track('t'),
          url: 'https://cdn.example/t.mp3',
          download: (_) async => const <int>[],
        ),
        isNull,
      );
      expect(await cache.lookup(_track('t')), isNull);
      expect(await cache.sizeBytes(), 0);
    });

    test('unusable URLs are rejected without fetching', () async {
      var downloads = 0;
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      expect(
        await cache.fetchAndStore(
          track: _track('t'),
          url: 'not a url',
          download: (_) async {
            downloads++;
            return const <int>[1];
          },
        ),
        isNull,
      );
      expect(downloads, 0);
    });
  });

  group('stale records', () {
    test('metadata without audio self-evicts on lookup', () async {
      final root = _tempRoot();
      final cache = PlaybackCacheManager.atRoot(root);
      await cache.storeBytes(track: _track('t'), bytes: const <int>[1]);
      await for (final entity in Directory('${root.path}/tracks').list()) {
        await entity.delete();
      }

      expect(await cache.lookup(_track('t')), isNull);
      expect(await Directory('${root.path}/metadata').list().length, 0);
    });

    test('corrupt metadata reads as a miss', () async {
      final root = _tempRoot();
      final cache = PlaybackCacheManager.atRoot(root);
      await cache.ensureLayout();
      final key = playbackCacheKeyForTrack(_track('t'));
      await File('${root.path}/metadata/$key.json')
          .writeAsString('not json{{{');

      expect(await cache.lookup(_track('t')), isNull);
    });
  });

  group('eviction', () {
    test('LRU evicts oldest-first when over budget', () async {
      var now = DateTime(2026, 1, 1, 12);
      final cache = PlaybackCacheManager.atRoot(
        _tempRoot(),
        maxSizeBytes: 100,
        clock: () => now,
      );
      await cache.storeBytes(
        track: _track('old'),
        bytes: List<int>.filled(60, 1),
      );
      now = now.add(const Duration(minutes: 1));
      await cache.storeBytes(
        track: _track('new'),
        bytes: List<int>.filled(60, 2),
      );

      expect(await cache.lookup(_track('old')), isNull);
      expect(await cache.lookup(_track('new')), isNotNull);
      expect(await cache.sizeBytes(), 60);
    });

    test('recently played entries survive over stale ones', () async {
      var now = DateTime(2026, 1, 1, 12);
      final cache = PlaybackCacheManager.atRoot(
        _tempRoot(),
        maxSizeBytes: 100,
        clock: () => now,
      );
      await cache.storeBytes(
        track: _track('a'),
        bytes: List<int>.filled(40, 1),
      );
      now = now.add(const Duration(minutes: 1));
      await cache.storeBytes(
        track: _track('b'),
        bytes: List<int>.filled(40, 2),
      );
      now = now.add(const Duration(minutes: 1));
      await cache.lookup(_track('a'));
      now = now.add(const Duration(minutes: 1));
      await cache.storeBytes(
        track: _track('c'),
        bytes: List<int>.filled(40, 3),
      );

      expect(await cache.lookup(_track('b')), isNull);
      expect(await cache.lookup(_track('a')), isNotNull);
      expect(await cache.lookup(_track('c')), isNotNull);
    });

    test('pins survive budget enforcement', () async {
      var now = DateTime(2026, 1, 1, 12);
      final cache = PlaybackCacheManager.atRoot(
        _tempRoot(),
        maxSizeBytes: 100,
        clock: () => now,
      );
      await cache.storeBytes(
        track: _track('pinned'),
        bytes: List<int>.filled(60, 1),
      );
      await cache.setPinned(_track('pinned'), pinned: true);
      now = now.add(const Duration(minutes: 1));
      await cache.storeBytes(
        track: _track('fresh'),
        bytes: List<int>.filled(60, 2),
      );

      expect(await cache.lookup(_track('pinned')), isNotNull);
      expect(await cache.lookup(_track('fresh')), isNull);
    });

    test('lowering the budget enforces asynchronously', () async {
      var now = DateTime(2026, 1, 1, 12);
      final cache = PlaybackCacheManager.atRoot(
        _tempRoot(),
        clock: () => now,
      );
      await cache.storeBytes(
        track: _track('a'),
        bytes: List<int>.filled(60, 1),
      );
      now = now.add(const Duration(minutes: 1));
      await cache.storeBytes(
        track: _track('b'),
        bytes: List<int>.filled(60, 2),
      );

      cache.maxSizeBytes = 100;
      await _flush();

      expect(await cache.lookup(_track('a')), isNull);
      expect(await cache.lookup(_track('b')), isNotNull);
    });

    test('evict removes audio, metadata, and artwork', () async {
      final root = _tempRoot();
      final cache = PlaybackCacheManager.atRoot(root);
      await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1],
        artworkBytes: const <int>[0xFF, 0xD8, 0xFF, 0x00],
      );
      await cache.evict(_track('t'));

      expect(await cache.lookup(_track('t')), isNull);
      for (final name in const <String>['tracks', 'metadata', 'artwork']) {
        expect(await Directory('${root.path}/$name').list().toList(), isEmpty);
      }
    });

    test('clear empties everything but keeps the layout', () async {
      final root = _tempRoot();
      final cache = PlaybackCacheManager.atRoot(root);
      await cache.storeBytes(track: _track('t'), bytes: const <int>[1]);
      await cache.clear();

      expect(await cache.sizeBytes(), 0);
      expect(await cache.lookup(_track('t')), isNull);
      for (final name in const <String>[
        'tracks',
        'artwork',
        'metadata',
        'tmp',
      ]) {
        expect(Directory('${root.path}/$name').existsSync(), isTrue);
      }
    });
  });

  group('maintenance', () {
    test('report accounts entries, bytes, and evictions', () async {
      var now = DateTime(2026, 1, 1, 12);
      final cache = PlaybackCacheManager.atRoot(
        _tempRoot(),
        maxSizeBytes: 100,
        clock: () => now,
      );
      await cache.storeBytes(
        track: _track('a'),
        bytes: List<int>.filled(60, 1),
      );
      now = now.add(const Duration(minutes: 1));
      await cache.storeBytes(
        track: _track('b'),
        bytes: List<int>.filled(60, 2),
      );

      final report = await cache.maintenance();
      expect(report.entryCount, 1);
      expect(report.totalBytes, 60);
      expect(report.evictedKeys, isEmpty);
      expect(report.freedBytes, 0);
      expect(report.prunedTmpFiles, 0);
    });

    test('maintenance drops records whose audio is gone', () async {
      final root = _tempRoot();
      final cache = PlaybackCacheManager.atRoot(root);
      await cache.storeBytes(track: _track('t'), bytes: const <int>[1]);
      await for (final entity in Directory('${root.path}/tracks').list()) {
        await entity.delete();
      }

      final report = await cache.maintenance();
      expect(report.entryCount, 0);
      expect(report.totalBytes, 0);
    });

    test('maintenance deletes orphaned audio files', () async {
      final root = _tempRoot();
      final cache = PlaybackCacheManager.atRoot(root);
      await cache.ensureLayout();
      await File('${root.path}/tracks/orphan.mp3')
          .writeAsBytes(const <int>[1, 2, 3]);

      await cache.maintenance();
      expect(File('${root.path}/tracks/orphan.mp3').existsSync(), isFalse);
    });

    test('maintenance prunes abandoned tmp writes', () async {
      final root = _tempRoot();
      final cache = PlaybackCacheManager.atRoot(root);
      await cache.ensureLayout();
      final abandoned = File('${root.path}/tmp/abandoned.part');
      await abandoned.writeAsBytes(const <int>[1]);
      await abandoned.setLastModified(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      await File('${root.path}/tmp/fresh.part')
          .writeAsBytes(const <int>[2]);

      final report = await cache.maintenance();
      expect(report.prunedTmpFiles, 1);
      expect(abandoned.existsSync(), isFalse);
      expect(File('${root.path}/tmp/fresh.part').existsSync(), isTrue);
    });
  });

  group('cache entries', () {
    test('tryParse round-trips valid records', () {
      final entry = PlaybackCacheEntry(
        key: 'k',
        trackId: 't',
        title: 'Title',
        artist: 'Artist',
        bytes: 12,
        format: 'FLAC',
        fileName: 'k.flac',
        createdAt: DateTime.utc(2026, 1, 1),
        lastAccessAt: DateTime.utc(2026, 1, 2),
        playCount: 3,
        pinned: true,
      );
      final parsed = PlaybackCacheEntry.tryParse(entry.toJson());
      expect(parsed, isNotNull);
      expect(parsed!.key, 'k');
      expect(parsed.playCount, 3);
      expect(parsed.pinned, isTrue);
      expect(parsed.fileName, 'k.flac');
    });

    test('tryParse rejects structural garbage and degrades dates', () {
      expect(PlaybackCacheEntry.tryParse(null), isNull);
      expect(PlaybackCacheEntry.tryParse('nope'), isNull);
      expect(PlaybackCacheEntry.tryParse(<String, Object?>{}), isNull);

      final parsed = PlaybackCacheEntry.tryParse(<String, Object?>{
        'key': 'k',
        'created_at': 'garbage',
      });
      expect(parsed, isNotNull);
      expect(
        parsed!.createdAt,
        DateTime.fromMillisecondsSinceEpoch(0),
      );
    });
  });

  group('cache playback source', () {
    test('play renders a verified hit as a cache file item', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      final stored = await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1, 2, 3],
        format: 'FLAC',
      );
      final source = CachePlaybackSource(backend: backend, cache: cache);
      addTearDown(source.dispose);
      await source.initialize();

      expect(source.kind, PlaybackSourceKind.streamCache);
      await source.play(_track('t'));

      expect(backend.played, hasLength(1));
      final media = backend.played.single;
      expect(media.id, stored.entry.key);
      expect(media.source, stored.filePath);
      expect(media.playbackMode, 'local');
      expect(media.sourceLabel, 'Stream cache');
      expect(media.qualityLabel, 'FLAC');
      expect((await cache.lookup(_track('t')))?.entry.playCount, 1);
    });

    test('play throws a typed error on a cache miss', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = CachePlaybackSource(
        backend: backend,
        cache: PlaybackCacheManager.atRoot(_tempRoot()),
      );
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
    });

    test('preload verifies the hit without playing', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      await cache.storeBytes(track: _track('t'), bytes: const <int>[1]);
      final source = CachePlaybackSource(backend: backend, cache: cache);
      addTearDown(source.dispose);
      await source.initialize();

      await source.preload(_track('t'));
      await expectLater(
        source.preload(_track('missing')),
        throwsA(isA<PlaybackSourceException>()),
      );
      expect(backend.played, isEmpty);
    });

    test('mediaIdForCacheKey is the key itself', () {
      expect(CachePlaybackSource.mediaIdForCacheKey('abc'), 'abc');
    });
  });
}
