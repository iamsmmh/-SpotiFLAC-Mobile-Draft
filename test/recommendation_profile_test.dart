import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/playback_session.dart';
import 'package:spotiflac_android/engine/recommendations.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/recommendation_provider.dart';

void main() {
  Track track(String id, String name, String artist) => Track(
    id: id,
    name: name,
    artistName: artist,
    albumName: 'Album',
    duration: 200000,
  );

  group('buildRecommendationProfile', () {
    test('maps stats, favorites and loved tracks into engine input', () {
      final stats = const ListeningStats().recordTrackPlay(
        TrackPlayIdentity(
          trackId: 't1',
          title: 'Song One',
          artist: 'Artist One',
          album: 'Album One',
        ),
        at: DateTime.utc(2026, 9, 5, 12),
      );
      final collections = LibraryCollectionsState(
        favoriteArtists: <CollectionArtistEntry>[
          CollectionArtistEntry(
            key: 'myext:art1',
            artistId: 'art1',
            providerId: 'myext',
            name: 'Fav Artist',
            addedAt: DateTime.utc(2026, 9, 1),
          ),
        ],
        favoriteAlbums: <CollectionAlbumEntry>[
          CollectionAlbumEntry(
            key: 'myext:alb1',
            albumId: 'alb1',
            providerId: 'myext',
            name: 'Fav Album',
            addedAt: DateTime.utc(2026, 9, 1),
          ),
        ],
        loved: <CollectionTrackEntry>[
          CollectionTrackEntry(
            key: 'builtin:t9',
            track: track('t9', 'Loved Song', 'Loved Artist'),
            addedAt: DateTime.utc(2026, 9, 2),
          ),
        ],
      );

      final profile = buildRecommendationProfile(
        stats: stats,
        collections: collections,
        at: DateTime.utc(2026, 9, 5, 18),
      );

      expect(profile.plays.single.trackId, 't1');
      expect(profile.plays.single.playCount, 1);
      expect(profile.plays.single.album, 'Album One');
      expect(profile.favoriteArtists.single.name, 'Fav Artist');
      expect(
        profile.favoriteAlbums.single.kind,
        RecommendedItemKind.album,
      );
      expect(profile.lovedTracks.single.title, 'Loved Song');
      expect(profile.dailySeed, isNotNull);
      expect(profile.isCold, isFalse);
    });

    test('empty inputs stay cold but well-formed', () {
      final profile = buildRecommendationProfile(
        stats: const ListeningStats(),
        collections: LibraryCollectionsState(),
      );
      expect(profile.isCold, isTrue);
      expect(profile.plays, isEmpty);
      expect(profile.favoriteArtists, isEmpty);
      expect(profile.lovedTracks, isEmpty);
    });

    test('daily seed changes across days and is stable within a day', () {
      final morning = recommendationDailySeed(
        at: DateTime.utc(2026, 9, 5, 8),
      );
      final evening = recommendationDailySeed(
        at: DateTime.utc(2026, 9, 5, 23),
      );
      final nextDay = recommendationDailySeed(
        at: DateTime.utc(2026, 9, 6, 1),
      );
      expect(morning, evening);
      expect(nextDay, isNot(evening));
    });
  });
}
