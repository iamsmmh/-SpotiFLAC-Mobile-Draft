import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/history/listening_history.dart';
import 'package:spotiflac_android/ecosystem/history/listening_insights.dart';

const _calculator = InsightsCalculator();

PlayEvent _event(
  String key,
  String title,
  String artist,
  String album, {
  int playedMs = 120000,
  int durationMs = 200000,
  DateTime? at,
  bool skipped = false,
}) {
  final ended = at ?? DateTime(2026, 9, 1, 12);
  return PlayEvent(
    trackKey: key,
    title: title,
    artist: artist,
    album: album,
    durationMs: durationMs,
    playedMs: playedMs,
    startedAt: ended.subtract(Duration(milliseconds: playedMs)),
    endedAt: ended,
    skipped: skipped,
  );
}

void main() {
  group('PlayEvent', () {
    test('completion is clamped and completion threshold is 90%', () {
      expect(_event('a', 'A', 'x', 'y').completion, 0.6);
      expect(
        _event('a', 'A', 'x', 'y', playedMs: 190000).completed,
        isTrue,
      );
      expect(
        _event('a', 'A', 'x', 'y', playedMs: 190000, skipped: true).completed,
        isFalse,
      );
      expect(
        _event('a', 'A', 'x', 'y', playedMs: 900000, durationMs: 100000)
            .completion,
        1.0,
      );
    });
  });

  group('InsightsCalculator', () {
    final events = <PlayEvent>[
      _event('t1', 'Alpha', 'Ada', 'First', at: DateTime(2026, 9, 1, 8)),
      _event('t1', 'Alpha', 'Ada', 'First', at: DateTime(2026, 9, 1, 20)),
      _event('t2', 'Beta', 'Ada', 'First', at: DateTime(2026, 9, 2, 9)),
      _event(
        't3',
        'Gamma',
        'Bo',
        'Second',
        at: DateTime(2026, 9, 3, 23),
        skipped: true,
      ),
    ];

    test('aggregates totals, uniques and completion', () {
      final insights = _calculator.compute(
        events,
        rangeStart: DateTime(2026, 9, 1),
        rangeEnd: DateTime(2026, 9, 4),
      );
      expect(insights.playCount, 4);
      expect(insights.uniqueTracks, 3);
      expect(insights.skipCount, 1);
      expect(insights.totalListened.inMinutes, 8); // 4 × 2 min
      expect(insights.minutesByDay.length, 3);
      expect(insights.averageCompletion, closeTo(0.6, 0.001));
    });

    test('ranks artists, albums and tracks by time listened', () {
      final insights = _calculator.compute(
        events,
        rangeStart: DateTime(2026, 9, 1),
        rangeEnd: DateTime(2026, 9, 4),
      );
      expect(insights.topArtists.first.title, 'Ada');
      expect(insights.topArtists.first.playCount, 3);
      expect(insights.topTracks.first.title, 'Alpha');
      expect(insights.topTracks.first.playCount, 2);
      expect(insights.topAlbums.first.title, 'First');
    });

    test('streaks count consecutive days', () {
      final insights = _calculator.compute(
        events,
        rangeStart: DateTime(2026, 9, 1),
        rangeEnd: DateTime(2026, 9, 3, 23),
      );
      expect(insights.longestStreakDays, 3);
      expect(insights.currentStreakDays, 3);
    });

    test('an empty window yields the empty insight', () {
      final insights = _calculator.compute(
        const <PlayEvent>[],
        rangeStart: DateTime(2026, 9, 1),
        rangeEnd: DateTime(2026, 9, 4),
      );
      expect(insights.isEmpty, isTrue);
      expect(insights.topTracks, isEmpty);
      expect(insights.busiestDay, isNull);
    });

    test('hourly histogram records local hours', () {
      final insights = _calculator.compute(
        events,
        rangeStart: DateTime(2026, 9, 1),
        rangeEnd: DateTime(2026, 9, 4),
      );
      expect(insights.playsByHour.values.reduce((a, b) => a + b), 4);
    });

    test('yearly recap reports milestones and monthly minutes', () {
      final recap = _calculator.buildRecap(
        events,
        year: 2026,
        now: DateTime(2026, 12, 31),
      );
      expect(recap.year, 2026);
      expect(recap.milestones, isNotEmpty);
      expect(recap.minutesByMonth[9], 8);
    });

    test('trend needs a baseline to report a change', () {
      expect(
        _calculator.trendVersusPrevious(
          currentMinutes: 100,
          previousMinutes: 50,
        ),
        closeTo(100, 0.001),
      );
      expect(
        _calculator.trendVersusPrevious(
          currentMinutes: 100,
          previousMinutes: 0,
        ),
        isNull,
      );
    });
  });
}
