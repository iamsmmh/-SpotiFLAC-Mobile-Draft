// Session compatibility: unified-playback queue items must persist and
// restore through the existing session store untouched, and the layer must
// ship no database migration (upgrade without reset).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/streaming/stream_provider.dart'
    show StreamSource;
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia;
import 'package:spotiflac_android/services/playback/playback.dart';

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
  final root = Directory.systemTemp.createTempSync('upm-session');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  return root;
}

Directory _packageRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) return Directory.current;
    dir = parent;
  }
}

void main() {
  group('queue item persistence', () {
    test('local items round-trip through JSON', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final source = LocalPlaybackSource(
        backend: backend,
        resolvePath: (_) async => '/music/t.flac',
      );
      final media = source.mediaFor(_track('t'), '/music/t.flac');

      final restored = PlayableMedia.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(media.toJson()))),
      );
      expect(restored, isNotNull);
      expect(restored!.id, media.id);
      expect(restored.source, media.source);
      expect(restored.title, 'Title t');
      expect(restored.artist, 'Artist');
      expect(restored.playbackMode, 'local');
      expect(restored.duration, const Duration(seconds: 200));
    });

    test('cache items round-trip through JSON', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final cache = PlaybackCacheManager.atRoot(_tempRoot());
      final hit = await cache.storeBytes(
        track: _track('t'),
        bytes: const <int>[1, 2, 3],
        format: 'FLAC',
      );
      final source = CachePlaybackSource(backend: backend, cache: cache);
      final media = source.mediaFor(_track('t'), hit);

      final restored = PlayableMedia.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(media.toJson()))),
      );
      expect(restored, isNotNull);
      expect(restored!.id, hit.entry.key);
      expect(restored.source, hit.filePath);
      expect(restored.sourceLabel, 'Stream cache');
      expect(restored.qualityLabel, 'FLAC');
    });

    test('stream items round-trip with expiry and provider', () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final expiry = DateTime.fromMillisecondsSinceEpoch(
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      );
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
            providerId: 'cdn',
            expiresAt: expiry,
          ),
          resolvedAt: DateTime.now(),
        ),
      );

      final restored = PlayableMedia.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(media.toJson()))),
      );
      expect(restored, isNotNull);
      expect(restored!.id, 't');
      expect(restored.source, 'https://cdn.example/t.mp3');
      expect(restored.playbackMode, 'stream');
      expect(restored.providerId, 'cdn');
      expect(restored.expiresAt, expiry);
    });

    test('deferred items round-trip and stay deferred', () async {
      final media = deferredMediaForTrack(_track('t'));
      expect(media.isDeferredStream, isTrue);

      final restored = PlayableMedia.fromJson(
        Map<String, dynamic>.from(jsonDecode(jsonEncode(media.toJson()))),
      );
      expect(restored, isNotNull);
      expect(restored!.id, 't');
      expect(restored.isDeferredStream, isTrue);
    });
  });

  group('forward and backward compatibility', () {
    test('minimal legacy entries still parse with defaults', () {
      final restored = PlayableMedia.fromJson(<String, dynamic>{
        'id': 'legacy',
        'source': '/music/legacy.mp3',
        'title': 'Legacy',
        'artist': 'Old',
      });
      expect(restored, isNotNull);
      expect(restored!.id, 'legacy');
      expect(restored.playbackMode, isNull);
      expect(restored.qualityLabel, isNull);
      expect(restored.duration, isNull);
      expect(restored.expiresAt, isNull);
    });

    test('unknown future keys are ignored', () {
      final restored = PlayableMedia.fromJson(<String, dynamic>{
        'id': 't',
        'source': '/music/t.mp3',
        'title': 'Title',
        'artist': 'Artist',
        'futureField': <String, dynamic>{'nested': true},
        'anotherOne': 42,
      });
      expect(restored, isNotNull);
      expect(restored!.id, 't');
    });

    test('entries without id or source are rejected', () {
      expect(
        PlayableMedia.fromJson(<String, dynamic>{'title': 'No ids'}),
        isNull,
      );
      expect(
        PlayableMedia.fromJson(<String, dynamic>{
          'id': 't',
          'source': '   ',
        }),
        isNull,
      );
    });
  });

  group('session envelope', () {
    test('mixed queue survives an encode/decode envelope round-trip',
        () async {
      final backend = _FakeBackend();
      addTearDown(backend.dispose);
      final root = _tempRoot();
      final localFile = File('${root.path}/kept.flac')
        ..writeAsBytesSync(const <int>[1, 2, 3]);
      final local = LocalPlaybackSource(
        backend: backend,
        resolvePath: (_) async => localFile.path,
      ).mediaFor(_track('local'), localFile.path);
      final deferred = deferredMediaForTrack(_track('stream'));

      // Same envelope the handler persists (version/index/position/shuffle).
      final envelope = <String, dynamic>{
        'version': 1,
        'media': <Map<String, dynamic>>[local.toJson(), deferred.toJson()],
        'index': 1,
        'positionMs': 87000,
        'shuffle': false,
        'repeat': 'off',
      };
      final decoded = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(envelope)),
      );

      expect(decoded['version'], 1);
      final items = <PlayableMedia>[];
      for (final entry in (decoded['media'] as List)) {
        final media = PlayableMedia.fromJson(
          Map<String, dynamic>.from(entry as Map),
        );
        if (media == null) continue;
        // Restore rule: deferred items are always kept; plain paths must
        // still exist (a persisted URL/path would be stale anyway).
        if (!media.isContentUri &&
            !media.isDeferredStream &&
            !await File(media.source).exists()) {
          continue;
        }
        items.add(media);
      }
      expect(items.map((item) => item.id), <String>[
        localFile.path,
        'stream',
      ]);
      expect(decoded['index'], 1);
      expect(decoded['positionMs'], 87000);
    });

    test('missing files drop out while deferred items survive', () async {
      final local = PlayableMedia(
        id: '/music/deleted.flac',
        source: '/music/deleted.flac',
        title: 'Deleted',
        artist: 'Artist',
        playbackMode: 'local',
      );
      final deferred = deferredMediaForTrack(_track('stream'));
      final decoded = <String, dynamic>{
        'version': 1,
        'media': <Map<String, dynamic>>[
          local.toJson(),
          deferred.toJson(),
        ],
        'index': 0,
        'positionMs': 12000,
      };

      final items = <PlayableMedia>[];
      final keptIndices = <int>[];
      final raw = decoded['media'] as List;
      for (var i = 0; i < raw.length; i++) {
        final media = PlayableMedia.fromJson(
          Map<String, dynamic>.from(raw[i] as Map),
        );
        if (media == null) continue;
        if (!media.isContentUri &&
            !media.isDeferredStream &&
            !await File(media.source).exists()) {
          continue;
        }
        items.add(media);
        keptIndices.add(i);
      }
      expect(items.map((item) => item.id), <String>['stream']);
      expect(keptIndices, <int>[1]);
    });
  });

  group('no database migration', () {
    test('playback layer ships no schema code', () {
      final dir = Directory('${_packageRoot().path}/lib/services/playback');
      expect(dir.existsSync(), isTrue);
      const banned = <String>[
        'sqflite',
        'CREATE TABLE',
        'ALTER TABLE',
        'onUpgrade',
        'getDatabasesPath',
        'openDatabase',
      ];
      final hits = <String>[];
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final content = entity.readAsStringSync();
        for (final marker in banned) {
          if (content.contains(marker)) {
            hits.add('${entity.uri.pathSegments.last}: $marker');
          }
        }
      }
      expect(hits, isEmpty,
          reason: 'unified playback must reuse existing stores, never migrate');
    });
  });
}
