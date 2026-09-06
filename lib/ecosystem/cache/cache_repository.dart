/// SQLite repository for the stream cache (Feature Group 7).
///
/// Owns every `ec_stream_cache` row: partial writes while the background
/// fetch streams, promotion (digest + completion) after verification, LRU
/// touch on playback, and eviction targets for the cleanup worker.
///
/// Pure SQLite against `EcosystemDatabase` — same pattern as
/// `ListeningHistoryRepository` (row codecs live on the models; SQL stays
/// here; planners that decide *what* to evict are pure classes under test).
library;

import 'package:sqflite/sqflite.dart';
import 'package:spotimusic/ecosystem/cache/cache_models.dart';
import 'package:spotimusic/ecosystem/ecosystem_database.dart';

class CacheRepository {
  CacheRepository({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  /// Inserts (or replaces) a partial entry when a background fetch starts.
  Future<void> upsertPartial(CacheEntry entry) async {
    final db = await _database.database;
    await db.insert(
      tableStreamCache,
      entry.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Promotes an entry after integrity verification.
  Future<void> markComplete(
    String cacheKey, {
    required int bytes,
    required String sha256,
    int? durationMs,
    String? fileName,
    CachedAudioFormat? audioFormat,
    bool encrypted = false,
    String ivHex = '',
  }) async {
    final db = await _database.database;
    await db.update(
      tableStreamCache,
      <String, Object?>{
        'complete': 1,
        'bytes': bytes,
        'sha256': sha256,
        'duration_ms': ?durationMs,
        'file_name': ?fileName,
        if (audioFormat != null) 'audio_format': audioFormat.name,
        'encrypted': encrypted ? 1 : 0,
        'iv_hex': ivHex,
      },
      where: 'cache_key = ?',
      whereArgs: <Object?>[cacheKey],
    );
  }

  /// LRU touch on playback.
  Future<void> touch(String cacheKey, {DateTime? at}) async {
    final db = await _database.database;
    await db.rawUpdate(
      'UPDATE $tableStreamCache SET last_accessed_at = ?, access_count = '
      'access_count + 1 WHERE cache_key = ?',
      <Object?>[
        (at ?? DateTime.now()).toUtc().toIso8601String(),
        cacheKey,
      ],
    );
  }

  Future<CacheEntry?> byCacheKey(String cacheKey) async {
    final db = await _database.database;
    final rows = await db.query(
      tableStreamCache,
      where: 'cache_key = ?',
      whereArgs: <Object?>[cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CacheEntry.fromRow(rows.first);
  }

  /// Best playable entry for a logical track (most recently accessed
  /// complete copy wins).
  Future<CacheEntry?> playableForTrack(String trackKey) async {
    final db = await _database.database;
    final rows = await db.query(
      tableStreamCache,
      where: 'track_key = ? AND complete = 1',
      whereArgs: <Object?>[trackKey],
      orderBy: 'last_accessed_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return CacheEntry.fromRow(rows.first);
  }

  Future<List<CacheEntry>> allForTrack(String trackKey) async {
    final db = await _database.database;
    final rows = await db.query(
      tableStreamCache,
      where: 'track_key = ?',
      whereArgs: <Object?>[trackKey],
      orderBy: 'created_at DESC',
    );
    return <CacheEntry>[for (final row in rows) CacheEntry.fromRow(row)];
  }

  Future<List<CacheEntry>> all() async {
    final db = await _database.database;
    final rows = await db.query(
      tableStreamCache,
      orderBy: 'last_accessed_at DESC',
    );
    return <CacheEntry>[for (final row in rows) CacheEntry.fromRow(row)];
  }

  /// Entries still fetching (cleanup sweeps their temp artifacts).
  Future<List<CacheEntry>> incomplete({Duration? olderThan}) async {
    final db = await _database.database;
    if (olderThan == null) {
      final rows = await db.query(
        tableStreamCache,
        where: 'complete = 0',
      );
      return <CacheEntry>[for (final row in rows) CacheEntry.fromRow(row)];
    }
    final cutoff =
        DateTime.now().toUtc().subtract(olderThan).toIso8601String();
    final rows = await db.query(
      tableStreamCache,
      where: 'complete = 0 AND created_at < ?',
      whereArgs: <Object?>[cutoff],
    );
    return <CacheEntry>[for (final row in rows) CacheEntry.fromRow(row)];
  }

  Future<void> setPinned(String cacheKey, bool pinned) async {
    final db = await _database.database;
    await db.update(
      tableStreamCache,
      <String, Object?>{'pinned': pinned ? 1 : 0},
      where: 'cache_key = ?',
      whereArgs: <Object?>[cacheKey],
    );
  }

  Future<void> delete(String cacheKey) async {
    final db = await _database.database;
    await db.delete(
      tableStreamCache,
      where: 'cache_key = ?',
      whereArgs: <Object?>[cacheKey],
    );
  }

  Future<void> deleteForTrack(String trackKey) async {
    final db = await _database.database;
    await db.delete(
      tableStreamCache,
      where: 'track_key = ?',
      whereArgs: <Object?>[trackKey],
    );
  }

  Future<int> totalBytes() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(bytes), 0) AS total FROM $tableStreamCache',
    );
    if (rows.isEmpty) return 0;
    return (rows.first['total'] as num?)?.toInt() ?? 0;
  }

  Future<int> count() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM $tableStreamCache',
    );
    if (rows.isEmpty) return 0;
    return (rows.first['n'] as num?)?.toInt() ?? 0;
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(tableStreamCache);
  }
}
