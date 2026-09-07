import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/carplay_service.dart';
import 'package:spotiflac_android/services/media_browse_tree.dart';
import 'package:spotiflac_android/services/music_player_service.dart';

PlayableMedia _media(String id, {String title = 'Song', String artist = 'A'}) =>
    PlayableMedia(
      id: id,
      source: '/music/$id.flac',
      title: title,
      artist: artist,
    );

/// Minimal browse source; only what the CarPlay tests exercise is populated.
class _Source implements MediaBrowseSource {
  _Source({
    this.counts = const MediaBrowseCounts(),
    this.queue = const [],
    this.playlistList = const [],
    this.throwOnChildren = false,
  });

  MediaBrowseCounts counts;
  List<PlayableMedia> queue;
  List<MediaBrowsePlaylist> playlistList;
  bool throwOnChildren;

  @override
  Future<MediaBrowseCounts> sectionCounts() async {
    if (throwOnChildren) throw StateError('database unavailable');
    return counts;
  }

  @override
  Future<List<PlayableMedia>> queueMedia() async => queue;
  @override
  Future<List<PlayableMedia>> recentMedia({required int limit}) async =>
      const [];
  @override
  Future<List<PlayableMedia>> mostPlayedMedia({required int limit}) async =>
      const [];
  @override
  Future<List<PlayableMedia>> lovedMedia() async => const [];
  @override
  Future<List<MediaBrowsePlaylist>> playlists() async => playlistList;
  @override
  Future<List<PlayableMedia>> playlistMedia(String playlistId) async =>
      const [];
  @override
  Future<List<MediaBrowseAlbum>> albums({
    required int limit,
    required int offset,
  }) async => const [];
  @override
  Future<List<PlayableMedia>> albumMedia({
    required String sourceTag,
    required String key,
  }) async => const [];
  @override
  Future<List<PlayableMedia>> libraryMedia({
    required int limit,
    required int offset,
  }) async => const [];
  @override
  Future<List<PlayableMedia>> searchMedia(
    String query, {
    required int limit,
  }) async => const [];
}

void main() {
  group('CarPlayService.browse', () {
    test('flattens root folders into browsable rows', () async {
      final service = CarPlayService(
        tree: MediaBrowseTree(
          _Source(counts: const MediaBrowseCounts(queue: 2, library: 10)),
        ),
        onPlay: (_, _) async {},
      );

      final rows = await service.browse(AudioService.browsableRootId);

      expect(rows, isNotEmpty);
      // Folders must be browsable so CarPlay draws a disclosure chevron.
      expect(rows.every((row) => row['isBrowsable'] == true), isTrue);
      expect(rows.first['id'], MediaBrowseTree.queueId);
      expect(rows.first['title'], 'Now playing');
    });

    test('marks tracks as playable, not browsable', () async {
      final service = CarPlayService(
        tree: MediaBrowseTree(
          _Source(
            counts: const MediaBrowseCounts(queue: 2),
            queue: [_media('t1', title: 'One'), _media('t2', title: 'Two')],
          ),
        ),
        onPlay: (_, _) async {},
      );

      final rows = await service.browse(MediaBrowseTree.queueId);

      expect(rows, hasLength(2));
      expect(rows.every((row) => row['isBrowsable'] == false), isTrue);
      expect(rows.first['title'], 'One');
    });

    test('uses the artist as the secondary line', () async {
      final service = CarPlayService(
        tree: MediaBrowseTree(
          _Source(
            counts: const MediaBrowseCounts(queue: 1),
            queue: [_media('t1', title: 'Nightcall', artist: 'Kavinsky')],
          ),
        ),
        onPlay: (_, _) async {},
      );

      final rows = await service.browse(MediaBrowseTree.queueId);
      expect(rows.single['subtitle'], 'Kavinsky');
    });

    test('caps the row count so a driver never gets an endless list', () async {
      final many = List.generate(
        CarPlayService.maxRows * 3,
        (i) => _media('t$i'),
      );
      final service = CarPlayService(
        tree: MediaBrowseTree(
          _Source(
            counts: MediaBrowseCounts(queue: many.length),
            queue: many,
          ),
        ),
        onPlay: (_, _) async {},
      );

      final rows = await service.browse(MediaBrowseTree.queueId);
      expect(rows.length, lessThanOrEqualTo(CarPlayService.maxRows));
    });

    test('unknown containers return an empty list, never throw', () async {
      final service = CarPlayService(
        tree: MediaBrowseTree(_Source()),
        onPlay: (_, _) async {},
      );
      expect(await service.browse('browse:does-not-exist'), isEmpty);
    });

    test('a failing source degrades to an empty list', () async {
      // A thrown exception would leave the head unit on a permanent
      // "Loading…" spinner, which is worse than an empty list.
      final service = CarPlayService(
        tree: MediaBrowseTree(_Source(throwOnChildren: true)),
        onPlay: (_, _) async {},
      );
      expect(await service.browse(AudioService.browsableRootId), isEmpty);
    });

    test('every row carries a non-empty id', () async {
      final service = CarPlayService(
        tree: MediaBrowseTree(
          _Source(
            counts: const MediaBrowseCounts(playlists: 1),
            playlistList: const [
              MediaBrowsePlaylist(id: 'p1', name: 'Roadtrip', trackCount: 3),
            ],
          ),
        ),
        onPlay: (_, _) async {},
      );

      final rows = await service.browse(MediaBrowseTree.playlistsId);
      expect(rows, isNotEmpty);
      for (final row in rows) {
        expect((row['id'] as String?) ?? '', isNotEmpty);
        expect((row['title'] as String?) ?? '', isNotEmpty);
      }
    });
  });

  group('CarPlayService platform guards', () {
    test('isConnected is false off iOS', () async {
      final service = CarPlayService(
        tree: MediaBrowseTree(_Source()),
        onPlay: (_, _) async {},
      );
      // The test host is not iOS, so this must short-circuit rather than
      // throw MissingPluginException.
      expect(await service.isConnected(), isFalse);
    });

    test('invalidate is a no-op off iOS', () async {
      final service = CarPlayService(
        tree: MediaBrowseTree(_Source()),
        onPlay: (_, _) async {},
      );
      await service.invalidate();
    });

    test('register and dispose are safe off iOS', () {
      final service = CarPlayService(
        tree: MediaBrowseTree(_Source()),
        onPlay: (_, _) async {},
      );
      service.register();
      service.dispose();
      service.dispose();
    });
  });
}
