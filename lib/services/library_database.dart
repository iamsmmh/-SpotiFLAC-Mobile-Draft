import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/utils/audio_format_utils.dart';
import 'package:spotiflac_android/utils/file_access.dart';
import 'package:spotiflac_android/services/history_database.dart';
import 'package:spotiflac_android/services/sqlite_helpers.dart' as sqlite;

part 'library_database_models.dart';
part 'library_database_queue_sql.dart';

final _log = AppLogger('LibraryDatabase');

class LibraryDatabase {
  static final LibraryDatabase instance = LibraryDatabase._init();
  static const int schemaVersion = 12;
  static const String legacySourceId = LocalLibraryItem.legacySourceId;
  static const String visibleLibraryView = 'library_visible';
  static const int audioMetadataScanVersion = 2;
  static final sqlite.SingleFlightInitializer<Database> _database =
      sqlite.SingleFlightInitializer<Database>();
  bool _historyAttached = false;

  LibraryDatabase._init();

  Future<Database> get database {
    return _database.getOrCreate(
      () => sqlite.openAppDatabase(
        'local_library.db',
        version: schemaVersion,
        onCreate: _createDB,
        onUpgrade: _upgradeDB,
      ),
    );
  }

  Future<void> _ensureHistoryAttached(Database db) async {
    if (_historyAttached) return;
    await HistoryDatabase.instance.database;
    final dbPath = await getApplicationDocumentsDirectory();
    final historyPath = join(dbPath.path, 'history.db');
    try {
      await db.execute('ATTACH DATABASE ? AS history_db', [historyPath]);
    } catch (e) {
      final message = e.toString().toLowerCase();
      if (!message.contains('already in use') &&
          !message.contains('already exists')) {
        rethrow;
      }
    }
    _historyAttached = true;
  }

  Future<void> _createDB(Database db, int version) async {
    _log.i('Creating library database schema v$version');

    await db.execute('''
      CREATE TABLE library (
        id TEXT PRIMARY KEY,
        source_id TEXT NOT NULL DEFAULT '$legacySourceId',
        track_name TEXT NOT NULL,
        artist_name TEXT NOT NULL,
        album_name TEXT NOT NULL,
        album_artist TEXT,
        file_path TEXT NOT NULL UNIQUE,
        cover_path TEXT,
        scanned_at TEXT NOT NULL,
        file_mod_time INTEGER,
        isrc TEXT,
        track_number INTEGER,
        total_tracks INTEGER,
        disc_number INTEGER,
        total_discs INTEGER,
        duration INTEGER,
        release_date TEXT,
        bit_depth INTEGER,
        sample_rate INTEGER,
        bitrate INTEGER,
        genre TEXT,
        composer TEXT,
        label TEXT,
        copyright TEXT,
        explicit INTEGER NOT NULL DEFAULT 0,
        format TEXT,
        audio_metadata_scan_version INTEGER NOT NULL DEFAULT 2,
        track_name_norm TEXT,
        artist_name_norm TEXT,
        album_name_norm TEXT,
        album_artist_norm TEXT,
        match_key TEXT,
        album_key TEXT,
        search_text TEXT,
        sort_genre TEXT,
        sort_release TEXT,
        sort_added INTEGER
      )
    ''');

    await db.execute('CREATE INDEX idx_library_isrc ON library(isrc)');
    await db.execute(
      'CREATE INDEX idx_library_track_artist ON library(track_name, artist_name)',
    );
    await db.execute(
      'CREATE INDEX idx_library_album ON library(album_name, album_artist)',
    );
    await db.execute(
      'CREATE INDEX idx_library_file_path ON library(file_path)',
    );
    await _createNormalizedIndexes(db);
    await _createQueueIndexes(db);
    await _createPathKeyTable(db);
    await _createLibrarySources(db);

    _log.i('Library database schema created with indexes');
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    _log.i('Upgrading library database from v$oldVersion to v$newVersion');

    if (oldVersion < 2) {
      await db.execute('ALTER TABLE library ADD COLUMN cover_path TEXT');
      _log.i('Added cover_path column');
    }

    if (oldVersion < 3) {
      await db.execute('ALTER TABLE library ADD COLUMN file_mod_time INTEGER');
      _log.i('Added file_mod_time column for incremental scanning');
    }

    if (oldVersion < 4) {
      await db.execute('ALTER TABLE library ADD COLUMN bitrate INTEGER');
      _log.i('Added bitrate column for lossy format quality');
    }

    if (oldVersion < 5) {
      await db.execute('ALTER TABLE library ADD COLUMN label TEXT');
      await db.execute('ALTER TABLE library ADD COLUMN copyright TEXT');
      _log.i('Added label/copyright columns');
    }

    if (oldVersion < 6) {
      await db.execute('ALTER TABLE library ADD COLUMN total_tracks INTEGER');
      await db.execute('ALTER TABLE library ADD COLUMN total_discs INTEGER');
      await db.execute('ALTER TABLE library ADD COLUMN composer TEXT');
      _log.i('Added total_tracks/total_discs/composer columns');
    }

    if (oldVersion < 7) {
      await sqlite.addColumnIfMissing(db, 'library', 'track_name_norm', 'TEXT');
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'artist_name_norm',
        'TEXT',
      );
      await sqlite.addColumnIfMissing(db, 'library', 'album_name_norm', 'TEXT');
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'album_artist_norm',
        'TEXT',
      );
      await sqlite.addColumnIfMissing(db, 'library', 'match_key', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'library', 'album_key', 'TEXT');
      await _backfillNormalizedColumns(db);
      await _createNormalizedIndexes(db);
      _log.i('Added normalized local library lookup columns');
    }
    if (oldVersion < 8) {
      await _createPathKeyTable(db);
      await sqlite.backfillPathKeys(db, 'library', 'library_path_keys');
      _log.i('Added local library path-key lookup table');
    }
    if (oldVersion < 9) {
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'audio_metadata_scan_version',
        'INTEGER NOT NULL DEFAULT 0',
      );
      _log.i('Marked existing rows for one-time audio metadata rescan');
    }
    if (oldVersion < 10) {
      await sqlite.addColumnIfMissing(db, 'library', 'search_text', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'library', 'sort_genre', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'library', 'sort_release', 'TEXT');
      await sqlite.addColumnIfMissing(db, 'library', 'sort_added', 'INTEGER');
      await _backfillQueueColumns(db);
      await _createQueueIndexes(db);
      _log.i('Added persisted queue sort/search columns');
    }
    if (oldVersion < 11) {
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'source_id',
        "TEXT NOT NULL DEFAULT '$legacySourceId'",
      );
      await _createLibrarySources(db);
      _log.i('Added multiple local library sources');
    }
    if (oldVersion < 12) {
      await sqlite.addColumnIfMissing(
        db,
        'library',
        'explicit',
        'INTEGER NOT NULL DEFAULT 0',
      );
      _log.i('Added explicit-content metadata');
    }
  }

  Future<void> _createLibrarySources(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS library_sources (
        id TEXT PRIMARY KEY,
        path TEXT NOT NULL UNIQUE,
        display_name TEXT NOT NULL,
        bookmark TEXT,
        volume_id TEXT,
        is_removable INTEGER NOT NULL DEFAULT 0,
        enabled INTEGER NOT NULL DEFAULT 1,
        available INTEGER NOT NULL DEFAULT 1,
        last_scanned_at TEXT,
        last_seen_at TEXT,
        last_scan_error TEXT
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_source_id ON library(source_id)',
    );
    await db.insert('library_sources', {
      'id': legacySourceId,
      'path': 'legacy://local-library',
      'display_name': 'Music',
      'enabled': 1,
      'available': 1,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    await db.execute('DROP VIEW IF EXISTS $visibleLibraryView');
    await db.execute('''
      CREATE VIEW $visibleLibraryView AS
      SELECT l.*
      FROM library l
      JOIN library_sources s ON s.id = l.source_id
      WHERE s.enabled = 1 AND s.available = 1
    ''');
  }

  Future<void> _createPathKeyTable(DatabaseExecutor db) =>
      sqlite.createPathKeyTable(db, 'library_path_keys');

  void _putPathKeysInBatch(Batch batch, String id, String? filePath) =>
      sqlite.putPathKeysInBatch(batch, 'library_path_keys', id, filePath);

  static String normalizeLookupText(String? value) =>
      sqlite.normalizeLookupText(value);

  static String matchKeyFor(String trackName, String artistName) {
    return '${normalizeLookupText(trackName)}|${normalizeLookupText(artistName)}';
  }

  static String albumKeyFor(
    String albumName,
    String? albumArtist,
    String artistName,
  ) {
    return '${normalizeLookupText(albumName)}|${normalizeLookupText(albumArtist ?? artistName)}';
  }

  Future<void> _createNormalizedIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_match_key ON library(match_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_album_key ON library(album_key)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_track_norm ON library(track_name_norm)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_artist_norm ON library(artist_name_norm)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_album_norm ON library(album_name_norm)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_scanned_at ON library(scanned_at)',
    );
  }

  Future<void> _createQueueIndexes(DatabaseExecutor db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_added '
      'ON library(sort_added DESC, track_name_norm, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_track '
      'ON library(track_name_norm, artist_name_norm, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_artist '
      'ON library(artist_name_norm, track_name_norm, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_album '
      'ON library(album_name_norm, track_name_norm, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_genre '
      'ON library(sort_genre, track_name_norm, id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_library_queue_release '
      'ON library(sort_release, track_name_norm, id)',
    );
  }

  Future<void> _backfillNormalizedColumns(Database db) async {
    final rows = await db.query(
      'library',
      columns: [
        'id',
        'track_name',
        'artist_name',
        'album_name',
        'album_artist',
      ],
    );
    final batch = db.batch();
    for (final row in rows) {
      final trackName = row['track_name'] as String? ?? '';
      final artistName = row['artist_name'] as String? ?? '';
      final albumName = row['album_name'] as String? ?? '';
      final albumArtist = row['album_artist'] as String?;
      batch.update(
        'library',
        _normalizedColumns(
          trackName: trackName,
          artistName: artistName,
          albumName: albumName,
          albumArtist: albumArtist,
        ),
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  Map<String, dynamic> _normalizedColumns({
    required String trackName,
    required String artistName,
    required String albumName,
    required String? albumArtist,
  }) {
    final trackNorm = normalizeLookupText(trackName);
    final artistNorm = normalizeLookupText(artistName);
    final albumNorm = normalizeLookupText(albumName);
    final albumArtistNorm = normalizeLookupText(albumArtist ?? artistName);
    return {
      'track_name_norm': trackNorm,
      'artist_name_norm': artistNorm,
      'album_name_norm': albumNorm,
      'album_artist_norm': albumArtistNorm,
      'match_key': '$trackNorm|$artistNorm',
      'album_key': '$albumNorm|$albumArtistNorm',
    };
  }

  Map<String, dynamic> _queueColumns({
    required String? trackName,
    required String? artistName,
    required String? albumName,
    required String? albumArtist,
    required String? genre,
    required String? releaseDate,
    required int? fileModTime,
    required String? scannedAt,
  }) {
    final trackNorm = normalizeLookupText(trackName);
    final artistNorm = normalizeLookupText(artistName);
    final albumNorm = normalizeLookupText(albumName);
    final albumArtistNorm = normalizeLookupText(
      (albumArtist ?? '').trim().isEmpty ? artistName : albumArtist,
    );
    return {
      'search_text': [
        trackNorm,
        artistNorm,
        albumNorm,
        albumArtistNorm,
      ].where((value) => value.isNotEmpty).join(' '),
      'sort_genre': normalizeLookupText(genre),
      'sort_release': releaseDate?.trim() ?? '',
      'sort_added':
          fileModTime ??
          DateTime.tryParse(scannedAt ?? '')?.millisecondsSinceEpoch ??
          0,
    };
  }

  Future<void> _backfillQueueColumns(Database db) async {
    final rows = await db.query(
      'library',
      columns: [
        'id',
        'track_name',
        'artist_name',
        'album_name',
        'album_artist',
        'genre',
        'release_date',
        'file_mod_time',
        'scanned_at',
      ],
    );
    final batch = db.batch();
    for (final row in rows) {
      batch.update(
        'library',
        _queueColumns(
          trackName: row['track_name'] as String?,
          artistName: row['artist_name'] as String?,
          albumName: row['album_name'] as String?,
          albumArtist: row['album_artist'] as String?,
          genre: row['genre'] as String?,
          releaseDate: row['release_date'] as String?,
          fileModTime: (row['file_mod_time'] as num?)?.toInt(),
          scannedAt: row['scanned_at'] as String?,
        ),
        where: 'id = ?',
        whereArgs: [row['id']],
      );
    }
    await batch.commit(noResult: true);
  }

  Map<String, dynamic> _jsonToDbRow(
    Map<String, dynamic> json, {
    String? sourceId,
  }) {
    final fileModTime = (json['fileModTime'] as num?)?.toInt();
    final scannedAt = json['scannedAt'] as String?;
    final row = {
      'id': json['id'],
      'source_id': sourceId ?? json['sourceId'] ?? legacySourceId,
      'track_name': json['trackName'],
      'artist_name': json['artistName'],
      'album_name': json['albumName'],
      'album_artist': json['albumArtist'],
      'file_path': json['filePath'],
      'cover_path': json['coverPath'],
      'scanned_at': json['scannedAt'],
      'file_mod_time': json['fileModTime'],
      'isrc': json['isrc'],
      'track_number': json['trackNumber'],
      'total_tracks': json['totalTracks'],
      'disc_number': json['discNumber'],
      'total_discs': json['totalDiscs'],
      'duration': json['duration'],
      'release_date': json['releaseDate'],
      'bit_depth': json['bitDepth'],
      'sample_rate': json['sampleRate'],
      'bitrate': json['bitrate'],
      'genre': json['genre'],
      'composer': json['composer'],
      'label': json['label'],
      'copyright': json['copyright'],
      'explicit': json['explicit'] == true || json['explicit'] == 1 ? 1 : 0,
      'format': json['format'],
      'audio_metadata_scan_version':
          (json['audioMetadataScanVersion'] as num?)?.toInt() ??
          audioMetadataScanVersion,
    };
    row.addAll(
      _queueColumns(
        trackName: json['trackName'] as String?,
        artistName: json['artistName'] as String?,
        albumName: json['albumName'] as String?,
        albumArtist: json['albumArtist'] as String?,
        genre: json['genre'] as String?,
        releaseDate: json['releaseDate'] as String?,
        fileModTime: fileModTime,
        scannedAt: scannedAt,
      ),
    );
    row.addAll(
      _normalizedColumns(
        trackName: json['trackName'] as String? ?? '',
        artistName: json['artistName'] as String? ?? '',
        albumName: json['albumName'] as String? ?? '',
        albumArtist: json['albumArtist'] as String?,
      ),
    );
    return row;
  }

  Map<String, dynamic> _dbRowToJson(Map<String, dynamic> row) {
    return {
      'id': row['id'],
      'sourceId': row['source_id'] ?? legacySourceId,
      'trackName': row['track_name'],
      'artistName': row['artist_name'],
      'albumName': row['album_name'],
      'albumArtist': row['album_artist'],
      'filePath': row['file_path'],
      'coverPath': row['cover_path'],
      'scannedAt': row['scanned_at'],
      'fileModTime': row['file_mod_time'],
      'isrc': row['isrc'],
      'trackNumber': row['track_number'],
      'totalTracks': row['total_tracks'],
      'discNumber': row['disc_number'],
      'totalDiscs': row['total_discs'],
      'duration': row['duration'],
      'releaseDate': row['release_date'],
      'bitDepth': row['bit_depth'],
      'sampleRate': row['sample_rate'],
      'bitrate': row['bitrate'],
      'genre': row['genre'],
      'composer': row['composer'],
      'label': row['label'],
      'copyright': row['copyright'],
      'explicit': row['explicit'] == 1 || row['explicit'] == true,
      'format': row['format'],
    };
  }

  Future<void> upsert(Map<String, dynamic> json, {String? sourceId}) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(
        'library',
        _jsonToDbRow(json, sourceId: sourceId),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final batch = txn.batch();
      _putPathKeysInBatch(
        batch,
        json['id'] as String,
        json['filePath'] as String?,
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertBatch(
    List<Map<String, dynamic>> items, {
    String? sourceId,
  }) async {
    if (items.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final json in items) {
        batch.insert(
          'library',
          _jsonToDbRow(json, sourceId: sourceId),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _putPathKeysInBatch(
          batch,
          json['id'] as String,
          json['filePath'] as String?,
        );
      }
      await batch.commit(noResult: true);
    });
    _log.i('Batch inserted ${items.length} items');
  }

  Future<void> replaceAll(List<Map<String, dynamic>> items) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('library_path_keys');
      await txn.delete('library');
      if (items.isEmpty) {
        return;
      }

      final batch = txn.batch();
      for (final json in items) {
        batch.insert(
          'library',
          _jsonToDbRow(json),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _putPathKeysInBatch(
          batch,
          json['id'] as String,
          json['filePath'] as String?,
        );
      }
      await batch.commit(noResult: true);
    });
    _log.i('Replaced library with ${items.length} items');
  }

  /// Atomically replaces the Library while consuming bounded scan batches.
  /// The stream may represent tens of thousands of tracks without requiring a
  /// second full list of models/maps on the Dart heap.
  Future<int> replaceAllStream(
    Stream<Map<String, dynamic>> items, {
    int batchSize = 300,
  }) async {
    if (batchSize <= 0) {
      throw ArgumentError.value(batchSize, 'batchSize', 'Must be positive');
    }
    final db = await database;
    var inserted = 0;
    await db.transaction((txn) async {
      await txn.delete('library_path_keys');
      await txn.delete('library');

      var batch = txn.batch();
      var pending = 0;
      Future<void> flush() async {
        if (pending == 0) return;
        await batch.commit(noResult: true);
        batch = txn.batch();
        pending = 0;
      }

      await for (final json in items) {
        final id = json['id'] as String?;
        if (id == null || id.trim().isEmpty) {
          throw const FormatException('Library scan row has no valid id');
        }
        batch.insert(
          'library',
          _jsonToDbRow(json),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _putPathKeysInBatch(batch, id, json['filePath'] as String?);
        inserted++;
        pending++;
        if (pending >= batchSize) await flush();
      }
      await flush();
    });
    _log.i('Stream-replaced library with $inserted items');
    return inserted;
  }

  /// Atomically replaces only one source. Other folders, including temporarily
  /// disconnected removable storage, retain their index rows.
  Future<int> replaceSourceStream(
    String sourceId,
    Stream<Map<String, dynamic>> items, {
    int batchSize = 300,
  }) async {
    if (batchSize <= 0) {
      throw ArgumentError.value(batchSize, 'batchSize', 'Must be positive');
    }
    final db = await database;
    var inserted = 0;
    await db.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM library_path_keys WHERE item_id IN '
        '(SELECT id FROM library WHERE source_id = ?)',
        [sourceId],
      );
      await txn.delete(
        'library',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );

      var batch = txn.batch();
      var pending = 0;
      Future<void> flush() async {
        if (pending == 0) return;
        await batch.commit(noResult: true);
        batch = txn.batch();
        pending = 0;
      }

      await for (final json in items) {
        final id = json['id'] as String?;
        if (id == null || id.trim().isEmpty) {
          throw const FormatException('Library scan row has no valid id');
        }
        batch.insert(
          'library',
          _jsonToDbRow(json, sourceId: sourceId),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        _putPathKeysInBatch(batch, id, json['filePath'] as String?);
        inserted++;
        pending++;
        if (pending >= batchSize) await flush();
      }
      await flush();
    });
    _log.i('Stream-replaced library source $sourceId with $inserted items');
    return inserted;
  }

  Future<List<LocalLibrarySource>> getSources() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.*, COUNT(l.id) AS track_count
      FROM library_sources s
      LEFT JOIN library l ON l.source_id = s.id
      GROUP BY s.id
      HAVING s.path != 'legacy://local-library' OR COUNT(l.id) > 0
      ORDER BY s.is_removable, LOWER(s.display_name), LOWER(s.path)
    ''');
    return rows.map(_sourceFromRow).toList(growable: false);
  }

  Future<LocalLibrarySource?> getSourceByPath(String path) async {
    final db = await database;
    final rows = await db.rawQuery(
      '''
      SELECT s.*, COUNT(l.id) AS track_count
      FROM library_sources s
      LEFT JOIN library l ON l.source_id = s.id
      WHERE s.path = ?
      GROUP BY s.id
      LIMIT 1
      ''',
      [path],
    );
    return rows.isEmpty ? null : _sourceFromRow(rows.first);
  }

  LocalLibrarySource _sourceFromRow(Map<String, Object?> row) {
    DateTime? parseDate(Object? value) =>
        value is String ? DateTime.tryParse(value) : null;
    return LocalLibrarySource(
      id: row['id'] as String,
      path: row['path'] as String,
      displayName: row['display_name'] as String,
      bookmark: row['bookmark'] as String?,
      volumeId: row['volume_id'] as String?,
      isRemovable: (row['is_removable'] as num?)?.toInt() == 1,
      enabled: (row['enabled'] as num?)?.toInt() != 0,
      available: (row['available'] as num?)?.toInt() != 0,
      trackCount: (row['track_count'] as num?)?.toInt() ?? 0,
      lastScannedAt: parseDate(row['last_scanned_at']),
      lastSeenAt: parseDate(row['last_seen_at']),
      lastScanError: row['last_scan_error'] as String?,
    );
  }

  Future<void> upsertSource(LocalLibrarySource source) async {
    final db = await database;
    final values = <String, Object?>{
      'path': source.path,
      'display_name': source.displayName,
      'bookmark': source.bookmark,
      'volume_id': source.volumeId,
      'is_removable': source.isRemovable ? 1 : 0,
      'enabled': source.enabled ? 1 : 0,
      'available': source.available ? 1 : 0,
      'last_scanned_at': source.lastScannedAt?.toIso8601String(),
      'last_seen_at': source.lastSeenAt?.toIso8601String(),
      'last_scan_error': source.lastScanError,
    };
    final updated = await db.update(
      'library_sources',
      values,
      where: 'id = ?',
      whereArgs: [source.id],
    );
    if (updated == 0) {
      await db.insert('library_sources', {'id': source.id, ...values});
    }
  }

  Future<void> updateSourceState(
    String sourceId, {
    bool? enabled,
    bool? available,
    DateTime? lastScannedAt,
    DateTime? lastSeenAt,
    String? lastScanError,
    bool clearLastScanError = false,
  }) async {
    final values = <String, Object?>{};
    if (enabled != null) values['enabled'] = enabled ? 1 : 0;
    if (available != null) values['available'] = available ? 1 : 0;
    if (lastScannedAt != null) {
      values['last_scanned_at'] = lastScannedAt.toIso8601String();
    }
    if (lastSeenAt != null) {
      values['last_seen_at'] = lastSeenAt.toIso8601String();
    }
    if (lastScanError != null || clearLastScanError) {
      values['last_scan_error'] = clearLastScanError ? null : lastScanError;
    }
    if (values.isEmpty) return;
    final db = await database;
    await db.update(
      'library_sources',
      values,
      where: 'id = ?',
      whereArgs: [sourceId],
    );
  }

  Future<void> migrateLegacySource({
    required String path,
    required String displayName,
    String? bookmark,
    String? volumeId,
    bool isRemovable = false,
    bool available = true,
    DateTime? lastScannedAt,
  }) async {
    if (path.trim().isEmpty) return;
    final db = await database;
    await db.update(
      'library_sources',
      {
        'path': path,
        'display_name': displayName,
        'bookmark': bookmark,
        'volume_id': volumeId,
        'is_removable': isRemovable ? 1 : 0,
        'available': available ? 1 : 0,
        'last_scanned_at': lastScannedAt?.toIso8601String(),
        'last_seen_at': available ? DateTime.now().toIso8601String() : null,
      },
      where: 'id = ?',
      whereArgs: [legacySourceId],
    );
  }

  Future<void> removeSource(String sourceId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.rawDelete(
        'DELETE FROM library_path_keys WHERE item_id IN '
        '(SELECT id FROM library WHERE source_id = ?)',
        [sourceId],
      );
      await txn.delete(
        'library',
        where: 'source_id = ?',
        whereArgs: [sourceId],
      );
      if (sourceId == legacySourceId) {
        await txn.update(
          'library_sources',
          {
            'path': 'legacy://local-library',
            'display_name': 'Music',
            'bookmark': null,
            'volume_id': null,
            'is_removable': 0,
            'enabled': 1,
            'available': 1,
            'last_scanned_at': null,
            'last_seen_at': null,
            'last_scan_error': null,
          },
          where: 'id = ?',
          whereArgs: [sourceId],
        );
      } else {
        await txn.delete(
          'library_sources',
          where: 'id = ?',
          whereArgs: [sourceId],
        );
      }
    });
  }

  Future<List<Map<String, dynamic>>> getAll({int? limit, int? offset}) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      orderBy: 'album_artist, album_name, disc_number, track_number',
      limit: limit,
      offset: offset,
    );
    return rows.map(_dbRowToJson).toList();
  }

  String _escapeLikePattern(String value) {
    return value
        .replaceAll('\\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
  }

  String _orderByForSort(LocalLibrarySortMode sortMode) {
    return switch (sortMode) {
      LocalLibrarySortMode.title =>
        'track_name_norm, artist_name_norm, album_name_norm, disc_number, track_number',
      LocalLibrarySortMode.artist =>
        'artist_name_norm, album_name_norm, disc_number, track_number, track_name_norm',
      LocalLibrarySortMode.latest =>
        'scanned_at DESC, album_artist_norm, album_name_norm, disc_number, track_number',
      LocalLibrarySortMode.quality =>
        'COALESCE(bit_depth, 0) DESC, COALESCE(sample_rate, 0) DESC, COALESCE(bitrate, 0) DESC, album_artist_norm, album_name_norm, disc_number, track_number',
      LocalLibrarySortMode.album =>
        'album_artist_norm, album_name_norm, COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name_norm',
    };
  }

  Future<List<Map<String, dynamic>>> getQueueTrackPage(
    QueueLibraryDbQuery request,
  ) async {
    return (await getQueueTrackPageResult(request)).rows;
  }

  Future<QueueLibraryDbPage> getQueueTrackPageResult(
    QueueLibraryDbQuery request,
  ) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    final args = <Object?>[];
    final orderTerms = _queueTrackOrderTerms(request.sortMode);
    final usesCursor =
        request.cursor != null &&
        request.cursor!.values.length == orderTerms.length;
    final unionSql = _queueTrackUnionSql(
      request,
      args,
      orderTerms: orderTerms,
      usesCursor: usesCursor,
    );
    final rows = await db.rawQuery(
      '''
      SELECT *
      FROM ($unionSql)
      ORDER BY ${_queueTrackOrderBy(request.sortMode)}
      LIMIT ? ${usesCursor ? '' : 'OFFSET ?'}
      ''',
      [...args, request.limit, if (!usesCursor) request.offset],
    );
    return QueueLibraryDbPage(
      rows: rows.map(_queueTrackRowToJson).toList(growable: false),
      nextCursor: _queueCursorFromRow(rows.lastOrNull, orderTerms),
    );
  }

  Future<QueueLibraryCounts> getQueueCounts(QueueLibraryDbQuery request) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    final fastCounts = await _getUnfilteredQueueCounts(db, request);
    if (fastCounts != null) return fastCounts;
    final parts = <String>[];
    final args = <Object?>[];

    if (request.source != 'local') {
      final where = <String>[];
      _appendQueueHistoryFilters(where, args, request);
      parts.add('''
        SELECT
          COUNT(*) AS all_count,
          COUNT(DISTINCT CASE WHEN grouped.track_count > 1 THEN h.album_key END) AS album_count,
          COALESCE(SUM(CASE WHEN grouped.track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM history_db.history h
        JOIN (
          SELECT album_key, COUNT(*) AS track_count
          FROM history_db.history
          GROUP BY album_key
        ) grouped ON grouped.album_key = h.album_key
        ${where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}'}
      ''');
    }

    if (request.includeLocal && request.source != 'downloaded') {
      final where = <String>[
        '''
        NOT EXISTS (
          SELECT 1
          FROM library_path_keys lpk
          JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
          WHERE lpk.item_id = l.id
        )
        ''',
      ];
      _appendQueueLocalFilters(where, args, request);
      parts.add('''
        SELECT
          COUNT(*) AS all_count,
          COUNT(DISTINCT CASE WHEN grouped.track_count > 1 THEN l.album_key END) AS album_count,
          COALESCE(SUM(CASE WHEN grouped.track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM $visibleLibraryView l
        JOIN (
          SELECT album_key, COUNT(*) AS track_count
          FROM $visibleLibraryView candidate
          WHERE NOT EXISTS (
            SELECT 1
            FROM library_path_keys lpk
            JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
            WHERE lpk.item_id = candidate.id
          )
          GROUP BY album_key
        ) grouped ON grouped.album_key = l.album_key
        WHERE ${where.join(' AND ')}
      ''');
    }

    if (parts.isEmpty) {
      return const QueueLibraryCounts(
        allTrackCount: 0,
        albumCount: 0,
        singleTrackCount: 0,
      );
    }

    final rows = await db.rawQuery('''
      SELECT
        COALESCE(SUM(all_count), 0) AS all_count,
        COALESCE(SUM(single_count), 0) AS single_count,
        COALESCE(SUM(album_count), 0) AS album_count
      FROM (${parts.join(' UNION ALL ')})
      ''', args);
    final row = rows.isNotEmpty ? rows.first : const <String, Object?>{};

    return QueueLibraryCounts(
      allTrackCount: (row['all_count'] as num?)?.toInt() ?? 0,
      albumCount: (row['album_count'] as num?)?.toInt() ?? 0,
      singleTrackCount: (row['single_count'] as num?)?.toInt() ?? 0,
    );
  }

  /// The default Library badges do not need a row-by-row join against album
  /// counts. Aggregate the covering album-key indexes directly and reserve the
  /// more expensive filtered query for active search/quality/metadata filters.
  Future<QueueLibraryCounts?> _getUnfilteredQueueCounts(
    Database db,
    QueueLibraryDbQuery request,
  ) async {
    if (normalizeLookupText(request.searchQuery).isNotEmpty ||
        request.quality != null ||
        request.format != null ||
        request.metadata != null) {
      return null;
    }
    final source = request.source;
    if (source != null && source != 'downloaded' && source != 'local') {
      return null;
    }

    final parts = <String>[];
    if (source != 'local') {
      parts.add('''
        SELECT
          COALESCE(SUM(track_count), 0) AS all_count,
          COALESCE(SUM(CASE WHEN track_count > 1 THEN 1 ELSE 0 END), 0) AS album_count,
          COALESCE(SUM(CASE WHEN track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM (
          SELECT album_key, COUNT(*) AS track_count
          FROM history_db.history
          GROUP BY album_key
        )
      ''');
    }
    if (request.includeLocal && source != 'downloaded') {
      parts.add('''
        SELECT
          COALESCE(SUM(track_count), 0) AS all_count,
          COALESCE(SUM(CASE WHEN track_count > 1 THEN 1 ELSE 0 END), 0) AS album_count,
          COALESCE(SUM(CASE WHEN track_count = 1 THEN 1 ELSE 0 END), 0) AS single_count
        FROM (
          SELECT l.album_key, COUNT(*) AS track_count
          FROM $visibleLibraryView l
          WHERE NOT EXISTS (
            SELECT 1
            FROM library_path_keys lpk
            JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
            WHERE lpk.item_id = l.id
          )
          GROUP BY l.album_key
        )
      ''');
    }
    if (parts.isEmpty) {
      return const QueueLibraryCounts(
        allTrackCount: 0,
        albumCount: 0,
        singleTrackCount: 0,
      );
    }

    final rows = await db.rawQuery('''
      SELECT
        COALESCE(SUM(all_count), 0) AS all_count,
        COALESCE(SUM(album_count), 0) AS album_count,
        COALESCE(SUM(single_count), 0) AS single_count
      FROM (${parts.join(' UNION ALL ')})
    ''');
    final row = rows.isEmpty ? const <String, Object?>{} : rows.first;
    return QueueLibraryCounts(
      allTrackCount: (row['all_count'] as num?)?.toInt() ?? 0,
      albumCount: (row['album_count'] as num?)?.toInt() ?? 0,
      singleTrackCount: (row['single_count'] as num?)?.toInt() ?? 0,
    );
  }

  Future<List<Map<String, dynamic>>> getQueueAlbumPage(
    QueueLibraryDbQuery request,
  ) async {
    return (await getQueueAlbumPageResult(request)).rows;
  }

  Future<QueueLibraryDbPage> getQueueAlbumPageResult(
    QueueLibraryDbQuery request,
  ) async {
    final db = await database;
    await _ensureHistoryAttached(db);
    final args = <Object?>[];
    final orderTerms = _queueAlbumOrderTerms(request.sortMode);
    final usesCursor =
        request.cursor != null &&
        request.cursor!.values.length == orderTerms.length;
    final unionSql = _queueAlbumUnionSql(
      request,
      args,
      orderTerms: orderTerms,
      usesCursor: usesCursor,
    );
    final rows = await db.rawQuery(
      '''
      SELECT *
      FROM ($unionSql)
      ORDER BY ${_queueAlbumOrderBy(request.sortMode)}
      LIMIT ? ${usesCursor ? '' : 'OFFSET ?'}
      ''',
      [...args, request.limit, if (!usesCursor) request.offset],
    );
    return QueueLibraryDbPage(
      rows: rows.toList(growable: false),
      nextCursor: _queueCursorFromRow(rows.lastOrNull, orderTerms),
    );
  }

  Future<List<Map<String, dynamic>>> getQueueLocalAlbumTracks(
    String albumName,
    String artistName,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where:
          "LOWER(album_name) = ? AND LOWER(COALESCE(NULLIF(album_artist, ''), artist_name)) = ?",
      whereArgs: [albumName.toLowerCase(), artistName.toLowerCase()],
      orderBy:
          'COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name',
    );
    return rows.map(_dbRowToJson).toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> getQueueLocalAlbumTracksByKey(
    String albumKey,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'album_key = ?',
      whereArgs: [albumKey],
      orderBy:
          'COALESCE(disc_number, 0), COALESCE(track_number, 0), track_name',
    );
    return rows.map(_dbRowToJson).toList(growable: false);
  }

  Future<Map<String, dynamic>?> getById(String id) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<Map<String, dynamic>?> getByIsrc(String isrc) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'isrc = ?',
      whereArgs: [isrc],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<List<Map<String, dynamic>>> findByTrackAndArtist(
    String trackName,
    String artistName,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'match_key = ?',
      whereArgs: [matchKeyFor(trackName, artistName)],
    );
    return rows.map(_dbRowToJson).toList();
  }

  Future<Map<String, dynamic>?> findFirstByTrackAndArtist(
    String trackName,
    String artistName,
  ) async {
    final db = await database;
    final rows = await db.query(
      visibleLibraryView,
      where: 'match_key = ?',
      whereArgs: [matchKeyFor(trackName, artistName)],
      orderBy: _orderByForSort(LocalLibrarySortMode.album),
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _dbRowToJson(rows.first);
  }

  Future<Map<String, dynamic>?> findExisting({
    String? isrc,
    String? trackName,
    String? artistName,
  }) async {
    if (isrc != null && isrc.isNotEmpty) {
      final byIsrc = await getByIsrc(isrc);
      if (byIsrc != null) return byIsrc;
    }

    if (trackName != null && artistName != null) {
      final matches = await findByTrackAndArtist(trackName, artistName);
      if (matches.isNotEmpty) return matches.first;
    }

    return null;
  }

  /// Resolves a track list with a bounded number of indexed queries instead
  /// of issuing up to three SQLite calls for every track.
  Future<List<Map<String, dynamic>?>> findExistingBatch(
    List<LocalLibraryBatchLookupRequest> requests,
  ) async {
    if (requests.isEmpty) return const [];
    final db = await database;
    final byId = <String, Map<String, dynamic>>{};
    final byIsrc = <String, Map<String, dynamic>>{};
    final byMatchKey = <String, Map<String, dynamic>>{};

    Future<void> loadColumn(
      String column,
      Iterable<String> rawValues,
      Map<String, Map<String, dynamic>> destination,
    ) {
      return sqlite.loadRowsByColumn(
        db,
        table: visibleLibraryView,
        column: column,
        rawValues: rawValues,
        destination: destination,
        mapRow: _dbRowToJson,
      );
    }

    await Future.wait([
      loadColumn('id', requests.map((request) => request.id ?? ''), byId),
      loadColumn('isrc', requests.map((request) => request.isrc ?? ''), byIsrc),
      loadColumn(
        'match_key',
        requests.map(
          (request) => matchKeyFor(request.trackName, request.artistName),
        ),
        byMatchKey,
      ),
    ]);

    return requests
        .map((request) {
          final id = request.id?.trim() ?? '';
          if (id.isNotEmpty && byId[id] != null) return byId[id];
          final isrc = request.isrc?.trim() ?? '';
          if (isrc.isNotEmpty && byIsrc[isrc] != null) return byIsrc[isrc];
          return byMatchKey[matchKeyFor(request.trackName, request.artistName)];
        })
        .toList(growable: false);
  }

  Future<LocalLibraryLookupIndex> getLookupIndex() async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT isrc, match_key FROM $visibleLibraryView',
    );
    final isrcs = <String>{};
    final matchKeys = <String>{};
    for (final row in rows) {
      final isrc = row['isrc'] as String?;
      if (isrc != null && isrc.isNotEmpty) {
        isrcs.add(isrc);
      }
      final matchKey = row['match_key'] as String?;
      if (matchKey != null && matchKey.isNotEmpty) {
        matchKeys.add(matchKey);
      }
    }
    return LocalLibraryLookupIndex(
      isrcs: Set<String>.unmodifiable(isrcs),
      matchKeys: Set<String>.unmodifiable(matchKeys),
    );
  }

  Future<List<String>> getCoverPaths({int? limit, int? offset}) async {
    final db = await database;
    final rows = await db.query(
      'library',
      columns: ['cover_path'],
      where: 'cover_path IS NOT NULL AND cover_path != ""',
      limit: limit,
      offset: offset,
    );
    return rows
        .map((row) => row['cover_path'] as String?)
        .whereType<String>()
        .toList(growable: false);
  }

  /// Groups of tracks sharing one ISRC across download history and the
  /// local library. Library rows whose path key already appears in history
  /// are excluded so a scanned copy of a download doesn't pair with itself.
  /// Entries come back best-quality first.
  Future<List<IsrcDuplicateGroup>> findIsrcDuplicateGroups() async {
    final db = await database;
    final rows = await db.rawQuery('''
      WITH merged AS (
        SELECT h.id AS id, 'downloaded' AS source, h.track_name, h.artist_name,
               h.album_name, h.file_path, UPPER(TRIM(h.isrc)) AS isrc_key,
               h.bit_depth, h.sample_rate, h.bitrate, h.format
        FROM history_db.history h
        WHERE h.isrc IS NOT NULL AND TRIM(h.isrc) != ''
        UNION ALL
        SELECT l.id AS id, 'local' AS source, l.track_name, l.artist_name,
               l.album_name, l.file_path, UPPER(TRIM(l.isrc)) AS isrc_key,
               l.bit_depth, l.sample_rate, l.bitrate, l.format
        FROM $visibleLibraryView l
        WHERE l.isrc IS NOT NULL AND TRIM(l.isrc) != ''
          AND NOT EXISTS (
            SELECT 1
            FROM library_path_keys lpk
            JOIN history_db.history_path_keys hpk ON hpk.path_key = lpk.path_key
            WHERE lpk.item_id = l.id
          )
      )
      SELECT * FROM merged
      WHERE isrc_key IN (
        SELECT isrc_key FROM merged GROUP BY isrc_key HAVING COUNT(*) > 1
      )
      ORDER BY isrc_key, bit_depth DESC, sample_rate DESC, bitrate DESC
    ''');

    final groups = <String, List<IsrcDuplicateEntry>>{};
    for (final row in rows) {
      final isrc = row['isrc_key'] as String? ?? '';
      final filePath = row['file_path'] as String? ?? '';
      if (isrc.isEmpty || filePath.isEmpty) continue;
      groups
          .putIfAbsent(isrc, () => [])
          .add(
            IsrcDuplicateEntry(
              id: row['id'] as String,
              source: row['source'] as String,
              trackName: row['track_name'] as String? ?? '',
              artistName: row['artist_name'] as String? ?? '',
              albumName: row['album_name'] as String? ?? '',
              filePath: filePath,
              bitDepth: (row['bit_depth'] as num?)?.toInt(),
              sampleRate: (row['sample_rate'] as num?)?.toInt(),
              bitrate: (row['bitrate'] as num?)?.toInt(),
              format: row['format'] as String?,
            ),
          );
    }
    return [
      for (final entry in groups.entries)
        if (entry.value.length > 1)
          IsrcDuplicateGroup(isrc: entry.key, entries: entry.value),
    ];
  }

  Future<void> deleteByPath(String filePath) async {
    final db = await database;
    final rows = await db.query(
      'library',
      columns: ['id'],
      where: 'file_path = ?',
      whereArgs: [filePath],
    );
    final ids = rows.map((row) => row['id'] as String).toList(growable: false);
    await db.transaction((txn) async {
      for (final id in ids) {
        await txn.delete(
          'library_path_keys',
          where: 'item_id = ?',
          whereArgs: [id],
        );
      }
      await txn.delete(
        'library',
        where: 'file_path = ?',
        whereArgs: [filePath],
      );
    });
  }

  Future<void> replaceWithConvertedItem({
    required LocalLibraryItem item,
    required String newFilePath,
    required String targetFormat,
    required String bitrate,
    int? bitDepth,
    int? sampleRate,
    bool keepOriginal = false,
  }) async {
    final db = await database;
    final stat = await fileStat(newFilePath);
    final now = DateTime.now();
    final normalizedFormat = _normalizeConvertedFormat(targetFormat);
    final convertedBitrate =
        _convertedBitrate(targetFormat: targetFormat, bitrate: bitrate) ??
        estimateAverageBitrateKbps(
          fileSizeBytes: stat?.size,
          durationSeconds: item.duration,
        );
    final updated = item.toJson()
      ..['id'] = _generateLibraryId(newFilePath)
      ..['filePath'] = newFilePath
      ..['scannedAt'] = now.toIso8601String()
      ..['fileModTime'] = stat?.modified?.millisecondsSinceEpoch
      ..['format'] = normalizedFormat
      ..['bitrate'] = convertedBitrate
      ..['audioMetadataScanVersion'] = convertedBitrate != null
          ? audioMetadataScanVersion
          : 0;

    if (normalizedFormat == 'mp3' ||
        normalizedFormat == 'opus' ||
        normalizedFormat == 'aac') {
      updated['bitDepth'] = null;
      updated['sampleRate'] = null;
    } else {
      updated['bitDepth'] = bitDepth ?? item.bitDepth;
      updated['sampleRate'] = sampleRate ?? item.sampleRate;
    }

    await db.transaction((txn) async {
      if (!keepOriginal) {
        await txn.delete(
          'library_path_keys',
          where: 'item_id = ?',
          whereArgs: [item.id],
        );
        await txn.delete(
          'library',
          where: 'id = ? OR file_path = ?',
          whereArgs: [item.id, item.filePath],
        );
      }
      await txn.insert(
        'library',
        _jsonToDbRow(updated),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
      final batch = txn.batch();
      _putPathKeysInBatch(
        batch,
        updated['id'] as String,
        updated['filePath'] as String?,
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> updateAudioMetadata(
    String id, {
    int? duration,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    bool? explicit,
    String? format,
  }) async {
    final values = <String, dynamic>{};
    if (duration != null && duration > 0) {
      values['duration'] = duration;
    }
    if (bitDepth != null && bitDepth > 0) {
      values['bit_depth'] = bitDepth;
    }
    if (sampleRate != null && sampleRate > 0) {
      values['sample_rate'] = sampleRate;
    }
    if (bitrate != null && bitrate > 0) {
      values['bitrate'] = bitrate;
    }
    if (explicit != null) {
      values['explicit'] = explicit ? 1 : 0;
    }
    final normalizedFormat = normalizeAudioFormatValue(format);
    if (normalizedFormat != null) {
      values['format'] = normalizedFormat;
    }
    if (values.isEmpty) return;
    values['audio_metadata_scan_version'] = audioMetadataScanVersion;

    final db = await database;
    await db.update('library', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> delete(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'library_path_keys',
        where: 'item_id = ?',
        whereArgs: [id],
      );
      await txn.delete('library', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<int> cleanupMissingFiles({String? sourceId}) async {
    final db = await database;
    final rows = await db.query(
      'library',
      columns: ['id', 'file_path'],
      where: sourceId == null ? null : 'source_id = ?',
      whereArgs: sourceId == null ? null : [sourceId],
    );

    final missingIds = <String>[];
    const checkChunkSize = 16;
    for (var i = 0; i < rows.length; i += checkChunkSize) {
      final end = (i + checkChunkSize < rows.length)
          ? i + checkChunkSize
          : rows.length;
      final chunk = rows.sublist(i, end);
      final checks = await Future.wait<MapEntry<String, bool>>(
        chunk.map((row) async {
          final id = row['id'] as String;
          final filePath = row['file_path'] as String;
          return MapEntry(id, await fileExists(filePath));
        }),
      );
      for (final check in checks) {
        if (!check.value) {
          missingIds.add(check.key);
        }
      }
    }

    if (missingIds.isEmpty) {
      return 0;
    }

    var removed = 0;
    const deleteChunkSize = 500;
    for (var i = 0; i < missingIds.length; i += deleteChunkSize) {
      final end = (i + deleteChunkSize < missingIds.length)
          ? i + deleteChunkSize
          : missingIds.length;
      final idChunk = missingIds.sublist(i, end);
      final placeholders = List.filled(idChunk.length, '?').join(',');
      await db.rawDelete(
        'DELETE FROM library_path_keys WHERE item_id IN ($placeholders)',
        idChunk,
      );
      removed += await db.rawDelete(
        'DELETE FROM library WHERE id IN ($placeholders)',
        idChunk,
      );
    }

    if (removed > 0) {
      _log.i('Cleaned up $removed missing files from library');
    }
    return removed;
  }

  Future<void> clearAll() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('library_path_keys');
      await txn.delete('library');
      await txn.update('library_sources', {
        'last_scanned_at': null,
        'last_scan_error': null,
      });
    });
    _log.i('Cleared all library data');
  }

  Future<int> getCount() async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM $visibleLibraryView',
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getSourceCount(String sourceId) async {
    final db = await database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) as count FROM library WHERE source_id = ?',
      [sourceId],
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<void> close() async {
    final db = await database;
    await db.close();
    _database.reset();
    _historyAttached = false;
  }

  Future<Map<String, int>> getFileModTimes({String? sourceId}) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT file_path, COALESCE(file_mod_time, 0) AS file_mod_time, '
      'audio_metadata_scan_version FROM library '
      '${sourceId == null ? '' : 'WHERE source_id = ?'}',
      sourceId == null ? const [] : [sourceId],
    );
    final result = <String, int>{};
    for (final row in rows) {
      final path = row['file_path'] as String;
      final modTime = (row['file_mod_time'] as num?)?.toInt() ?? 0;
      final scanVersion =
          (row['audio_metadata_scan_version'] as num?)?.toInt() ?? 0;
      // A sentinel timestamp keeps the path in deletion/dedup checks while
      // making the incremental scanner treat a legacy row as changed once.
      result[path] = libraryIncrementalSnapshotModTime(
        storedModTime: modTime,
        storedScanVersion: scanVersion,
      );
    }
    return result;
  }

  Future<String> writeFileModTimesSnapshot({String? sourceId}) async {
    final db = await database;
    final rows = await db.rawQuery(
      'SELECT file_path, COALESCE(file_mod_time, 0) AS file_mod_time, '
      'audio_metadata_scan_version FROM library '
      '${sourceId == null ? '' : 'WHERE source_id = ?'}',
      sourceId == null ? const [] : [sourceId],
    );
    final tempDir = await getTemporaryDirectory();
    final file = File(
      join(
        tempDir.path,
        'library_file_mod_times_${DateTime.now().microsecondsSinceEpoch}.tsv',
      ),
    );
    final buffer = StringBuffer();
    for (final row in rows) {
      final path = row['file_path'] as String?;
      if (path == null || path.isEmpty) continue;
      final modTime = (row['file_mod_time'] as num?)?.toInt() ?? 0;
      final scanVersion =
          (row['audio_metadata_scan_version'] as num?)?.toInt() ?? 0;
      buffer
        ..write(
          libraryIncrementalSnapshotModTime(
            storedModTime: modTime,
            storedScanVersion: scanVersion,
          ),
        )
        ..write('\t')
        ..writeln(path);
    }
    await file.writeAsString(buffer.toString(), flush: true);
    return file.path;
  }

  Future<void> updateFileModTimes(Map<String, int> fileModTimes) async {
    if (fileModTimes.isEmpty) return;
    final db = await database;
    final batch = db.batch();
    for (final entry in fileModTimes.entries) {
      batch.update(
        'library',
        {'file_mod_time': entry.value, 'sort_added': entry.value},
        where: 'file_path = ?',
        whereArgs: [entry.key],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<Set<String>> getAllFilePaths() async {
    final db = await database;
    final rows = await db.rawQuery('SELECT file_path FROM library');
    return rows.map((r) => r['file_path'] as String).toSet();
  }

  Future<int> deleteByPaths(List<String> filePaths) async {
    if (filePaths.isEmpty) return 0;
    final db = await database;
    var totalDeleted = 0;
    const chunkSize = 500;
    for (var i = 0; i < filePaths.length; i += chunkSize) {
      final end = (i + chunkSize < filePaths.length)
          ? i + chunkSize
          : filePaths.length;
      final chunk = filePaths.sublist(i, end);
      final placeholders = List.filled(chunk.length, '?').join(',');
      final rows = await db.rawQuery(
        'SELECT id FROM library WHERE file_path IN ($placeholders)',
        chunk,
      );
      final ids = rows
          .map((row) => row['id'] as String)
          .toList(growable: false);
      if (ids.isNotEmpty) {
        final idPlaceholders = List.filled(ids.length, '?').join(',');
        await db.rawDelete(
          'DELETE FROM library_path_keys WHERE item_id IN ($idPlaceholders)',
          ids,
        );
      }
      totalDeleted += await db.rawDelete(
        'DELETE FROM library WHERE file_path IN ($placeholders)',
        chunk,
      );
    }
    if (totalDeleted > 0) {
      _log.i('Deleted $totalDeleted items from library');
    }
    return totalDeleted;
  }

  String _normalizeConvertedFormat(String targetFormat) {
    return normalizeAudioFormatValue(targetFormat) ?? 'mp3';
  }

  int? _convertedBitrate({
    required String targetFormat,
    required String bitrate,
  }) {
    switch (targetFormat.trim().toLowerCase()) {
      case 'mp3':
      case 'opus':
      case 'aac':
        final match = RegExp(r'(\d+)').firstMatch(bitrate);
        return match != null ? int.tryParse(match.group(1)!) : null;
      default:
        return null;
    }
  }

  String _generateLibraryId(String filePath) {
    return 'lib_${_hashString(filePath).toRadixString(16)}';
  }

  int _hashString(String input) {
    var hash = 5381;
    for (final codeUnit in input.codeUnits) {
      hash = (((hash << 5) + hash) + codeUnit) & 0xffffffff;
    }
    return hash;
  }
}
