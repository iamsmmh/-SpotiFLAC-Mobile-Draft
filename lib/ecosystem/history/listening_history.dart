/// Listening history tracking (Feature Group 4).
///
/// Two tables, one writer:
///   * `ec_listening_events` — append-only raw events (one row per play);
///   * `ec_track_history`    — per-track aggregate (play count, skip count,
///     last played, completion) maintained inside the same transaction.
///
/// Aggregation is done with a read-modify-write transaction rather than
/// SQLite's `ON CONFLICT … DO UPDATE` upsert because Android API 24 ships
/// SQLite 3.9, which predates upsert support (3.24).
///
/// Recording is opt-in (`EngineSettings.trackListeningStats`) and stays
/// entirely on-device unless the user enables the history sync scope.
library;

import 'package:spotimusic/ecosystem/ecosystem_database.dart';

/// One playback session of one track.
class PlayEvent {
  const PlayEvent({
    required this.trackKey,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    required this.durationMs,
    required this.playedMs,
    required this.startedAt,
    required this.endedAt,
    this.skipped = false,
    this.source = 'unknown',
  });

  final String trackKey;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int durationMs;
  final int playedMs;
  final DateTime startedAt;
  final DateTime endedAt;
  final bool skipped;
  final String source;

  /// 0..1 — how much of the track was heard.
  double get completion =>
      durationMs <= 0 ? 0 : (playedMs / durationMs).clamp(0.0, 1.0);

  /// A track counts as "completed" at 90 %, matching the skip heuristics the
  /// player already uses: a listen that ends a few seconds early is still a
  /// listen.
  bool get completed => !skipped && completion >= 0.9;

  Duration get listened => Duration(milliseconds: playedMs);

  Map<String, Object?> toRow() => <String, Object?>{
    'track_key': trackKey,
    'title': title,
    'artist': artist,
    'album': album,
    'cover_url': coverUrl,
    'duration_ms': durationMs,
    'played_ms': playedMs,
    'completed': completed ? 1 : 0,
    'skipped': skipped ? 1 : 0,
    'source': source,
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt.toUtc().toIso8601String(),
  };

  static PlayEvent fromRow(Map<String, Object?> row) {
    int asInt(String key) {
      final value = row[key];
      return value is num ? value.toInt() : 0;
    }

    return PlayEvent(
      trackKey: row['track_key']?.toString() ?? '',
      title: row['title']?.toString() ?? '',
      artist: row['artist']?.toString() ?? '',
      album: row['album']?.toString() ?? '',
      coverUrl: row['cover_url']?.toString(),
      durationMs: asInt('duration_ms'),
      playedMs: asInt('played_ms'),
      skipped: asInt('skipped') == 1,
      source: row['source']?.toString() ?? 'unknown',
      startedAt:
          DateTime.tryParse(row['started_at']?.toString() ?? '') ??
          DateTime.now(),
      endedAt:
          DateTime.tryParse(row['ended_at']?.toString() ?? '') ?? DateTime.now(),
    );
  }
}

/// Per-track aggregate.
class TrackHistory {
  const TrackHistory({
    required this.trackKey,
    required this.title,
    this.artist = '',
    this.album = '',
    this.coverUrl,
    this.playCount = 0,
    this.skipCount = 0,
    this.totalPlayedMs = 0,
    this.averageCompletion = 0,
    required this.firstPlayedAt,
    required this.lastPlayedAt,
  });

  final String trackKey;
  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final int playCount;
  final int skipCount;
  final int totalPlayedMs;

  /// Mean completion ratio (0..1) across plays that reported a duration.
  final double averageCompletion;

  final DateTime firstPlayedAt;
  final DateTime lastPlayedAt;

  Duration get totalListened => Duration(milliseconds: totalPlayedMs);

  /// Share of plays that were skipped (0..1).
  double get skipRate => playCount == 0 ? 0 : skipCount / playCount;

  TrackHistory copyWith({
    String? title,
    String? artist,
    String? album,
    String? coverUrl,
    int? playCount,
    int? skipCount,
    int? totalPlayedMs,
    double? averageCompletion,
    DateTime? lastPlayedAt,
  }) {
    return TrackHistory(
      trackKey: trackKey,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      coverUrl: coverUrl ?? this.coverUrl,
      playCount: playCount ?? this.playCount,
      skipCount: skipCount ?? this.skipCount,
      totalPlayedMs: totalPlayedMs ?? this.totalPlayedMs,
      averageCompletion: averageCompletion ?? this.averageCompletion,
      firstPlayedAt: firstPlayedAt,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
    );
  }

  Map<String, Object?> toRow() => <String, Object?>{
    'track_key': trackKey,
    'title': title,
    'artist': artist,
    'album': album,
    'cover_url': coverUrl,
    'play_count': playCount,
    'skip_count': skipCount,
    'total_played_ms': totalPlayedMs,
    'completion_sum': averageCompletion,
    'completion_count': 1,
    'first_played_at': firstPlayedAt.toUtc().toIso8601String(),
    'last_played_at': lastPlayedAt.toUtc().toIso8601String(),
  };

  static TrackHistory fromRow(Map<String, Object?> row) {
    int asInt(String key) {
      final value = row[key];
      return value is num ? value.toInt() : 0;
    }

    double asDouble(String key) {
      final value = row[key];
      return value is num ? value.toDouble() : 0;
    }

    final now = DateTime.now();
    final completionCount = asInt('completion_count');
    final completionSum = asDouble('completion_sum');
    final average = completionCount > 0
        ? (completionSum / completionCount).clamp(0.0, 1.0)
        : completionSum.clamp(0.0, 1.0);
    return TrackHistory(
      trackKey: row['track_key']?.toString() ?? '',
      title: row['title']?.toString() ?? '',
      artist: row['artist']?.toString() ?? '',
      album: row['album']?.toString() ?? '',
      coverUrl: row['cover_url']?.toString(),
      playCount: asInt('play_count'),
      skipCount: asInt('skip_count'),
      totalPlayedMs: asInt('total_played_ms'),
      averageCompletion: average,
      firstPlayedAt:
          DateTime.tryParse(row['first_played_at']?.toString() ?? '') ?? now,
      lastPlayedAt:
          DateTime.tryParse(row['last_played_at']?.toString() ?? '') ?? now,
    );
  }
}

/// Appends events and maintains aggregates.
class ListeningHistoryRepository {
  ListeningHistoryRepository({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  /// Records one play. The event row and the aggregate row land in the same
  /// transaction so the two can never disagree.
  Future<void> record(PlayEvent event) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.insert(tableListeningEvents, event.toRow());
      final existing = await txn.query(
        tableTrackHistory,
        where: 'track_key = ?',
        whereArgs: <Object?>[event.trackKey],
        limit: 1,
      );
      final completion = event.completion;
      if (existing.isEmpty) {
        await txn.insert(tableTrackHistory, <String, Object?>{
          'track_key': event.trackKey,
          'title': event.title,
          'artist': event.artist,
          'album': event.album,
          'cover_url': event.coverUrl,
          'play_count': 1,
          'skip_count': event.skipped ? 1 : 0,
          'total_played_ms': event.playedMs,
          'completion_sum': completion,
          'completion_count': 1,
          'first_played_at': event.startedAt.toUtc().toIso8601String(),
          'last_played_at': event.endedAt.toUtc().toIso8601String(),
        });
        return;
      }
      final row = existing.first;
      int asInt(String key) {
        final value = row[key];
        return value is num ? value.toInt() : 0;
      }

      final playCount = asInt('play_count') + 1;
      final skipCount = asInt('skip_count') + (event.skipped ? 1 : 0);
      final completionSum =
          (row['completion_sum'] is num
              ? (row['completion_sum']! as num).toDouble()
              : 0) + completion;
      await txn.update(
        tableTrackHistory,
        <String, Object?>{
          'title': event.title,
          'artist': event.artist,
          'album': event.album,
          if (event.coverUrl != null) 'cover_url': event.coverUrl,
          'play_count': playCount,
          'skip_count': skipCount,
          'total_played_ms': asInt('total_played_ms') + event.playedMs,
          'completion_sum': completionSum,
          'last_played_at': event.endedAt.toUtc().toIso8601String(),
        },
        where: 'track_key = ?',
        whereArgs: <Object?>[event.trackKey],
      );
    });
  }

  /// Most recent events first (deduped per track when [uniqueTracks]).
  Future<List<PlayEvent>> recentEvents({
    int limit = 200,
    DateTime? since,
    bool uniqueTracks = false,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      tableListeningEvents,
      where: since == null ? null : 'ended_at >= ?',
      whereArgs: since == null
          ? null
          : <Object?>[since.toUtc().toIso8601String()],
      orderBy: 'ended_at DESC',
      limit: uniqueTracks ? limit * 4 : limit,
    );
    final events = rows
        .map(PlayEvent.fromRow)
        .where((event) => event.trackKey.isNotEmpty)
        .toList(growable: false);
    if (!uniqueTracks) return events;
    final seen = <String>{};
    final unique = <PlayEvent>[];
    for (final event in events) {
      if (!seen.add(event.trackKey)) continue;
      unique.add(event);
      if (unique.length >= limit) break;
    }
    return unique;
  }

  Future<List<TrackHistory>> mostPlayed({int limit = 50}) async {
    final db = await _database.database;
    final rows = await db.query(
      tableTrackHistory,
      orderBy: 'play_count DESC, last_played_at DESC',
      limit: limit,
    );
    return rows
        .map(TrackHistory.fromRow)
        .where((history) => history.trackKey.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<TrackHistory>> recentlyPlayed({int limit = 50}) async {
    final db = await _database.database;
    final rows = await db.query(
      tableTrackHistory,
      orderBy: 'last_played_at DESC',
      limit: limit,
    );
    return rows
        .map(TrackHistory.fromRow)
        .where((history) => history.trackKey.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<TrackHistory>> allAggregates() async {
    final db = await _database.database;
    final rows = await db.query(
      tableTrackHistory,
      orderBy: 'last_played_at DESC',
    );
    return rows
        .map(TrackHistory.fromRow)
        .where((history) => history.trackKey.isNotEmpty)
        .toList(growable: false);
  }

  /// Every event in [range] — the input for insights and recaps.
  Future<List<PlayEvent>> eventsBetween(DateTime from, DateTime to) async {
    final db = await _database.database;
    final rows = await db.query(
      tableListeningEvents,
      where: 'ended_at >= ? AND ended_at <= ?',
      whereArgs: <Object?>[
        from.toUtc().toIso8601String(),
        to.toUtc().toIso8601String(),
      ],
      orderBy: 'ended_at ASC',
    );
    return rows
        .map(PlayEvent.fromRow)
        .where((event) => event.trackKey.isNotEmpty)
        .toList(growable: false);
  }

  Future<TrackHistory?> track(String trackKey) async {
    final db = await _database.database;
    final rows = await db.query(
      tableTrackHistory,
      where: 'track_key = ?',
      whereArgs: <Object?>[trackKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TrackHistory.fromRow(rows.first);
  }

  Future<int> totalPlayCount() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM $tableListeningEvents',
    );
    final value = rows.first['total'];
    return value is num ? value.toInt() : 0;
  }

  Future<void> deleteTrack(String trackKey) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete(
        tableListeningEvents,
        where: 'track_key = ?',
        whereArgs: <Object?>[trackKey],
      );
      await txn.delete(
        tableTrackHistory,
        where: 'track_key = ?',
        whereArgs: <Object?>[trackKey],
      );
    });
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete(tableListeningEvents);
      await txn.delete(tableTrackHistory);
    });
  }
}
