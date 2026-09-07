/// History analytics (Phase 12).
///
/// Wraps [InsightsCalculator] with play-count / duration / completion
/// recaps. Pure over [PlayEvent] lists so tests never touch SQLite.
library;

import 'package:spotiflac_android/ecosystem/history/listening_history.dart';
import 'package:spotiflac_android/ecosystem/history/listening_insights.dart';

/// Compact counters the recap cards render.
class HistoryAnalyticsSnapshot {
  const HistoryAnalyticsSnapshot({
    required this.playCount,
    required this.skipCount,
    required this.completedCount,
    required this.totalListened,
    required this.averageCompletion,
    required this.uniqueTracks,
    required this.insights,
    required this.recap,
  });

  final int playCount;
  final int skipCount;
  final int completedCount;
  final Duration totalListened;
  final double averageCompletion;
  final int uniqueTracks;
  final ListeningInsights insights;
  final RecapReport recap;

  double get skipRate => playCount == 0 ? 0 : skipCount / playCount;

  double get completionRate =>
      playCount == 0 ? 0 : completedCount / playCount;
}

/// Facade over the existing insights calculator.
class HistoryAnalyticsService {
  const HistoryAnalyticsService({
    this.calculator = const InsightsCalculator(),
  });

  final InsightsCalculator calculator;

  HistoryAnalyticsSnapshot summarize(
    List<PlayEvent> events, {
    required DateTime rangeStart,
    required DateTime rangeEnd,
    int? recapYear,
  }) {
    final insights = calculator.compute(
      events,
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
    );
    var completed = 0;
    for (final event in events) {
      if (event.completed) completed++;
    }
    final recap = calculator.buildRecap(
      events,
      year: recapYear ?? rangeEnd.year,
      now: rangeEnd,
    );
    return HistoryAnalyticsSnapshot(
      playCount: insights.playCount,
      skipCount: insights.skipCount,
      completedCount: completed,
      totalListened: insights.totalListened,
      averageCompletion: insights.averageCompletion,
      uniqueTracks: insights.uniqueTracks,
      insights: insights,
      recap: recap,
    );
  }
}
