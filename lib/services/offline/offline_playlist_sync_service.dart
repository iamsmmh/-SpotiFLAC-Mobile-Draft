/// Auto-download playlists marked offline (Phase 2).
///
/// Walks the playlists the user pinned for offline, diffs against what is
/// already downloaded / cached, and emits a work list the downloader already
/// knows how to consume. No second download pipeline.
library;

import 'package:spotiflac_android/services/offline/offline_policy.dart';

/// One playlist the user marked "Available offline".
class OfflinePlaylistTarget {
  const OfflinePlaylistTarget({
    required this.playlistId,
    required this.name,
    required this.trackIds,
  });

  final String playlistId;
  final String name;
  final List<String> trackIds;
}

/// One track that still needs a local copy.
class OfflineTrackWork {
  const OfflineTrackWork({
    required this.trackId,
    required this.playlistId,
    required this.collection,
  });

  final String trackId;
  final String playlistId;
  final OfflineCollectionKind collection;
}

/// Diffs marked playlists against the local/cached set.
class OfflinePlaylistSyncService {
  const OfflinePlaylistSyncService();

  /// Returns tracks in [targets] that are not in [alreadyLocal], preserving
  /// playlist order. Empty when everything is already on disk.
  List<OfflineTrackWork> plan({
    required List<OfflinePlaylistTarget> targets,
    required Set<String> alreadyLocal,
  }) {
    final work = <OfflineTrackWork>[];
    final seen = <String>{};
    for (final target in targets) {
      for (final trackId in target.trackIds) {
        if (trackId.isEmpty) continue;
        if (alreadyLocal.contains(trackId)) continue;
        if (!seen.add(trackId)) continue;
        work.add(
          OfflineTrackWork(
            trackId: trackId,
            playlistId: target.playlistId,
            collection: OfflineCollectionKind.markedPlaylists,
          ),
        );
      }
    }
    return List<OfflineTrackWork>.unmodifiable(work);
  }
}
