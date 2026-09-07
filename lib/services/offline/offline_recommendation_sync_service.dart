/// Auto-download Discover Weekly, Daily Mixes and liked songs (Phase 2).
///
/// Reuses the existing recommendation / favorites identity lists; this
/// service only decides *which* of those tracks still need a local copy.
library;

import 'package:spotiflac_android/services/offline/offline_playlist_sync_service.dart';
import 'package:spotiflac_android/services/offline/offline_policy.dart';

/// One generated shelf the user opted into auto-downloading.
class OfflineRecommendationShelf {
  const OfflineRecommendationShelf({
    required this.kind,
    required this.shelfId,
    required this.trackIds,
  });

  final OfflineCollectionKind kind;
  final String shelfId;
  final List<String> trackIds;
}

/// Diffs recommendation shelves against the local set.
class OfflineRecommendationSyncService {
  const OfflineRecommendationSyncService();

  List<OfflineTrackWork> plan({
    required List<OfflineRecommendationShelf> shelves,
    required Set<String> alreadyLocal,
  }) {
    final work = <OfflineTrackWork>[];
    final seen = <String>{};
    for (final shelf in shelves) {
      if (shelf.kind == OfflineCollectionKind.markedPlaylists) continue;
      for (final trackId in shelf.trackIds) {
        if (trackId.isEmpty) continue;
        if (alreadyLocal.contains(trackId)) continue;
        if (!seen.add(trackId)) continue;
        work.add(
          OfflineTrackWork(
            trackId: trackId,
            playlistId: shelf.shelfId,
            collection: shelf.kind,
          ),
        );
      }
    }
    return List<OfflineTrackWork>.unmodifiable(work);
  }
}
