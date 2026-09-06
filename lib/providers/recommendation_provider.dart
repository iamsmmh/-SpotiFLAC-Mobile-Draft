import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/engine/playback_session.dart';
import 'package:spotiflac_android/engine/recommendations.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/playback_statistics_provider.dart';

/// The app's recommendation service (Phase 7).
///
/// Ships with the fully local engine as the fallback. Remote/extension-backed
/// providers activate by overriding this provider at the composition root
/// (ProviderScope.overrides) with a service built via
/// `RecommendationService.localOnly().withProvider(...)` — the chain keeps
/// them ahead of the local engine so richer sources win per section kind.
final recommendationServiceProvider = Provider<RecommendationService>((ref) {
  return RecommendationService.localOnly();
});

/// Deterministic daily rotation seed: ordinal of the current UTC day. The
/// discovery mix is stable within a day and reshuffles overnight.
int recommendationDailySeed({DateTime? at}) {
  final utc = (at ?? DateTime.now()).toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day).millisecondsSinceEpoch ~/
      Duration.millisecondsPerDay;
}

/// Builds the engine input from on-device state only (statistics, favorites).
RecommendationProfile buildRecommendationProfile({
  required ListeningStats stats,
  required LibraryCollectionsState collections,
  DateTime? at,
}) {
  return RecommendationProfile(
    plays: stats.trackStats.values
        .map(
          (stat) => ProfilePlay(
            trackId: stat.trackId,
            title: stat.title,
            artist: stat.artist,
            album: stat.album,
            playCount: stat.playCount,
            listenedMs: stat.listenedMs,
            lastPlayedAt: stat.lastPlayedAt,
          ),
        )
        .toList(growable: false),
    favoriteArtists: collections.favoriteArtists
        .map(
          (entry) => ProfileAffinity(
            id: entry.artistId,
            name: entry.name,
            imageUrl: entry.imageUrl,
            providerId: entry.providerId,
          ),
        )
        .toList(growable: false),
    favoriteAlbums: collections.favoriteAlbums
        .map(
          (entry) => ProfileAffinity(
            id: entry.albumId,
            name: entry.name,
            kind: RecommendedItemKind.album,
            imageUrl: entry.imageUrl,
            providerId: entry.providerId,
          ),
        )
        .toList(growable: false),
    lovedTracks: collections.loved
        .map(
          (entry) => ProfilePlay(
            trackId: entry.track.id,
            title: entry.track.name,
            artist: entry.track.artistName,
            album: entry.track.albumName,
            playCount: 1,
          ),
        )
        .toList(growable: false),
    dailySeed: recommendationDailySeed(at: at),
  );
}

/// The For You shelves. Recomputes when statistics or favorites change; the
/// engine is cheap (bounded lists, no I/O) so a [FutureProvider] is enough.
final forYouSectionsProvider = FutureProvider<List<RecommendationSection>>((
  ref,
) async {
  final stats = ref.watch(playbackStatisticsProvider);
  final collections = ref.watch(libraryCollectionsProvider);
  final service = ref.watch(recommendationServiceProvider);
  final profile = buildRecommendationProfile(
    stats: stats,
    collections: collections,
  );
  return service.recommend(profile, maxItemsPerSection: 20);
});
