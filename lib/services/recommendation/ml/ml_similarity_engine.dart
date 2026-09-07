/// Taste-aware similarity (Phase 6).
///
/// Combines the on-device [UserTasteModel] with co-listen / same-artist
/// heuristics. Distinct from `engine/discovery/similarity_engine.dart` (which
/// ranks *artists* from taxonomy); this engine ranks *tracks* for mix
/// generation.
library;

import 'package:spotiflac_android/services/recommendation/ml/user_taste_model.dart';

/// One scored neighbour.
class SimilarTrack {
  const SimilarTrack({
    required this.trackId,
    required this.score,
    this.reason = '',
  });

  final String trackId;
  final double score;
  final String reason;
}

/// Ranks candidate tracks against a seed using taste + metadata overlap.
class MlSimilarityEngine {
  const MlSimilarityEngine();

  List<SimilarTrack> similarTo({
    required String seedTrackId,
    required String seedArtistId,
    required String seedGenre,
    required UserTasteModel taste,
    required Iterable<TasteSignal> pool,
    int limit = 20,
  }) {
    final results = <SimilarTrack>[];
    for (final candidate in pool) {
      if (candidate.trackId == seedTrackId) continue;
      var score = 0.0;
      final reasons = <String>[];
      if (candidate.artistId.isNotEmpty &&
          candidate.artistId == seedArtistId) {
        score += 0.45;
        reasons.add('same artist');
      }
      if (candidate.genre.isNotEmpty && candidate.genre == seedGenre) {
        score += 0.25;
        reasons.add('same genre');
      }
      final affinity = taste.affinityFor(candidate.trackId);
      if (affinity > 0) {
        score += 0.20 * affinity;
        reasons.add('taste');
      }
      final artistAff = taste.artistAffinity[candidate.artistId] ?? 0;
      if (artistAff > 0) {
        score += 0.10 * artistAff;
      }
      if (score <= 0) continue;
      results.add(
        SimilarTrack(
          trackId: candidate.trackId,
          score: score > 1 ? 1 : score,
          reason: reasons.join(', '),
        ),
      );
    }
    results.sort((a, b) => b.score.compareTo(a.score));
    if (results.length > limit) {
      return List<SimilarTrack>.unmodifiable(results.sublist(0, limit));
    }
    return List<SimilarTrack>.unmodifiable(results);
  }
}
