/// User taste model (Phase 6) — on-device signals.
///
/// Builds a compact taste vector from play duration, skip rate, replay rate,
/// favorite actions, search history and download behaviour. Pure Dart; the
/// existing [LocalRecommendationEngine] stays the fallback shelf producer.
library;

/// One observed track the model can score.
class TasteSignal {
  const TasteSignal({
    required this.trackId,
    required this.artistId,
    this.genre = '',
    this.playCount = 0,
    this.skipCount = 0,
    this.replayCount = 0,
    this.listenedMs = 0,
    this.durationMs = 0,
    this.favorited = false,
    this.downloaded = false,
    this.searchHits = 0,
  });

  final String trackId;
  final String artistId;
  final String genre;
  final int playCount;
  final int skipCount;
  final int replayCount;
  final int listenedMs;
  final int durationMs;
  final bool favorited;
  final bool downloaded;
  final int searchHits;

  double get skipRate {
    final total = playCount + skipCount;
    if (total <= 0) return 0;
    return skipCount / total;
  }

  double get replayRate {
    if (playCount <= 0) return 0;
    return replayCount / playCount;
  }

  double get completion {
    if (durationMs <= 0) return 0;
    final ratio = listenedMs / durationMs;
    if (ratio.isNaN || ratio <= 0) return 0;
    return ratio >= 1 ? 1 : ratio;
  }
}

/// Aggregated taste: per-artist / per-genre weights plus a 0..1 affinity
/// for every observed track.
class UserTasteModel {
  const UserTasteModel({
    required this.trackAffinity,
    required this.artistAffinity,
    required this.genreAffinity,
  });

  final Map<String, double> trackAffinity;
  final Map<String, double> artistAffinity;
  final Map<String, double> genreAffinity;

  bool get isCold => trackAffinity.isEmpty;

  double affinityFor(String trackId) => trackAffinity[trackId] ?? 0;
}

/// Builds [UserTasteModel] from raw signals.
class UserTasteBuilder {
  const UserTasteBuilder({
    this.playWeight = 0.28,
    this.completionWeight = 0.18,
    this.skipPenalty = 0.22,
    this.replayWeight = 0.12,
    this.favoriteBoost = 0.12,
    this.downloadBoost = 0.05,
    this.searchBoost = 0.03,
  });

  final double playWeight;
  final double completionWeight;
  final double skipPenalty;
  final double replayWeight;
  final double favoriteBoost;
  final double downloadBoost;
  final double searchBoost;

  UserTasteModel build(Iterable<TasteSignal> signals) {
    final track = <String, double>{};
    final artist = <String, double>{};
    final genre = <String, double>{};
    var maxPlay = 1;
    for (final signal in signals) {
      if (signal.playCount > maxPlay) maxPlay = signal.playCount;
    }
    for (final signal in signals) {
      final playNorm = signal.playCount / maxPlay;
      var score = playWeight * playNorm +
          completionWeight * signal.completion +
          replayWeight * signal.replayRate.clamp(0.0, 1.0) -
          skipPenalty * signal.skipRate.clamp(0.0, 1.0);
      if (signal.favorited) score += favoriteBoost;
      if (signal.downloaded) score += downloadBoost;
      if (signal.searchHits > 0) {
        score += searchBoost * (signal.searchHits > 3 ? 1.0 : signal.searchHits / 3);
      }
      final clamped = score < 0 ? 0.0 : (score > 1 ? 1.0 : score);
      track[signal.trackId] = clamped;
      if (signal.artistId.isNotEmpty) {
        artist[signal.artistId] = (artist[signal.artistId] ?? 0) + clamped;
      }
      if (signal.genre.isNotEmpty) {
        genre[signal.genre] = (genre[signal.genre] ?? 0) + clamped;
      }
    }
    return UserTasteModel(
      trackAffinity: Map<String, double>.unmodifiable(track),
      artistAffinity: _peak(artist),
      genreAffinity: _peak(genre),
    );
  }

  static Map<String, double> _peak(Map<String, double> input) {
    var max = 0.0;
    for (final value in input.values) {
      if (value > max) max = value;
    }
    if (max <= 0) return Map<String, double>.unmodifiable(input);
    return Map<String, double>.unmodifiable(<String, double>{
      for (final entry in input.entries) entry.key: entry.value / max,
    });
  }
}
