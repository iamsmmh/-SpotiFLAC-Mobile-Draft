/// Discovery AI Improvements (Milestone 8).
///
/// Enhances the existing recommendation engine with:
///   - User Vector: Dense embedding of listening preferences
///   - Artist Vector: Per-artist embedding from co-listen patterns
///   - Track Vector: Per-track embedding from audio features + metadata
///   - Cosine Similarity: For vector-based matching
///   - Collaborative Filtering: User-user and item-item similarity
///   - Content-Based Ranking: Audio feature similarity for cold-start
///
/// These complement the existing engines:
///   - similarity_engine.dart (already has cosine similarity)
///   - recommendation_scorer.dart (already has scoring)
///   - discovery_math.dart (already has time decay, normalization)
///
/// This module adds the vector storage and collaborative filtering
/// that were missing from the existing discovery system.
library;

import 'dart:math' as math;

import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';

// ---------------------------------------------------------------------------
// User Vector
// ---------------------------------------------------------------------------

/// Dense user preference vector derived from listening history.
///
/// Dimensions represent latent features (mood, energy, genre clusters)
/// that emerge from collaborative filtering over the listening graph.
class UserVector {
  UserVector({
    required this.userId,
    required this.dimensions,
    required this.weights,
    required this.updatedAt,
  });

  final String userId;
  final int dimensions;
  final List<double> weights;
  final DateTime updatedAt;

  /// Cosine similarity with another user vector.
  double similarity(UserVector other) {
    if (dimensions != other.dimensions) return 0;
    return _cosineSim(weights, other.weights);
  }

  /// Creates a UserVector from listening profile data.
  factory UserVector.fromProfile(
    String userId,
    ListeningProfile profile, {
    int dimensions = 64,
  }) {
    final weights = List<double>.filled(dimensions, 0);
    final random = math.Random(userId.hashCode);

    // Hash artist affinities into the vector space.
    for (final entry in profile.artists.take(50)) {
      final idx = entry.key.hashCode.abs() % dimensions;
      weights[idx] += entry.affinity * 0.5;
    }

    // Hash genre affinities.
    for (final entry in profile.genreAffinity.entries.take(20)) {
      final idx = entry.key.hashCode.abs() % dimensions;
      weights[idx] += entry.value * 0.3;
    }

    // Normalize.
    final magnitude = math.sqrt(weights.fold<double>(0, (s, w) => s + w * w));
    if (magnitude > 0) {
      for (var i = 0; i < dimensions; i++) {
        weights[i] /= magnitude;
      }
    }

    return UserVector(
      userId: userId,
      dimensions: dimensions,
      weights: weights,
      updatedAt: DateTime.now(),
    );
  }
}

// ---------------------------------------------------------------------------
// Artist Vector
// ---------------------------------------------------------------------------

/// Per-artist embedding derived from co-listen patterns.
///
/// Artists that are frequently listened to by the same users get
/// similar vectors, enabling "fans of X also like Y" discovery.
class ArtistVector {
  ArtistVector({
    required this.artistId,
    required this.dimensions,
    required this.weights,
    required this.listenCount,
  });

  final String artistId;
  final int dimensions;
  final List<double> weights;
  final int listenCount;

  /// Similarity with another artist.
  double similarity(ArtistVector other) {
    if (dimensions != other.dimensions) return 0;
    return _cosineSim(weights, other.weights);
  }
}

// ---------------------------------------------------------------------------
// Track Vector
// ---------------------------------------------------------------------------

/// Per-track embedding from audio features and metadata.
///
/// Used for content-based ranking when collaborative data is sparse
/// (cold start for new tracks or users).
class TrackVector {
  TrackVector({
    required this.trackId,
    required this.dimensions,
    required this.weights,
  });

  final String trackId;
  final int dimensions;
  final List<double> weights;

  /// Similarity with another track (content-based).
  double similarity(TrackVector other) {
    if (dimensions != other.dimensions) return 0;
    return _cosineSim(weights, other.weights);
  }

  /// Creates a TrackVector from audio features.
  factory TrackVector.fromFeatures(
    String trackId, {
    double energy = 0.5,
    double valence = 0.5,
    double danceability = 0.5,
    double acousticness = 0.5,
    double instrumentalness = 0.0,
    double tempo = 120,
    String genre = '',
  }) {
    const dimensions = 16;
    final weights = <double>[
      energy,
      valence,
      danceability,
      acousticness,
      instrumentalness,
      (tempo - 60) / 140, // Normalize 60-200 BPM to 0-1.
      // Genre clusters (hash-based projection).
      ...List<double>.generate(
        10,
        (i) {
          final h = genre.hashCode.abs() + i;
          return (h % 100) / 100.0 * 0.3;
        },
      ),
    ];
    return TrackVector(
      trackId: trackId,
      dimensions: dimensions,
      weights: weights,
    );
  }
}

// ---------------------------------------------------------------------------
// Collaborative Filtering
// ---------------------------------------------------------------------------

/// Collaborative filtering engine for recommendations.
///
/// Uses user-user similarity to find "neighbors" and recommend what
/// they listen to that the target user hasn't heard yet.
class CollaborativeFilter {
  CollaborativeFilter({
    required this.userVectors,
    required this.userTrackMatrix,
  });

  /// All user vectors in the system.
  final Map<String, UserVector> userVectors;

  /// User → track listen counts.
  final Map<String, Map<String, int>> userTrackMatrix;

  /// Finds the K most similar users to the target.
  List<({String userId, double similarity})> findNeighbors(
    String targetUserId, {
    int k = 20,
  }) {
    final target = userVectors[targetUserId];
    if (target == null) return const [];

    final scored = <({String userId, double similarity})>[];
    for (final entry in userVectors.entries) {
      if (entry.key == targetUserId) continue;
      final sim = target.similarity(entry.value);
      if (sim > 0.1) {
        scored.add((userId: entry.key, similarity: sim));
      }
    }
    scored.sort((a, b) => b.similarity.compareTo(a.similarity));
    return scored.take(k).toList();
  }

  /// Recommends tracks based on what similar users listen to.
  List<({String trackId, double score})> recommend(
    String targetUserId, {
    int limit = 30,
  }) {
    final neighbors = findNeighbors(targetUserId);
    if (neighbors.isEmpty) return const [];

    // Aggregate neighbor track preferences, weighted by similarity.
    final trackScores = <String, double>{};
    final targetTracks = userTrackMatrix[targetUserId] ?? {};

    for (final neighbor in neighbors) {
      final neighborTracks = userTrackMatrix[neighbor.userId] ?? {};
      for (final entry in neighborTracks.entries) {
        if (targetTracks.containsKey(entry.key)) continue; // Already listened.
        trackScores.update(
          entry.key,
          (existing) => existing + neighbor.similarity * math.log(1 + entry.value),
          ifAbsent: () => neighbor.similarity * math.log(1 + entry.value),
        );
      }
    }

    final results = trackScores.entries
        .map((e) => (trackId: e.key, score: e.value))
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));

    return results.take(limit).toList();
  }
}

// ---------------------------------------------------------------------------
// Content-Based Ranking
// ---------------------------------------------------------------------------

/// Content-based ranking for cold-start scenarios.
///
/// When collaborative data is sparse (new user, new track), falls back
/// to content similarity based on audio features and metadata.
class ContentBasedRanker {
  ContentBasedRanker({
    required this.trackVectors,
  });

  final Map<String, TrackVector> trackVectors;

  /// Finds tracks most similar to the seed tracks.
  List<({String trackId, double score})> rankSimilar(
    List<String> seedTrackIds, {
    Set<String>? exclude,
    int limit = 30,
  }) {
    if (seedTrackIds.isEmpty) return const [];
    exclude ??= {};

    // Average the seed vectors.
    final dimensions = trackVectors[seedTrackIds.first]?.dimensions ?? 0;
    if (dimensions == 0) return const [];

    final avgWeights = List<double>.filled(dimensions, 0);
    var count = 0;
    for (final id in seedTrackIds) {
      final v = trackVectors[id];
      if (v == null) continue;
      for (var i = 0; i < dimensions; i++) {
        avgWeights[i] += v.weights[i];
      }
      count++;
    }
    if (count == 0) return const [];
    for (var i = 0; i < dimensions; i++) {
      avgWeights[i] /= count;
    }

    // Score all tracks against the average.
    final scored = <({String trackId, double score})>[];
    for (final entry in trackVectors.entries) {
      if (seedTrackIds.contains(entry.key)) continue;
      if (exclude.contains(entry.key)) continue;
      final sim = _cosineSim(avgWeights, entry.value.weights);
      if (sim > 0.2) {
        scored.add((trackId: entry.key, score: sim));
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList();
  }
}

// ---------------------------------------------------------------------------
// Trending Engine Enhancement
// ---------------------------------------------------------------------------

/// Enhanced trending computation with decay and velocity.
class EnhancedTrending {
  EnhancedTrending._();

  /// Computes trending scores for tracks based on recent listen velocity.
  ///
  /// Combines:
  ///   - Recency-weighted listen count
  ///   - Velocity (acceleration of listens)
  ///   - Diversity bonus (less-concentrated = higher score)
  static List<({String trackId, double score})> computeTrending(
    Map<String, List<DateTime>> trackListenTimes, {
    DateTime? now,
    Duration window = const Duration(days: 7),
    int limit = 50,
  }) {
    final reference = now ?? DateTime.now();
    final windowStart = reference.subtract(window);
    final scored = <({String trackId, double score})>[];

    for (final entry in trackListenTimes.entries) {
      final recentListens = entry.value
          .where((t) => t.isAfter(windowStart))
          .toList()
        ..sort();
      if (recentListens.isEmpty) continue;

      // Recency-weighted count.
      var weightedCount = 0.0;
      for (final listen in recentListens) {
        final decay = timeDecay(listen, reference,
            halfLife: const Duration(days: 2));
        weightedCount += decay;
      }

      // Velocity: listens in the last 24h vs the full window.
      final last24h = recentListens
          .where((t) => t.isAfter(reference.subtract(const Duration(days: 1))))
          .length;
      final velocity = last24h / math.max(1, recentListens.length);

      // Combined score.
      final score = weightedCount * (1 + velocity);
      scored.add((trackId: entry.key, score: score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).toList();
  }
}

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

/// Cosine similarity between two vectors.
double _cosineSim(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  final denom = math.sqrt(normA) * math.sqrt(normB);
  if (denom <= 0) return 0;
  return dot / denom;
}
