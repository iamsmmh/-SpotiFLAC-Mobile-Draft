/// Weighted recommendation scoring (Phase 2).
///
/// The contract is a single number in `0..100` per candidate, decomposed into
/// four weighted axes so the ranking is explainable and tunable:
///
///   recency     — how recently the *taste* behind this candidate was active
///   frequency   — how often, and how completely, that taste was exercised
///   favorite    — explicit love signals (hearted track/artist/album)
///   similarity  — content + behavioural closeness to the user's profile
///
/// Everything is pure: no I/O, no clock reads (the caller passes `now`), no
/// Flutter — the same rule as `engine/recommendations.dart`.
library;

import 'dart:math' as math;

import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';

// ---------------------------------------------------------------------------
// Weights
// ---------------------------------------------------------------------------

/// The four scoring weights, normalised to sum to `1`.
///
/// `const` by default (the engines are compile-time constants); use
/// [RecommendationWeights.ratio] when a value comes from settings and has to be
/// re-normalised at runtime.
class RecommendationWeights {
  const RecommendationWeights({
    this.recency = 0.22,
    this.frequency = 0.18,
    this.favorite = 0.14,
    this.similarity = 0.46,
  });

  /// Shipped balance: similarity-dominant, which suits a discovery surface
  /// where most candidates have never been played.
  const RecommendationWeights.standard() : this();

  /// "Play it again" surfaces (Continue Listening, favorites).
  const RecommendationWeights.replay()
    : recency = 0.34,
      frequency = 0.34,
      favorite = 0.22,
      similarity = 0.10;

  /// Pure discovery (Discover Weekly, hidden gems): similarity and novelty win.
  const RecommendationWeights.discovery()
    : recency = 0.14,
      frequency = 0.10,
      favorite = 0.10,
      similarity = 0.66;

  /// Normalised 0..1 weight per axis.
  final double recency;
  final double frequency;
  final double favorite;
  final double similarity;

  /// Builds weights from raw relative magnitudes (`25/20/15/40`) and
  /// normalises them. Negative inputs are clamped to zero; an all-zero set
  /// falls back to the shipped balance rather than scoring everything `0`.
  factory RecommendationWeights.ratio({
    double recency = 22,
    double frequency = 18,
    double favorite = 14,
    double similarity = 46,
  }) {
    final r = recency < 0 ? 0.0 : recency;
    final f = frequency < 0 ? 0.0 : frequency;
    final v = favorite < 0 ? 0.0 : favorite;
    final s = similarity < 0 ? 0.0 : similarity;
    final total = r + f + v + s;
    if (total <= 0) return const RecommendationWeights.standard();
    return RecommendationWeights(
      recency: r / total,
      frequency: f / total,
      favorite: v / total,
      similarity: s / total,
    );
  }

  double get sum => recency + frequency + favorite + similarity;

  /// True when the weights are usable (positive and normalised).
  bool get isNormalised => (sum - 1.0).abs() < 0.001 && sum > 0;

  RecommendationWeights copyWith({
    double? recency,
    double? frequency,
    double? favorite,
    double? similarity,
  }) {
    return RecommendationWeights.ratio(
      recency: (recency ?? this.recency) * 100,
      frequency: (frequency ?? this.frequency) * 100,
      favorite: (favorite ?? this.favorite) * 100,
      similarity: (similarity ?? this.similarity) * 100,
    );
  }
}

// ---------------------------------------------------------------------------
// Scorer input
// ---------------------------------------------------------------------------

/// Everything the scorer needs about one candidate.
///
/// Callers fill only what they know: a brand-new release has no [signals] and
/// scores on similarity alone, which is exactly what a discovery shelf wants.
class ScoringInput {
  const ScoringInput({
    required this.track,
    this.signals,
    this.genreSimilarity = 0,
    this.artistSimilarity = 0,
    this.albumSimilarity = 0,
    this.tagSimilarity = 0,
    this.coListenSimilarity = 0,
    this.playlistSimilarity = 0,
    this.isFavoriteArtist = false,
    this.isFavoriteAlbum = false,
    this.novelty = 0,
    this.offlinePlayable = false,
    this.lastTasteActivity,
  });

  final DiscoveryTrack track;

  /// Null for candidates the user has never played.
  final TrackSignals? signals;

  /// 0..1 content similarity per axis, supplied by `SimilarityEngine`.
  final double genreSimilarity;
  final double artistSimilarity;
  final double albumSimilarity;
  final double tagSimilarity;

  /// 0..1 behavioural similarity: how often this candidate's artist is played
  /// alongside the user's own seeds.
  final double coListenSimilarity;

  /// 0..1 overlap with the user's own playlists.
  final double playlistSimilarity;

  final bool isFavoriteArtist;
  final bool isFavoriteAlbum;

  /// 0..1 "you have not heard this" bonus (new releases, hidden gems).
  final double novelty;

  /// Offline-playable candidates get a small tie-break bump: on a plane a
  /// downloaded track is strictly better than an equal-ranked stream.
  final bool offlinePlayable;

  /// When the matching taste entry (artist/genre) was last active. Falls back
  /// to the candidate's own last play when null.
  final DateTime? lastTasteActivity;
}

// ---------------------------------------------------------------------------
// Scorer
// ---------------------------------------------------------------------------

/// Turns a [ScoringInput] into a 0..100 [ScoredTrack].
class RecommendationScorer {
  const RecommendationScorer({
    this.weights = const RecommendationWeights.standard(),
    this.recencyHalfLife = const Duration(days: 21),
    this.frequencyReferencePlays = 24,
    this.reasonsEnabled = true,
    this.noveltyBoost = 6,
    this.offlineBoost = 3,
    this.skipPenalty = 12,
    this.sourceId = 'local',
  });

  final RecommendationWeights weights;

  /// Half-life of the recency decay.
  final Duration recencyHalfLife;

  /// Play count that maps to a frequency score of ~1.0.
  final int frequencyReferencePlays;

  /// Emit human-readable reasons (turn off for bulk background passes).
  final bool reasonsEnabled;

  /// Maximum extra points for never-heard candidates.
  final double noveltyBoost;

  /// Maximum extra points for offline-playable candidates.
  final double offlineBoost;

  /// Maximum points removed for frequently skipped tracks.
  final double skipPenalty;

  final String sourceId;

  /// Scores one candidate.
  ScoredTrack score(ScoringInput input, {required DateTime now}) {
    final breakdown = breakdownFor(input, now: now);
    var total = breakdown.total * 100.0;

    // Novelty and offline are additive bonuses *after* the weighted blend so
    // they can lift a candidate without letting them dominate the ranking.
    total += clamp01(input.novelty) * noveltyBoost;
    if (input.offlinePlayable) total += offlineBoost;

    final signals = input.signals;
    if (signals != null && signals.playCount > 0) {
      total -= signals.skipRate * skipPenalty;
    }

    return ScoredTrack(
      track: input.track,
      score: clampScore(total),
      breakdown: breakdown,
      source: sourceId,
    );
  }

  /// Scores and sorts a batch, best first. Ties break on title so the order is
  /// stable across runs — a cached shelf must not reshuffle on re-read.
  List<ScoredTrack> scoreAll(
    Iterable<ScoringInput> inputs, {
    required DateTime now,
    int? limit,
  }) {
    final scored = inputs.map((input) => score(input, now: now)).toList();
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.track.title.toLowerCase().compareTo(
        b.track.title.toLowerCase(),
      );
    });
    if (limit != null && limit > 0 && scored.length > limit) {
      return List<ScoredTrack>.unmodifiable(scored.sublist(0, limit));
    }
    return List<ScoredTrack>.unmodifiable(scored);
  }

  /// Per-axis contributions, each already multiplied by its weight.
  ScoreBreakdown breakdownFor(ScoringInput input, {required DateTime now}) {
    final w = weights;
    final reasons = <RecommendationReason>[];

    // ---- recency ----------------------------------------------------------
    // No activity at all must score 0 on this axis. Defaulting to `now` would
    // hand a never-heard candidate full recency credit and flatten the whole
    // discovery ranking onto its similarity term.
    final DateTime? activity =
        input.lastTasteActivity ?? input.signals?.lastPlayedAt;
    final double recencyRaw = activity == null
        ? 0
        : timeDecay(activity, now, halfLife: recencyHalfLife);
    final recency = recencyRaw * w.recency;
    if (reasonsEnabled && recencyRaw > 0.6) {
      reasons.add(const RecommendationReason('recent', 'Played recently'));
    }

    // ---- frequency --------------------------------------------------------
    final signals = input.signals;
    var frequencyRaw = 0.0;
    if (signals != null) {
      final countScore = logScaledCount(
        signals.playCount,
        reference: frequencyReferencePlays,
      );
      // Completion weights the count: 10 plays heard through beat 10 skips.
      final quality = 0.35 + 0.65 * signals.averageCompletion;
      frequencyRaw = clamp01(countScore * quality);
      if (reasonsEnabled && signals.playCount >= 3) {
        reasons.add(
          RecommendationReason(
            'frequency',
            'Played ${signals.playCount} times',
          ),
        );
      }
    }
    final frequency = frequencyRaw * w.frequency;

    // ---- favorite ---------------------------------------------------------
    var favoriteRaw = 0.0;
    if (input.track.isFavorite || (signals?.isFavorite ?? false)) {
      favoriteRaw = 1.0;
      if (reasonsEnabled) {
        reasons.add(const RecommendationReason('favorite', 'In your library'));
      }
    } else {
      // Implicit love: finished often, replayed, never skipped.
      if (signals != null && signals.playCount > 0) {
        favoriteRaw = clamp01(
          0.5 * signals.completionRate +
              0.3 * signals.repeatRate +
              0.2 * (1 - signals.skipRate),
        );
      }
      if (input.isFavoriteArtist) {
        favoriteRaw = math.max(favoriteRaw, 0.8);
        if (reasonsEnabled) {
          reasons.add(
            RecommendationReason(
              'favoriteArtist',
              'By ${input.track.artist}, who you follow',
            ),
          );
        }
      }
      if (input.isFavoriteAlbum) {
        favoriteRaw = math.max(favoriteRaw, 0.7);
      }
    }
    final favorite = favoriteRaw * w.favorite;

    // ---- similarity -------------------------------------------------------
    final similarityRaw = _similarityFor(input, reasons);
    final similarity = similarityRaw * w.similarity;

    return ScoreBreakdown(
      recency: recency,
      frequency: frequency,
      favorite: favorite,
      similarity: similarity,
      reasons: reasonsEnabled
          ? List<RecommendationReason>.unmodifiable(reasons)
          : const <RecommendationReason>[],
    );
  }

  /// Blend of the five similarity signals. Artist and genre dominate (they are
  /// the signals the on-device data actually supports well); co-listen and
  /// playlist overlap are behavioural bonuses.
  double _similarityFor(
    ScoringInput input,
    List<RecommendationReason> reasons,
  ) {
    final genre = clamp01(input.genreSimilarity);
    final artist = clamp01(input.artistSimilarity);
    final album = clamp01(input.albumSimilarity);
    final tag = clamp01(input.tagSimilarity);
    final coListen = clamp01(input.coListenSimilarity);
    final playlist = clamp01(input.playlistSimilarity);

    if (reasonsEnabled) {
      if (artist >= 0.55) {
        reasons.add(
          RecommendationReason('artist', 'Sounds like ${input.track.artist}'),
        );
      } else if (genre >= 0.5) {
        final label = input.track.genres.isEmpty
            ? 'your genres'
            : input.track.genres.first;
        reasons.add(RecommendationReason('genre', 'Matches $label'));
      } else if (album >= 0.6) {
        reasons.add(RecommendationReason('album', 'From ${input.track.album}'));
      }
    }

    final content = 0.34 * genre + 0.34 * artist + 0.14 * album + 0.18 * tag;
    final behavioural = 0.7 * coListen + 0.3 * playlist;
    // A candidate with no behavioural data still ranks on content; one with
    // strong behavioural data is pulled towards it.
    return clamp01(0.72 * content + 0.28 * behavioural);
  }
}

/// The scorer wired with the shipped balance.
const RecommendationScorer standardScorer = RecommendationScorer();

/// The scorer wired for replay surfaces.
const RecommendationScorer replayScorer = RecommendationScorer(
  weights: RecommendationWeights.replay(),
);

/// The scorer wired for pure discovery.
const RecommendationScorer discoveryScorer = RecommendationScorer(
  weights: RecommendationWeights.discovery(),
  noveltyBoost: 10,
);
