/// SQLite metadata storage for the smart stream cache (Phase 2).
///
/// Complements the ecosystem byte cache (`ec_stream_cache` owns the bytes
/// ledger) with the milestone's own metadata:
///
///   * `warm_requests` — predictive warm-up bookkeeping (what was requested,
///     when, in which priority, and how it ended), so a restart can see what
///     the predictor planned and the UI can explain cache behaviour;
///   * `maintenance_log` — last maintenance run (expired/evicted counts),
///     so background cleanup can be scheduled and inspected.
///
/// Row codecs are pure and unit-tested; the store itself is a thin sqflite
/// wrapper over the shared `openAppDatabase` configuration.
library;

import 'dart:convert';

import 'package:spotiflac_android/services/sqlite_helpers.dart' as sqlite;
import 'package:spotiflac_android/utils/logger.dart';
import 'package:sqflite/sqflite.dart';

final _log = AppLogger('CacheMetadataDb');

/// Lifecycle of one predictive warm request.
enum WarmRequestState { requested, completed, failed, cancelled }

WarmRequestState _stateFromName(Object? name) {
  final text = name?.toString().trim().toLowerCase() ?? '';
  for (final state in WarmRequestState.values) {
    if (state.name == text) return state;
  }
  return WarmRequestState.requested;
}

/// One predictive warm-up record.
class WarmRequestRecord {
  final String trackKey;
  final String url;
  final int priority;
  final DateTime requestedAt;
  final WarmRequestState state;

  /// Bytes fetched when the request completed (0 while pending/failed).
  final int bytes;

  const WarmRequestRecord({
    required this.trackKey,
    required this.url,
    required this.priority,
    required this.requestedAt,
    required this.state,
    this.bytes = 0,
  });

  WarmRequestRecord copyWith({WarmRequestState? state, int? bytes}) =>
      WarmRequestRecord(
        trackKey: trackKey,
        url: url,
        priority: priority,
        requestedAt: requestedAt,
        state: state ?? this.state,
        bytes: bytes ?? this.bytes,
      );

  Map<String, Object?> toRow() => <String, Object?>{
    'track_key': trackKey,
    'url': url,
    'priority': priority,
    'requested_at': requestedAt.toUtc().toIso8601String(),
    'state': state.name,
    'bytes': bytes,
  };

  static WarmRequestRecord? fromRow(Map<String, Object?> row) {
    final trackKey = row['track_key']?.toString() ?? '';
    if (trackKey.isEmpty) return null;
    final requestedAt =
        DateTime.tryParse(row['requested_at']?.toString() ?? '')?.toUtc() ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    return WarmRequestRecord(
      trackKey: trackKey,
      url: row['url']?.toString() ?? '',
      priority: (row['priority'] as num?)?.toInt() ?? 0,
      requestedAt: requestedAt,
      state: _stateFromName(row['state']),
      bytes: (row['bytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// JSON codec used by the diagnostics export and by tests.
  Map<String, Object?> toJson() => <String, Object?>{
    'track_key': trackKey,
    'url': url,
    'priority': priority,
    'requested_at': requestedAt.toUtc().toIso8601String(),
    'state': state.name,
    'bytes': bytes,
  };

  static WarmRequestRecord? tryParseJson(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final trackKey = map['track_key']?.toString() ?? '';
    if (trackKey.isEmpty) return null;
    return WarmRequestRecord(
      trackKey: trackKey,
      url: map['url']?.toString() ?? '',
      priority: (map['priority'] as num?)?.toInt() ?? 0,
      requestedAt:
          DateTime.tryParse(map['requested_at']?.toString() ?? '')
                  ?.toUtc() ??
              DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      state: _stateFromName(map['state']),
      bytes: (map['bytes'] as num?)?.toInt() ?? 0,
    );
  }

  static String encodeList(List<WarmRequestRecord> records) =>
      jsonEncode(<Object?>[for (final r in records) r.toJson()]);

  static List<WarmRequestRecord> decodeList(String payload) {
    final decoded = jsonDecode(payload);
    if (decoded is! List) return const <WarmRequestRecord>[];
    return <WarmRequestRecord>[
      for (final raw in decoded)
        ?WarmRequestRecord.tryParseJson(raw),
    ];
  }
}

/// Outcome of the last maintenance pass.
class CacheMaintenanceRecord {
  final DateTime ranAt;
  final int expired;
  final int evicted;
  final int freedBytes;

  const CacheMaintenanceRecord({
    required this.ranAt,
    required this.expired,
    required this.evicted,
    required this.freedBytes,
  });

  Map<String, Object?> toRow() => <String, Object?>{
    'id': 1,
    'ran_at': ranAt.toUtc().toIso8601String(),
    'expired': expired,
    'evicted': evicted,
    'freed_bytes': freedBytes,
  };

  static CacheMaintenanceRecord? fromRow(Map<String, Object?> row) {
    final ranAt = DateTime.tryParse(row['ran_at']?.toString() ?? '')?.toUtc();
    if (ranAt == null) return null;
    return CacheMaintenanceRecord(
      ranAt: ranAt,
      expired: (row['expired'] as num?)?.toInt() ?? 0,
      evicted: (row['evicted'] as num?)?.toInt() ?? 0,
      freedBytes: (row['freed_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Persistence port so tests can substitute an in-memory store.
abstract interface class CacheMetadataStore {
  Future<void> upsertWarmRequest(WarmRequestRecord record);

  Future<List<WarmRequestRecord>> warmRequests({int limit = 200});

  Future<void> clearWarmRequests();

  Future<void> recordMaintenance(CacheMaintenanceRecord record);

  Future<CacheMaintenanceRecord?> lastMaintenance();
}

/// SQLite implementation (`stream_cache_meta.db`).
class SQLiteCacheMetadataStore implements CacheMetadataStore {
  static const String _dbFileName = 'stream_cache_meta.db';
  static const int _dbVersion = 1;
  static const String _warmTable = 'warm_requests';
  static const String _maintenanceTable = 'maintenance_log';

  static final sqlite.SingleFlightInitializer<Database> _database =
      sqlite.SingleFlightInitializer<Database>();

  final Future<Database> Function() _open;

  SQLiteCacheMetadataStore({Future<Database> Function()? open})
    : _open = open ?? _openDefault;

  static Future<Database> _openDefault() {
    return sqlite.openAppDatabase(
      _dbFileName,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_warmTable (
            track_key TEXT PRIMARY KEY,
            url TEXT NOT NULL,
            priority INTEGER NOT NULL,
            requested_at TEXT NOT NULL,
            state TEXT NOT NULL,
            bytes INTEGER NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_${_warmTable}_requested '
          'ON $_warmTable(requested_at DESC)',
        );
        await db.execute('''
          CREATE TABLE $_maintenanceTable (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            ran_at TEXT NOT NULL,
            expired INTEGER NOT NULL,
            evicted INTEGER NOT NULL,
            freed_bytes INTEGER NOT NULL
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {},
    );
  }

  Future<Database> get database => _database.getOrCreate(_open);

  @override
  Future<void> upsertWarmRequest(WarmRequestRecord record) async {
    final db = await database;
    await db.insert(
      _warmTable,
      record.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<WarmRequestRecord>> warmRequests({int limit = 200}) async {
    final db = await database;
    final rows = await db.query(
      _warmTable,
      orderBy: 'requested_at DESC',
      limit: limit,
    );
    return <WarmRequestRecord>[
      for (final row in rows) ?WarmRequestRecord.fromRow(row),
    ];
  }

  @override
  Future<void> clearWarmRequests() async {
    final db = await database;
    await db.delete(_warmTable);
  }

  @override
  Future<void> recordMaintenance(CacheMaintenanceRecord record) async {
    final db = await database;
    await db.insert(
      _maintenanceTable,
      record.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<CacheMaintenanceRecord?> lastMaintenance() async {
    final db = await database;
    final rows = await db.query(_maintenanceTable, limit: 1);
    if (rows.isEmpty) return null;
    return CacheMaintenanceRecord.fromRow(rows.first);
  }
}

/// Best-effort wrapper used by the manager: metadata failures must never
/// break playback, so every call is swallowed with a log line.
class FailSafeCacheMetadataStore implements CacheMetadataStore {
  FailSafeCacheMetadataStore(this._inner);

  final CacheMetadataStore _inner;

  @override
  Future<void> upsertWarmRequest(WarmRequestRecord record) async {
    try {
      await _inner.upsertWarmRequest(record);
    } catch (e) {
      _log.w('warm-request metadata write failed: $e');
    }
  }

  @override
  Future<List<WarmRequestRecord>> warmRequests({int limit = 200}) async {
    try {
      return await _inner.warmRequests(limit: limit);
    } catch (e) {
      _log.w('warm-request metadata read failed: $e');
      return const <WarmRequestRecord>[];
    }
  }

  @override
  Future<void> clearWarmRequests() async {
    try {
      await _inner.clearWarmRequests();
    } catch (e) {
      _log.w('warm-request clear failed: $e');
    }
  }

  @override
  Future<void> recordMaintenance(CacheMaintenanceRecord record) async {
    try {
      await _inner.recordMaintenance(record);
    } catch (e) {
      _log.w('maintenance metadata write failed: $e');
    }
  }

  @override
  Future<CacheMaintenanceRecord?> lastMaintenance() async {
    try {
      return await _inner.lastMaintenance();
    } catch (e) {
      _log.w('maintenance metadata read failed: $e');
      return null;
    }
  }
}
