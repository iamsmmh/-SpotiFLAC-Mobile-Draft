/// Genre clustering for Daily Mixes (Phase 4).
///
/// Algorithm: deterministic farthest-first (k-center) seeding over artists'
/// genre vectors, followed by two Lloyd passes. Deterministic matters more
/// than optimal here — a Daily Mix that reshuffles every time the user
/// re-opens it feels broken, so the same profile always yields the same
/// clusters, and only the daily seed changes which tracks are picked *within*
/// a cluster.
///
/// Pure Dart: no I/O, no clock, no Flutter.
library;

import 'dart:math' as math;

import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';

/// One artist reduced to the vector clustering needs.
class ClusterArtist {
  const ClusterArtist({
    required this.key,
    required this.label,
    required this.genres,
    this.affinity = 0,
    this.playCount = 0,
  });

  final String key;
  final String label;

  /// Genre token → weight.
  final Map<String, double> genres;

  /// The user's decayed affinity for this artist (0..1).
  final double affinity;
  final int playCount;
}

/// A coherent group of artists sharing a genre neighbourhood.
class GenreCluster {
  const GenreCluster({
    required this.index,
    required this.label,
    required this.genres,
    required this.artistKeys,
    required this.artistLabels,
    this.genreWeights = const <String, double>{},
    this.affinity = 0,
  });

  /// Stable 0-based position — Daily Mix `index + 1`.
  final int index;

  /// Display name: the dominant genre, title-cased.
  final String label;

  /// Genre tokens that define the cluster, strongest first.
  final List<String> genres;

  final Set<String> artistKeys;
  final List<String> artistLabels;
  final Map<String, double> genreWeights;

  /// Mean user affinity across member artists.
  final double affinity;

  bool get isEmpty => artistKeys.isEmpty;
}

/// Splits the user's artists into [clusterCount] genre clusters.
class GenreClusterEngine {
  const GenreClusterEngine({
    this.clusterCount = 5,
    this.minGenresPerCluster = 1,
    this.maxGenresPerLabel = 4,
    this.lloydPasses = 2,
    this.minArtistsPerCluster = 2,
  });

  /// Target number of clusters (Daily Mix 1..5).
  final int clusterCount;

  /// A cluster with fewer distinct genres than this is not a real cluster and
  /// gets merged into its nearest neighbour.
  final int minGenresPerCluster;

  /// How many genre tokens make up the cluster label.
  final int maxGenresPerLabel;

  /// Lloyd refinement passes after seeding.
  final int lloydPasses;

  /// Clusters smaller than this are dropped, so the UI never shows a
  /// one-artist "mix".
  final int minArtistsPerCluster;

  /// Clusters [artists] into at most [clusterCount] groups.
  ///
  /// Artists without any genre information are excluded: clustering them would
  /// be noise, and they still reach the user through the other shelves.
  List<GenreCluster> cluster(
    Iterable<ClusterArtist> artists, {
    int? count,
    int seed = 0,
  }) {
    final target = (count ?? clusterCount).clamp(1, 16);
    final usable = artists
        .where((artist) => artist.key.isNotEmpty && artist.genres.isNotEmpty)
        .toList();
    if (usable.isEmpty) return const <GenreCluster>[];

    final effectiveTarget = math.min(target, usable.length);
    final centroids = _seedCentroids(usable, effectiveTarget, seed);
    var assignment = _assign(usable, centroids);

    for (var pass = 0; pass < lloydPasses; pass++) {
      final recomputed = _recomputeCentroids(usable, assignment, centroids);
      if (_centroidsEqual(recomputed, centroids)) break;
      centroids
        ..clear()
        ..addAll(recomputed);
      final next = _assign(usable, centroids);
      if (_assignmentEqual(next, assignment)) {
        assignment = next;
        break;
      }
      assignment = next;
    }

    final clusters = <GenreCluster>[];
    for (var i = 0; i < centroids.length; i++) {
      final members = <ClusterArtist>[];
      for (var j = 0; j < usable.length; j++) {
        if (assignment[j] == i) members.add(usable[j]);
      }
      if (members.length < minArtistsPerCluster) continue;
      final genreWeights = <String, double>{};
      var affinitySum = 0.0;
      for (final member in members) {
        accumulateWeights(genreWeights, member.genres);
        affinitySum += member.affinity;
      }
      final ranked = _rankGenres(genreWeights);
      if (ranked.length < minGenresPerCluster) continue;
      clusters.add(
        GenreCluster(
          index: clusters.length,
          label: _labelFor(ranked),
          genres: ranked.map((entry) => entry.key).toList(growable: false),
          artistKeys: Set<String>.unmodifiable(
            members.map((member) => member.key),
          ),
          artistLabels: members
              .map((member) => member.label)
              .toList(growable: false)
            ..sort(
              (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
            ),
          genreWeights: Map<String, double>.unmodifiable(
            peakNormalise(genreWeights),
          ),
          affinity: members.isEmpty ? 0 : affinitySum / members.length,
        ),
      );
    }

    // Sort by affinity so Daily Mix 1 is always the user's strongest taste,
    // then re-index so the `index` field matches the displayed order.
    clusters.sort((a, b) {
      final byAffinity = b.affinity.compareTo(a.affinity);
      if (byAffinity != 0) return byAffinity;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    return List<GenreCluster>.unmodifiable(<GenreCluster>[
      for (var i = 0; i < clusters.length; i++)
        GenreCluster(
          index: i,
          label: clusters[i].label,
          genres: clusters[i].genres,
          artistKeys: clusters[i].artistKeys,
          artistLabels: clusters[i].artistLabels,
          genreWeights: clusters[i].genreWeights,
          affinity: clusters[i].affinity,
        ),
    ]);
  }

  /// Which cluster a candidate track belongs to (strongest genre overlap), or
  /// -1 when it belongs to none.
  int clusterIndexFor(DiscoveryTrack track, List<GenreCluster> clusters) {
    if (track.genres.isEmpty || clusters.isEmpty) return -1;
    var best = -1;
    var bestScore = 0.0;
    for (final cluster in clusters) {
      final score = cosineSimilarity(
        <String, double>{for (final genre in track.genres) genre: 1.0},
        cluster.genreWeights,
      );
      if (score > bestScore) {
        bestScore = score;
        best = cluster.index;
      }
    }
    return bestScore <= 0 ? -1 : best;
  }

  /// Farthest-first seeding: pick the highest-affinity artist, then repeatedly
  /// the artist least similar to everything already chosen.
  List<Map<String, double>> _seedCentroids(
    List<ClusterArtist> artists,
    int count,
    int seed,
  ) {
    final ranked = List<ClusterArtist>.of(artists)
      ..sort((a, b) {
        final byAffinity = b.affinity.compareTo(a.affinity);
        if (byAffinity != 0) return byAffinity;
        final byPlays = b.playCount.compareTo(a.playCount);
        if (byPlays != 0) return byPlays;
        return a.key.compareTo(b.key);
      });

    final chosen = <ClusterArtist>[ranked.first];
    while (chosen.length < count && chosen.length < ranked.length) {
      ClusterArtist? best;
      var bestDistance = -1.0;
      for (final candidate in ranked) {
        if (chosen.any((entry) => entry.key == candidate.key)) continue;
        var maxSimilarity = 0.0;
        for (final entry in chosen) {
          final similarity = cosineSimilarity(candidate.genres, entry.genres);
          if (similarity > maxSimilarity) maxSimilarity = similarity;
        }
        final distance = 1 - maxSimilarity;
        if (distance > bestDistance) {
          bestDistance = distance;
          best = candidate;
        }
      }
      if (best == null) break;
      chosen.add(best);
    }

    // If the taste space is smaller than [count], top up with deterministic
    // rotations of the existing seeds so the caller still gets `count` mixes
    // (they will overlap, which is honest: a two-genre listener has two).
    final centroids = <Map<String, double>>[
      for (final artist in chosen) Map<String, double>.of(artist.genres),
    ];
    var rotation = 0;
    while (centroids.length < count && centroids.isNotEmpty) {
      final source = centroids[rotation % centroids.length];
      // Perturb with a seeded salt so repeated top-ups are not identical rows,
      // which would otherwise collapse to one cluster on the next Lloyd pass.
      final perturbed = <String, double>{
        for (final entry in source.entries)
          entry.key: entry.value * (0.6 + 0.4 * seededRandom(seed, '${entry.key}:$rotation')),
      };
      centroids.add(perturbed);
      rotation++;
      if (rotation > count * 4) break;
    }
    return centroids;
  }

  List<int> _assign(
    List<ClusterArtist> artists,
    List<Map<String, double>> centroids,
  ) {
    final assignment = List<int>.filled(artists.length, 0);
    for (var i = 0; i < artists.length; i++) {
      var best = 0;
      var bestScore = -1.0;
      for (var c = 0; c < centroids.length; c++) {
        final score = cosineSimilarity(artists[i].genres, centroids[c]);
        if (score > bestScore) {
          bestScore = score;
          best = c;
        }
      }
      assignment[i] = best;
    }
    return assignment;
  }

  List<Map<String, double>> _recomputeCentroids(
    List<ClusterArtist> artists,
    List<int> assignment,
    List<Map<String, double>> previous,
  ) {
    final sums = <Map<String, double>>[
      for (var c = 0; c < previous.length; c++) <String, double>{},
    ];
    for (var i = 0; i < artists.length; i++) {
      final cluster = assignment[i];
      if (cluster < 0 || cluster >= sums.length) continue;
      accumulateWeights(sums[cluster], artists[i].genres);
    }
    for (var c = 0; c < sums.length; c++) {
      // An emptied cluster keeps its previous centroid so it can win members
      // back on the next pass instead of drifting to the zero vector.
      if (sums[c].isEmpty) {
        sums[c] = Map<String, double>.of(previous[c]);
      }
    }
    return sums;
  }

  bool _centroidsEqual(
    List<Map<String, double>> a,
    List<Map<String, double>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].length != b[i].length) return false;
      for (final entry in a[i].entries) {
        final other = b[i][entry.key];
        if (other == null) return false;
        if ((other - entry.value).abs() > 0.0001) return false;
      }
    }
    return true;
  }

  bool _assignmentEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<MapEntry<String, double>> _rankGenres(Map<String, double> weights) {
    final ranked = weights.entries.toList()
      ..sort((a, b) {
        final byWeight = b.value.compareTo(a.value);
        if (byWeight != 0) return byWeight;
        return a.key.compareTo(b.key);
      });
    return ranked;
  }

  /// "Indie rock & folk" — up to [maxGenresPerLabel] tokens, title-cased.
  String _labelFor(List<MapEntry<String, double>> ranked) {
    final taken = ranked.take(maxGenresPerLabel).map((entry) => entry.key);
    final labels = taken.map(titleCaseToken).toList(growable: false);
    if (labels.isEmpty) return 'Mix';
    if (labels.length == 1) return labels.first;
    return '${labels.sublist(0, labels.length - 1).join(' · ')} '
        '· ${labels.last}';
  }
}

/// Title-cases a normalised token (`"indie rock"` → `"Indie Rock"`).
String titleCaseToken(String token) {
  if (token.isEmpty) return token;
  final words = token.split(' ');
  return words
      .map(
        (word) => word.isEmpty
            ? word
            : word[0].toUpperCase() + word.substring(1),
      )
      .join(' ');
}
