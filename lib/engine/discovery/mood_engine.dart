/// Mood classification for generated playlists (Phase 5).
///
/// Four evidence sources, blended:
///
///   1. **BPM** — when the file or provider carries it. The only *measured*
///      signal, so it gets the largest weight when present.
///   2. **Genre** — a curated genre→mood lexicon (see [moodProfiles]).
///   3. **Tags** — free-form descriptors (`"ambient"`, `"aggressive"`,
///      `"acoustic"`) from the provider payload or the local tag reader.
///   4. **User behaviour** — what the user actually plays in the time-of-day
///      bucket a mood belongs to, supplied by `UserProfileEngine`.
///
/// When BPM is missing the engine does *not* invent one: it re-weights the
/// remaining signals and reports `bpmEvidence == false` so the UI can say
/// "based on genre and tags" instead of implying an analysis it never ran.
library;

import 'dart:math' as math;

import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';

// ---------------------------------------------------------------------------
// Mood catalogue
// ---------------------------------------------------------------------------

/// The moods the app generates a playlist for.
enum Mood { chill, focus, workout, relax, sleep, party, travel, coding, driving }

/// Tunable definition of one mood.
class MoodProfile {
  const MoodProfile({
    required this.mood,
    required this.label,
    required this.genres,
    required this.tags,
    required this.bpmMin,
    required this.bpmMax,
    required this.energy,
    required this.valence,
    required this.buckets,
    required this.icon,
  });

  final Mood mood;
  final String label;

  /// Genre tokens that score full marks for this mood.
  final Set<String> genres;

  /// Descriptor tokens that score full marks.
  final Set<String> tags;

  /// Inclusive BPM window. Tracks outside it decay smoothly to zero at the
  /// soft edges rather than cutting off — a 128 BPM chill track still fits.
  final int bpmMin;
  final int bpmMax;

  /// Target energy 0..1 (danceability/loudness proxy).
  final double energy;

  /// Target positivity 0..1.
  final double valence;

  /// Time-of-day buckets where the user historically listens to this mood.
  final List<DaytimeBucket> buckets;

  /// Material icon name, resolved by the UI.
  final String icon;

  /// BPM window widened by [softEdge] percent on each side.
  bool bpmInRange(int bpm, {double softEdge = 0.18}) {
    final span = (bpmMax - bpmMin).toDouble();
    final pad = span * softEdge;
    return bpm >= bpmMin - pad && bpm <= bpmMax + pad;
  }

  /// 0..1 BPM fit, with a triangular falloff outside the core window.
  double bpmFit(int bpm, {double softEdge = 0.18}) {
    if (bpm <= 0) return 0;
    if (bpm >= bpmMin && bpm <= bpmMax) return 1;
    final span = math.max(1.0, (bpmMax - bpmMin).toDouble());
    final pad = span * softEdge;
    if (pad <= 0) return 0;
    if (bpm < bpmMin) {
      return clamp01(1 - (bpmMin - bpm) / pad);
    }
    return clamp01(1 - (bpm - bpmMax) / pad);
  }
}

/// The shipped mood catalogue.
///
/// Genre sets are deliberately broad and lower-cased so they match the
/// normalised tokens produced by [splitTaxonomy].
const Map<Mood, MoodProfile> moodProfiles = <Mood, MoodProfile>{
  Mood.chill: MoodProfile(
    mood: Mood.chill,
    label: 'Chill',
    genres: <String>{
      'lofi', 'lo fi', 'chillhop', 'chillwave', 'downtempo', 'trip hop',
      'triphop', 'r b', 'rnb', 'soul', 'neo soul', 'indie pop', 'dream pop',
      'bossa nova', 'jazz', 'smooth jazz', 'nu jazz', 'ambient pop',
      'chillout', 'chill', 'electronic', 'folk', 'acoustic',
    },
    tags: <String>{
      'chill', 'mellow', 'smooth', 'laid back', 'laidback', 'easy listening',
      'warm', 'soft', 'groovy', 'late night', 'coffee',
    },
    bpmMin: 60,
    bpmMax: 105,
    energy: 0.32,
    valence: 0.55,
    buckets: <DaytimeBucket>[
      DaytimeBucket.afternoon,
      DaytimeBucket.evening,
      DaytimeBucket.night,
    ],
    icon: 'self_improvement',
  ),
  Mood.focus: MoodProfile(
    mood: Mood.focus,
    label: 'Focus',
    genres: <String>{
      'classical', 'neoclassical', 'minimal', 'minimalism', 'ambient',
      'drone', 'modern classical', 'film score', 'soundtrack', 'instrumental',
      'post rock', 'piano', 'strings', 'electronic', 'idm', 'downtempo',
      'study', 'concentration',
    },
    tags: <String>{
      'instrumental', 'ambient', 'minimal', 'atmospheric', 'calm', 'quiet',
      'no vocals', 'study', 'concentration', 'deep', 'sparse', 'texture',
    },
    bpmMin: 55,
    bpmMax: 100,
    energy: 0.24,
    valence: 0.42,
    buckets: <DaytimeBucket>[DaytimeBucket.morning, DaytimeBucket.afternoon],
    icon: 'psychology',
  ),
  Mood.workout: MoodProfile(
    mood: Mood.workout,
    label: 'Workout',
    genres: <String>{
      'edm', 'house', 'electro house', 'big room', 'dubstep', 'drum and bass',
      'dnb', 'trap', 'hardstyle', 'techno', 'hard rock', 'metal', 'metalcore',
      'punk', 'punk rock', 'hip hop', 'rap', 'phonk', 'industrial', 'rock',
      'grime', 'moombahton',
    },
    tags: <String>{
      'energetic', 'aggressive', 'hard', 'fast', 'pump', 'intense', 'driving',
      'hype', 'powerful', 'heavy', 'anthem', 'gym', 'running', 'banger',
    },
    bpmMin: 125,
    bpmMax: 175,
    energy: 0.88,
    valence: 0.62,
    buckets: <DaytimeBucket>[DaytimeBucket.morning, DaytimeBucket.afternoon],
    icon: 'fitness_center',
  ),
  Mood.relax: MoodProfile(
    mood: Mood.relax,
    label: 'Relax',
    genres: <String>{
      'ambient', 'new age', 'chillout', 'downtempo', 'classical', 'piano',
      'acoustic', 'folk', 'jazz', 'smooth jazz', 'nature', 'meditation',
      'spa', 'instrumental', 'world', 'celtic',
    },
    tags: <String>{
      'calm', 'peaceful', 'gentle', 'soothing', 'slow', 'soft', 'acoustic',
      'warm', 'restful', 'serene', 'unwind',
    },
    bpmMin: 50,
    bpmMax: 92,
    energy: 0.2,
    valence: 0.5,
    buckets: <DaytimeBucket>[DaytimeBucket.evening, DaytimeBucket.night],
    icon: 'spa',
  ),
  Mood.sleep: MoodProfile(
    mood: Mood.sleep,
    label: 'Sleep',
    genres: <String>{
      'ambient', 'drone', 'new age', 'sleep', 'meditation', 'classical',
      'neoclassical', 'piano', 'nature', 'soundscape', 'minimal', 'dark ambient',
    },
    tags: <String>{
      'ambient', 'drone', 'sleep', 'quiet', 'slow', 'minimal', 'no vocals',
      'soft', 'calm', 'dreamy', 'texture', 'night',
    },
    bpmMin: 40,
    bpmMax: 75,
    energy: 0.12,
    valence: 0.35,
    buckets: <DaytimeBucket>[DaytimeBucket.night],
    icon: 'nightlight',
  ),
  Mood.party: MoodProfile(
    mood: Mood.party,
    label: 'Party',
    genres: <String>{
      'edm', 'house', 'electro', 'dance', 'dance pop', 'pop', 'reggaeton',
      'latin', 'afrobeats', 'funk', 'disco', 'hip hop', 'rap', 'trap',
      'club', 'big room', 'progressive house', 'tropical house', 'k pop',
    },
    tags: <String>{
      'party', 'dance', 'upbeat', 'anthem', 'banger', 'fun', 'hype',
      'singalong', 'club', 'energetic', 'catchy', 'festival',
    },
    bpmMin: 112,
    bpmMax: 135,
    energy: 0.92,
    valence: 0.82,
    buckets: <DaytimeBucket>[DaytimeBucket.evening, DaytimeBucket.night],
    icon: 'celebration',
  ),
  Mood.travel: MoodProfile(
    mood: Mood.travel,
    label: 'Travel',
    genres: <String>{
      'indie', 'indie rock', 'indie pop', 'folk', 'folk rock', 'americana',
      'country', 'rock', 'alternative', 'reggae', 'world', 'latin',
      'afrobeats', 'pop rock', 'electronic', 'synth pop',
    },
    tags: <String>{
      'uplifting', 'road trip', 'adventure', 'breezy', 'sunny', 'open',
      'anthem', 'feelgood', 'feel good', 'wanderlust', 'bright',
    },
    bpmMin: 95,
    bpmMax: 130,
    energy: 0.62,
    valence: 0.72,
    buckets: <DaytimeBucket>[DaytimeBucket.morning, DaytimeBucket.afternoon],
    icon: 'flight',
  ),
  Mood.coding: MoodProfile(
    mood: Mood.coding,
    label: 'Coding',
    genres: <String>{
      'synthwave', 'electronic', 'idm', 'techno', 'minimal techno', 'ambient',
      'chiptune', 'video game', 'soundtrack', 'instrumental', 'drum and bass',
      'dnb', 'downtempo', 'trance', 'progressive', 'lofi', 'chillhop',
    },
    tags: <String>{
      'instrumental', 'no vocals', 'repetitive', 'hypnotic', 'focus',
      'atmospheric', 'synth', 'minimal', 'flow', 'deep', 'loop',
    },
    bpmMin: 85,
    bpmMax: 140,
    energy: 0.5,
    valence: 0.45,
    buckets: <DaytimeBucket>[
      DaytimeBucket.morning,
      DaytimeBucket.afternoon,
      DaytimeBucket.night,
    ],
    icon: 'code',
  ),
  Mood.driving: MoodProfile(
    mood: Mood.driving,
    label: 'Driving',
    genres: <String>{
      'rock', 'classic rock', 'indie rock', 'pop rock', 'alternative',
      'hip hop', 'rap', 'pop', 'synthwave', 'electronic', 'house', 'funk',
      'disco', 'country', 'metal', 'punk',
    },
    tags: <String>{
      'driving', 'road trip', 'anthem', 'upbeat', 'singalong', 'energetic',
      'cruise', 'highway', 'night drive', 'catchy', 'powerful',
    },
    bpmMin: 100,
    bpmMax: 150,
    energy: 0.74,
    valence: 0.68,
    buckets: <DaytimeBucket>[DaytimeBucket.morning, DaytimeBucket.evening],
    icon: 'directions_car',
  ),
};

/// Every mood in catalogue order.
const List<Mood> allMoods = <Mood>[
  Mood.chill,
  Mood.focus,
  Mood.workout,
  Mood.relax,
  Mood.sleep,
  Mood.party,
  Mood.travel,
  Mood.coding,
  Mood.driving,
];

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

/// How a track matched one mood.
class MoodMatch {
  const MoodMatch({
    required this.mood,
    required this.score,
    this.bpmScore = 0,
    this.genreScore = 0,
    this.tagScore = 0,
    this.behaviourScore = 0,
    this.bpmEvidence = false,
  });

  final Mood mood;

  /// 0..1 overall fit.
  final double score;

  final double bpmScore;
  final double genreScore;
  final double tagScore;
  final double behaviourScore;

  /// False when the track carried no BPM and the score rests on genre/tags
  /// alone. The UI surfaces that distinction instead of implying an analysis.
  final bool bpmEvidence;

  /// Human-readable explanation of the strongest signal.
  String describe() {
    if (bpmEvidence && bpmScore >= genreScore && bpmScore >= tagScore) {
      return 'Tempo fit';
    }
    if (genreScore >= tagScore && genreScore > 0) return 'Genre match';
    if (tagScore > 0) return 'Tag match';
    if (behaviourScore > 0) return 'You play this late';
    return 'Taste match';
  }
}

/// Classifies tracks into moods.
class MoodEngine {
  const MoodEngine({
    this.bpmWeight = 0.4,
    this.genreWeight = 0.34,
    this.tagWeight = 0.16,
    this.behaviourWeight = 0.1,
    this.minScore = 0.18,
  });

  /// Weight of measured BPM when present.
  final double bpmWeight;
  final double genreWeight;
  final double tagWeight;

  /// Weight of "the user plays this kind of thing at this time of day".
  final double behaviourWeight;

  /// Below this a track is not placed in the mood at all.
  final double minScore;

  /// Scores [track] against one mood.
  MoodMatch match(
    DiscoveryTrack track,
    Mood mood, {
    Map<Mood, double> behaviourAffinity = const <Mood, double>{},
  }) {
    final profile = moodProfiles[mood]!;
    final behaviour = clamp01(behaviourAffinity[mood] ?? 0);

    final genreScore = _lexiconScore(track.genres, profile.genres);
    final tagScore = _lexiconScore(track.tags, profile.tags);

    final bpm = track.bpm;
    final hasBpm = bpm != null && bpm > 0;
    final bpmScore = hasBpm ? profile.bpmFit(bpm) : 0.0;

    // Re-normalise over the evidence actually available. Dropping the BPM
    // weight entirely when it is missing is the honest behaviour: the track is
    // judged on genre/tags rather than on a fabricated tempo.
    final double score;
    if (hasBpm) {
      final total = bpmWeight + genreWeight + tagWeight + behaviourWeight;
      score = total <= 0
          ? 0
          : (bpmWeight * bpmScore +
                    genreWeight * genreScore +
                    tagWeight * tagScore +
                    behaviourWeight * behaviour) /
                total;
    } else {
      final total = genreWeight + tagWeight + behaviourWeight;
      score = total <= 0
          ? 0
          : (genreWeight * genreScore +
                    tagWeight * tagScore +
                    behaviourWeight * behaviour) /
                total;
    }

    return MoodMatch(
      mood: mood,
      score: clamp01(score),
      bpmScore: bpmScore,
      genreScore: genreScore,
      tagScore: tagScore,
      behaviourScore: behaviour,
      bpmEvidence: hasBpm,
    );
  }

  /// Every mood the track qualifies for, best first.
  List<MoodMatch> classify(
    DiscoveryTrack track, {
    Map<Mood, double> behaviourAffinity = const <Mood, double>{},
    int limit = 3,
  }) {
    final matches = <MoodMatch>[];
    for (final mood in allMoods) {
      final result = match(track, mood, behaviourAffinity: behaviourAffinity);
      if (result.score < minScore) continue;
      matches.add(result);
    }
    matches.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.mood.index.compareTo(b.mood.index);
    });
    if (limit > 0 && matches.length > limit) {
      return List<MoodMatch>.unmodifiable(matches.sublist(0, limit));
    }
    return List<MoodMatch>.unmodifiable(matches);
  }

  /// The single best mood, or null when the track matches nothing above
  /// [minScore] — such tracks are simply left out of the mood shelves.
  Mood? primaryMood(
    DiscoveryTrack track, {
    Map<Mood, double> behaviourAffinity = const <Mood, double>{},
  }) {
    final matches = classify(track, behaviourAffinity: behaviourAffinity, limit: 1);
    return matches.isEmpty ? null : matches.first.mood;
  }

  /// Buckets every track into its best mood.
  ///
  /// Tracks that qualify for several moods are assigned to their strongest
  /// one, then the weakest buckets are topped up from the runner-up matches so
  /// no mood ships an embarrassingly short playlist.
  Map<Mood, List<DiscoveryTrack>> assign(
    Iterable<DiscoveryTrack> tracks, {
    Map<Mood, double> behaviourAffinity = const <Mood, double>{},
    int perMood = 40,
    int minPerMood = 12,
  }) {
    final primary = <Mood, List<DiscoveryTrack>>{
      for (final mood in allMoods) mood: <DiscoveryTrack>[],
    };
    final backup = <Mood, List<DiscoveryTrack>>{
      for (final mood in allMoods) mood: <DiscoveryTrack>[],
    };
    final scores = <Mood, Map<String, double>>{
      for (final mood in allMoods) mood: <String, double>{},
    };

    for (final track in tracks) {
      final matches = classify(track, behaviourAffinity: behaviourAffinity);
      if (matches.isEmpty) continue;
      final best = matches.first;
      scores[best.mood]![track.key] = best.score;
      primary[best.mood]!.add(track);
      for (var i = 1; i < matches.length; i++) {
        final fallback = matches[i];
        scores[fallback.mood]![track.key] = fallback.score;
        backup[fallback.mood]!.add(track);
      }
    }

    final result = <Mood, List<DiscoveryTrack>>{};
    for (final mood in allMoods) {
      final bucket = primary[mood]!;
      final moodScores = scores[mood]!;
      bucket.sort((a, b) {
        final byScore = (moodScores[b.key] ?? 0).compareTo(
          moodScores[a.key] ?? 0,
        );
        if (byScore != 0) return byScore;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });

      final filled = bucket.take(perMood).toList();
      if (filled.length < minPerMood) {
        final seen = <String>{for (final track in filled) track.key};
        final fallback = backup[mood]!
          ..sort((a, b) {
            final byScore = (moodScores[b.key] ?? 0).compareTo(
              moodScores[a.key] ?? 0,
            );
            if (byScore != 0) return byScore;
            return a.title.toLowerCase().compareTo(b.title.toLowerCase());
          });
        for (final track in fallback) {
          if (filled.length >= minPerMood) break;
          if (!seen.add(track.key)) continue;
          filled.add(track);
        }
      }
      result[mood] = List<DiscoveryTrack>.unmodifiable(filled);
    }
    return Map<Mood, List<DiscoveryTrack>>.unmodifiable(result);
  }

  /// Share of a track's tokens found in a mood's lexicon, weighted so a single
  /// exact genre hit beats several partial tag hits.
  double _lexiconScore(List<String> tokens, Set<String> lexicon) {
    if (tokens.isEmpty || lexicon.isEmpty) return 0;
    var hits = 0;
    for (final token in tokens) {
      if (lexicon.contains(token)) {
        hits++;
        continue;
      }
      // Multi-word genres normalise with spaces; a provider may still emit the
      // hyphenated or concatenated form (`"drum-n-bass"`, `"dnb"`).
      final compact = token.replaceAll(' ', '');
      for (final entry in lexicon) {
        if (entry.replaceAll(' ', '') == compact) {
          hits++;
          break;
        }
      }
    }
    if (hits == 0) return 0;
    // Diminishing returns: the second matching genre confirms the first rather
    // than doubling the evidence.
    return clamp01(1 - math.pow(0.45, hits).toDouble());
  }

  /// Behavioural affinity per mood, derived from the user's own listening:
  /// the genres/tags they play inside each mood's time-of-day buckets.
  ///
  /// `profileGenres`/`profileTags` are affinity maps restricted to plays that
  /// happened in the mood's preferred buckets.
  Map<Mood, double> behaviourAffinity({
    required Map<Mood, Map<String, double>> genresByMood,
    required Map<Mood, Map<String, double>> tagsByMood,
    required Map<String, double> profileGenres,
    required Map<String, double> profileTags,
  }) {
    final result = <Mood, double>{};
    for (final mood in allMoods) {
      final genreScore = cosineSimilarity(
        peakNormalise(genresByMood[mood] ?? const <String, double>{}),
        peakNormalise(profileGenres),
      );
      final tagScore = cosineSimilarity(
        peakNormalise(tagsByMood[mood] ?? const <String, double>{}),
        peakNormalise(profileTags),
      );
      result[mood] = clamp01(0.7 * genreScore + 0.3 * tagScore);
    }
    return Map<Mood, double>.unmodifiable(result);
  }
}
