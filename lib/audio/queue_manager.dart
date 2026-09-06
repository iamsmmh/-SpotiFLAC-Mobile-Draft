/// Advanced queue engine (premium audio engine, Phase 1).
///
/// Builds on the session persistence the audio service already performs
/// (`app_state.db` → one live session) with the missing premium pieces:
///
///   * **Named snapshots** — explicit save points the user can create, list,
///     rename and delete.
///   * **Rolling auto-snapshots** — the queue is captured automatically so a
///     restarted app can offer "continue where you left off" variants.
///   * **Export / import** — a versioned, shareable JSON envelope
///     (`spotiflac.queue` v1) that round-trips every queue fact.
///   * **Retention policy** — pure, unit-tested pruning so the store cannot
///     grow without bound.
///
/// The manager is transport-agnostic: items are generic JSON maps (the exact
/// `PlayableMedia.toJson()` shape at the provider boundary), so this module
/// stays plugin-free and unit-testable headlessly.
library;

import 'dart:convert';

import 'package:spotiflac_android/services/sqlite_helpers.dart' as sqlite;
import 'package:spotiflac_android/utils/logger.dart';
import 'package:sqflite/sqflite.dart';

final _log = AppLogger('QueueManager');

/// Where a snapshot came from.
enum QueueSnapshotSource { manual, auto, imported }

QueueSnapshotSource _sourceFromName(Object? name) {
  final text = name?.toString().trim().toLowerCase() ?? '';
  for (final source in QueueSnapshotSource.values) {
    if (source.name == text) return source;
  }
  return QueueSnapshotSource.manual;
}

/// One saved queue state.
class QueueSnapshot {
  final String id;
  final String name;
  final QueueSnapshotSource source;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Queue items as `PlayableMedia.toJson()` maps (order preserved).
  final List<Map<String, Object?>> items;
  final int currentIndex;
  final int positionMs;
  final bool shuffle;

  /// `AudioServiceRepeatMode` name (`none|one|all|group`).
  final String repeatMode;

  const QueueSnapshot({
    required this.id,
    required this.name,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    required this.items,
    required this.currentIndex,
    this.positionMs = 0,
    this.shuffle = false,
    this.repeatMode = 'none',
  });

  int get itemCount => items.length;

  QueueSnapshot copyWith({
    String? name,
    DateTime? updatedAt,
    int? currentIndex,
    int? positionMs,
    String? repeatMode,
  }) => QueueSnapshot(
    id: id,
    name: name ?? this.name,
    source: source,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    items: items,
    currentIndex: currentIndex ?? this.currentIndex,
    positionMs: positionMs ?? this.positionMs,
    shuffle: shuffle,
    repeatMode: repeatMode ?? this.repeatMode,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'source': source.name,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'items': items,
    'current_index': currentIndex,
    'position_ms': positionMs,
    'shuffle': shuffle,
    'repeat_mode': repeatMode,
  };

  /// Strict parse: returns null when the snapshot is structurally invalid
  /// (missing id/items, unparsable timestamps, empty queue).
  static QueueSnapshot? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final id = map['id']?.toString() ?? '';
    if (id.isEmpty) return null;
    final rawItems = map['items'];
    if (rawItems is! List) return null;
    final items = <Map<String, Object?>>[];
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      items.add(Map<String, Object?>.from(entry));
    }
    if (items.isEmpty) return null;
    final createdAt = _parseDate(map['created_at']);
    final updatedAt = _parseDate(map['updated_at']) ?? createdAt;
    if (createdAt == null || updatedAt == null) return null;
    final index = (map['current_index'] as num?)?.toInt() ?? 0;
    return QueueSnapshot(
      id: id,
      name: map['name']?.toString() ?? '',
      source: _sourceFromName(map['source']),
      createdAt: createdAt,
      updatedAt: updatedAt,
      items: items,
      currentIndex: index.clamp(0, items.length - 1),
      positionMs: (map['position_ms'] as num?)?.toInt() ?? 0,
      shuffle: map['shuffle'] == true,
      repeatMode: map['repeat_mode']?.toString() ?? 'none',
    );
  }

  static DateTime? _parseDate(Object? raw) {
    final text = raw?.toString() ?? '';
    if (text.isEmpty) return null;
    return DateTime.tryParse(text)?.toUtc();
  }
}

/// The versioned export/import envelope.
abstract final class QueueExportCodec {
  static const String formatId = 'spotiflac.queue';
  static const int currentVersion = 1;

  static const int maxImportItems = 1000;

  /// Encodes [snapshot] into the shareable JSON envelope.
  static Map<String, Object?> encode(QueueSnapshot snapshot) =>
      <String, Object?>{
        'format': formatId,
        'version': currentVersion,
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'snapshot': snapshot.toJson(),
      };

  /// Parses an envelope back into a snapshot (source forced to `imported`).
  /// Accepts a full envelope or a bare snapshot object (forward tolerance).
  /// Returns null on version mismatch or structural invalidity.
  static QueueSnapshot? tryDecode(Object? raw) {
    if (raw is! Map) return null;
    final map = Map<String, Object?>.from(raw);
    final snapshotRaw = map['snapshot'];
    if (snapshotRaw == null) return _asImported(QueueSnapshot.tryParse(map));
    final format = map['format']?.toString();
    if (format != null && format != formatId) return null;
    final envelopeVersion = (map['version'] as num?)?.toInt() ?? currentVersion;
    if (envelopeVersion > currentVersion) return null;
    return _asImported(QueueSnapshot.tryParse(snapshotRaw));
  }

  static QueueSnapshot? _asImported(QueueSnapshot? snapshot) {
    if (snapshot == null) return null;
    final items = snapshot.items.length > maxImportItems
        ? snapshot.items.sublist(0, maxImportItems)
        : snapshot.items;
    return QueueSnapshot(
      id: snapshot.id,
      name: snapshot.name,
      source: QueueSnapshotSource.imported,
      createdAt: snapshot.createdAt,
      updatedAt: snapshot.updatedAt,
      items: items,
      currentIndex: snapshot.currentIndex.clamp(0, items.length - 1),
      positionMs: snapshot.positionMs,
      shuffle: snapshot.shuffle,
      repeatMode: snapshot.repeatMode,
    );
  }
}

/// Retention policy (pure): how many snapshots of each kind survive a prune.
class QueueRetentionPolicy {
  /// Rolling auto-snapshots kept (the newest wins, older ones fall off).
  final int maxAutoSnapshots;

  /// Named (manual/imported) snapshots kept.
  final int maxManualSnapshots;

  const QueueRetentionPolicy({
    this.maxAutoSnapshots = 3,
    this.maxManualSnapshots = 20,
  });

  /// Returns the ids that should be deleted, newest-first retention.
  List<String> planDeletions(List<QueueSnapshot> snapshots) {
    final deletions = <String>[];
    final autos = snapshots
        .where((s) => s.source == QueueSnapshotSource.auto)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    for (var i = maxAutoSnapshots; i < autos.length; i++) {
      deletions.add(autos[i].id);
    }
    final manuals = snapshots
        .where((s) => s.source != QueueSnapshotSource.auto)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    for (var i = maxManualSnapshots; i < manuals.length; i++) {
      deletions.add(manuals[i].id);
    }
    return deletions;
  }
}

/// Persistence port so tests can substitute an in-memory store.
abstract interface class QueueSnapshotStore {
  Future<void> put(QueueSnapshot snapshot);

  Future<List<QueueSnapshot>> all();

  Future<void> delete(String id);

  Future<void> clear();
}

/// SQLite-backed store (`queue_snapshots.db`). The full snapshot lives in one
/// JSON column — a snapshot is only ever read/written whole, and the extra
/// columns exist purely for cheap listing and pruning.
class SQLiteQueueSnapshotStore implements QueueSnapshotStore {
  static const String _dbFileName = 'queue_snapshots.db';
  static const int _dbVersion = 1;
  static const String _table = 'queue_snapshots';

  static final sqlite.SingleFlightInitializer<Database> _database =
      sqlite.SingleFlightInitializer<Database>();

  final Future<Database> Function() _open;

  SQLiteQueueSnapshotStore({Future<Database> Function()? open})
    : _open = open ?? _openDefault;

  static Future<Database> _openDefault() {
    return sqlite.openAppDatabase(
      _dbFileName,
      version: _dbVersion,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_table (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            source TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            item_count INTEGER NOT NULL,
            payload_json TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_${_table}_updated ON $_table(updated_at DESC)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {},
    );
  }

  Future<Database> get database => _database.getOrCreate(_open);

  @override
  Future<void> put(QueueSnapshot snapshot) async {
    final db = await database;
    await db.insert(
      _table,
      <String, Object?>{
        'id': snapshot.id,
        'name': snapshot.name,
        'source': snapshot.source.name,
        'updated_at': snapshot.updatedAt.toUtc().toIso8601String(),
        'item_count': snapshot.itemCount,
        'payload_json': jsonEncode(snapshot.toJson()),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<List<QueueSnapshot>> all() async {
    final db = await database;
    final rows = await db.query(_table, orderBy: 'updated_at DESC');
    final snapshots = <QueueSnapshot>[];
    for (final row in rows) {
      final payload = row['payload_json']?.toString() ?? '';
      try {
        final decoded = jsonDecode(payload);
        final snapshot = QueueSnapshot.tryParse(decoded);
        if (snapshot != null) snapshots.add(snapshot);
      } on FormatException {
        _log.w('Dropping corrupt queue snapshot ${row['id']}');
      }
    }
    return snapshots;
  }

  @override
  Future<void> delete(String id) async {
    final db = await database;
    await db.delete(_table, where: 'id = ?', whereArgs: <Object?>[id]);
  }

  @override
  Future<void> clear() async {
    final db = await database;
    await db.delete(_table);
  }
}

/// Snapshot orchestration: capture, restore, prune, export/import.
class QueueManager {
  QueueManager({
    required QueueSnapshotStore store,
    QueueRetentionPolicy retention = const QueueRetentionPolicy(),
    DateTime Function()? clock,
    String Function()? idFactory,
  }) : _store = store,
       _retention = retention,
       _clock = clock ?? () => DateTime.now().toUtc(),
       _idFactory = idFactory ?? _defaultIdFactory();

  final QueueSnapshotStore _store;
  final QueueRetentionPolicy _retention;
  final DateTime Function() _clock;
  final String Function() _idFactory;

  /// Monotonic id suffix so two snapshots created in the same microsecond
  /// (tests) can never collide.
  static int _idCounter = 0;

  static String Function() _defaultIdFactory() {
    var counter = 0;
    return () {
      counter++;
      _idCounter++;
      return 'q-${_clockNow().microsecondsSinceEpoch.toRadixString(36)}-'
          '$_idCounter-$counter';
    };
  }

  static DateTime _clockNow() => DateTime.now().toUtc();

  List<QueueSnapshot> _cache = const <QueueSnapshot>[];

  /// Last-known snapshots (refreshed by [reload]).
  List<QueueSnapshot> get snapshots => List<QueueSnapshot>.unmodifiable(_cache);

  Future<List<QueueSnapshot>> reload() async {
    _cache = await _store.all();
    return snapshots;
  }

  /// Captures the current queue as a snapshot.
  Future<QueueSnapshot> snapshot({
    required String name,
    required List<Map<String, Object?>> items,
    required int currentIndex,
    int positionMs = 0,
    bool shuffle = false,
    String repeatMode = 'none',
    QueueSnapshotSource source = QueueSnapshotSource.manual,
    String? id,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError.value(items, 'items', 'cannot snapshot an empty queue');
    }
    final now = _clock().toUtc();
    final trimmedName = name.trim();
    final snapshot = QueueSnapshot(
      id: id ?? _idFactory(),
      name: trimmedName.isEmpty ? 'Queue ${now.toIso8601String()}' : trimmedName,
      source: source,
      createdAt: now,
      updatedAt: now,
      items: items,
      currentIndex: currentIndex.clamp(0, items.length - 1),
      positionMs: positionMs < 0 ? 0 : positionMs,
      shuffle: shuffle,
      repeatMode: repeatMode,
    );
    await _store.put(snapshot);
    await _prune();
    await reload();
    return snapshot;
  }

  /// Re-captures the rolling auto snapshot (throttled by callers). A no-op
  /// for an empty queue.
  Future<QueueSnapshot?> snapshotAuto({
    required List<Map<String, Object?>> items,
    required int currentIndex,
    int positionMs = 0,
    bool shuffle = false,
    String repeatMode = 'none',
  }) async {
    if (items.isEmpty) return null;
    return snapshot(
      name: 'Continue listening',
      items: items,
      currentIndex: currentIndex,
      positionMs: positionMs,
      shuffle: shuffle,
      repeatMode: repeatMode,
      source: QueueSnapshotSource.auto,
    );
  }

  Future<void> rename(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    final all = await _store.all();
    for (final snapshot in all) {
      if (snapshot.id != id) continue;
      await _store.put(
        snapshot.copyWith(name: trimmed, updatedAt: _clock().toUtc()),
      );
    }
    await reload();
  }

  Future<void> delete(String id) async {
    await _store.delete(id);
    await reload();
  }

  Future<void> deleteAll() async {
    await _store.clear();
    await reload();
  }

  /// Applies the retention policy and deletes the offenders.
  Future<List<String>> _prune() async {
    final deletions = _retention.planDeletions(await _store.all());
    for (final id in deletions) {
      await _store.delete(id);
    }
    return deletions;
  }

  /// Shareable JSON envelope for one stored snapshot (null when the id is
  /// unknown).
  Future<String?> exportJson(String id) async {
    final all = await _store.all();
    for (final snapshot in all) {
      if (snapshot.id != id) continue;
      return jsonEncode(QueueExportCodec.encode(snapshot));
    }
    return null;
  }

  /// Exports the *current* queue state without persisting it first.
  String exportCurrent({
    required List<Map<String, Object?>> items,
    required int currentIndex,
    int positionMs = 0,
    bool shuffle = false,
    String repeatMode = 'none',
  }) {
    final now = _clock().toUtc();
    final snapshot = QueueSnapshot(
      id: 'export',
      name: 'Shared queue',
      source: QueueSnapshotSource.manual,
      createdAt: now,
      updatedAt: now,
      items: items,
      currentIndex: currentIndex.clamp(0, items.length - 1),
      positionMs: positionMs,
      shuffle: shuffle,
      repeatMode: repeatMode,
    );
    return jsonEncode(QueueExportCodec.encode(snapshot));
  }

  /// Imports a shareable JSON payload; returns the stored snapshot.
  /// Throws [FormatException] when the payload is not a valid queue export.
  Future<QueueSnapshot> importJson(String payload) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      throw const FormatException('payload is not valid JSON');
    }
    final snapshot = QueueExportCodec.tryDecode(decoded);
    if (snapshot == null) {
      throw const FormatException('not a SpotiFLAC queue export');
    }
    final stored = snapshot.copyWith(updatedAt: _clock().toUtc());
    await _store.put(stored);
    await _prune();
    await reload();
    return stored;
  }
}
