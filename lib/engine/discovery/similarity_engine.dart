/// Similarity maths for artists, tracks and albums (Phase 6).
///
/// Five signals, combined with fixed weights that are documented per term:
///
///   genre overlap      cosine over the artist's genre weight vector
///   tag overlap        cosine over free-form descriptor tags
///   co-listen overlap  Jaccard over "artists heard in the same session"
///   playlist overlap   Jaccard over the user's playlists containing them
///   album overlap      cosine over the albums the user plays from each
///
/// All of it runs on data the device already has — no external similarity
/// graph, no network. The engine is honest about that: when the taxonomy is
/// empty the score is `0` and the caller must not present it as "similar".
library;

import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';

// ---------------------------------------------------------------------------
// Vectors
// ---------------------------------------------------------------------------

/// One artist reduced to the signals similarity can compare.
class ArtistVector {
  const ArtistVector({
    required this.key,
    required this.label,
    this.genres = const <String, double>{},
    this.tags = const <String, double>{},
    this.albums = const <String, double>{},
    this.coListenedArtists = const <String>{},
    this.playlistIds = const <String>{},
    this.playCount = 0,
    this.imageUrl,
    this.providerId,
  });

  final String key;
  final String label;

  /// Genre token → weight (typically play count or decayed affinity).
  final Map<String, double> genres;
  final Map<String, double> tags;
  final Map<String, double> albums;

  /// Artist keys heard in the same listening session (see [buildCoListenGraph]).
  final Set<String> coListenedArtists;

  /// Ids of the user's playlists that contain this artist.
  final Set<String> playlistIds;

  final int playCount;
  final String? imageUrl;
  final String? providerId;

  bool get hasTaxonomy => genres.isNotEmpty || tags.isNotEmpty;

  ArtistVector copyWith({
    Set<String>? coListenedArtists,
    Set<String>? playlistIds,
    Map<String, double>? albums,
  }) {
    return ArtistVector(
      key: key,
      label: label,
      genres: genres,
      tags: tags,
      albums: albums ?? this.albums,
      coListenedArtists: coListenedArtists ?? this.coListenedArtists,
      playlistIds: playlistIds ?? this.playlistIds,
      playCount: playCount,
      imageUrl: imageUrl,
      providerId: providerId,
    );
  }

  /// Builds a vector from raw tracks — the shape the repository layer has
  /// after reading the library and the listening history.
  factory ArtistVector.fromTracks(
    String key,
    String label,
    Iterable<DiscoveryTrack> tracks, {
    Map<String, TrackSignals>? signals,
    Set<String> playlistIds = const <String>{},
    Set<String> coListenedArtists = const <String>{},
    String? imageUrl,
    String? providerId,
  }) {
    final genres = <String, double>{};
    final tags = <String, double>{};
    final albums = <String, double>{};
    var plays = 0;
    String? cover = imageUrl;
    for (final track in tracks) {
      final weight = (signals?[track.key]?.playCount ?? 1).toDouble();
      plays += signals?[track.key]?.playCount ?? 1;
      for (final genre in track.genres) {
        genres[genre] = (genres[genre] ?? 0) + weight;
      }
      for (final tag in track.tags) {
        tags[tag] = (tags[tag] ?? 0) + weight;
      }
      if (track.albumKey.isNotEmpty) {
        albums[track.albumKey] = (albums[track.albumKey] ?? 0) + weight;
      }
      cover ??= track.coverUrl;
    }
    return ArtistVector(
      key: key,
      label: label,
      genres: peakNormalise(genres),
      tags: peakNormalise(tags),
      albums: peakNormalise(albums),
      coListenedArtists: coListenedArtists,
      playlistIds: playlistIds,
      playCount: plays,
      imageUrl: cover,
      providerId: providerId,
    );
  }
}

/// The decomposed similarity between two artists.
class ArtistSimilarity {
  const ArtistSimilarity({
    required this.artistKey,
    required this.label,
    required this.score,
    this.genreOverlap = 0,
    this.tagOverlap = 0,
    this.coListenOverlap = 0,
    this.playlistOverlap = 0,
    this.albumOverlap = 0,
    this.topTracks = const <ScoredTrack>[],
    this.recommendedAlbums = const <String>[],
    this.imageUrl,
    this.providerId,
  });

  final String artistKey;
  final String label;

  /// 0..1 combined similarity — the number the UI shows as a percentage.
  final double score;

  final double genreOverlap;
  final double tagOverlap;
  final double coListenOverlap;
  final double playlistOverlap;
  final double albumOverlap;

  /// Most representative tracks, best first (drives the "Top tracks" list).
  final List<ScoredTrack> topTracks;

  /// Album labels worth surfacing ("Recommended albums").
  final List<String> recommendedAlbums;

  final String? imageUrl;
  final String? providerId;

  /// True when at least one real signal matched — the UI hides the percentage
  /// for zero-signal pairs rather than claiming a similarity it cannot back.
  bool get isGrounded =>
      genreOverlap > 0 ||
      tagOverlap > 0 ||
      coListenOverlap > 0 ||
      playlistOverlap > 0 ||
      albumOverlap > 0;

  Map<String, Object?> toRow(DateTime computedAt) => <String, Object?>{
    'other_key': artistKey,
    'score': score,
    'genre_overlap': genreOverlap,
    'tag_overlap': tagOverlap,
    'colisten_overlap': coListenOverlap,
    'playlist_overlap': playlistOverlap,
    'computed_at': computedAt.toUtc().toIso8601String(),
  };

  ArtistSimilarity withTracks(
    List<ScoredTrack> tracks,
    List<String> albums,
  ) {
    return ArtistSimilarity(
      artistKey: artistKey,
      label: label,
      score: score,
      genreOverlap: genreOverlap,
      tagOverlap: tagOverlap,
      coListenOverlap: coListenOverlap,
      playlistOverlap: playlistOverlap,
      albumOverlap: albumOverlap,
      topTracks: tracks,
      recommendedAlbums: albums,
      imageUrl: imageUrl,
      providerId: providerId,
    );
  }
}

// ---------------------------------------------------------------------------
// Engine
// ---------------------------------------------------------------------------

/// Signal weights for the artist blend.
class SimilarityWeights {
  const SimilarityWeights({
    this.genre = 0.34,
    this.tag = 0.16,
    this.coListen = 0.28,
    this.playlist = 0.10,
    this.album = 0.12,
  });

  final double genre;
  final double tag;
  final double coListen;
  final double playlist;
  final double album;
}

/// Computes artist/track/album similarity from on-device evidence.
class SimilarityEngine {
  const SimilarityEngine({this.weights = const SimilarityWeights()});

  final SimilarityWeights weights;

  /// Compares two artist vectors.
  ArtistSimilarity compare(ArtistVector target, ArtistVector other) {
    if (target.key == other.key) {
      return ArtistSimilarity(
        artistKey: other.key,
        label: other.label,
        score: 1,
        genreOverlap: 1,
        tagOverlap: 1,
        albumOverlap: 1,
        imageUrl: other.imageUrl,
        providerId: other.providerId,
      );
    }
    final genre = cosineSimilarity(target.genres, other.genres);
    final tag = cosineSimilarity(target.tags, other.tags);
    final album = cosineSimilarity(target.albums, other.albums);
    final coListen = jaccardSimilarity(
      target.coListenedArtists,
      other.coListenedArtists,
    );
    final playlist = jaccardSimilarity(target.playlistIds, other.playlistIds);

    final w = weights;
    final raw =
        w.genre * genre +
        w.tag * tag +
        w.coListen * coListen +
        w.playlist * playlist +
        w.album * album;
    final totalWeight =
        w.genre + w.tag + w.coListen + w.playlist + w.album;
    final score = totalWeight <= 0 ? 0.0 : clamp01(raw / totalWeight);

    return ArtistSimilarity(
      artistKey: other.key,
      label: other.label,
      score: score,
      genreOverlap: genre,
      tagOverlap: tag,
      coListenOverlap: coListen,
      playlistOverlap: playlist,
      albumOverlap: album,
      imageUrl: other.imageUrl,
      providerId: other.providerId,
    );
  }

  /// Ranks [pool] against [target], best first.
  ///
  /// [target] itself and any key in [exclude] are dropped. Candidates with no
  /// grounded signal are dropped too — an empty taxonomy must not produce a
  /// fake "similar artist".
  List<ArtistSimilarity> rank({
    required ArtistVector target,
    required Iterable<ArtistVector> pool,
    Set<String> exclude = const <String>{},
    int limit = 20,
    double minScore = 0.02,
  }) {
    final results = <ArtistSimilarity>[];
    for (final candidate in pool) {
      if (candidate.key == target.key) continue;
      if (exclude.contains(candidate.key)) continue;
      final similarity = compare(target, candidate);
      if (!similarity.isGrounded) continue;
      if (similarity.score < minScore) continue;
      results.add(similarity);
    }
    results.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.label.toLowerCase().compareTo(b.label.toLowerCase());
    });
    if (limit > 0 && results.length > limit) {
      return List<ArtistSimilarity>.unmodifiable(results.sublist(0, limit));
    }
    return List<ArtistSimilarity>.unmodifiable(results);
  }

  /// Track-level similarity: taxonomy cosine blended with artist/album match.
  ///
  /// Used by Track Radio and by "more like this" on the player.
  double trackSimilarity(DiscoveryTrack a, DiscoveryTrack b) {
    if (a.key == b.key) return 1;
    final taxonomy = cosineSimilarity(
      _taxonomyVector(a),
      _taxonomyVector(b),
    );
    final sameArtist =
        a.artistKey.isNotEmpty && a.artistKey == b.artistKey ? 1.0 : 0.0;
    final sameAlbum =
        a.albumKey.isNotEmpty && a.albumKey == b.albumKey ? 1.0 : 0.0;
    // Same-artist is a strong but not conclusive signal (a deep cut can be
    // nothing like the hit), so it lifts rather than decides.
    return clamp01(0.62 * taxonomy + 0.26 * sameArtist + 0.12 * sameAlbum);
  }

  Map<String, double> _taxonomyVector(DiscoveryTrack track) {
    final vector = <String, double>{};
    for (final genre in track.genres) {
      vector['g:$genre'] = 1.0;
    }
    for (final tag in track.tags) {
      vector['t:$tag'] = 0.7;
    }
    return vector;
  }

  /// Genre-overlap between a candidate and the user's taste profile.
  ///
  /// Weighted by the profile so a candidate matching the user's *strongest*
  /// genre outranks one matching three niche ones.
  double genreAffinityScore(
    DiscoveryTrack track,
    Map<String, double> profileGenres,
  ) {
    if (track.genres.isEmpty || profileGenres.isEmpty) return 0;
    final candidate = <String, double>{
      for (final genre in track.genres) genre: 1.0,
    };
    // Peak-normalised profile keeps the comparison scale-free.
    return cosineSimilarity(candidate, peakNormalise(profileGenres));
  }

  /// Tag-overlap against the profile (same maths, softer weight).
  double tagAffinityScore(
    DiscoveryTrack track,
    Map<String, double> profileTags,
  ) {
    if (track.tags.isEmpty || profileTags.isEmpty) return 0;
    final candidate = <String, double>{for (final tag in track.tags) tag: 1.0};
    return cosineSimilarity(candidate, peakNormalise(profileTags));
  }
}

// ---------------------------------------------------------------------------
// Co-listen graph
// ---------------------------------------------------------------------------

/// One observed play, the minimum the co-listen graph needs.
class CoListenEvent {
  const CoListenEvent({
    required this.artistKey,
    required this.at,
    this.trackKey = '',
  });

  final String artistKey;
  final DateTime at;
  final String trackKey;
}

/// Builds `artist → artists heard in the same session` adjacency.
///
/// A *session* is a run of plays where consecutive plays are at most
/// [sessionGap] apart. Two artists that only ever appear in different sessions
/// get no edge, which is what keeps the co-listen signal meaningful: it
/// captures "you actually listen to these together", not "both exist in your
/// library".
///
/// Edges are capped at [maxEdgesPerArtist] (highest co-occurrence first) so a
/// heavy user's graph stays bounded in memory.
Map<String, Set<String>> buildCoListenGraph(
  Iterable<CoListenEvent> events, {
  Duration sessionGap = const Duration(minutes: 30),
  int maxEdgesPerArtist = 24,
}) {
  final ordered = events
      .where((event) => event.artistKey.isNotEmpty)
      .toList()
    ..sort((a, b) => a.at.compareTo(b.at));

  final sessions = <List<CoListenEvent>>[];
  var current = <CoListenEvent>[];
  DateTime? previous;
  for (final event in ordered) {
    if (previous != null &&
        event.at.difference(previous) > sessionGap) {
      sessions.add(current);
      current = <CoListenEvent>[];
    }
    current.add(event);
    previous = event.at;
  }
  if (current.isNotEmpty) sessions.add(current);

  final counts = <String, Map<String, int>>{};
  for (final session in sessions) {
    final artists = <String>{
      for (final event in session) event.artistKey,
    };
    if (artists.length < 2) continue;
    final list = artists.toList()..sort();
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        _bump(counts, list[i], list[j]);
        _bump(counts, list[j], list[i]);
      }
    }
  }

  final graph = <String, Set<String>>{};
  for (final entry in counts.entries) {
    final ranked = entry.value.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.compareTo(a.value);
        if (byCount != 0) return byCount;
        return a.key.compareTo(b.key);
      });
    final capped = ranked.length > maxEdgesPerArtist
        ? ranked.sublist(0, maxEdgesPerArtist)
        : ranked;
    graph[entry.key] = Set<String>.unmodifiable(
      capped.map((entry) => entry.key),
    );
  }
  return Map<String, Set<String>>.unmodifiable(graph);
}

void _bump(
  Map<String, Map<String, int>> counts,
  String from,
  String to,
) {
  final bucket = counts.putIfAbsent(from, () => <String, int>{});
  bucket[to] = (bucket[to] ?? 0) + 1;
}

/// Co-listen similarity of [candidateArtistKey] against a set of seed artists,
/// normalised by the strongest seed edge (0..1).
double coListenScore(
  String candidateArtistKey,
  Map<String, double> seedWeights,
  Map<String, Set<String>> coListenGraph,
) {
  if (candidateArtistKey.isEmpty || seedWeights.isEmpty) return 0;
  var weighted = 0.0;
  var totalWeight = 0.0;
  for (final seed in seedWeights.entries) {
    totalWeight += seed.value;
    final neighbours = coListenGraph[seed.key];
    if (neighbours == null) continue;
    if (neighbours.contains(candidateArtistKey)) {
      weighted += seed.value;
    }
  }
  return totalWeight <= 0 ? 0 : clamp01(weighted / totalWeight);
}
