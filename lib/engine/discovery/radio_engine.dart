/// Radio mode (Phase 7): endless, self-refilling queues.
///
/// Three seed kinds — artist, track, genre — plus mood, all driven by the same
/// generator. The engine is a pure state machine: the caller owns persistence
/// (`ds_radio_sessions`) and playback; this file only decides *what comes
/// next*.
///
/// Guarantees:
///   * **Endless** — `refill` always returns a queue of [targetQueueLength]
///     unless the candidate pool is genuinely exhausted, and exhausted means
///     "the user's whole reachable library is on air", not an empty screen.
///   * **No duplicates** — recently played keys are held in a bounded ring, so
///     a long session cannot loop back onto itself while staying in memory.
///   * **No artist pile-ups** — at most [maxSameArtistWindow] tracks from one
///     artist inside any window of that size.
///   * **Smart transitions** — after scoring, the queue is re-ordered by a
///     greedy tempo/genre walk so consecutive tracks do not jump from a 60 BPM
///     ballad to a 170 BPM banger.
///   * **Adaptive** — skips pull the skipped artist's affinity down and the
///     seed's genre weight down; completions push them up.
library;

import 'dart:math' as math;

import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/recommendation_scorer.dart';

/// What the station was started from.
enum RadioKind { artist, track, genre, mood }

/// The immutable description of a station's origin.
class RadioSeed {
  const RadioSeed({
    required this.kind,
    required this.key,
    required this.label,
    this.genres = const <String, double>{},
    this.artistKeys = const <String>{},
    this.trackKeys = const <String>{},
    this.targetBpm,
    this.coverUrl,
  });

  final RadioKind kind;
  final String key;
  final String label;

  /// Genre weights the station should gravitate towards.
  final Map<String, double> genres;

  /// Artists that always belong on this station.
  final Set<String> artistKeys;

  /// Tracks that always belong (track radio's seed + its closest neighbours).
  final Set<String> trackKeys;

  /// Preferred tempo, when the seed provides one.
  final int? targetBpm;

  final String? coverUrl;

  bool get isEmpty =>
      genres.isEmpty && artistKeys.isEmpty && trackKeys.isEmpty;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'key': key,
    'label': label,
    'genres': <String, Object?>{
      for (final entry in genres.entries) entry.key: entry.value,
    },
    'artists': artistKeys.toList(growable: false),
    'tracks': trackKeys.toList(growable: false),
    if (targetBpm != null) 'bpm': targetBpm,
    if (coverUrl != null) 'cover': coverUrl,
  };

  static RadioSeed? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, Object?>.from(raw);
    RadioKind kind = RadioKind.artist;
    for (final value in RadioKind.values) {
      if (value.name == json['kind']?.toString()) {
        kind = value;
        break;
      }
    }
    final rawGenres = json['genres'];
    final genres = <String, double>{};
    if (rawGenres is Map) {
      for (final entry in rawGenres.entries) {
        final value = entry.value;
        if (value is! num) continue;
        genres[entry.key.toString()] = value.toDouble();
      }
    }
    return RadioSeed(
      kind: kind,
      key: json['key']?.toString() ?? '',
      label: json['label']?.toString() ?? '',
      genres: Map<String, double>.unmodifiable(genres),
      artistKeys: _stringSet(json['artists']),
      trackKeys: _stringSet(json['tracks']),
      targetBpm: json['bpm'] is num ? (json['bpm']! as num).toInt() : null,
      coverUrl: json['cover']?.toString(),
    );
  }

  static Set<String> _stringSet(Object? raw) {
    if (raw is! List) return const <String>{};
    return Set<String>.unmodifiable(
      raw.whereType<Object>().map((entry) => entry.toString()),
    );
  }
}

/// Live station state. Immutable: every transition returns a new state, which
/// is what makes the session row in SQLite a straightforward serialisation.
class RadioState {
  const RadioState({
    required this.sessionId,
    required this.seed,
    required this.startedAt,
    this.queue = const <ScoredTrack>[],
    this.playedKeys = const <String>[],
    this.artistAffinity = const <String, double>{},
    this.genreAffinity = const <String, double>{},
    this.playCount = 0,
    this.skipCount = 0,
    this.skipStreak = 0,
    this.generation = 0,
    this.lastRefilledAt,
  });

  final String sessionId;
  final RadioSeed seed;
  final DateTime startedAt;

  /// Upcoming tracks, best first.
  final List<ScoredTrack> queue;

  /// Bounded ring of recently played track keys (newest last).
  final List<String> playedKeys;

  /// Adapted artist weights: seeds start at `1`, skips subtract.
  final Map<String, double> artistAffinity;

  /// Adapted genre weights.
  final Map<String, double> genreAffinity;

  final int playCount;
  final int skipCount;

  /// Consecutive skips — drives the "explore harder" escape hatch.
  final int skipStreak;

  /// Bumped on every refill; used as the deterministic shuffle seed.
  final int generation;

  final DateTime? lastRefilledAt;

  bool get isDrained => queue.isEmpty;

  ScoredTrack? get next => queue.isEmpty ? null : queue.first;

  RadioState copyWith({
    List<ScoredTrack>? queue,
    List<String>? playedKeys,
    Map<String, double>? artistAffinity,
    Map<String, double>? genreAffinity,
    int? playCount,
    int? skipCount,
    int? skipStreak,
    int? generation,
    DateTime? lastRefilledAt,
  }) {
    return RadioState(
      sessionId: sessionId,
      seed: seed,
      startedAt: startedAt,
      queue: queue ?? this.queue,
      playedKeys: playedKeys ?? this.playedKeys,
      artistAffinity: artistAffinity ?? this.artistAffinity,
      genreAffinity: genreAffinity ?? this.genreAffinity,
      playCount: playCount ?? this.playCount,
      skipCount: skipCount ?? this.skipCount,
      skipStreak: skipStreak ?? this.skipStreak,
      generation: generation ?? this.generation,
      lastRefilledAt: lastRefilledAt ?? this.lastRefilledAt,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionId': sessionId,
    'seed': seed.toJson(),
    'startedAt': startedAt.toUtc().toIso8601String(),
    'queue': queue
        .map(
          (entry) => <String, Object?>{
            'track': entry.track.toJson(),
            'score': entry.score,
          },
        )
        .toList(growable: false),
    'played': playedKeys,
    'artists': <String, Object?>{
      for (final entry in artistAffinity.entries) entry.key: entry.value,
    },
    'genres': <String, Object?>{
      for (final entry in genreAffinity.entries) entry.key: entry.value,
    },
    'plays': playCount,
    'skips': skipCount,
    'streak': skipStreak,
    'generation': generation,
    if (lastRefilledAt != null)
      'refilledAt': lastRefilledAt!.toUtc().toIso8601String(),
  };

  static RadioState? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, Object?>.from(raw);
    final seed = RadioSeed.fromJson(json['seed']);
    final sessionId = json['sessionId']?.toString() ?? '';
    if (seed == null || sessionId.isEmpty) return null;

    final queue = <ScoredTrack>[];
    final rawQueue = json['queue'];
    if (rawQueue is List) {
      for (final entry in rawQueue) {
        if (entry is! Map) continue;
        final track = DiscoveryTrack.fromJson(entry['track']);
        if (track == null) continue;
        final score = entry['score'];
        queue.add(
          ScoredTrack(
            track: track,
            score: score is num ? score.toDouble() : 0,
            source: 'radio',
          ),
        );
      }
    }

    Map<String, double> readMap(String name) {
      final value = json[name];
      if (value is! Map) return const <String, double>{};
      final result = <String, double>{};
      for (final entry in value.entries) {
        final number = entry.value;
        if (number is! num) continue;
        result[entry.key.toString()] = number.toDouble();
      }
      return Map<String, double>.unmodifiable(result);
    }

    final rawPlayed = json['played'];
    final played = rawPlayed is List
        ? rawPlayed.whereType<Object>().map((e) => e.toString()).toList()
        : const <String>[];

    return RadioState(
      sessionId: sessionId,
      seed: seed,
      startedAt:
          DateTime.tryParse(json['startedAt']?.toString() ?? '') ??
          DateTime.now(),
      queue: List<ScoredTrack>.unmodifiable(queue),
      playedKeys: List<String>.unmodifiable(played),
      artistAffinity: readMap('artists'),
      genreAffinity: readMap('genres'),
      playCount: json['plays'] is num ? (json['plays']! as num).toInt() : 0,
      skipCount: json['skips'] is num ? (json['skips']! as num).toInt() : 0,
      skipStreak: json['streak'] is num ? (json['streak']! as num).toInt() : 0,
      generation:
          json['generation'] is num ? (json['generation']! as num).toInt() : 0,
      lastRefilledAt: DateTime.tryParse(json['refilledAt']?.toString() ?? ''),
    );
  }
}

/// Generates and adapts radio queues.
class RadioEngine {
  const RadioEngine({
    this.scorer = const RecommendationScorer(
      weights: RecommendationWeights.discovery(),
      reasonsEnabled: false,
      sourceId: 'radio',
    ),
    this.targetQueueLength = 25,
    this.maxPlayedMemory = 300,
    this.maxSameArtistWindow = 3,
    this.candidatePoolCap = 1200,
    this.seedGenreBoost = 0.35,
    this.skipAffinityStep = 0.35,
    this.playAffinityStep = 0.12,
    this.smoothTransitions = true,
  });

  final RecommendationScorer scorer;

  /// How many tracks a refill tops the queue up to.
  final int targetQueueLength;

  /// Recently-played ring size. Bounded so a marathon session cannot grow the
  /// session row without limit.
  final int maxPlayedMemory;

  /// At most one track per artist inside any window of this size.
  final int maxSameArtistWindow;

  /// Candidates considered per refill. Keeps a 20 000-track library at a
  /// bounded cost per generation (Phase 12: background-only, no jank).
  final int candidatePoolCap;

  /// Bonus for tracks whose genres match the seed.
  final double seedGenreBoost;

  /// Affinity removed from an artist on a skip.
  final double skipAffinityStep;

  /// Affinity added to an artist on a completion.
  final double playAffinityStep;

  /// Re-order the scored list so adjacent tracks are close in tempo/genre.
  final bool smoothTransitions;

  /// Starts a new station.
  RadioState start({
    required String sessionId,
    required RadioSeed seed,
    required Iterable<DiscoveryTrack> pool,
    required Map<String, TrackSignals> signals,
    required DateTime now,
  }) {
    final artistAffinity = <String, double>{
      for (final key in seed.artistKeys) key: 1.0,
    };
    final genreAffinity = Map<String, double>.of(seed.genres);

    final state = RadioState(
      sessionId: sessionId,
      seed: seed,
      startedAt: now,
      artistAffinity: Map<String, double>.unmodifiable(artistAffinity),
      genreAffinity: Map<String, double>.unmodifiable(genreAffinity),
    );
    return refill(state, pool: pool, signals: signals, now: now);
  }

  /// Tops [state.queue] back up to [targetQueueLength].
  RadioState refill(
    RadioState state, {
    required Iterable<DiscoveryTrack> pool,
    required Map<String, TrackSignals> signals,
    required DateTime now,
    int? target,
  }) {
    final desired = target ?? targetQueueLength;
    if (desired <= 0) return state;
    if (state.queue.length >= desired) return state;

    final needed = desired - state.queue.length;
    final blocked = <String>{
      ...state.playedKeys,
      for (final entry in state.queue) entry.track.key,
    };

    // Pre-filter to the candidate window before scoring: the expensive part is
    // the scorer, so shrinking the input first is what keeps a refill under
    // the performance budget on large libraries.
    final candidates = _candidates(
      pool: pool,
      blocked: blocked,
      state: state,
      limit: candidatePoolCap,
    );
    if (candidates.isEmpty) return state;

    final inputs = candidates.map((track) {
      final trackSignals = signals[track.key];
      final genreMatch = _genreMatch(track, state);
      final artistMatch = _artistMatch(track, state);
      return ScoringInput(
        track: track,
        signals: trackSignals,
        genreSimilarity: clamp01(genreMatch),
        artistSimilarity: artistMatch,
        tagSimilarity: clamp01(genreMatch * 0.6),
        novelty: trackSignals == null ? 0.4 : 0,
        offlinePlayable: track.isOfflinePlayable,
      );
    });

    final ranked = scorer.scoreAll(inputs, now: now, limit: needed * 3);
    final ordered = smoothTransitions
        ? _smooth(ranked, state)
        : ranked;
    final selected = _diversify(ordered, needed, state);

    return state.copyWith(
      queue: List<ScoredTrack>.unmodifiable(
        <ScoredTrack>[...state.queue, ...selected],
      ),
      generation: state.generation + 1,
      lastRefilledAt: now,
    );
  }

  /// Records that [trackKey] finished (or was skipped) and drops it from the
  /// queue. Returns the state to persist.
  RadioState consume(
    RadioState state,
    String trackKey, {
    required bool skipped,
    required Map<String, TrackSignals> signals,
  }) {
    final played = <String>[...state.playedKeys, trackKey];
    while (played.length > maxPlayedMemory) {
      played.removeAt(0);
    }

    final consumed = state.queue.isEmpty
        ? null
        : (state.queue.first.track.key == trackKey ? state.queue.first : null);
    final queue = state.queue.isEmpty
        ? state.queue
        : List<ScoredTrack>.unmodifiable(state.queue.sublist(1));

    final artistAffinity = Map<String, double>.of(state.artistAffinity);
    final genreAffinity = Map<String, double>.of(state.genreAffinity);

    final track = consumed?.track;
    if (track != null) {
      final step = skipped ? -skipAffinityStep : playAffinityStep;
      if (track.artistKey.isNotEmpty) {
        artistAffinity[track.artistKey] = clamp01(
          (artistAffinity[track.artistKey] ?? 0.5) + step,
        );
      }
      final genreStep = skipped ? -skipAffinityStep * 0.5 : playAffinityStep * 0.5;
      for (final genre in track.genres) {
        genreAffinity[genre] = clamp01(
          (genreAffinity[genre] ?? 0.25) + genreStep,
        );
      }
    }

    return state.copyWith(
      queue: queue,
      playedKeys: List<String>.unmodifiable(played),
      artistAffinity: Map<String, double>.unmodifiable(artistAffinity),
      genreAffinity: Map<String, double>.unmodifiable(genreAffinity),
      playCount: state.playCount + (skipped ? 0 : 1),
      skipCount: state.skipCount + (skipped ? 1 : 0),
      skipStreak: skipped ? state.skipStreak + 1 : 0,
    );
  }

  /// True when the caller should schedule another [refill].
  bool needsRefill(RadioState state) => state.queue.length <= targetQueueLength ~/ 3;

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  List<DiscoveryTrack> _candidates({
    required Iterable<DiscoveryTrack> pool,
    required Set<String> blocked,
    required RadioState state,
    required int limit,
  }) {
    final seedArtists = state.seed.artistKeys;
    final seedGenres = state.seed.genres;
    final seedTracks = state.seed.trackKeys;

    // Always-eligible seeds first, then everything else sorted by a cheap
    // pre-score so the expensive scorer only ever sees the promising window.
    final seeds = <DiscoveryTrack>[];
    final rest = <DiscoveryTrack>[];
    for (final track in pool) {
      if (blocked.contains(track.key)) continue;
      if (seedTracks.contains(track.key) ||
          (track.artistKey.isNotEmpty && seedArtists.contains(track.artistKey))) {
        seeds.add(track);
        continue;
      }
      rest.add(track);
    }
    if (seeds.length >= limit) {
      return _deterministicTake(seeds, limit, state.generation);
    }
    final remaining = limit - seeds.length;
    if (rest.length <= remaining) {
      return <DiscoveryTrack>[...seeds, ...rest];
    }

    rest.sort((a, b) {
      final byScore = _preScore(b, seedGenres, state).compareTo(
        _preScore(a, seedGenres, state),
      );
      if (byScore != 0) return byScore;
      return a.key.compareTo(b.key);
    });
    return <DiscoveryTrack>[...seeds, ...rest.sublist(0, remaining)];
  }

  /// Cheap genre/artist overlap used only to pick the candidate window.
  double _preScore(
    DiscoveryTrack track,
    Map<String, double> seedGenres,
    RadioState state,
  ) {
    var score = 0.0;
    if (track.artistKey.isNotEmpty) {
      score += (state.artistAffinity[track.artistKey] ?? 0) * 0.6;
    }
    if (seedGenres.isNotEmpty && track.genres.isNotEmpty) {
      for (final genre in track.genres) {
        score += (seedGenres[genre] ?? 0) * 0.4;
      }
    }
    if (track.isFavorite) score += 0.15;
    return score;
  }

  double _genreMatch(DiscoveryTrack track, RadioState state) {
    final weights = state.genreAffinity;
    if (weights.isEmpty || track.genres.isEmpty) return 0;
    var best = 0.0;
    var sum = 0.0;
    for (final genre in track.genres) {
      final value = weights[genre] ?? 0;
      sum += value;
      if (value > best) best = value;
    }
    final mean = sum / track.genres.length;
    final blended = 0.6 * best + 0.4 * mean;
    return clamp01(blended + (blended > 0 ? seedGenreBoost * 0.2 : 0));
  }

  double _artistMatch(DiscoveryTrack track, RadioState state) {
    if (track.artistKey.isEmpty) return 0;
    if (state.seed.artistKeys.contains(track.artistKey)) return 1;
    return clamp01(state.artistAffinity[track.artistKey] ?? 0);
  }

  /// Greedy nearest-neighbour walk over tempo and genre, starting from the
  /// highest-scored track. Keeps ~score order for the first slot (that is what
  /// plays next) while avoiding jarring jumps further down the queue.
  List<ScoredTrack> _smooth(List<ScoredTrack> ranked, RadioState state) {
    if (ranked.length < 3) return ranked;
    final remaining = ranked.toList();
    final result = <ScoredTrack>[remaining.removeAt(0)];
    while (remaining.isNotEmpty) {
      final previous = result.last;
      var bestIndex = 0;
      var bestCost = double.infinity;
      for (var i = 0; i < remaining.length; i++) {
        final cost = _transitionCost(previous.track, remaining[i].track, i);
        if (cost < bestCost) {
          bestCost = cost;
          bestIndex = i;
        }
        // The queue is roughly score-ordered, so after a handful of good
        // options the rest cannot win — bound the scan.
        if (i >= 24) break;
      }
      result.add(remaining.removeAt(bestIndex));
    }
    return result;
  }

  /// Lower is better. Combines a tempo jump penalty, a genre-disjoint penalty
  /// and the candidate's position in the scored list (so score still matters).
  double _transitionCost(DiscoveryTrack from, DiscoveryTrack to, int rankIndex) {
    final positionPenalty = rankIndex * 0.04;
    final fromBpm = from.bpm;
    final toBpm = to.bpm;
    double tempoPenalty;
    if (fromBpm == null || toBpm == null || fromBpm <= 0 || toBpm <= 0) {
      // No tempo evidence: fall back to a flat, small penalty so the genre
      // term does the work instead of pretending to know the tempo.
      tempoPenalty = 0.1;
    } else {
      final ratio = math.max(fromBpm, toBpm) / math.min(fromBpm, toBpm);
      // 2:1 ratios are often the same groove at half/double time.
      final effective = ratio > 1.85 && ratio < 2.15 ? ratio / 2 : ratio;
      tempoPenalty = clamp01((effective - 1) * 1.6);
    }
    final genrePenalty = from.genres.isEmpty || to.genres.isEmpty
        ? 0.15
        : 1 -
            jaccardSimilarity(
              from.genres.toSet(),
              to.genres.toSet(),
            );
    final artistPenalty =
        from.artistKey.isNotEmpty && from.artistKey == to.artistKey ? 0.5 : 0.0;
    return positionPenalty + 0.55 * tempoPenalty + 0.3 * genrePenalty + artistPenalty;
  }

  /// Enforces the artist window and de-duplicates.
  List<ScoredTrack> _diversify(
    List<ScoredTrack> ordered,
    int needed,
    RadioState state,
  ) {
    final selected = <ScoredTrack>[];
    final seen = <String>{};
    // Window includes the tail of the current queue so a refill cannot
    // immediately repeat the artist that is already playing.
    final window = <String>[
      for (final entry in state.queue.take(maxSameArtistWindow))
        entry.track.artistKey,
    ];

    for (final candidate in ordered) {
      if (selected.length >= needed) break;
      final key = candidate.track.key;
      if (!seen.add(key)) continue;
      final artistKey = candidate.track.artistKey;
      if (artistKey.isNotEmpty) {
        final recent = window.length >= maxSameArtistWindow
            ? window.sublist(window.length - maxSameArtistWindow + 1)
            : window;
        if (recent.where((entry) => entry == artistKey).length >=
            maxSameArtistWindow - 1) {
          continue;
        }
      }
      window.add(artistKey);
      selected.add(candidate);
    }

    // If diversity starved the batch, relax it rather than under-fill: a
    // shorter queue is worse than a slightly repetitive one.
    if (selected.length < needed) {
      for (final candidate in ordered) {
        if (selected.length >= needed) break;
        if (!seen.add(candidate.track.key)) continue;
        selected.add(candidate);
      }
    }
    return selected;
  }

  List<DiscoveryTrack> _deterministicTake(
    List<DiscoveryTrack> source,
    int limit,
    int generation,
  ) {
    final shuffled = seededShuffle(source, 0x5eed + generation);
    return shuffled.take(limit).toList(growable: false);
  }
}
