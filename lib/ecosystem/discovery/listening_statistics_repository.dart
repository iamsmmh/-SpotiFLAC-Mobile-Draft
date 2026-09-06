/// Day-bucketed listening statistics (Phase 1 storage).
///
/// The raw event log (`ec_listening_events`) is append-only and owned by
/// `history/listening_history.dart`. This repository **rolls it up** into
/// `ds_listening_statistics`, one row per `(track_key, UTC day)`, so every
/// downstream question — "most played this week", "night listening", "fastest
/// growing" — is an indexed range scan instead of a full walk of the event log.
///
/// Battery/IO discipline (Phase 12):
///   * the roll-up is incremental — a `last_event_id` watermark in
///     `ec_meta` means a normal run reads only new events;
///   * it runs off the UI thread (`compute` is not needed: the work is SQL,
///     and Dart-side arithmetic is O(new events));
///   * it is debounced by the caller (`DiscoveryService`) to at most once per
///     interval, never once per play.
///
/// No `ON CONFLICT … DO UPDATE`: Android API 24 ships SQLite 3.9, so
/// aggregates use an explicit read-modify-write inside a transaction, exactly
/// like `ListeningHistoryRepository.record`.
library;

import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_schema.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/ecosystem/history/listening_history.dart';
import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/trending_engine.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('DiscoveryStats');

/// Watermark key in `ec_meta`.
const String dsRollupWatermarkKey = 'discovery_stats_last_event_id';

/// One aggregated day bucket as read back from SQLite.
class _BucketRow {
  const _BucketRow({
    required this.trackKey,
    required this.bucket,
    required this.title,
    required this.artist,
    required this.album,
    required this.playCount,
    required this.skipCount,
    required this.completedCount,
    required this.repeatCount,
    required this.listenedMs,
    required this.completionSum,
    required this.nightPlayCount,
    required this.weekendPlayCount,
    required this.hourHistogram,
    required this.lastPlayedAt,
  });

  final String trackKey;
  final String bucket;
  final String title;
  final String artist;
  final String album;
  final int playCount;
  final int skipCount;
  final int completedCount;
  final int repeatCount;
  final int listenedMs;
  final double completionSum;
  final int nightPlayCount;
  final int weekendPlayCount;
  final Map<int, int> hourHistogram;
  final String lastPlayedAt;

  static _BucketRow fromRow(Map<String, Object?> row) {
    int asInt(String key) {
      final value = row[key];
      return value is num ? value.toInt() : 0;
    }

    double asDouble(String key) {
      final value = row[key];
      return value is num ? value.toDouble() : 0;
    }

    return _BucketRow(
      trackKey: row['track_key']?.toString() ?? '',
      bucket: row['bucket']?.toString() ?? '',
      title: row['title']?.toString() ?? '',
      artist: row['artist']?.toString() ?? '',
      album: row['album']?.toString() ?? '',
      playCount: asInt('play_count'),
      skipCount: asInt('skip_count'),
      completedCount: asInt('completed_count'),
      repeatCount: asInt('repeat_count'),
      listenedMs: asInt('listened_ms'),
      completionSum: asDouble('completion_sum'),
      nightPlayCount: asInt('night_play_count'),
      weekendPlayCount: asInt('weekend_play_count'),
      hourHistogram: _decodeHistogram(row['hour_histogram']?.toString()),
      lastPlayedAt: row['last_played_at']?.toString() ?? '',
    );
  }
}

/// Reads and maintains `ds_listening_statistics`.
class ListeningStatisticsRepository {
  ListeningStatisticsRepository({
    EcosystemDatabase? database,
    this.repeatWindow = const Duration(minutes: 5),
    this.habitLookbackDays = 90,
    this.sessionGap = const Duration(minutes: 30),
    this.habitEventCap = 20000,
  }) : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  /// A play starting within this window of the previous play of the same track
  /// counts as a repeat.
  final Duration repeatWindow;

  /// Habits (sessions, hour histogram) are computed over this window. Bounded
  /// so a multi-year history cannot make a background refresh expensive.
  final int habitLookbackDays;

  /// Gap that separates two listening sessions.
  final Duration sessionGap;

  /// Hard cap on events read for the session computation.
  final int habitEventCap;

  // -------------------------------------------------------------------------
  // Roll-up
  // -------------------------------------------------------------------------

  /// Folds every new event since the watermark into the day buckets.
  ///
  /// Returns the number of events processed. Safe to call on every app
  /// resume; it is a no-op when nothing new arrived.
  Future<int> rollUp({int maxEvents = 20000}) async {
    final db = await _database.database;
    final watermark = await _readWatermark(db);

    final rows = await db.query(
      tableListeningEvents,
      where: 'id > ?',
      whereArgs: <Object?>[watermark],
      orderBy: 'id ASC',
      limit: maxEvents,
    );
    if (rows.isEmpty) return 0;

    // Pair each row with its decoded event so the id watermark and the
    // accumulation stay aligned (rows with an empty track key are skipped
    // without losing their id).
    final pairs = <(int, PlayEvent)>[];
    var highestId = watermark;
    for (final row in rows) {
      final id = row['id'];
      final rowId = id is num ? id.toInt() : 0;
      if (rowId > highestId) highestId = rowId;
      final event = PlayEvent.fromRow(row);
      if (event.trackKey.isEmpty) continue;
      pairs.add((rowId, event));
    }
    if (pairs.isEmpty) {
      await _writeWatermark(db, highestId);
      return 0;
    }

    // Group into (track, day) buckets, tracking repeats in chronological
    // order — the only stateful part of the roll-up. Rows arrive ordered by
    // `id ASC`, which is insertion order and therefore time order.
    //
    // Known, accepted edge: a repeat whose two plays straddle a roll-up
    // boundary is not counted, because the previous play's timestamp is not
    // re-read. That costs at most one repeat per track per roll-up and keeps
    // the common path free of an extra query.
    final deltas = <String, _BucketDelta>{};
    final lastPlayedAt = <String, DateTime>{};
    for (final pair in pairs) {
      _accumulate(deltas, lastPlayedAt, pair.$2);
    }

    await db.transaction((txn) async {
      for (final delta in deltas.values) {
        await _applyDelta(txn, delta);
      }
      await txn.insert(
        tableEcosystemMeta,
        <String, Object?>{
          'key': dsRollupWatermarkKey,
          'value': '$highestId',
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    });

    _log.i('Rolled up ${events.length} listening events');
    return events.length;
  }

  void _accumulate(
    Map<String, _BucketDelta> deltas,
    Map<String, DateTime> lastPlayedAt,
    PlayEvent event,
  ) {
    final started = event.startedAt.toUtc();
    final bucket = dayKey(started);
    final key = '${event.trackKey}@$bucket';
    final delta = deltas.putIfAbsent(
      key,
      () => _BucketDelta(
        trackKey: event.trackKey,
        bucket: bucket,
        title: event.title,
        artist: event.artist,
        album: event.album,
      ),
    );

    final previous = lastPlayedAt[event.trackKey];
    final isRepeat =
        previous != null && started.difference(previous) <= repeatWindow;
    lastPlayedAt[event.trackKey] = started;

    delta.playCount++;
    delta.listenedMs += event.playedMs;
    delta.completionSum += event.completion;
    if (event.skipped) {
      delta.skipCount++;
    } else if (event.completed) {
      delta.completedCount++;
    }
    if (isRepeat) delta.repeatCount++;

    final hour = started.hour.clamp(0, 23);
    delta.hourHistogram[hour] = (delta.hourHistogram[hour] ?? 0) + 1;
    if (daytimeBucketForHour(hour) == DaytimeBucket.night) {
      delta.nightPlayCount++;
    }
    final weekday = started.weekday;
    if (weekday == DateTime.saturday || weekday == DateTime.sunday) {
      delta.weekendPlayCount++;
    }
    final ended = event.endedAt.toUtc().toIso8601String();
    if (ended.compareTo(delta.lastPlayedAt) > 0) {
      delta.lastPlayedAt = ended;
    }
  }

  Future<void> _applyDelta(Transaction txn, _BucketDelta delta) async {
    final existing = await txn.query(
      dsListeningStatistics,
      where: 'track_key = ? AND bucket = ?',
      whereArgs: <Object?>[delta.trackKey, delta.bucket],
      limit: 1,
    );

    if (existing.isEmpty) {
      await txn.insert(dsListeningStatistics, <String, Object?>{
        'track_key': delta.trackKey,
        'bucket': delta.bucket,
        'title': delta.title,
        'artist': delta.artist,
        'album': delta.album,
        'play_count': delta.playCount,
        'skip_count': delta.skipCount,
        'completed_count': delta.completedCount,
        'repeat_count': delta.repeatCount,
        'listened_ms': delta.listenedMs,
        'completion_sum': delta.completionSum,
        'night_play_count': delta.nightPlayCount,
        'weekend_play_count': delta.weekendPlayCount,
        'hour_histogram': _encodeHistogram(delta.hourHistogram),
        'last_played_at': delta.lastPlayedAt,
      });
      return;
    }

    final row = _BucketRow.fromRow(existing.first);
    final merged = <int, int>{...row.hourHistogram};
    for (final entry in delta.hourHistogram.entries) {
      merged[entry.key] = (merged[entry.key] ?? 0) + entry.value;
    }
    final lastPlayed = row.lastPlayedAt.compareTo(delta.lastPlayedAt) >= 0
        ? row.lastPlayedAt
        : delta.lastPlayedAt;

    await txn.update(
      dsListeningStatistics,
      <String, Object?>{
        'title': delta.title.isEmpty ? row.title : delta.title,
        'artist': delta.artist.isEmpty ? row.artist : delta.artist,
        'album': delta.album.isEmpty ? row.album : delta.album,
        'play_count': row.playCount + delta.playCount,
        'skip_count': row.skipCount + delta.skipCount,
        'completed_count': row.completedCount + delta.completedCount,
        'repeat_count': row.repeatCount + delta.repeatCount,
        'listened_ms': row.listenedMs + delta.listenedMs,
        'completion_sum': row.completionSum + delta.completionSum,
        'night_play_count': row.nightPlayCount + delta.nightPlayCount,
        'weekend_play_count': row.weekendPlayCount + delta.weekendPlayCount,
        'hour_histogram': _encodeHistogram(merged),
        'last_played_at': lastPlayed,
      },
      where: 'track_key = ? AND bucket = ?',
      whereArgs: <Object?>[delta.trackKey, delta.bucket],
    );
  }

  Future<int> _readWatermark(DatabaseExecutor db) async {
    final rows = await db.query(
      tableEcosystemMeta,
      where: 'key = ?',
      whereArgs: <Object?>[dsRollupWatermarkKey],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return int.tryParse(rows.first['value']?.toString() ?? '') ?? 0;
  }

  Future<void> _writeWatermark(DatabaseExecutor db, int value) async {
    await db.insert(
      tableEcosystemMeta,
      <String, Object?>{'key': dsRollupWatermarkKey, 'value': '$value'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  /// Per-track signals over all time, with the windowed counts the trending
  /// engine needs. [limit] bounds memory on very large libraries.
  Future<List<TrackSignals>> trackSignals({int limit = 4000}) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc();
    final weekStart = dayKey(now.subtract(const Duration(days: 7)));
    final monthStart = dayKey(now.subtract(const Duration(days: 30)));
    final priorStart = dayKey(now.subtract(const Duration(days: 60)));

    final rows = await db.rawQuery(
      '''
      SELECT track_key,
             MAX(title) AS title,
             MAX(artist) AS artist,
             MAX(album) AS album,
             SUM(play_count) AS play_count,
             SUM(skip_count) AS skip_count,
             SUM(completed_count) AS completed_count,
             SUM(repeat_count) AS repeat_count,
             SUM(listened_ms) AS listened_ms,
             SUM(completion_sum) AS completion_sum,
             SUM(CASE WHEN bucket >= ? THEN play_count ELSE 0 END) AS plays_7d,
             SUM(CASE WHEN bucket >= ? THEN play_count ELSE 0 END) AS plays_30d,
             SUM(CASE WHEN bucket >= ? AND bucket < ? THEN play_count ELSE 0 END) AS plays_prior_30d,
             MIN(bucket) AS first_bucket,
             MAX(last_played_at) AS last_played_at
      FROM $dsListeningStatistics
      GROUP BY track_key
      ORDER BY SUM(play_count) DESC, MAX(last_played_at) DESC
      LIMIT ?
      ''',
      <Object?>[weekStart, monthStart, priorStart, monthStart, limit],
    );

    final results = <TrackSignals>[];
    for (final row in rows) {
      int asInt(String key) {
        final value = row[key];
        return value is num ? value.toInt() : 0;
      }

      double asDouble(String key) {
        final value = row[key];
        return value is num ? value.toDouble() : 0;
      }

      final trackKey = row['track_key']?.toString() ?? '';
      if (trackKey.isEmpty) continue;
      results.add(
        TrackSignals(
          trackKey: trackKey,
          title: row['title']?.toString() ?? '',
          artist: row['artist']?.toString() ?? '',
          album: row['album']?.toString() ?? '',
          playCount: asInt('play_count'),
          skipCount: asInt('skip_count'),
          completedCount: asInt('completed_count'),
          repeatCount: asInt('repeat_count'),
          listenedMs: asInt('listened_ms'),
          completionSum: asDouble('completion_sum'),
          firstPlayedAt:
              DateTime.tryParse('${row['first_bucket']}T00:00:00Z') ?? now,
          lastPlayedAt:
              DateTime.tryParse(row['last_played_at']?.toString() ?? '') ?? now,
          playsInLast7Days: asInt('plays_7d'),
          playsInLast30Days: asInt('plays_30d'),
          playsInPrior30Days: asInt('plays_prior_30d'),
        ),
      );
    }
    return List<TrackSignals>.unmodifiable(results);
  }

  /// Signals indexed by track key — the shape every engine consumes.
  Future<Map<String, TrackSignals>> signalsByKey({int limit = 4000}) async {
    final signals = await trackSignals(limit: limit);
    return <String, TrackSignals>{
      for (final entry in signals) entry.trackKey: entry,
    };
  }

  /// Per-artist rollup for the emerging-artists shelf.
  Future<List<ArtistSignals>> artistSignals({int limit = 2000}) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc();
    final monthStart = dayKey(now.subtract(const Duration(days: 30)));
    final priorStart = dayKey(now.subtract(const Duration(days: 60)));

    final rows = await db.rawQuery(
      '''
      SELECT LOWER(TRIM(artist)) AS artist_key,
             MAX(artist) AS label,
             SUM(play_count) AS play_count,
             SUM(CASE WHEN bucket >= ? THEN play_count ELSE 0 END) AS plays_30d,
             SUM(CASE WHEN bucket >= ? AND bucket < ? THEN play_count ELSE 0 END) AS plays_prior_30d,
             COUNT(DISTINCT track_key) AS track_count,
             MIN(bucket) AS first_bucket
      FROM $dsListeningStatistics
      WHERE TRIM(artist) <> ''
      GROUP BY LOWER(TRIM(artist))
      ORDER BY SUM(play_count) DESC
      LIMIT ?
      ''',
      <Object?>[monthStart, priorStart, monthStart, limit],
    );

    final results = <ArtistSignals>[];
    for (final row in rows) {
      int asInt(String key) {
        final value = row[key];
        return value is num ? value.toInt() : 0;
      }

      final label = row['label']?.toString() ?? '';
      if (label.isEmpty) continue;
      results.add(
        ArtistSignals(
          artistKey: discoveryEntityKey(label),
          label: label,
          playCount: asInt('play_count'),
          playsInLast30Days: asInt('plays_30d'),
          playsInPrior30Days: asInt('plays_prior_30d'),
          trackCount: asInt('track_count'),
          firstPlayedAt:
              DateTime.tryParse('${row['first_bucket']}T00:00:00Z') ?? now,
        ),
      );
    }
    return List<ArtistSignals>.unmodifiable(results);
  }

  /// Raw material for [ListeningHabits]: totals, hour histogram, weekday /
  /// weekend split and session boundaries, over [habitLookbackDays].
  Future<HabitsAggregate> habits() async {
    final db = await _database.database;
    final now = DateTime.now().toUtc();
    final since = now.subtract(Duration(days: habitLookbackDays));
    final sinceIso = since.toIso8601String();

    final totals = await db.rawQuery(
      '''
      SELECT SUM(play_count) AS plays,
             SUM(skip_count) AS skips,
             SUM(completed_count) AS completed,
             SUM(listened_ms) AS listened_ms,
             SUM(completion_sum) AS completion_sum,
             SUM(night_play_count) AS night_plays,
             SUM(weekend_play_count) AS weekend_plays,
             COUNT(DISTINCT bucket) AS active_days
      FROM $dsListeningStatistics
      WHERE bucket >= ?
      ''',
      <Object?>[dayKey(since)],
    );

    final hourRows = await db.rawQuery(
      '''
      SELECT substr(started_at, 12, 2) AS hour, COUNT(*) AS plays
      FROM $tableListeningEvents
      WHERE started_at >= ?
      GROUP BY substr(started_at, 12, 2)
      ''',
      <Object?>[sinceIso],
    );

    final sessionRows = await db.query(
      tableListeningEvents,
      columns: <String>['started_at', 'played_ms'],
      where: 'started_at >= ?',
      whereArgs: <Object?>[sinceIso],
      orderBy: 'started_at ASC',
      limit: habitEventCap,
    );

    int asInt(Map<String, Object?> row, String key) {
      final value = row[key];
      return value is num ? value.toInt() : 0;
    }

    final totalsRow = totals.isEmpty ? const <String, Object?>{} : totals.first;
    final histogram = <int, int>{};
    for (final row in hourRows) {
      final hour = int.tryParse(row['hour']?.toString() ?? '');
      if (hour == null || hour < 0 || hour > 23) continue;
      histogram[hour] = asInt(row, 'plays');
    }

    var sessionCount = 0;
    var sessionMs = 0;
    var currentMs = 0;
    DateTime? previousStart;
    for (final row in sessionRows) {
      final started = DateTime.tryParse(row['started_at']?.toString() ?? '');
      if (started == null) continue;
      final playedMs = asInt(row, 'played_ms');
      if (previousStart == null ||
          started.difference(previousStart!) > sessionGap) {
        if (currentMs > 0) {
          sessionCount++;
          sessionMs += currentMs;
        }
        currentMs = 0;
      }
      currentMs += playedMs;
      previousStart = started.toUtc();
    }
    if (currentMs > 0) {
      sessionCount++;
      sessionMs += currentMs;
    }

    final plays = asInt(totalsRow, 'plays');
    final skips = asInt(totalsRow, 'skips');
    final completed = asInt(totalsRow, 'completed');
    final weekendPlays = asInt(totalsRow, 'weekend_plays');
    final completionSum = totalsRow['completion_sum'];

    return HabitsAggregate(
      habits: ListeningHabits(
        totalPlays: plays,
        totalListenedMs: asInt(totalsRow, 'listened_ms'),
        activeDays: asInt(totalsRow, 'active_days'),
        sessionCount: sessionCount,
        totalSessionMs: sessionMs,
        hourHistogram: Map<int, int>.unmodifiable(histogram),
        weekdayPlays: plays - weekendPlays < 0 ? 0 : plays - weekendPlays,
        weekendPlays: weekendPlays,
        skipRate: plays <= 0 ? 0 : (skips / plays).clamp(0.0, 1.0),
        averageCompletion: plays <= 0
            ? 0
            : ((completionSum is num ? completionSum.toDouble() : 0) / plays)
                  .clamp(0.0, 1.0),
      ),
      completedCount: completed,
    );
  }

  /// Every distinct (artist, album, genre-free) label pair seen, newest first.
  ///
  /// Used to enrich candidates whose metadata is missing from the library row.
  Future<Map<String, TrackSignals>> mostRecentByArtist({int limit = 500}) async {
    final signals = await trackSignals(limit: limit);
    final result = <String, TrackSignals>{};
    for (final entry in signals) {
      if (entry.artist.isEmpty) continue;
      result.putIfAbsent(discoveryEntityKey(entry.artist), () => entry);
    }
    return Map<String, TrackSignals>.unmodifiable(result);
  }

  /// Drops every rolled-up row. Called by "erase listening data".
  Future<void> clear() async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete(dsListeningStatistics);
      await txn.delete(
        tableEcosystemMeta,
        where: 'key = ?',
        whereArgs: <Object?>[dsRollupWatermarkKey],
      );
    });
  }
}

/// Habits plus the completed-play total (the caller may want both).
class HabitsAggregate {
  const HabitsAggregate({required this.habits, this.completedCount = 0});

  final ListeningHabits habits;
  final int completedCount;
}

/// In-flight accumulation for one `(track, day)` bucket.
class _BucketDelta {
  _BucketDelta({
    required this.trackKey,
    required this.bucket,
    required this.title,
    required this.artist,
    required this.album,
  });

  final String trackKey;
  final String bucket;
  final String title;
  final String artist;
  final String album;

  int playCount = 0;
  int skipCount = 0;
  int completedCount = 0;
  int repeatCount = 0;
  int listenedMs = 0;
  double completionSum = 0;
  int nightPlayCount = 0;
  int weekendPlayCount = 0;
  final Map<int, int> hourHistogram = <int, int>{};
  String lastPlayedAt = '';
}

/// `"0:2,13:5"` — compact enough to sit in a row, cheap to merge.
String _encodeHistogram(Map<int, int> histogram) {
  if (histogram.isEmpty) return '';
  final keys = histogram.keys.toList()..sort();
  return keys.map((hour) => '$hour:${histogram[hour]}').join(',');
}

Map<int, int> _decodeHistogram(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return const <int, int>{};
  final result = <int, int>{};
  for (final part in value.split(',')) {
    final pieces = part.split(':');
    if (pieces.length != 2) continue;
    final hour = int.tryParse(pieces[0]);
    final count = int.tryParse(pieces[1]);
    if (hour == null || count == null) continue;
    if (hour < 0 || hour > 23) continue;
    result[hour] = (result[hour] ?? 0) + count;
  }
  return Map<int, int>.unmodifiable(result);
}
