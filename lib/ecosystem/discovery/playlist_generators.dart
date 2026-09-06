/// Generated-playlist engines: Discover Weekly, Daily Mixes, mood shelves
/// (Phases 3, 4 and 5).
///
/// All three are pure functions over a [RecommendationContext] plus an
/// explicit `now`. They never touch SQLite, so the cache layer can decide when
/// to persist and the UI can call them synchronously on a stale context if it
/// has to. Determinism is a hard requirement: the same context and the same
/// week/day key always produce the same playlist, otherwise a shelf would
/// reshuffle every time the user scrolled away and back.
library;

import 'dart:math' as math;

import 'package:spotiflac_android/ecosystem/discovery/recommendation_engine.dart';
import 'package:spotiflac_android/ecosystem/discovery/recommendation_repository.dart';
import 'package:spotiflac_android/engine/discovery/cluster_engine.dart';
import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/mood_engine.dart';
import 'package:spotiflac_android/engine/discovery/recommendation_scorer.dart';
import 'package:spotiflac_android/engine/discovery/similarity_engine.dart';

// ===========================================================================
// Discover Weekly (Phase 3)
// ===========================================================================

/// Stable id for the Discover Weekly shelf.
const String discoverWeeklyShelfId = 'discover-weekly';

/// Weekly discovery generator.
class DiscoverWeeklyGenerator {
  const DiscoverWeeklyGenerator({
    this.engine = const RecommendationEngine(),
    this.minTracks = 30,
    this.maxTracks = 50,
    this.excludeRecentDays = 14,
    this.hiddenGemQuota = 8,
    this.newReleaseQuota = 6,
    this.seedArtistCount = 8,
    this.candidateCap = 1500,
  });

  final RecommendationEngine engine;

  /// Hard floor / ceiling for the shelf length.
  final int minTracks;
  final int maxTracks;

  /// Tracks played inside this window never appear.
  final int excludeRecentDays;

  /// Slots reserved for low-play, high-similarity finds.
  final int hiddenGemQuota;

  /// Slots reserved for tracks released inside the last 90 days.
  final int newReleaseQuota;

  /// How many of the user's top artists seed the week.
  final int seedArtistCount;

  /// Candidate window before scoring — bounds the cost on big libraries.
  final int candidateCap;

  /// The ISO week this generation belongs to. Refreshes on Monday by
  /// construction: [startOfWeek] is Monday 00:00 UTC.
  String weekKey(DateTime now) => isoWeekKey(now);

  DateTime weekStart(DateTime now) => startOfWeek(now);

  /// Expiry: the following Monday.
  DateTime weekExpiry(DateTime now) =>
      startOfWeek(now).add(const Duration(days: 7));

  /// True when the cached shelf for [now]'s week is missing or stale.
  bool needsRefresh({DateTime? cachedGeneratedAt, required DateTime now}) {
    if (cachedGeneratedAt == null) return true;
    return cachedGeneratedAt.isBefore(weekStart(now));
  }

  /// Generates the shelf.
  ///
  /// The playlist is a deliberate mix rather than a flat top-N: roughly
  /// `hiddenGemQuota` deep cuts, `newReleaseQuota` fresh releases and the rest
  /// filled by the strongest similarity matches. Quotas are *targets*, not
  /// guarantees — when the library cannot supply a category the remaining
  /// slots go to the best available track instead of being left empty.
  GeneratedShelf generate(
    RecommendationContext context, {
    Map<String, List<ArtistSimilarity>>? similarityMap,
    DateTime? now,
  }) {
    final at = now ?? context.now;
    final stopwatch = Stopwatch()..start();
    final map = similarityMap ?? engine.artistSimilarityMap(context);

    final recentlyPlayed = _recentlyPlayedKeys(context, at);
    final exclude = <String>{...recentlyPlayed};

    // Seeds: the user's strongest artists, plus any similar artist that is
    // itself strongly connected (that is what widens the week beyond the
    // obvious).
    final seedKeys = <String>{
      for (final entry in context.profile.artists.take(seedArtistCount))
        entry.key,
    };
    final similarArtistScores = <String, double>{};
    for (final entry in map.entries) {
      if (!seedKeys.contains(entry.key)) continue;
      for (final neighbour in entry.value) {
        final existing = similarArtistScores[neighbour.artistKey];
        final score = neighbour.score * 0.9;
        if (existing == null || score > existing) {
          similarArtistScores[neighbour.artistKey] = score;
        }
      }
    }

    final candidates = <DiscoveryTrack>[];
    final seen = <String>{};
    final seedArtists = context.profile.artists.take(seedArtistCount).toList();
    for (final entry in seedArtists) {
      for (final neighbour in map[entry.key] ?? const <ArtistSimilarity>[]) {
        for (final track in context.pool.tracksByArtist(neighbour.artistKey)) {
          if (exclude.contains(track.key) || !seen.add(track.key)) continue;
          candidates.add(track);
        }
      }
    }
    // Genre neighbours fill in when the artist graph is thin (a new user, or
    // a library whose artists rarely co-occur).
    final topGenres = context.profile.genres.take(6).map((e) => e.key);
    for (final track in context.pool.tracksInGenres(topGenres)) {
      if (exclude.contains(track.key) || !seen.add(track.key)) continue;
      candidates.add(track);
    }

    final bounded = candidates.length > candidateCap
        ? _deterministicSlice(candidates, candidateCap, at)
        : candidates;

    final scored = const RecommendationScorer(
      weights: RecommendationWeights.discovery(),
      noveltyBoost: 10,
      sourceId: 'discover-weekly',
    ).scoreAll(
      bounded.map(
        (track) => engine.inputFor(
          track,
          context,
          similarArtistScores: similarArtistScores,
          novelty: _noveltyFor(track, context, at),
        ),
      ),
      now: at,
    );

    final items = _compose(scored, context, at);
    stopwatch.stop();

    return GeneratedShelf(
      id: discoverWeeklyShelfId,
      title: 'Discover Weekly',
      subtitle: _subtitle(context, items.length),
      items: items,
      generatedAt: at,
      expiresAt: weekExpiry(at),
      seedLabels: seedArtists
          .map((entry) => entry.label)
          .take(4)
          .toList(growable: false),
      accentSeed: seedArtists.isEmpty ? null : seedArtists.first.label,
    );
  }

  /// Applies the quotas: hidden gems first, then new releases, then the rest
  /// by score, with a final deterministic interleave so the shelf does not
  /// read as three visibly separate blocks.
  List<ScoredTrack> _compose(
    List<ScoredTrack> scored,
    RecommendationContext context,
    DateTime now,
  ) {
    final gems = <ScoredTrack>[];
    final fresh = <ScoredTrack>[];
    final rest = <ScoredTrack>[];
    final cutoff = now.subtract(const Duration(days: 90));

    for (final entry in scored) {
      final signals = context.pool.signals[entry.track.key];
      final released = entry.track.releaseDate;
      final isNew = released != null && released.isAfter(cutoff);
      final isGem =
          (signals == null || signals.playCount <= 2) &&
          entry.breakdown.similarity > 0.12;
      if (isGem && gems.length < hiddenGemQuota * 3) {
        gems.add(entry);
      } else if (isNew && fresh.length < newReleaseQuota * 3) {
        fresh.add(entry);
      } else {
        rest.add(entry);
      }
    }

    final selected = <ScoredTrack>[];
    final used = <String>{};
    void take(List<ScoredTrack> source, int quota) {
      var taken = 0;
      for (final entry in source) {
        if (taken >= quota) break;
        if (!used.add(entry.track.key)) continue;
        selected.add(entry);
        taken++;
      }
    }

    take(gems, hiddenGemQuota);
    take(fresh, newReleaseQuota);
    take(rest, maxTracks - selected.length);
    // Still short: spend the gem and fresh reserves before giving up, so a
    // small library still gets a full-length playlist.
    if (selected.length < minTracks) take(gems, gems.length);
    if (selected.length < minTracks) take(fresh, fresh.length);

    final capped = selected.length > maxTracks
        ? selected.sublist(0, maxTracks)
        : selected;

    // Interleave on the ISO-week seed: stable for the week, different next
    // Monday, and never a strict score order (which would put every deep cut
    // at the bottom).
    final seed = fnv1a(weekKey(now));
    final shuffled = seededShuffle(capped, seed);
    // Keep a strong opener — the first track is the one that decides whether
    // the shelf feels good.
    if (shuffled.length > 1) {
      var bestIndex = 0;
      for (var i = 1; i < math.min(shuffled.length, 6); i++) {
        if (shuffled[i].score > shuffled[bestIndex].score) bestIndex = i;
      }
      final best = shuffled.removeAt(bestIndex);
      shuffled.insert(0, best);
    }
    return List<ScoredTrack>.unmodifiable(shuffled);
  }

  /// Keys played inside [excludeRecentDays], so the week never repeats what
  /// the user just heard.
  Set<String> _recentlyPlayedKeys(RecommendationContext context, DateTime now) {
    final cutoff = now.subtract(Duration(days: excludeRecentDays));
    return <String>{
      for (final signal in context.pool.signals.values)
        if (signal.lastPlayedAt.isAfter(cutoff)) signal.trackKey,
    };
  }

  double _noveltyFor(
    DiscoveryTrack track,
    RecommendationContext context,
    DateTime now,
  ) {
    final signals = context.pool.signals[track.key];
    if (signals == null) return 0.8;
    final released = track.releaseDate;
    if (released != null &&
        released.isAfter(now.subtract(const Duration(days: 90)))) {
      return 0.7;
    }
    return 0.3;
  }

  String _subtitle(RecommendationContext context, int count) {
    if (context.profile.artists.isEmpty) return '$count fresh picks';
    final seed = context.profile.artists.first.label;
    return '$count picks based on $seed';
  }

  List<DiscoveryTrack> _deterministicSlice(
    List<DiscoveryTrack> source,
    int limit,
    DateTime now,
  ) {
    return seededShuffle(source, fnv1a(weekKey(now))).take(limit).toList();
  }
}

// ===========================================================================
// Daily Mixes (Phase 4)
// ===========================================================================

/// Cache-key prefix for the five mixes.
const String dailyMixIdPrefix = 'daily-mix';

/// Daily mix generator.
class DailyMixGenerator {
  const DailyMixGenerator({
    this.clustering = const GenreClusterEngine(),
    this.engine = const RecommendationEngine(),
    this.mixCount = 5,
    this.tracksPerMix = 30,
    this.maxPerArtistPerMix = 3,
    this.favoriteShare = 0.3,
    this.discoveryShare = 0.35,
    this.lesserPlayedShare = 0.35,
    this.candidateCap = 800,
  });

  final GenreClusterEngine clustering;
  final RecommendationEngine engine;

  /// Daily Mix 1..5.
  final int mixCount;
  final int tracksPerMix;

  /// Diversity guard inside one mix.
  final int maxPerArtistPerMix;

  /// Rough composition of each mix. Shares are targets, not guarantees: when
  /// a bucket runs dry the others absorb the slots.
  final double favoriteShare;
  final double discoveryShare;
  final double lesserPlayedShare;

  final int candidateCap;

  String mixId(int position) => '$dailyMixIdPrefix-${position + 1}';

  /// True when the mixes were generated for a different UTC day.
  bool needsRefresh({DateTime? cachedGeneratedAt, required DateTime now}) {
    if (cachedGeneratedAt == null) return true;
    return dayKey(cachedGeneratedAt) != dayKey(now);
  }

  /// Generates up to [mixCount] mixes.
  ///
  /// A user whose taste is narrower than five clusters gets fewer mixes rather
  /// than five near-identical ones — an honest three is better than a padded
  /// five.
  List<GeneratedShelf> generate(
    RecommendationContext context, {
    DateTime? now,
  }) {
    final at = now ?? context.now;
    if (context.isCold || context.pool.isEmpty) {
      return const <GeneratedShelf>[];
    }

    final artists = <ClusterArtist>[];
    for (final entry in context.pool.byArtist.entries) {
      final tracks = entry.value;
      if (tracks.isEmpty) continue;
      final genres = <String, double>{};
      var plays = 0;
      for (final track in tracks) {
        final weight = (context.pool.signals[track.key]?.playCount ?? 1).toDouble();
        plays += weight.round();
        for (final genre in track.genres) {
          genres[genre] = (genres[genre] ?? 0) + weight;
        }
      }
      if (genres.isEmpty) continue;
      artists.add(
        ClusterArtist(
          key: entry.key,
          label: tracks.first.artist,
          genres: peakNormalise(genres),
          affinity: context.artistAffinity[entry.key] ?? 0,
          playCount: plays,
        ),
      );
    }
    if (artists.isEmpty) return const <GeneratedShelf>[];

    final clusters = clustering.cluster(
      artists,
      count: mixCount,
      seed: fnv1a('daily-mix:${dayKey(at)}'),
    );
    if (clusters.isEmpty) return const <GeneratedShelf>[];

    return List<GeneratedShelf>.unmodifiable(<GeneratedShelf>[
      for (final cluster in clusters)
        _buildMix(cluster, context, at, position: cluster.index),
    ]);
  }

  GeneratedShelf _buildMix(
    GenreCluster cluster,
    RecommendationContext context,
    DateTime now, {
    required int position,
  }) {
    final seed = fnv1a('${mixId(position)}:${dayKey(now)}');

    final inCluster = <DiscoveryTrack>[];
    final seen = <String>{};
    for (final artistKey in cluster.artistKeys) {
      for (final track in context.pool.tracksByArtist(artistKey)) {
        if (seen.add(track.key)) inCluster.add(track);
      }
    }
    // Genre neighbours: tracks outside the cluster's artists that still fit
    // its sound. This is the "recommendations" bucket.
    final neighbours = <DiscoveryTrack>[];
    final bounded = inCluster.length > candidateCap
        ? seededShuffle(inCluster, seed).take(candidateCap).toList()
        : inCluster;
    for (final track in context.pool.tracksInGenres(cluster.genres.take(6))) {
      if (seen.add(track.key)) neighbours.add(track);
    }

    final favorites = <ScoredTrack>[];
    final lesserPlayed = <ScoredTrack>[];
    final core = <ScoredTrack>[];

    final scorer = const RecommendationScorer(
      weights: RecommendationWeights.replay(),
      sourceId: 'daily-mix',
    );
    for (final track in bounded) {
      final signals = context.pool.signals[track.key];
      final scored = scorer.score(
        ScoringInput(
          track: track,
          signals: signals,
          genreSimilarity: _clusterGenreScore(track, cluster),
          offlinePlayable: track.isOfflinePlayable,
        ),
        now: now,
      );
      if (track.isFavorite) {
        favorites.add(scored);
      } else if (signals == null || signals.playCount <= 2) {
        lesserPlayed.add(scored);
      } else {
        core.add(scored);
      }
    }

    final discoveryScorer = const RecommendationScorer(
      weights: RecommendationWeights.discovery(),
      noveltyBoost: 8,
      sourceId: 'daily-mix',
    );
    final discoveries = discoveryScorer.scoreAll(
      neighbours.map(
        (track) => ScoringInput(
          track: track,
          signals: context.pool.signals[track.key],
          genreSimilarity: _clusterGenreScore(track, cluster),
          novelty: context.pool.signals[track.key] == null ? 0.6 : 0.2,
          offlinePlayable: track.isOfflinePlayable,
        ),
      ),
      now: now,
      limit: (tracksPerMix * discoveryShare * 3).round(),
    );

    final favoriteSlots = (tracksPerMix * favoriteShare).round();
    final discoverySlots = (tracksPerMix * discoveryShare).round();
    final lesserSlots = tracksPerMix - favoriteSlots - discoverySlots;

    final selected = <ScoredTrack>[];
    final used = <String>{};
    void take(List<ScoredTrack> source, int quota) {
      var taken = 0;
      for (final entry in source) {
        if (taken >= quota) break;
        if (!used.add(entry.track.key)) continue;
        selected.add(entry);
        taken++;
      }
    }

    _sortByScore(favorites);
    _sortByScore(core);
    _sortByScore(lesserPlayed);

    take(favorites, favoriteSlots);
    take(lesserPlayed, lesserSlots);
    take(core, tracksPerMix - selected.length);
    take(discoveries, discoverySlots);
    // Absorb any shortfall so the mix is never stubby.
    if (selected.length < tracksPerMix) take(favorites, favorites.length);
    if (selected.length < tracksPerMix) take(lesserPlayed, lesserPlayed.length);
    if (selected.length < tracksPerMix) take(discoveries, discoveries.length);

    final diversified = _diversifyByArtist(selected, seed);
    final capped = diversified.length > tracksPerMix
        ? diversified.sublist(0, tracksPerMix)
        : diversified;

    return GeneratedShelf(
      id: mixId(position),
      title: 'Daily Mix ${position + 1}',
      subtitle: cluster.label,
      items: List<ScoredTrack>.unmodifiable(capped),
      generatedAt: now,
      // Next UTC midnight: the mix is a daily artefact.
      expiresAt: DateTime.utc(now.year, now.month, now.day)
          .add(const Duration(days: 1)),
      seedLabels: cluster.genres.take(3).map(titleCaseToken).toList(growable: false),
      accentSeed: cluster.label,
    );
  }

  double _clusterGenreScore(DiscoveryTrack track, GenreCluster cluster) {
    if (track.genres.isEmpty) return 0;
    return cosineSimilarity(
      <String, double>{for (final genre in track.genres) genre: 1.0},
      cluster.genreWeights,
    );
  }

  /// Enforces [maxPerArtistPerMix] and shuffles deterministically, keeping the
  /// highest-scored track as the opener.
  List<ScoredTrack> _diversifyByArtist(List<ScoredTrack> source, int seed) {
    final shuffled = seededShuffle(source, seed);
    final result = <ScoredTrack>[];
    final counts = <String, int>{};
    for (final entry in shuffled) {
      final artistKey = entry.track.artistKey;
      if (artistKey.isNotEmpty) {
        final count = counts[artistKey] ?? 0;
        if (count >= maxPerArtistPerMix) continue;
        counts[artistKey] = count + 1;
      }
      result.add(entry);
    }
    if (result.length > 1) {
      var bestIndex = 0;
      for (var i = 1; i < math.min(result.length, 6); i++) {
        if (result[i].score > result[bestIndex].score) bestIndex = i;
      }
      final best = result.removeAt(bestIndex);
      result.insert(0, best);
    }
    return result;
  }

  void _sortByScore(List<ScoredTrack> items) {
    items.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.track.title.toLowerCase().compareTo(
        b.track.title.toLowerCase(),
      );
    });
  }
}

// ===========================================================================
// Mood playlists (Phase 5)
// ===========================================================================

/// Mood playlist generator.
class MoodPlaylistGenerator {
  const MoodPlaylistGenerator({
    this.moodEngine = const MoodEngine(),
    this.tracksPerMood = 40,
    this.minTracksPerMood = 12,
  });

  final MoodEngine moodEngine;
  final int tracksPerMood;
  final int minTracksPerMood;

  /// Builds every mood shelf at once — one pass over the pool, not nine.
  Map<Mood, GeneratedShelf> generate(
    RecommendationContext context, {
    DateTime? now,
  }) {
    final at = now ?? context.now;
    if (context.pool.isEmpty) return const <Mood, GeneratedShelf>{};

    final affinity = _behaviourAffinity(context);
    final assigned = moodEngine.assign(
      context.pool.tracks,
      behaviourAffinity: affinity,
      perMood: tracksPerMood,
      minPerMood: minTracksPerMood,
    );

    final scorer = const RecommendationScorer(
      weights: RecommendationWeights.standard(),
      sourceId: 'mood',
    );
    final result = <Mood, GeneratedShelf>{};
    for (final entry in assigned.entries) {
      final tracks = entry.value;
      if (tracks.isEmpty) continue;
      final scored = scorer.scoreAll(
        tracks.map(
          (track) => ScoringInput(
            track: track,
            signals: context.pool.signals[track.key],
            genreSimilarity: moodEngine
                .match(track, entry.key, behaviourAffinity: affinity)
                .score,
            offlinePlayable: track.isOfflinePlayable,
          ),
        ),
        now: at,
      );
      result[entry.key] = GeneratedShelf(
        id: 'mood-${entry.key.name}',
        title: moodProfiles[entry.key]!.label,
        subtitle: _moodSubtitle(entry.key, affinity),
        items: scored,
        generatedAt: at,
        expiresAt: at.add(const Duration(days: 3)),
      );
    }
    return Map<Mood, GeneratedShelf>.unmodifiable(result);
  }

  /// How strongly the user's own listening supports each mood, derived from
  /// the time-of-day buckets they actually listen in.
  Map<Mood, double> _behaviourAffinity(RecommendationContext context) {
    final distribution = context.profile.habits.daytimeDistribution;
    final result = <Mood, double>{};
    for (final mood in allMoods) {
      final profile = moodProfiles[mood]!;
      var share = 0.0;
      for (final bucket in profile.buckets) {
        share += distribution[bucket] ?? 0;
      }
      result[mood] = clamp01(share / math.max(1, profile.buckets.length));
    }
    return Map<Mood, double>.unmodifiable(result);
  }

  String _moodSubtitle(Mood mood, Map<Mood, double> affinity) {
    final profile = moodProfiles[mood]!;
    final strength = affinity[mood] ?? 0;
    if (strength >= 0.6) return 'Matches how you listen';
    return '${profile.bpmMin}–${profile.bpmMax} BPM · ${profile.genres.length} genres';
  }
}
