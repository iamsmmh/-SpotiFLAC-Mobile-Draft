/// Context-aware recommendations (Phase 6).
///
/// Time-of-day / weekend / activity context re-weights the taste model so a
/// Monday-morning commute does not get the Friday-night mix.
library;

import 'package:spotiflac_android/services/recommendation/ml/playlist_generator.dart';
import 'package:spotiflac_android/services/recommendation/ml/user_taste_model.dart';

/// Coarse listening context derived from local clock (never from GPS).
enum ListeningContext {
  morning,
  afternoon,
  evening,
  night,
  weekend,
}

/// Resolves [ListeningContext] from a local timestamp.
class ContextClock {
  const ContextClock();

  ListeningContext contextFor(DateTime local) {
    if (local.weekday == DateTime.saturday ||
        local.weekday == DateTime.sunday) {
      return ListeningContext.weekend;
    }
    final hour = local.hour;
    if (hour >= 5 && hour < 12) return ListeningContext.morning;
    if (hour >= 12 && hour < 17) return ListeningContext.afternoon;
    if (hour >= 17 && hour < 22) return ListeningContext.evening;
    return ListeningContext.night;
  }
}

/// Picks a mix kind that fits the current context.
class ContextAwareRecommendations {
  const ContextAwareRecommendations({
    this.clock = const ContextClock(),
    this.generator = const PlaylistGenerator(),
  });

  final ContextClock clock;
  final PlaylistGenerator generator;

  GeneratedMix recommend({
    required DateTime localNow,
    required UserTasteModel taste,
    required List<TasteSignal> pool,
  }) {
    final context = clock.contextFor(localNow);
    switch (context) {
      case ListeningContext.morning:
        return generator.moodMix(
          mood: 'Focus',
          taste: taste,
          pool: pool,
        );
      case ListeningContext.afternoon:
        return generator.dailyMix(
          taste: taste,
          pool: pool,
          index: 1,
          utcNow: localNow.toUtc(),
        );
      case ListeningContext.evening:
        return generator.moodMix(
          mood: 'Chill',
          taste: taste,
          pool: pool,
        );
      case ListeningContext.night:
        return generator.moodMix(
          mood: 'Sleep',
          taste: taste,
          pool: pool,
        );
      case ListeningContext.weekend:
        return generator.moodMix(
          mood: 'Party',
          taste: taste,
          pool: pool,
        );
    }
  }
}
