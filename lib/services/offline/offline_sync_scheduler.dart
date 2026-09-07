/// Offline-sync scheduler (Phase 2).
///
/// Combines [OfflineSyncPolicy] with the playlist + recommendation planners
/// into one work list the existing download queue can consume. The scheduler
/// itself never starts a download: a denied admission returns an empty plan
/// with the reason, so the UI can show "Waiting for Wi-Fi" instead of
/// silently doing nothing.
library;

import 'package:spotiflac_android/services/offline/offline_playlist_sync_service.dart';
import 'package:spotiflac_android/services/offline/offline_policy.dart';
import 'package:spotiflac_android/services/offline/offline_recommendation_sync_service.dart';

/// One scheduled pass.
class OfflineSyncPlan {
  const OfflineSyncPlan({
    required this.admission,
    required this.work,
  });

  final OfflineAdmission admission;
  final List<OfflineTrackWork> work;

  bool get isRunnable => admission.isAllowed && work.isNotEmpty;

  int get trackCount => work.length;
}

/// Orchestrates one offline-sync cycle.
class OfflineSyncScheduler {
  OfflineSyncScheduler({
    OfflineSyncPolicy? policy,
    OfflinePlaylistSyncService playlists = const OfflinePlaylistSyncService(),
    OfflineRecommendationSyncService recommendations =
        const OfflineRecommendationSyncService(),
  })  : _policy = policy ?? const OfflineSyncPolicy(),
        _playlists = playlists,
        _recommendations = recommendations;

  final OfflineSyncPolicy _policy;
  final OfflinePlaylistSyncService _playlists;
  final OfflineRecommendationSyncService _recommendations;

  OfflineSyncPolicy get policy => _policy;

  /// Builds the work list. Never throws: a denied admission yields an empty
  /// work list so callers can always render a status chip.
  OfflineSyncPlan schedule({
    required OfflineDeviceState device,
    required Set<String> alreadyLocal,
    List<OfflinePlaylistTarget> playlists = const <OfflinePlaylistTarget>[],
    List<OfflineRecommendationShelf> shelves =
        const <OfflineRecommendationShelf>[],
  }) {
    final admission = _policy.admission(device);
    if (!admission.isAllowed) {
      return OfflineSyncPlan(
        admission: admission,
        work: const <OfflineTrackWork>[],
      );
    }
    final playlistWork = _playlists.plan(
      targets: playlists,
      alreadyLocal: alreadyLocal,
    );
    final recommendationWork = _recommendations.plan(
      shelves: shelves,
      alreadyLocal: alreadyLocal,
    );
    final seen = <String>{};
    final merged = <OfflineTrackWork>[];
    for (final item in [...playlistWork, ...recommendationWork]) {
      if (!seen.add(item.trackId)) continue;
      merged.add(item);
    }
    return OfflineSyncPlan(
      admission: admission,
      work: List<OfflineTrackWork>.unmodifiable(merged),
    );
  }
}
