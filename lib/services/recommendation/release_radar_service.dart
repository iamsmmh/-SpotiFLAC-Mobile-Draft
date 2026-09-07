/// Release Radar (Phase 7).
///
/// Builds a weekly playlist of new releases from followed, favorited and
/// frequently-played artists. Metadata is cached locally so the shelf still
/// renders offline.
library;

import 'package:spotiflac_android/services/recommendation/ml/playlist_generator.dart';

/// One known release (album or single) the radar can consider.
class ArtistRelease {
  const ArtistRelease({
    required this.releaseId,
    required this.artistId,
    required this.artistName,
    required this.title,
    required this.releasedAt,
    required this.trackIds,
  });

  final String releaseId;
  final String artistId;
  final String artistName;
  final String title;
  final DateTime releasedAt;
  final List<String> trackIds;
}

/// Cached radar snapshot.
class ReleaseRadarSnapshot {
  const ReleaseRadarSnapshot({
    required this.generatedAt,
    required this.mix,
    required this.releaseIds,
  });

  final DateTime generatedAt;
  final GeneratedMix mix;
  final List<String> releaseIds;
}

/// Generates the weekly radar playlist.
class ReleaseRadarService {
  const ReleaseRadarService({this.window = const Duration(days: 7)});

  /// How far back a release still counts as "new".
  final Duration window;

  /// Artists we watch: followed ∪ favorited ∪ frequently played.
  static Set<String> watchedArtists({
    Iterable<String> followed = const <String>[],
    Iterable<String> favorited = const <String>[],
    Iterable<String> frequentlyPlayed = const <String>[],
  }) {
    return <String>{
      ...followed.where((id) => id.isNotEmpty),
      ...favorited.where((id) => id.isNotEmpty),
      ...frequentlyPlayed.where((id) => id.isNotEmpty),
    };
  }

  ReleaseRadarSnapshot generate({
    required Set<String> artists,
    required Iterable<ArtistRelease> catalog,
    required DateTime utcNow,
    int maxTracks = 50,
  }) {
    final cutoff = utcNow.toUtc().subtract(window);
    final hits = catalog.where((release) {
      if (!artists.contains(release.artistId)) return false;
      return !release.releasedAt.toUtc().isBefore(cutoff);
    }).toList()
      ..sort((a, b) => b.releasedAt.compareTo(a.releasedAt));

    final trackIds = <String>[];
    final releaseIds = <String>[];
    final seen = <String>{};
    for (final release in hits) {
      releaseIds.add(release.releaseId);
      for (final trackId in release.trackIds) {
        if (trackIds.length >= maxTracks) break;
        if (trackId.isEmpty || !seen.add(trackId)) continue;
        trackIds.add(trackId);
      }
      if (trackIds.length >= maxTracks) break;
    }

    final seed = PlaylistGenerator.dailySeed(utcNow);
    return ReleaseRadarSnapshot(
      generatedAt: utcNow.toUtc(),
      mix: GeneratedMix(
        kind: GeneratedMixKind.releaseRadar,
        id: 'release-radar-$seed',
        title: 'Release Radar',
        trackIds: List<String>.unmodifiable(trackIds),
      ),
      releaseIds: List<String>.unmodifiable(releaseIds),
    );
  }
}
