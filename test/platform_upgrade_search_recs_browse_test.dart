import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/carplay_service.dart';
import 'package:spotiflac_android/services/media_browse_tree.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/services/recommendation/ml/ml.dart';
import 'package:spotiflac_android/services/recommendation/release_radar_service.dart';
import 'package:spotiflac_android/services/search/search.dart';

PlayableMedia _media(String id, {String title = 'Song', String artist = 'A'}) =>
    PlayableMedia(
      id: id,
      source: '/music/$id.flac',
      title: title,
      artist: artist,
    );

class _Source implements MediaBrowseSource {
  _Source({
    this.counts = const MediaBrowseCounts(),
    this.recent = const <PlayableMedia>[],
    this.top = const <PlayableMedia>[],
    this.albumList = const <MediaBrowseAlbum>[],
    this.library = const <PlayableMedia>[],
  });

  final MediaBrowseCounts counts;
  final List<PlayableMedia> recent;
  final List<PlayableMedia> top;
  final List<MediaBrowseAlbum> albumList;
  final List<PlayableMedia> library;

  @override
  Future<MediaBrowseCounts> sectionCounts() async => counts;
  @override
  Future<List<PlayableMedia>> queueMedia() async => const <PlayableMedia>[];
  @override
  Future<List<PlayableMedia>> recentMedia({required int limit}) async =>
      recent.take(limit).toList();
  @override
  Future<List<PlayableMedia>> mostPlayedMedia({required int limit}) async =>
      top.take(limit).toList();
  @override
  Future<List<PlayableMedia>> lovedMedia() async => const <PlayableMedia>[];
  @override
  Future<List<MediaBrowsePlaylist>> playlists() async =>
      const <MediaBrowsePlaylist>[];
  @override
  Future<List<PlayableMedia>> playlistMedia(String playlistId) async =>
      const <PlayableMedia>[];
  @override
  Future<List<MediaBrowseAlbum>> albums({
    required int limit,
    required int offset,
  }) async =>
      albumList.skip(offset).take(limit).toList();
  @override
  Future<List<PlayableMedia>> albumMedia({
    required String sourceTag,
    required String key,
  }) async =>
      const <PlayableMedia>[];
  @override
  Future<List<PlayableMedia>> libraryMedia({
    required int limit,
    required int offset,
  }) async =>
      library.skip(offset).take(limit).toList();
  @override
  Future<List<PlayableMedia>> searchMedia(
    String query, {
    required int limit,
  }) async {
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
  group('TypoCorrector', () {
    const corrector = TypoCorrector();

    test('corrects a single substitution', () {
      expect(
        corrector.correct('beonce', const <String>['Beyoncé', 'Radiohead']),
        'Beyoncé',
      );
    });

    test('ignores short queries', () {
      expect(corrector.suggestions('ab', const <String>['abc']), isEmpty);
    });
  });

  group('SmartSearchEngine', () {
    test('returns unified hits and marks a correction', () {
      const engine = SmartSearchEngine();
      final response = engine.search(
        query: 'daft pnk',
        catalog: const SmartSearchCatalog(
          tracks: <SmartSearchHit>[
            SmartSearchHit(
              kind: SmartSearchKind.track,
              id: 't1',
              title: 'One More Time',
              subtitle: 'Daft Punk',
            ),
          ],
          artists: <SmartSearchHit>[
            SmartSearchHit(
              kind: SmartSearchKind.artist,
              id: 'a1',
              title: 'Daft Punk',
            ),
          ],
        ),
        recent: const <String>['Daft Punk'],
      );
      expect(response.hits, isNotEmpty);
      expect(response.suggestions, isNotEmpty);
    });
  });

  group('PlaylistGenerator + ReleaseRadar', () {
    test('builds Discover Weekly and Daily Mix from taste', () {
      const builder = UserTasteBuilder();
      const generator = PlaylistGenerator();
      final signals = <TasteSignal>[
        const TasteSignal(
          trackId: 't1',
          artistId: 'a1',
          genre: 'electronic',
          playCount: 10,
          listenedMs: 180000,
          durationMs: 200000,
        ),
        const TasteSignal(
          trackId: 't2',
          artistId: 'a2',
          genre: 'electronic',
          playCount: 4,
          listenedMs: 90000,
          durationMs: 200000,
        ),
        const TasteSignal(
          trackId: 't3',
          artistId: 'a3',
          genre: 'jazz',
          playCount: 2,
          listenedMs: 40000,
          durationMs: 200000,
        ),
      ];
      final taste = builder.build(signals);
      final weekly = generator.discoverWeekly(
        taste: taste,
        pool: signals,
        utcNow: DateTime.utc(2026, 9, 7),
        size: 3,
      );
      expect(weekly.kind, GeneratedMixKind.discoverWeekly);
      expect(weekly.trackIds, isNotEmpty);
      final mix = generator.dailyMix(
        taste: taste,
        pool: signals,
        index: 1,
        utcNow: DateTime.utc(2026, 9, 7),
      );
      expect(mix.id, contains('daily-mix-1'));
    });

    test('Release Radar keeps only recent watched-artist tracks', () {
      const radar = ReleaseRadarService();
      final snapshot = radar.generate(
        artists: ReleaseRadarService.watchedArtists(
          followed: const <String>['a1'],
        ),
        catalog: <ArtistRelease>[
          ArtistRelease(
            releaseId: 'r1',
            artistId: 'a1',
            artistName: 'Ada',
            title: 'New',
            releasedAt: DateTime.utc(2026, 9, 5),
            trackIds: const <String>['n1', 'n2'],
          ),
          ArtistRelease(
            releaseId: 'r-old',
            artistId: 'a1',
            artistName: 'Ada',
            title: 'Old',
            releasedAt: DateTime.utc(2026, 1, 1),
            trackIds: const <String>['old'],
          ),
        ],
        utcNow: DateTime.utc(2026, 9, 7),
      );
      expect(snapshot.mix.trackIds, <String>['n1', 'n2']);
      expect(snapshot.mix.kind, GeneratedMixKind.releaseRadar);
    });
  });

  group('MediaBrowseTree extra sections', () {
    test('appends home/continue/artists after the original root', () async {
      final tree = MediaBrowseTree(
        _Source(
          counts: const MediaBrowseCounts(
            queue: 1,
            albums: 1,
            library: 1,
            home: 1,
            continueListening: 2,
            artists: 1,
            recommendations: 1,
          ),
        ),
      );
      final root = await tree.children(AudioService.browsableRootId);
      expect(root.map((e) => e.id).toList(), <String>[
        MediaBrowseTree.queueId,
        MediaBrowseTree.albumsId,
        MediaBrowseTree.libraryId,
        MediaBrowseTree.homeId,
        MediaBrowseTree.continueId,
        MediaBrowseTree.artistsId,
        MediaBrowseTree.recommendationsId,
      ]);
    });

    test('zero extra counts keep the original three-folder root', () async {
      final tree = MediaBrowseTree(
        _Source(
          counts: const MediaBrowseCounts(queue: 3, albums: 2, library: 40),
        ),
      );
      final root = await tree.children(AudioService.browsableRootId);
      expect(root.map((e) => e.id), <String>[
        MediaBrowseTree.queueId,
        MediaBrowseTree.albumsId,
        MediaBrowseTree.libraryId,
      ]);
    });

    test('artists group albums and continue uses recents', () async {
      final tree = MediaBrowseTree(
        _Source(
          counts: const MediaBrowseCounts(artists: 1, continueListening: 1),
          recent: <PlayableMedia>[_media('r1')],
          albumList: const <MediaBrowseAlbum>[
            MediaBrowseAlbum(
              source: 'local',
              key: 'k',
              name: 'Album',
              artist: 'Daft Punk',
            ),
          ],
        ),
      );
      final artists = await tree.children(MediaBrowseTree.artistsId);
      expect(artists.single.title, 'Daft Punk');
      final continueRows = await tree.children(MediaBrowseTree.continueId);
      expect(continueRows.single.id, 'r1');
    });
  });

  group('CarPlayService search', () {
    test('returns playable search rows', () async {
      final service = CarPlayService(
        tree: MediaBrowseTree(
          _Source(
            library: <PlayableMedia>[
              _media('d1', title: 'One More Time', artist: 'Daft Punk'),
            ],
          ),
        ),
        onPlay: (_, _) async {},
      );
      final rows = await service.search('daft');
      expect(rows.single['id'], 'd1');
      expect(rows.single['isBrowsable'], isFalse);
      expect(service.nowPlayingTemplate()['template'], 'nowPlaying');
    });
  });
}
