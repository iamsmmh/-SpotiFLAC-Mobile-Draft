/// The recommendation engine (Phase 2 + Phase 11 `RecommendationEngine`).
///
/// Pure orchestration over the pure engines: it takes a candidate pool, a
/// listening profile and a clock, and produces ranked shelves. It owns no
/// state and performs no I/O — the repository layer supplies everything and
/// the cache layer stores the result.
///
/// Swappable for a future on-device model: [RecommendationEngine] is the only
/// thing the generators talk to, so replacing `scorer` with an inference
/// wrapper (TFLite/CoreML) changes nothing upstream. That is the whole point
/// of the seam.
library;

import 'dart:math' as math;

import 'package:spotiflac_android/ecosystem/discovery/recommendation_repository.dart';
import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/recommendation_scorer.dart';
import 'package:spotiflac_android/engine/discovery/similarity_engine.dart';

/// Everything a generation pass needs, assembled once and reused.
class RecommendationContext {
  RecommendationContext({
    required this.pool,
    required this.profile,
    required this.now,
    required this.artistVectors,
    required this.coListenGraph,
  }) : _artistAffinity = profile.artistAffinity,
       _genreAffinity = profile.genreAffinity,
       _albumAffinity = profile.albumAffinity,
       _tagAffinity = profile.tagAffinity {
    // Artist affinity restricted to the strongest seeds drives co-listen
    // scoring: a hundred long-tail artists would dilute the signal.
    final seeds = <String, double>{};
    for (final entry in profile.artists.take(12)) {
      seeds[entry.key] = entry.affinity;
    }
    _seedAffinity = Map<String, double>.unmodifiable(seeds);
  }

  final DiscoveryCandidatePool pool;
  final ListeningProfile profile;
  final DateTime now;
  final List<ArtistVector> artistVectors;
  final Map<String, Set<String>> coListenGraph;

  final Map<String, double> _artistAffinity;
  final Map<String, double> _genreAffinity;
  final Map<String, double> _albumAffinity;
  final Map<String, double> _tagAffinity;

  late final Map<String, double> _seedAffinity;

  Map<String, double> get artistAffinity => _artistAffinity;
  Map<String, double> get genreAffinity => _genreAffinity;
  Map<String, double> get albumAffinity => _albumAffinity;
  Map<String, double> get tagAffinity => _tagAffinity;
  Map<String, double> get seedAffinity => _seedAffinity;

  bool get isCold => profile.isCold;

  TrackSignals? signalsFor(DiscoveryTrack track) => pool.signals[track.key];
}

/// Ranked output plus the evidence behind it.
class RecommendationResult {
  const RecommendationResult({
    required this.items,
    required this.computeMs,
    this.candidateCount = 0,
  });

  final List<ScoredTrack> items;

  /// Wall-clock cost of the pass — recorded in the cache row so the
  /// performance budget (Phase 12) is observable, not assumed.
  final int computeMs;

  final int candidateCount;

  bool get isEmpty => items.isEmpty;
}

/// Ranks candidates. Stateless; construct once and reuse.
class RecommendationEngine {
  const RecommendationEngine({
    this.scorer = standardScorer,
    this.discoveryScorerInstance = discoveryScorer,
    this.replayScorerInstance = replayScorer,
    this.similarity = const SimilarityEngine(),
    this.artistSimilarityLimit = 24,
    this.newReleaseWindowDays = 90,
  });

  final RecommendationScorer scorer;

  /// Weights for shelves whose job is finding new music.
  final RecommendationScorer discoveryScorerInstance;

  /// Weights for shelves whose job is replaying loved music.
  final RecommendationScorer replayScorerInstance;

  final SimilarityEngine similarity;

  /// How many similar artists are kept per seed artist.
  final int artistSimilarityLimit;

  /// A release newer than this counts as "new" for the New Releases shelf.
  final int newReleaseWindowDays;

  // -------------------------------------------------------------------------
  // Similarity
  // -------------------------------------------------------------------------

  /// Builds the artist-similarity map for a context.
  ///
  /// Computed once per refresh and shared by every generator, which is what
  /// keeps a full home-screen rebuild inside the performance budget: without
  /// it each shelf would redo the same O(artists²) comparison.
  Map<String, List<ArtistSimilarity>> artistSimilarityMap(
    RecommendationContext context, {
    int seeds = 12,
  }) {
    final vectors = context.artistVectors;
    if (vectors.length < 2) return const <String, List<ArtistSimilarity>>{};

    final byKey = <String, ArtistVector>{
      for (final vector in vectors) vector.key: vector,
    };
    final result = <String, List<ArtistSimilarity>>{};
    for (final seed in context.profile.artists.take(seeds)) {
      final vector = byKey[seed.key];
      if (vector == null) continue;
      final ranked = similarity.rank(
        target: vector,
        pool: vectors,
        limit: artistSimilarityLimit,
      );
      if (ranked.isEmpty) continue;
      result[seed.key] = ranked;
    }
    return Map<String, List<ArtistSimilarity>>.unmodifiable(result);
  }

  /// Similar artists for one specific artist (the artist-screen section).
  List<ArtistSimilarity> similarArtists(
    RecommendationContext context,
    String artistKey, {
    int limit = 12,
  }) {
    final byKey = <String, ArtistVector>{
      for (final vector in context.artistVectors) vector.key: vector,
    };
    final target = byKey[artistKey];
    if (target == null) return const <ArtistSimilarity>[];
    return similarity.rank(
      target: target,
      pool: context.artistVectors,
      limit: limit,
    );
  }

  /// Most representative tracks of one artist, best first.
  ///
  /// Ranked by the user's own signals when they exist (their favourite deep
  /// cut is the better introduction than the album opener) and by track
  /// position otherwise.
  List<ScoredTrack> topTracksForArtist(
    RecommendationContext context,
    String artistKey, {
    int limit = 5,
  }) {
    final tracks = context.pool.tracksByArtist(artistKey);
    if (tracks.isEmpty) return const <ScoredTrack>[];
    final scored = replayScorerInstance.scoreAll(
      tracks.map(
        (track) => ScoringInput(
          track: track,
          signals: context.pool.signals[track.key],
          offlinePlayable: track.isOfflinePlayable,
        ),
      ),
      now: context.now,
      limit: limit,
    );
    return scored;
  }

  /// Albums worth surfacing for one artist: those the user actually plays,
  /// strongest first.
  List<AlbumSuggestion> recommendedAlbums(
    RecommendationContext context,
    String artistKey, {
    int limit = 4,
  }) {
    final tracks = context.pool.tracksByArtist(artistKey);
    if (tracks.isEmpty) return const <AlbumSuggestion>[];
    final weight = <String, double>{};
    final label = <String, String>{};
    final cover = <String, String>{};
    for (final track in tracks) {
      if (track.albumKey.isEmpty) continue;
      final plays = context.pool.signals[track.key]?.playCount ?? 1;
      weight[track.albumKey] = (weight[track.albumKey] ?? 0) + plays;
      label.putIfAbsent(track.albumKey, () => track.album);
      final existing = cover[track.albumKey];
      if (existing == null || existing.isEmpty) {
        final trackCover = track.coverUrl;
        if (trackCover != null && trackCover.isNotEmpty) {
          cover[track.albumKey] = trackCover;
        }
      }
    }
    final ranked = weight.entries.toList()
      ..sort((a, b) {
        final byWeight = b.value.compareTo(a.value);
        if (byWeight != 0) return byWeight;
        return a.key.compareTo(b.key);
      });
    return List<AlbumSuggestion>.unmodifiable(<AlbumSuggestion>[
      for (final entry in ranked.take(limit))
        AlbumSuggestion(
          albumKey: entry.key,
          label: label[entry.key] ?? entry.key,
          coverUrl: cover[entry.key],
          playCount: entry.value.round(),
        ),
    ]);
  }

  // -------------------------------------------------------------------------
  // Scoring
  // -------------------------------------------------------------------------

  /// Builds the [ScoringInput] for one candidate against the profile.
  ///
  /// [similarArtistKeys] carries the pre-computed similarity map so the
  /// artist axis does not re-run the vector maths per candidate.
  ScoringInput inputFor(
    DiscoveryTrack track,
    RecommendationContext context, {
    Map<String, double> similarArtistScores = const <String, double>{},
    double novelty = 0,
  }) {
    final signals = context.pool.signals[track.key];

    final genreScore = similarity.genreAffinityScore(
      track,
      context.genreAffinity,
    );
    final tagScore = similarity.tagAffinityScore(track, context.tagAffinity);

    // Artist axis: explicit taste first, then the similarity map (a neighbour
    // of a loved artist inherits part of its score).
    final directArtist =
        track.artistKey.isEmpty ? 0.0 : (context.artistAffinity[track.artistKey] ?? 0);
    final similarArtist =
        track.artistKey.isEmpty ? 0.0 : (similarArtistScores[track.artistKey] ?? 0);
    final artistScore = clamp01(math.max(directArtist, similarArtist * 0.85));

    final albumScore = track.albumKey.isEmpty
        ? 0.0
        : clamp01(context.albumAffinity[track.albumKey] ?? 0);

    final coListen = coListenScore(
      track.artistKey,
      context.seedAffinity,
      context.coListenGraph,
    );

    final playlistIds =
        context.pool.playlistIdsByTrackKey[track.key] ?? const <String>{};
    final playlistScore = playlistIds.isEmpty
        ? 0.0
        : clamp01(playlistIds.length / 3.0);

    final isFavoriteArtist =
        track.artistKey.isNotEmpty &&
        context.pool.favoriteArtistKeys.contains(track.artistKey);
    final isFavoriteAlbum =
        track.albumKey.isNotEmpty &&
        context.pool.favoriteAlbumKeys.contains(track.albumKey);

    // Taste recency: when was the matching artist/genre last active? Used for
    // the recency axis so a brand-new track by a loved artist still scores as
    // "recent taste" even though the track itself has never been played.
    DateTime? tasteActivity;
    for (final entry in context.profile.artists) {
      if (entry.key == track.artistKey) {
        tasteActivity = entry.lastPlayedAt;
        break;
      }
    }

    return ScoringInput(
      track: track,
      signals: signals,
      genreSimilarity: genreScore,
      artistSimilarity: artistScore,
      albumSimilarity: albumScore,
      tagSimilarity: tagScore,
      coListenSimilarity: coListen,
      playlistSimilarity: playlistScore,
      isFavoriteArtist: isFavoriteArtist,
      isFavoriteAlbum: isFavoriteAlbum,
      novelty: novelty,
      offlinePlayable: track.isOfflinePlayable,
      lastTasteActivity: tasteActivity,
    );
  }

  /// The "Recommended For You" shelf.
  ///
  /// Candidates are pre-filtered by a cheap affinity bound before the scorer
  /// runs, so a large library does not turn into a large pass.
  RecommendationResult recommendForYou(
    RecommendationContext context, {
    int limit = 30,
    int candidateCap = 900,
    Set<String> exclude = const <String>{},
    bool unseenOnly = true,
    Map<String, List<ArtistSimilarity>> similarityMap =
        const <String, List<ArtistSimilarity>>{},
  }) {
    final stopwatch = Stopwatch()..start();
    final similarArtistScores = _flattenSimilarity(similarityMap);

    final candidates = _prefilter(
      context,
      exclude: exclude,
      unseenOnly: unseenOnly,
      similarArtistScores: similarArtistScores,
      cap: candidateCap,
    );

    final items = scorer.scoreAll(
      candidates.map(
        (track) => inputFor(
          track,
          context,
          similarArtistScores: similarArtistScores,
          novelty: context.pool.signals[track.key] == null ? 0.5 : 0,
        ),
      ),
      now: context.now,
      limit: limit,
    );

    stopwatch.stop();
    return RecommendationResult(
      items: items,
      computeMs: stopwatch.elapsedMilliseconds,
      candidateCount: candidates.length,
    );
  }

  /// Recently played, newest first — the shelf the home screen shows first.
  List<ScoredTrack> recentlyPlayed(
    RecommendationContext context, {
    int limit = 20,
  }) {
    final signals = context.pool.signals.values.toList()
      ..sort((a, b) => b.lastPlayedAt.compareTo(a.lastPlayedAt));
    final items = <ScoredTrack>[];
    for (final signal in signals) {
      if (items.length >= limit) break;
      final track = context.pool.track(signal.trackKey);
      if (track == null) continue;
      final scored = replayScorerInstance.score(
        ScoringInput(
          track: track,
          signals: signal,
          offlinePlayable: track.isOfflinePlayable,
        ),
        now: context.now,
      );
      items.add(scored);
    }
    return List<ScoredTrack>.unmodifiable(items);
  }

  /// Most played overall.
  List<ScoredTrack> mostPlayed(
    RecommendationContext context, {
    int limit = 20,
  }) {
    final signals = context.pool.signals.values.toList()
      ..sort((a, b) {
        final byPlays = b.playCount.compareTo(a.playCount);
        if (byPlays != 0) return byPlays;
        return b.listenedMs.compareTo(a.listenedMs);
      });
    final items = <ScoredTrack>[];
    for (final signal in signals) {
      if (items.length >= limit) break;
      final track = context.pool.track(signal.trackKey);
      if (track == null) continue;
      items.add(
        replayScorerInstance.score(
          ScoringInput(
            track: track,
            signals: signal,
            offlinePlayable: track.isOfflinePlayable,
          ),
          now: context.now,
        ),
      );
    }
    return List<ScoredTrack>.unmodifiable(items);
  }

  /// Tracks released inside [newReleaseWindowDays], newest first, ranked by
  /// how well they match the profile.
  ///
  /// Honest scope: "new" means new *to this library's metadata*. There is no
  /// editorial new-release feed to fetch, so a library whose tags carry no
  /// release dates yields an empty shelf rather than a fabricated one.
  RecommendationResult newReleases(
    RecommendationContext context, {
    int limit = 20,
    Set<String> exclude = const <String>{},
  }) {
    final stopwatch = Stopwatch()..start();
    final cutoff = context.now.subtract(Duration(days: newReleaseWindowDays));
    final candidates = context.pool.tracks
        .where((track) {
          if (exclude.contains(track.key)) return false;
          final released = track.releaseDate;
          if (released == null) return false;
          return released.isAfter(cutoff);
        })
        .toList();

    final items = discoveryScorerInstance.scoreAll(
      candidates.map(
        (track) => inputFor(
          track,
          context,
          novelty: context.pool.signals[track.key] == null ? 0.8 : 0.3,
        ),
      ),
      now: context.now,
      limit: limit,
    );
    stopwatch.stop();
    return RecommendationResult(
      items: items,
      computeMs: stopwatch.elapsedMilliseconds,
      candidateCount: candidates.length,
    );
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  /// `artistKey → best similarity score` across every seed's neighbour list.
  Map<String, double> _flattenSimilarity(
    Map<String, List<ArtistSimilarity>> similarityMap,
  ) {
    if (similarityMap.isEmpty) return const <String, double>{};
    final flat = <String, double>{};
    for (final neighbours in similarityMap.values) {
      for (final neighbour in neighbours) {
        final existing = flat[neighbour.artistKey];
        if (existing == null || neighbour.score > existing) {
          flat[neighbour.artistKey] = neighbour.score;
        }
      }
    }
    return Map<String, double>.unmodifiable(flat);
  }

  /// Cheap candidate selection: keep tracks with *some* affinity signal, plus
  /// a deterministic slice of the rest so genuinely new music can surface.
  List<DiscoveryTrack> _prefilter(
    RecommendationContext context, {
    required Set<String> exclude,
    required bool unseenOnly,
    required Map<String, double> similarArtistScores,
    required int cap,
  }) {
    final all = context.pool.tracks;
    if (all.length <= cap) {
      return all.where((track) => _eligible(track, exclude, unseenOnly, context))
          .toList(growable: false);
    }

    final scored = <_PrefilterRow>[];
    for (final track in all) {
      if (!_eligible(track, exclude, unseenOnly, context)) continue;
      scored.add(_PrefilterRow(track, _cheapAffinity(track, context, similarArtistScores)));
    }
    scored.sort((a, b) {
      final byScore = b.affinity.compareTo(a.affinity);
      if (byScore != 0) return byScore;
      return a.track.key.compareTo(b.track.key);
    });
    return scored.take(cap).map((row) => row.track).toList(growable: false);
  }

  bool _eligible(
    DiscoveryTrack track,
    Set<String> exclude,
    bool unseenOnly,
    RecommendationContext context,
  ) {
    if (exclude.contains(track.key)) return false;
    if (unseenOnly && context.pool.signals.containsKey(track.key)) return false;
    return track.title.isNotEmpty;
  }

  double _cheapAffinity(
    DiscoveryTrack track,
    RecommendationContext context,
    Map<String, double> similarArtistScores,
  ) {
    var score = 0.0;
    if (track.artistKey.isNotEmpty) {
      score += (context.artistAffinity[track.artistKey] ?? 0) * 1.0;
      score += (similarArtistScores[track.artistKey] ?? 0) * 0.8;
    }
    for (final genre in track.genres) {
      score += (context.genreAffinity[genre] ?? 0) * 0.6;
    }
    if (track.albumKey.isNotEmpty) {
      score += (context.albumAffinity[track.albumKey] ?? 0) * 0.4;
    }
    if (track.isFavorite) score += 0.5;
    if (track.isOfflinePlayable) score += 0.1;
    return score;
  }
}

class _PrefilterRow {
  const _PrefilterRow(this.track, this.affinity);
  final DiscoveryTrack track;
  final double affinity;
}

/// One album surfaced under a similar artist.
class AlbumSuggestion {
  const AlbumSuggestion({
    required this.albumKey,
    required this.label,
    this.coverUrl,
    this.playCount = 0,
  });

  final String albumKey;
  final String label;
  final String? coverUrl;
  final int playCount;
}
