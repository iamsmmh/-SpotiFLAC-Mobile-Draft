/// Local trending algorithm (Phase 9).
///
/// Four shelves, all computed from on-device listening statistics — there is no
/// global chart to fetch, and the UI says so ("Trending in your library"):
///
///   week     most played in the last 7 days
///   month    most played in the last 30 days
///   velocity fastest growing: current 7-day pace vs. the prior 30-day baseline
///   emerging artists first heard in the last 30 days whose plays are climbing
///
/// Pure Dart: the repository hands over the windowed counts, this file only
/// does arithmetic.
library;

import 'dart:math' as math;

import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';

/// Which trending shelf an entry belongs to.
enum TrendingPeriod { week, month, velocity, emerging }

/// One ranked trending row.
class TrendingEntry {
  const TrendingEntry({
    required this.key,
    required this.label,
    this.subtitle = '',
    this.coverUrl,
    required this.rank,
    required this.score,
    this.playCount = 0,
    this.delta = 0,
    this.period = TrendingPeriod.week,
    this.isArtist = false,
    this.firstPlayedAt,
  });

  /// Track key, or artist key when [isArtist].
  final String key;
  final String label;
  final String subtitle;
  final String? coverUrl;

  /// 1-based position in the shelf.
  final int rank;

  /// 0..100 shelf score (comparable inside the shelf, not across shelves).
  final double score;

  final int playCount;

  /// Growth factor: `>1` means accelerating, `1` steady, `<1` decaying.
  final double delta;

  final TrendingPeriod period;
  final bool isArtist;
  final DateTime? firstPlayedAt;

  /// Human-readable delta, e.g. `+180 %`.
  String get deltaLabel {
    if (delta <= 0) return 'New';
    final percent = ((delta - 1) * 100).round();
    if (percent <= 0) return 'Steady';
    return '+$percent %';
  }

  Map<String, Object?> toRow(DateTime computedAt) => <String, Object?>{
    'track_key': key,
    'rank': rank,
    'score': score,
    'play_count': playCount,
    'delta': delta,
    'computed_at': computedAt.toUtc().toIso8601String(),
  };
}

/// Per-artist rollup the emerging-artists shelf needs.
class ArtistSignals {
  const ArtistSignals({
    required this.artistKey,
    required this.label,
    this.playCount = 0,
    this.playsInLast30Days = 0,
    this.playsInPrior30Days = 0,
    this.trackCount = 0,
    this.coverUrl,
    required this.firstPlayedAt,
  });

  final String artistKey;
  final String label;
  final int playCount;
  final int playsInLast30Days;
  final int playsInPrior30Days;
  final int trackCount;
  final String? coverUrl;
  final DateTime firstPlayedAt;
}

/// Computes the trending shelves.
class TrendingEngine {
  const TrendingEngine({
    this.weekWindow = const Duration(days: 7),
    this.monthWindow = const Duration(days: 30),
    this.emergingWindow = const Duration(days: 45),
    this.minWeekPlays = 1,
    this.minVelocityPlays = 3,
    this.limit = 20,
  });

  final Duration weekWindow;
  final Duration monthWindow;

  /// An artist counts as "emerging" while they are younger than this.
  final Duration emergingWindow;

  final int minWeekPlays;
  final int minVelocityPlays;
  final int limit;

  /// Most played in the last 7 days.
  List<TrendingEntry> topOfWeek(
    Iterable<TrackSignals> signals, {
    required DateTime now,
  }) {
    final eligible = signals
        .where((entry) => entry.playsInLast7Days >= minWeekPlays)
        .toList();
    if (eligible.isEmpty) return const <TrendingEntry>[];

    var peak = 0;
    for (final entry in eligible) {
      if (entry.playsInLast7Days > peak) peak = entry.playsInLast7Days;
    }
    final ranked = _rank(
      eligible,
      TrendingPeriod.week,
      scoreOf: (entry) => logScaledCount(
        entry.playsInLast7Days,
        reference: math.max(peak, 1),
      ) * 100,
      deltaOf: (entry) => _growth(entry.playsInLast7Days * 4, entry.playsInPrior30Days),
    );
    return _take(ranked);
  }

  /// Most played in the last 30 days.
  List<TrendingEntry> topOfMonth(
    Iterable<TrackSignals> signals, {
    required DateTime now,
  }) {
    final eligible = signals.where((entry) => entry.playsInLast30Days > 0).toList();
    if (eligible.isEmpty) return const <TrendingEntry>[];

    var peak = 0;
    for (final entry in eligible) {
      if (entry.playsInLast30Days > peak) peak = entry.playsInLast30Days;
    }
    final ranked = _rank(
      eligible,
      TrendingPeriod.month,
      scoreOf: (entry) => logScaledCount(
        entry.playsInLast30Days,
        reference: math.max(peak, 1),
      ) * 100,
      deltaOf: (entry) => _growth(entry.playsInLast30Days, entry.playsInPrior30Days),
    );
    return _take(ranked);
  }

  /// Fastest growing: current weekly pace against the prior 30-day baseline.
  ///
  /// `delta = (last7 × 30/7) / prior30`. A track played 10 times this week and
  /// 10 times in the previous month is accelerating hard; one played once a
  /// week for a year sits at ~1.0 and never trends.
  List<TrendingEntry> fastestGrowing(
    Iterable<TrackSignals> signals, {
    required DateTime now,
  }) {
    final eligible = signals
        .where((entry) => entry.playsInLast7Days >= minVelocityPlays)
        .toList();
    if (eligible.isEmpty) return const <TrendingEntry>[];

    final withGrowth = <_GrowthRow>[];
    var peakGrowth = 0.0;
    for (final entry in eligible) {
      final growth = _growth(
        (entry.playsInLast7Days * 30) ~/ 7,
        entry.playsInPrior30Days,
      );
      if (growth > peakGrowth) peakGrowth = growth;
      withGrowth.add(_GrowthRow(entry, growth));
    }

    withGrowth.sort((a, b) {
      final byGrowth = b.growth.compareTo(a.growth);
      if (byGrowth != 0) return byGrowth;
      final byPlays = b.signals.playsInLast7Days.compareTo(
        a.signals.playsInLast7Days,
      );
      if (byPlays != 0) return byPlays;
      return a.signals.title.toLowerCase().compareTo(
        b.signals.title.toLowerCase(),
      );
    });

    final results = <TrendingEntry>[];
    for (var i = 0; i < withGrowth.length && i < limit; i++) {
      final row = withGrowth[i];
      // Volume keeps a single lucky play from topping the shelf: the score
      // blends growth with how much was actually played.
      final volume = logScaledCount(
        row.signals.playsInLast7Days,
        reference: math.max(minVelocityPlays * 4, 1),
      );
      final growthScore = peakGrowth <= 1
          ? 0.5
          : clamp01((row.growth - 1) / (peakGrowth - 1));
      results.add(
        TrendingEntry(
          key: row.signals.trackKey,
          label: row.signals.title,
          subtitle: row.signals.artist,
          rank: i + 1,
          score: clampScore((0.65 * growthScore + 0.35 * volume) * 100),
          playCount: row.signals.playsInLast7Days,
          delta: row.growth,
          period: TrendingPeriod.velocity,
        ),
      );
    }
    return List<TrendingEntry>.unmodifiable(results);
  }

  /// Artists first heard inside [emergingWindow] whose plays are climbing.
  List<TrendingEntry> emergingArtists(
    Iterable<ArtistSignals> artists, {
    required DateTime now,
  }) {
    final eligible = artists
        .where(
          (entry) =>
              now.difference(entry.firstPlayedAt) <= emergingWindow &&
              entry.playsInLast30Days > 0,
        )
        .toList();
    if (eligible.isEmpty) return const <TrendingEntry>[];

    final rows = <_ArtistGrowthRow>[];
    for (final entry in eligible) {
      final growth = _growth(entry.playsInLast30Days, entry.playsInPrior30Days);
      // A brand-new artist has no baseline; treat "no prior plays" as growth
      // rather than a division by zero, but rank it below an accelerating one.
      final effective = entry.playsInPrior30Days == 0 ? math.max(growth, 1.2) : growth;
      rows.add(_ArtistGrowthRow(entry, effective));
    }
    rows.sort((a, b) {
      final byGrowth = b.growth.compareTo(a.growth);
      if (byGrowth != 0) return byGrowth;
      final byPlays = b.signals.playsInLast30Days.compareTo(
        a.signals.playsInLast30Days,
      );
      if (byPlays != 0) return byPlays;
      return a.signals.label.toLowerCase().compareTo(
        b.signals.label.toLowerCase(),
      );
    });

    var peakPlays = 0;
    for (final row in rows) {
      if (row.signals.playsInLast30Days > peakPlays) {
        peakPlays = row.signals.playsInLast30Days;
      }
    }

    final results = <TrendingEntry>[];
    for (var i = 0; i < rows.length && i < limit; i++) {
      final row = rows[i];
      final volume = logScaledCount(
        row.signals.playsInLast30Days,
        reference: math.max(peakPlays, 1),
      );
      final freshness = clamp01(
        1 -
            now.difference(row.signals.firstPlayedAt).inDays /
                emergingWindow.inDays,
      );
      results.add(
        TrendingEntry(
          key: row.signals.artistKey,
          label: row.signals.label,
          subtitle: '${row.signals.trackCount} tracks',
          coverUrl: row.signals.coverUrl,
          rank: i + 1,
          score: clampScore(
            (0.5 * volume + 0.3 * freshness + 0.2 * clamp01((row.growth - 1) / 3)) *
                100,
          ),
          playCount: row.signals.playsInLast30Days,
          delta: row.growth,
          period: TrendingPeriod.emerging,
          isArtist: true,
          firstPlayedAt: row.signals.firstPlayedAt,
        ),
      );
    }
    return List<TrendingEntry>.unmodifiable(results);
  }

  List<TrendingEntry> _rank(
    List<TrackSignals> signals,
    TrendingPeriod period, {
    required double Function(TrackSignals) scoreOf,
    required double Function(TrackSignals) deltaOf,
  }) {
    signals.sort((a, b) {
      final byScore = scoreOf(b).compareTo(scoreOf(a));
      if (byScore != 0) return byScore;
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    return <TrendingEntry>[
      for (var i = 0; i < signals.length; i++)
        TrendingEntry(
          key: signals[i].trackKey,
          label: signals[i].title,
          subtitle: signals[i].artist,
          rank: i + 1,
          score: clampScore(scoreOf(signals[i])),
          playCount: period == TrendingPeriod.week
              ? signals[i].playsInLast7Days
              : signals[i].playsInLast30Days,
          delta: deltaOf(signals[i]),
          period: period,
        ),
    ];
  }

  List<TrendingEntry> _take(List<TrendingEntry> entries) {
    if (limit > 0 && entries.length > limit) {
      return List<TrendingEntry>.unmodifiable(entries.sublist(0, limit));
    }
    return List<TrendingEntry>.unmodifiable(entries);
  }

  /// `current / baseline`, with a floor so a zero baseline yields a finite,
  /// comparable number instead of infinity.
  double _growth(int current, int baseline) {
    if (current <= 0) return 0;
    if (baseline <= 0) return current.toDouble();
    return current / baseline;
  }
}

class _GrowthRow {
  const _GrowthRow(this.signals, this.growth);
  final TrackSignals signals;
  final double growth;
}

class _ArtistGrowthRow {
  const _ArtistGrowthRow(this.signals, this.growth);
  final ArtistSignals signals;
  final double growth;
}
