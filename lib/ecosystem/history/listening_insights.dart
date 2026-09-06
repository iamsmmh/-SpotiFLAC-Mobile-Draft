/// Listening insights + recap models (Feature Groups 4 & 12).
///
/// Pure computation over [PlayEvent] lists: no database, no Flutter. The
/// analytics page feeds it a window of events and renders the result, and the
/// yearly-recap builder reuses the same code with a 365-day window.
library;

import 'package:spotimusic/ecosystem/history/listening_history.dart';

/// Aggregated listening stats for one ranking dimension.
class ListeningRanking {
  const ListeningRanking({
    required this.title,
    required this.playCount,
    required this.listenedMs,
    this.subtitle = '',
    this.coverUrl,
    this.skipCount = 0,
  });

  final String title;
  final String subtitle;
  final int playCount;
  final int listenedMs;
  final int skipCount;
  final String? coverUrl;

  Duration get listened => Duration(milliseconds: listenedMs);

  double get skipRate => playCount == 0 ? 0 : skipCount / playCount;

  @override
  String toString() => '$title ($playCount plays)';
}

/// Aggregated history for one artist (Feature 7 view over the events).
class ArtistHistory {
  const ArtistHistory({
    required this.artist,
    required this.playCount,
    required this.skipCount,
    required this.listenedMs,
    required this.firstPlayedAt,
    required this.lastPlayedAt,
    this.trackCount = 0,
  });

  final String artist;
  final int playCount;
  final int skipCount;
  final int listenedMs;
  final DateTime firstPlayedAt;
  final DateTime lastPlayedAt;

  /// Distinct tracks of this artist in the window.
  final int trackCount;

  Duration get listened => Duration(milliseconds: listenedMs);

  double get skipRate => playCount == 0 ? 0 : skipCount / playCount;
}

/// Aggregated history for one album (Feature 7 view over the events).
class AlbumHistory {
  const AlbumHistory({
    required this.album,
    required this.artist,
    required this.playCount,
    required this.skipCount,
    required this.listenedMs,
    required this.lastPlayedAt,
    this.coverUrl,
  });

  final String album;
  final String artist;
  final int playCount;
  final int skipCount;
  final int listenedMs;
  final DateTime lastPlayedAt;
  final String? coverUrl;

  Duration get listened => Duration(milliseconds: listenedMs);

  double get skipRate => playCount == 0 ? 0 : skipCount / playCount;
}

/// Everything the insights/analytics surfaces need.
class ListeningInsights {
  const ListeningInsights({
    required this.rangeStart,
    required this.rangeEnd,
    required this.totalListenedMs,
    required this.playCount,
    required this.skipCount,
    required this.uniqueTracks,
    required this.averageCompletion,
    required this.topTracks,
    required this.topArtists,
    required this.topAlbums,
    required this.minutesByDay,
    required this.playsByHour,
    required this.busiestDay,
    required this.longestStreakDays,
    required this.currentStreakDays,
  });

  final DateTime rangeStart;
  final DateTime rangeEnd;

  final int totalListenedMs;
  final int playCount;
  final int skipCount;
  final int uniqueTracks;

  /// Mean completion across all events (0..1).
  final double averageCompletion;

  final List<ListeningRanking> topTracks;
  final List<ListeningRanking> topArtists;
  final List<ListeningRanking> topAlbums;

  /// Local date (yyyy-mm-dd) → minutes listened.
  final Map<String, double> minutesByDay;

  /// Hour-of-day (0..23) → number of plays started.
  final Map<int, int> playsByHour;

  /// Day key with the most listening, or null when the window is empty.
  final String? busiestDay;

  final int longestStreakDays;
  final int currentStreakDays;

  static final ListeningInsights empty = ListeningInsights(
    rangeStart: _epoch,
    rangeEnd: _epoch,
    totalListenedMs: 0,
    playCount: 0,
    skipCount: 0,
    uniqueTracks: 0,
    averageCompletion: 0,
    topTracks: <ListeningRanking>[],
    topArtists: <ListeningRanking>[],
    topAlbums: <ListeningRanking>[],
    minutesByDay: <String, double>{},
    playsByHour: <int, int>{},
    busiestDay: null,
    longestStreakDays: 0,
    currentStreakDays: 0,
  );

  static final DateTime _epoch = DateTime.fromMillisecondsSinceEpoch(0);

  Duration get totalListened => Duration(milliseconds: totalListenedMs);

  double get listeningHours => totalListenedMs / Duration.millisecondsPerHour;

  double get skipRate => playCount == 0 ? 0 : skipCount / playCount;

  /// Average minutes per active day.
  double get minutesPerActiveDay =>
      minutesByDay.isEmpty ? 0 : _totalMinutes / minutesByDay.length;

  double get _totalMinutes => totalListenedMs / Duration.millisecondsPerMinute;

  bool get isEmpty => playCount == 0;
}

/// Yearly-recap style summary built from the same primitives.
class RecapReport {
  const RecapReport({
    required this.year,
    required this.insights,
    required this.minutesByMonth,
    required this.topGenres,
    required this.milestones,
  });

  final int year;
  final ListeningInsights insights;

  /// Month number (1..12) → minutes listened.
  final Map<int, double> minutesByMonth;

  /// Best-effort genre ranking derived from metadata when present.
  final List<ListeningRanking> topGenres;

  /// Human-readable highlights ("Listened in 42 different days", …).
  final List<String> milestones;

  Duration get totalListened => insights.totalListened;
}

/// Pure calculator — the single place ranking/trend maths lives.
class InsightsCalculator {
  const InsightsCalculator();

  /// Computes insights for [events] (already filtered to the window).
  ListeningInsights compute(
    List<PlayEvent> events, {
    required DateTime rangeStart,
    required DateTime rangeEnd,
    int topLimit = 10,
  }) {
    if (events.isEmpty) {
      return ListeningInsights(
        rangeStart: rangeStart,
        rangeEnd: rangeEnd,
        totalListenedMs: 0,
        playCount: 0,
        skipCount: 0,
        uniqueTracks: 0,
        averageCompletion: 0,
        topTracks: const <ListeningRanking>[],
        topArtists: const <ListeningRanking>[],
        topAlbums: const <ListeningRanking>[],
        minutesByDay: const <String, double>{},
        playsByHour: const <int, int>{},
        busiestDay: null,
        longestStreakDays: 0,
        currentStreakDays: 0,
      );
    }

    final minutesByDay = <String, double>{};
    final playsByHour = <int, int>{};
    final trackStats = <String, _Accumulator>{};
    final artistStats = <String, _Accumulator>{};
    final albumStats = <String, _Accumulator>{};
    final uniqueTracks = <String>{};
    var totalMs = 0;
    var skips = 0;
    var completionSum = 0.0;

    for (final event in events) {
      totalMs += event.playedMs;
      if (event.skipped) skips++;
      completionSum += event.completion;
      uniqueTracks.add(event.trackKey);

      final day = _dayKey(event.endedAt);
      minutesByDay[day] =
          (minutesByDay[day] ?? 0) + event.playedMs / Duration.millisecondsPerMinute;
      final hour = event.endedAt.toLocal().hour;
      playsByHour[hour] = (playsByHour[hour] ?? 0) + 1;

      trackStats
          .putIfAbsent(
            event.trackKey,
            () => _Accumulator(
              title: event.title,
              subtitle: event.artist,
              coverUrl: event.coverUrl,
            ),
          )
          .add(event);
      final artist = event.artist.trim().isEmpty ? 'Unknown artist' : event.artist.trim();
      artistStats
          .putIfAbsent(artist.toLowerCase(), () => _Accumulator(title: artist))
          .add(event);
      final albumKey = '${event.album.trim().toLowerCase()}|${artist.toLowerCase()}';
      albumStats
          .putIfAbsent(
            albumKey,
            () => _Accumulator(
              title: event.album.trim().isEmpty ? 'Unknown album' : event.album.trim(),
              subtitle: artist,
              coverUrl: event.coverUrl,
            ),
          )
          .add(event);
    }

    final playCount = events.length;
    final dayKeys = minutesByDay.keys.toList()..sort();
    String? busiestDay;
    var busiestMinutes = 0.0;
    for (final day in dayKeys) {
      final minutes = minutesByDay[day] ?? 0;
      if (minutes > busiestMinutes) {
        busiestMinutes = minutes;
        busiestDay = day;
      }
    }

    return ListeningInsights(
      rangeStart: rangeStart,
      rangeEnd: rangeEnd,
      totalListenedMs: totalMs,
      playCount: playCount,
      skipCount: skips,
      uniqueTracks: uniqueTracks.length,
      averageCompletion: playCount == 0 ? 0 : completionSum / playCount,
      topTracks: _top(trackStats, topLimit),
      topArtists: _top(artistStats, topLimit),
      topAlbums: _top(albumStats, topLimit),
      minutesByDay: Map<String, double>.unmodifiable(minutesByDay),
      playsByHour: Map<int, int>.unmodifiable(playsByHour),
      busiestDay: busiestDay,
      longestStreakDays: _longestStreak(dayKeys),
      currentStreakDays: _currentStreak(dayKeys, rangeEnd),
    );
  }

  /// Builds a yearly recap. [events] should already be limited to [year].
  RecapReport buildRecap(
    List<PlayEvent> events, {
    required int year,
    required DateTime now,
    int topLimit = 10,
  }) {
    final start = DateTime.utc(year);
    final end = DateTime.utc(year + 1).subtract(const Duration(milliseconds: 1));
    final insights = compute(
      events,
      rangeStart: start,
      rangeEnd: end.isAfter(now) ? now : end,
      topLimit: topLimit,
    );

    final minutesByMonth = <int, double>{};
    for (final event in events) {
      final month = event.endedAt.toLocal().month;
      minutesByMonth[month] =
          (minutesByMonth[month] ?? 0) +
          event.playedMs / Duration.millisecondsPerMinute;
    }

    final milestones = <String>[
      if (insights.uniqueTracks > 0)
        'Played ${insights.uniqueTracks} different tracks',
      if (insights.topArtists.isNotEmpty)
        '${insights.topArtists.first.title} was your most played artist',
      if (insights.longestStreakDays > 1)
        'Longest listening streak: ${insights.longestStreakDays} days',
      if (insights.listeningHours >= 1)
        '${insights.listeningHours.toStringAsFixed(1)} hours of music',
      if (insights.busiestDay != null) 'Busiest day: ${insights.busiestDay}',
    ];

    return RecapReport(
      year: year,
      insights: insights,
      minutesByMonth: Map<int, double>.unmodifiable(minutesByMonth),
      topGenres: const <ListeningRanking>[],
      milestones: List<String>.unmodifiable(milestones),
    );
  }

  /// Trend comparison: percentage change in minutes versus the previous window
  /// of the same length. Null when there is no baseline.
  double? trendVersusPrevious({
    required double currentMinutes,
    required double previousMinutes,
  }) {
    if (previousMinutes <= 0) return null;
    return (currentMinutes - previousMinutes) / previousMinutes * 100;
  }

  List<ListeningRanking> _top(Map<String, _Accumulator> stats, int limit) {
    final ranked = stats.values.toList(growable: false)
      ..sort((a, b) {
        final byListened = b.listenedMs.compareTo(a.listenedMs);
        return byListened != 0
            ? byListened
            : b.playCount.compareTo(a.playCount);
      });
    final sliced = ranked.take(limit);
    return sliced
        .map(
          (accumulator) => ListeningRanking(
            title: accumulator.title,
            subtitle: accumulator.subtitle,
            playCount: accumulator.playCount,
            listenedMs: accumulator.listenedMs,
            skipCount: accumulator.skipCount,
            coverUrl: accumulator.coverUrl,
          ),
        )
        .toList(growable: false);
  }

  /// Longest run of consecutive listening days.
  int _longestStreak(List<String> sortedDayKeys) {
    if (sortedDayKeys.isEmpty) return 0;
    var longest = 1;
    var current = 1;
    for (var i = 1; i < sortedDayKeys.length; i++) {
      final previous = DateTime.tryParse(sortedDayKeys[i - 1]);
      final day = DateTime.tryParse(sortedDayKeys[i]);
      if (previous == null || day == null) continue;
      if (day.difference(previous).inDays == 1) {
        current++;
        if (current > longest) longest = current;
      } else {
        current = 1;
      }
    }
    return longest;
  }

  /// Streak ending today (or yesterday — a day that has not finished yet does
  /// not break the streak).
  int _currentStreak(List<String> sortedDayKeys, DateTime rangeEnd) {
    if (sortedDayKeys.isEmpty) return 0;
    final days = sortedDayKeys.toSet();
    var cursor = DateTime(
      rangeEnd.year,
      rangeEnd.month,
      rangeEnd.day,
    );
    if (!days.contains(_key(cursor))) {
      final yesterday = cursor.subtract(const Duration(days: 1));
      if (!days.contains(_key(yesterday))) return 0;
      cursor = yesterday;
    }
    var streak = 0;
    while (days.contains(_key(cursor))) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  static String _key(DateTime day) =>
      '${day.year.toString().padLeft(4, '0')}-'
      '${day.month.toString().padLeft(2, '0')}-'
      '${day.day.toString().padLeft(2, '0')}';

  static String _dayKey(DateTime instant) => _key(instant.toLocal());
}

extension ArtistAlbumHistory on InsightsCalculator {
  /// Aggregates events per artist (play/skip counts, listening time).
  List<ArtistHistory> artistHistory(List<PlayEvent> events, {int limit = 50}) {
    final stats = <String, _ArtistAlbumAccumulator>{};
    for (final event in events) {
      final key = event.artist.trim().isEmpty ? 'Unknown artist' : event.artist.trim();
      final accumulator = stats.putIfAbsent(
        key,
        () => _ArtistAlbumAccumulator(title: key),
      );
      accumulator.add(event);
    }
    final ranked = stats.values.toList(growable: false)
      ..sort((a, b) {
        final byListened = b.listenedMs.compareTo(a.listenedMs);
        return byListened != 0
            ? byListened
            : b.playCount.compareTo(a.playCount);
      });
    return <ArtistHistory>[
      for (final accumulator in ranked.take(limit))
        ArtistHistory(
          artist: accumulator.title,
          playCount: accumulator.playCount,
          skipCount: accumulator.skipCount,
          listenedMs: accumulator.listenedMs,
          firstPlayedAt: accumulator.firstAt,
          lastPlayedAt: accumulator.lastAt,
          trackCount: accumulator.titles.length,
        ),
    ];
  }

  /// Aggregates events per album.
  List<AlbumHistory> albumHistory(List<PlayEvent> events, {int limit = 50}) {
    final stats = <String, _ArtistAlbumAccumulator>{};
    for (final event in events) {
      final album = event.album.trim();
      if (album.isEmpty) continue;
      final key = '$album|${event.artist.trim()}';
      final accumulator = stats.putIfAbsent(
        key,
        () => _ArtistAlbumAccumulator(
          title: album,
          subtitle: event.artist.trim(),
          coverUrl: event.coverUrl,
        ),
      );
      accumulator.add(event);
    }
    final ranked = stats.values.toList(growable: false)
      ..sort((a, b) {
        final byListened = b.listenedMs.compareTo(a.listenedMs);
        return byListened != 0
            ? byListened
            : b.playCount.compareTo(a.playCount);
      });
    return <AlbumHistory>[
      for (final accumulator in ranked.take(limit))
        AlbumHistory(
          album: accumulator.title,
          artist: accumulator.subtitle,
          playCount: accumulator.playCount,
          skipCount: accumulator.skipCount,
          listenedMs: accumulator.listenedMs,
          lastPlayedAt: accumulator.lastAt,
          coverUrl: accumulator.coverUrl,
        ),
    ];
  }
}

class _ArtistAlbumAccumulator {
  _ArtistAlbumAccumulator({
    required this.title,
    this.subtitle = '',
    this.coverUrl,
  });

  final String title;
  final String subtitle;
  String? coverUrl;
  int playCount = 0;
  int skipCount = 0;
  int listenedMs = 0;
  DateTime firstAt = DateTime.now();
  DateTime lastAt = DateTime.now();
  final Set<String> titles = <String>{};

  void add(PlayEvent event) {
    playCount++;
    if (event.skipped) skipCount++;
    listenedMs += event.playedMs;
    titles.add(event.title);
    coverUrl ??= event.coverUrl;
    if (event.startedAt.isBefore(firstAt)) firstAt = event.startedAt;
    if (event.endedAt.isAfter(lastAt)) lastAt = event.endedAt;
  }
}

class _Accumulator {
  _Accumulator({required this.title, this.subtitle = '', this.coverUrl});

  final String title;
  final String subtitle;
  String? coverUrl;
  int playCount = 0;
  int skipCount = 0;
  int listenedMs = 0;

  void add(PlayEvent event) {
    playCount++;
    if (event.skipped) skipCount++;
    listenedMs += event.playedMs;
    coverUrl ??= event.coverUrl;
  }
}
