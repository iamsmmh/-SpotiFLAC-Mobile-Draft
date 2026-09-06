import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/media_browse_tree.dart';
import 'package:spotiflac_android/services/music_player_service.dart';

PlayableMedia _media(String id, {String title = 'Song', String artist = 'A'}) =>
    PlayableMedia(id: id, source: '/music/$id.flac', title: title, artist: artist);

class _FakeSource implements MediaBrowseSource {
  _FakeSource({
    this.counts = const MediaBrowseCounts(),
    this.queue = const [],
    this.recent = const [],
    this.top = const [],
    this.loved = const [],
    this.playlistList = const [],
    this.playlistTracks = const {},
    this.albumList = const [],
    this.albumTracks = const {},
    this.library = const [],
  });

  MediaBrowseCounts counts;
  List<PlayableMedia> queue;
  List<PlayableMedia> recent;
  List<PlayableMedia> top;
  List<PlayableMedia> loved;
  List<MediaBrowsePlaylist> playlistList;
  Map<String, List<PlayableMedia>> playlistTracks;
  List<MediaBrowseAlbum> albumList;
  Map<String, List<PlayableMedia>> albumTracks;
  List<PlayableMedia> library;
  final List<String> searches = [];
  final List<(int, int)> libraryPages = [];

  @override
  Future<MediaBrowseCounts> sectionCounts() async => counts;
  @override
  Future<List<PlayableMedia>> queueMedia() async => queue;
  @override
  Future<List<PlayableMedia>> recentMedia({required int limit}) async =>
      recent.take(limit).toList();
  @override
  Future<List<PlayableMedia>> mostPlayedMedia({required int limit}) async =>
      top.take(limit).toList();
  @override
  Future<List<PlayableMedia>> lovedMedia() async => loved;
  @override
  Future<List<MediaBrowsePlaylist>> playlists() async => playlistList;
  @override
  Future<List<PlayableMedia>> playlistMedia(String playlistId) async =>
      playlistTracks[playlistId] ?? const [];
  @override
  Future<List<MediaBrowseAlbum>> albums({
    required int limit,
    required int offset,
  }) async => albumList.skip(offset).take(limit).toList();
  @override
  Future<List<PlayableMedia>> albumMedia({
    required String sourceTag,
    required String key,
  }) async => albumTracks['$sourceTag:$key'] ?? const [];
  @override
  Future<List<PlayableMedia>> libraryMedia({
    required int limit,
    required int offset,
  }) async {
    libraryPages.add((limit, offset));
    return library.skip(offset).take(limit).toList();
  }

  @override
  Future<List<PlayableMedia>> searchMedia(
    String query, {
    required int limit,
  }) async {
    searches.add(query);
    final q = query.toLowerCase();
    return library
        .where(
          (m) =>
              m.title.toLowerCase().contains(q) ||
              m.artist.toLowerCase().contains(q),
        )
        .take(limit)
        .toList();
  }
}

void main() {
  group('MediaBrowseTree root', () {
    test('shows only sections that have content', () async {
      final tree = MediaBrowseTree(
        _FakeSource(
          counts: const MediaBrowseCounts(queue: 3, albums: 2, library: 40),
        ),
      );
      final root = await tree.children(AudioService.browsableRootId);
      expect(root.map((e) => e.id), [
        MediaBrowseTree.queueId,
        MediaBrowseTree.albumsId,
        MediaBrowseTree.libraryId,
      ]);
      expect(root.every((e) => e.playable == false), isTrue);
      expect(root.first.artist, '3 songs');
      expect(root[1].artist, '2 albums');
      // Content-style hints are present for Android Auto rendering.
      expect(
        root[1].extras?['android.media.browse.CONTENT_STYLE_BROWSABLE_HINT'],
        2,
      );
    });

    test('empty library yields an empty root, never throws', () async {
      final tree = MediaBrowseTree(_FakeSource());
      expect(await tree.children(AudioService.browsableRootId), isEmpty);
      expect(await tree.children('nonsense:id'), isEmpty);
      expect(await tree.children('album:broken'), isEmpty);
    });
  });

  group('MediaBrowseTree containers', () {
    test('recent root alias and queue return playable queue items', () async {
      final source = _FakeSource(queue: [_media('q1'), _media('q2')]);
      final tree = MediaBrowseTree(source);
      final viaRecent = await tree.children(AudioService.recentRootId);
      final viaQueue = await tree.children(MediaBrowseTree.queueId);
      expect(viaRecent.map((e) => e.id), ['q1', 'q2']);
      expect(viaQueue.map((e) => e.id), ['q1', 'q2']);
      expect(viaQueue.every((e) => e.playable == true), isTrue);
      expect(
        viaQueue.first.extras?[MediaBrowseTree.containerExtraKey],
        MediaBrowseTree.queueId,
      );
      // The original source extra survives the copy.
      expect(viaQueue.first.extras?['source'], '/music/q1.flac');
    });

    test('recent / most played / loved sections expose playable items',
        () async {
      final source = _FakeSource(
        recent: [_media('r1'), _media('r2'), _media('r3')],
        top: [_media('t1')],
        loved: [_media('l1'), _media('l2')],
      );
      final tree = MediaBrowseTree(source);
      final recent = await tree.children(MediaBrowseTree.recentId);
      final top = await tree.children(MediaBrowseTree.topId);
      final loved = await tree.children(MediaBrowseTree.lovedId);
      expect(recent.map((e) => e.id), ['r1', 'r2', 'r3']);
      expect(top.map((e) => e.id), ['t1']);
      expect(loved.map((e) => e.id), ['l1', 'l2']);
      for (final item in [...recent, ...top, ...loved]) {
        expect(item.playable, isTrue);
      }
      expect(
        loved.first.extras?[MediaBrowseTree.containerExtraKey],
        MediaBrowseTree.lovedId,
      );
    });

    test('playlists are browsable folders whose children are playable',
        () async {
      final source = _FakeSource(
        playlistList: const [
          MediaBrowsePlaylist(id: 'p1', name: 'Gym', trackCount: 2),
        ],
        playlistTracks: {
          'p1': [_media('t1'), _media('t2')],
        },
      );
      final tree = MediaBrowseTree(source);
      final folders = await tree.children(MediaBrowseTree.playlistsId);
      expect(folders.single.id, 'playlist:p1');
      expect(folders.single.title, 'Gym');
      expect(folders.single.playable, isFalse);
      final tracks = await tree.children('playlist:p1');
      expect(tracks.map((e) => e.id), ['t1', 't2']);
      expect(
        tracks.first.extras?[MediaBrowseTree.containerExtraKey],
        'playlist:p1',
      );
      expect(
        (await tree.containerMedia('playlist:p1'))!.map((m) => m.id),
        ['t1', 't2'],
      );
    });

    test('album ids round-trip source tag and keys containing colons',
        () async {
      final source = _FakeSource(
        albumList: const [
          MediaBrowseAlbum(
            source: 'local',
            key: 'album|artist:with:colons',
            name: 'Album',
            artist: 'Artist',
          ),
        ],
        albumTracks: {
          'local:album|artist:with:colons': [_media('a1')],
        },
      );
      final tree = MediaBrowseTree(source);
      final albums = await tree.children(MediaBrowseTree.albumsId);
      expect(albums.single.id, 'album:local:album|artist:with:colons');
      final tracks = await tree.children(albums.single.id);
      expect(tracks.single.id, 'a1');
      expect(
        (await tree.containerMedia(albums.single.id))!.single.id,
        'a1',
      );
      expect(await tree.containerMedia('album:local'), isNull);
    });

    test('library pages through the source with the page option', () async {
      final source = _FakeSource(
        library: List.generate(5, (i) => _media('l$i')),
      );
      final tree = MediaBrowseTree(source);
      final first = await tree.children(
        MediaBrowseTree.libraryId,
        page: 0,
        pageSize: 2,
      );
      final second = await tree.children(
        MediaBrowseTree.libraryId,
        page: 1,
        pageSize: 2,
      );
      expect(first.map((e) => e.id), ['l0', 'l1']);
      expect(second.map((e) => e.id), ['l2', 'l3']);
      expect(source.libraryPages, [(2, 0), (2, 2)]);
    });
  });

  group('MediaBrowseTree search', () {
    test('returns playable matches and ignores blank queries', () async {
      final source = _FakeSource(
        library: [
          _media('d1', title: 'One More Time', artist: 'Daft Punk'),
          _media('x1', title: 'Other', artist: 'Someone'),
        ],
      );
      final tree = MediaBrowseTree(source);
      expect(await tree.search('   '), isEmpty);
      expect(source.searches, isEmpty);
      final hits = await tree.search('daft');
      expect(hits.single.id, 'd1');
      expect(hits.single.playable, isTrue);
    });
  });
}
