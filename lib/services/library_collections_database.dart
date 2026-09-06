import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/services/sqlite_helpers.dart' as sqlite;
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('LibraryCollectionsDb');

const _dbFileName = 'library_collections.db';
const _dbVersion = 3;

const _tableWishlist = 'wishlist_tracks';
const _tableLoved = 'loved_tracks';
const _tablePlaylists = 'playlists';
const _tablePlaylistTracks = 'playlist_tracks';
const _tableFavoriteArtists = 'favorite_artists';
const _tableFavoriteAlbums = 'favorite_albums';

const _legacyCollectionsStorageKey = 'library_collections_v1';
const _migrationDoneKey = 'library_collections_migrated_to_sqlite_v1';

class LibraryCollectionsSnapshot {
  final List<Map<String, dynamic>> wishlistRows;
  final List<Map<String, dynamic>> lovedRows;
  final List<Map<String, dynamic>> playlistRows;
  final List<Map<String, dynamic>> playlistTrackRows;
  final List<Map<String, dynamic>> favoriteArtistRows;
  final List<Map<String, dynamic>> favoriteAlbumRows;

  const LibraryCollectionsSnapshot({
    required this.wishlistRows,
    required this.lovedRows,
    required this.playlistRows,
    required this.playlistTrackRows,
    required this.favoriteArtistRows,
    required this.favoriteAlbumRows,
  });
}

class PlaylistPickerSummaryRow {
  final String id;
  final String name;
  final String? coverImagePath;
  final String? previewCover;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int trackCount;
  final bool containsAllRequestedTracks;

  const PlaylistPickerSummaryRow({
    required this.id,
    required this.name,
    this.coverImagePath,
    this.previewCover,
    required this.createdAt,
    required this.updatedAt,
    required this.trackCount,
    required this.containsAllRequestedTracks,
  });
}

class LibraryCollectionsDatabase {
  static final LibraryCollectionsDatabase instance =
      LibraryCollectionsDatabase._init();
  static final sqlite.SingleFlightInitializer<Database> _database =
      sqlite.SingleFlightInitializer<Database>();

  final Future<SharedPreferences> _prefs = SharedPreferences.getInstance();

  LibraryCollectionsDatabase._init();

  Future<Database> get database {
    return _database.getOrCreate(
      () => sqlite.openAppDatabase(
        _dbFileName,
        version: _dbVersion,
        foreignKeys: true,
        onCreate: _createDb,
        onUpgrade: _upgradeDb,
      ),
    );
  }

  Future<void> _createDb(Database db, int version) async {
    _log.i('Creating collections database schema v$version');

    await db.execute('''
      CREATE TABLE $_tableWishlist (
        track_key TEXT PRIMARY KEY,
        track_json TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tableLoved (
        track_key TEXT PRIMARY KEY,
        track_json TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tablePlaylists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        cover_image_path TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE $_tablePlaylistTracks (
        playlist_id TEXT NOT NULL,
        track_key TEXT NOT NULL,
        track_json TEXT NOT NULL,
        added_at TEXT NOT NULL,
        PRIMARY KEY (playlist_id, track_key),
        FOREIGN KEY (playlist_id) REFERENCES $_tablePlaylists(id) ON DELETE CASCADE
      )
    ''');

    await _createFavoriteArtistsTable(db);
    await _createFavoriteAlbumsTable(db);

    await db.execute(
      'CREATE INDEX idx_${_tableWishlist}_added_at ON $_tableWishlist(added_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tableLoved}_added_at ON $_tableLoved(added_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylists}_created_at ON $_tablePlaylists(created_at DESC)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylistTracks}_playlist_id ON $_tablePlaylistTracks(playlist_id)',
    );
    await db.execute(
      'CREATE INDEX idx_${_tablePlaylistTracks}_added_at ON $_tablePlaylistTracks(added_at DESC)',
    );
  }

  Future<void> _upgradeDb(Database db, int oldVersion, int newVersion) async {
    _log.i('Upgrading collections database from v$oldVersion to v$newVersion');
    if (oldVersion < 2) {
      await _createFavoriteArtistsTable(db);
    }
    if (oldVersion < 3) {
      await _createFavoriteAlbumsTable(db);
    }
  }

  Future<void> _createFavoriteArtistsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_tableFavoriteArtists (
        artist_key TEXT PRIMARY KEY,
        artist_json TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_${_tableFavoriteArtists}_added_at ON $_tableFavoriteArtists(added_at DESC)',
    );
  }

  Future<void> _createFavoriteAlbumsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_tableFavoriteAlbums (
        album_key TEXT PRIMARY KEY,
        album_json TEXT NOT NULL,
        added_at TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_${_tableFavoriteAlbums}_added_at ON $_tableFavoriteAlbums(added_at DESC)',
    );
  }

  Future<bool> migrateFromSharedPreferences() async {
    final prefs = await _prefs;
    if (prefs.getBool(_migrationDoneKey) == true) {
      return false;
    }

    final raw = prefs.getString(_legacyCollectionsStorageKey);
    if (raw == null || raw.isEmpty) {
      await prefs.setBool(_migrationDoneKey, true);
      return false;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        await prefs.setBool(_migrationDoneKey, true);
        return false;
      }

      final root = Map<String, dynamic>.from(decoded);
      final wishlistRaw = (root['wishlist'] as List?) ?? const [];
      final lovedRaw = (root['loved'] as List?) ?? const [];
      final playlistsRaw = (root['playlists'] as List?) ?? const [];
      final nowIso = DateTime.now().toIso8601String();

      final db = await database;
      await db.transaction((txn) async {
        for (final entry in wishlistRaw.whereType<Map<Object?, Object?>>()) {
          final map = Map<String, dynamic>.from(entry);
          final trackKey = map['key'] as String?;
          final track = map['track'];
          if (trackKey == null || track is! Map<Object?, Object?>) continue;
          final addedAt = (map['addedAt'] as String?) ?? nowIso;
          await txn.insert(_tableWishlist, {
            'track_key': trackKey,
            'track_json': jsonEncode(track),
            'added_at': addedAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }

        for (final entry in lovedRaw.whereType<Map<Object?, Object?>>()) {
          final map = Map<String, dynamic>.from(entry);
          final trackKey = map['key'] as String?;
          final track = map['track'];
          if (trackKey == null || track is! Map<Object?, Object?>) continue;
          final addedAt = (map['addedAt'] as String?) ?? nowIso;
          await txn.insert(_tableLoved, {
            'track_key': trackKey,
            'track_json': jsonEncode(track),
            'added_at': addedAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }

        for (final playlistEntry
            in playlistsRaw.whereType<Map<Object?, Object?>>()) {
          final playlist = Map<String, dynamic>.from(playlistEntry);
          final playlistId = playlist['id'] as String?;
          if (playlistId == null || playlistId.isEmpty) continue;

          final createdAt = (playlist['createdAt'] as String?) ?? nowIso;
          final updatedAt = (playlist['updatedAt'] as String?) ?? createdAt;
          await txn.insert(_tablePlaylists, {
            'id': playlistId,
            'name': (playlist['name'] as String?) ?? '',
            'cover_image_path': playlist['coverImagePath'] as String?,
            'created_at': createdAt,
            'updated_at': updatedAt,
          }, conflictAlgorithm: ConflictAlgorithm.replace);

          final tracksRaw = (playlist['tracks'] as List?) ?? const [];
          for (final trackEntry
              in tracksRaw.whereType<Map<Object?, Object?>>()) {
            final trackMap = Map<String, dynamic>.from(trackEntry);
            final trackKey = trackMap['key'] as String?;
            final track = trackMap['track'];
            if (trackKey == null || track is! Map<Object?, Object?>) continue;
            final addedAt = (trackMap['addedAt'] as String?) ?? nowIso;
            await txn.insert(_tablePlaylistTracks, {
              'playlist_id': playlistId,
              'track_key': trackKey,
              'track_json': jsonEncode(track),
              'added_at': addedAt,
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      });

      await prefs.setBool(_migrationDoneKey, true);
      _log.i('Migrated legacy collections data to SQLite');
      return true;
    } catch (e, stack) {
      _log.e('Failed migrating collections to SQLite: $e', e, stack);
      return false;
    }
  }

  Future<LibraryCollectionsSnapshot> loadSnapshot() async {
    final db = await database;
    final wishlistRows = await db.query(
      _tableWishlist,
      orderBy: 'added_at DESC, rowid DESC',
    );
    final lovedRows = await db.query(
      _tableLoved,
      orderBy: 'added_at DESC, rowid DESC',
    );
    final playlistRows = await db.rawQuery('''
      SELECT
        p.*,
        CASE WHEN p.cover_image_path IS NULL OR p.cover_image_path = '' THEN (
          SELECT pt.track_json
          FROM $_tablePlaylistTracks pt
          WHERE pt.playlist_id = p.id
          ORDER BY pt.added_at ASC, pt.rowid ASC
          LIMIT 1
        ) END AS preview_track_json
      FROM $_tablePlaylists p
      ORDER BY p.created_at DESC, p.rowid DESC
    ''');
    final playlistTrackRows = await db.query(
      _tablePlaylistTracks,
      columns: ['playlist_id', 'track_key'],
      orderBy: 'playlist_id ASC, rowid ASC',
    );
    final favoriteArtistRows = await db.query(
      _tableFavoriteArtists,
      orderBy: 'added_at DESC, rowid DESC',
    );
    final favoriteAlbumRows = await db.query(
      _tableFavoriteAlbums,
      orderBy: 'added_at DESC, rowid DESC',
    );

    return LibraryCollectionsSnapshot(
      wishlistRows: wishlistRows,
      lovedRows: lovedRows,
      playlistRows: playlistRows,
      playlistTrackRows: playlistTrackRows,
      favoriteArtistRows: favoriteArtistRows,
      favoriteAlbumRows: favoriteAlbumRows,
    );
  }

  Future<List<Map<String, dynamic>>> loadPlaylistTracks(
    String playlistId,
  ) async {
    final db = await database;
    return db.query(
      _tablePlaylistTracks,
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'added_at ASC, rowid ASC',
    );
  }

  Future<List<PlaylistPickerSummaryRow>> loadPlaylistPickerSummaries(
    List<String> requestedTrackKeys,
  ) async {
    final db = await database;
    final uniqueTrackKeys = requestedTrackKeys
        .where((key) => key.trim().isNotEmpty)
        .toSet()
        .toList(growable: false);

    final playlistRows = await db.rawQuery('''
      SELECT
        p.id,
        p.name,
        p.cover_image_path,
        p.created_at,
        p.updated_at,
        COUNT(pt.track_key) AS track_count
      FROM $_tablePlaylists p
      LEFT JOIN $_tablePlaylistTracks pt ON pt.playlist_id = p.id
      GROUP BY p.id
      ORDER BY p.created_at DESC, p.rowid DESC
    ''');

    final matchedCountsByPlaylistId = <String, int>{};
    if (uniqueTrackKeys.isNotEmpty) {
      final placeholders = List.filled(uniqueTrackKeys.length, '?').join(', ');
      final matchedRows = await db.rawQuery('''
          SELECT playlist_id, COUNT(*) AS matched_count
          FROM $_tablePlaylistTracks
          WHERE track_key IN ($placeholders)
          GROUP BY playlist_id
        ''', uniqueTrackKeys);
      for (final row in matchedRows) {
        final playlistId = row['playlist_id']?.toString();
        if (playlistId == null || playlistId.isEmpty) continue;
        matchedCountsByPlaylistId[playlistId] =
            (row['matched_count'] as num?)?.toInt() ?? 0;
      }
    }

    final playlistIdsNeedingPreview = playlistRows
        .where((row) {
          final coverPath = row['cover_image_path']?.toString();
          return coverPath == null || coverPath.isEmpty;
        })
        .map((row) => row['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);

    final previewCoverByPlaylistId = <String, String?>{};
    if (playlistIdsNeedingPreview.isNotEmpty) {
      final placeholders = List.filled(
        playlistIdsNeedingPreview.length,
        '?',
      ).join(', ');
      final previewRows = await db.rawQuery('''
          SELECT outer_tracks.playlist_id, outer_tracks.track_json
          FROM $_tablePlaylistTracks outer_tracks
          WHERE outer_tracks.playlist_id IN ($placeholders)
            AND outer_tracks.rowid = (
              SELECT inner_tracks.rowid
              FROM $_tablePlaylistTracks inner_tracks
              WHERE inner_tracks.playlist_id = outer_tracks.playlist_id
              ORDER BY inner_tracks.added_at ASC, inner_tracks.rowid ASC
              LIMIT 1
            )
        ''', playlistIdsNeedingPreview);

      for (final row in previewRows) {
        final playlistId = row['playlist_id']?.toString();
        final trackJson = row['track_json'] as String?;
        if (playlistId == null ||
            playlistId.isEmpty ||
            trackJson == null ||
            trackJson.isEmpty) {
          continue;
        }
        try {
          final decoded = jsonDecode(trackJson);
          if (decoded is! Map) continue;
          final coverUrl = decoded['coverUrl']?.toString();
          if (coverUrl != null && coverUrl.isNotEmpty) {
            previewCoverByPlaylistId[playlistId] = coverUrl;
          }
        } catch (e) {
          _log.d('best-effort step failed: $e');
        }
      }
    }

    return playlistRows
        .map((row) {
          final id = row['id']?.toString() ?? '';
          final createdAt =
              DateTime.tryParse(row['created_at']?.toString() ?? '') ??
              DateTime.now();
          final updatedAt =
              DateTime.tryParse(row['updated_at']?.toString() ?? '') ??
              createdAt;
          return PlaylistPickerSummaryRow(
            id: id,
            name: row['name']?.toString() ?? '',
            coverImagePath: row['cover_image_path'] as String?,
            previewCover: previewCoverByPlaylistId[id],
            createdAt: createdAt,
            updatedAt: updatedAt,
            trackCount: (row['track_count'] as num?)?.toInt() ?? 0,
            containsAllRequestedTracks:
                uniqueTrackKeys.isNotEmpty &&
                matchedCountsByPlaylistId[id] == uniqueTrackKeys.length,
          );
        })
        .toList(growable: false);
  }

  Future<void> _upsertEntry(
    String table,
    String prefix, {
    required String key,
    required String json,
    required String addedAt,
  }) async {
    final db = await database;
    await db.insert(table, {
      '${prefix}_key': key,
      '${prefix}_json': json,
      'added_at': addedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> _deleteEntry(String table, String prefix, String key) async {
    final db = await database;
    await db.delete(table, where: '${prefix}_key = ?', whereArgs: [key]);
  }

  Future<void> upsertWishlistEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) => _upsertEntry(
    _tableWishlist,
    'track',
    key: trackKey,
    json: trackJson,
    addedAt: addedAt,
  );

  Future<void> deleteWishlistEntry(String trackKey) =>
      _deleteEntry(_tableWishlist, 'track', trackKey);

  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) => _upsertEntry(
    _tableLoved,
    'track',
    key: trackKey,
    json: trackJson,
    addedAt: addedAt,
  );

  Future<void> deleteLovedEntry(String trackKey) =>
      _deleteEntry(_tableLoved, 'track', trackKey);

  Future<void> upsertFavoriteArtistEntry({
    required String artistKey,
    required String artistJson,
    required String addedAt,
  }) => _upsertEntry(
    _tableFavoriteArtists,
    'artist',
    key: artistKey,
    json: artistJson,
    addedAt: addedAt,
  );

  Future<void> deleteFavoriteArtistEntry(String artistKey) =>
      _deleteEntry(_tableFavoriteArtists, 'artist', artistKey);

  Future<void> upsertFavoriteAlbumEntry({
    required String albumKey,
    required String albumJson,
    required String addedAt,
  }) => _upsertEntry(
    _tableFavoriteAlbums,
    'album',
    key: albumKey,
    json: albumJson,
    addedAt: addedAt,
  );

  Future<void> deleteFavoriteAlbumEntry(String albumKey) =>
      _deleteEntry(_tableFavoriteAlbums, 'album', albumKey);

  Future<void> upsertPlaylist({
    required String id,
    required String name,
    required String createdAt,
    required String updatedAt,
    String? coverImagePath,
  }) async {
    final db = await database;
    await db.insert(_tablePlaylists, {
      'id': id,
      'name': name,
      'cover_image_path': coverImagePath,
      'created_at': createdAt,
      'updated_at': updatedAt,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> renamePlaylist({
    required String playlistId,
    required String name,
    required String updatedAt,
  }) async {
    final db = await database;
    await db.update(
      _tablePlaylists,
      {'name': name, 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [playlistId],
    );
  }

  Future<void> updatePlaylistCover({
    required String playlistId,
    required String updatedAt,
    String? coverImagePath,
  }) async {
    final db = await database;
    await db.update(
      _tablePlaylists,
      {'cover_image_path': coverImagePath, 'updated_at': updatedAt},
      where: 'id = ?',
      whereArgs: [playlistId],
    );
  }

  Future<void> deletePlaylist(String playlistId) async {
    final db = await database;
    await db.delete(_tablePlaylists, where: 'id = ?', whereArgs: [playlistId]);
  }

  Future<void> upsertPlaylistTrack({
    required String playlistId,
    required String trackKey,
    required String trackJson,
    required String addedAt,
    required String playlistUpdatedAt,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.insert(_tablePlaylistTracks, {
        'playlist_id': playlistId,
        'track_key': trackKey,
        'track_json': trackJson,
        'added_at': addedAt,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
    });
  }

  Future<void> upsertPlaylistTracksBatch({
    required String playlistId,
    required String playlistUpdatedAt,
    required List<Map<String, String>> tracks,
  }) async {
    if (tracks.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final track in tracks) {
        batch.insert(_tablePlaylistTracks, {
          'playlist_id': playlistId,
          'track_key': track['track_key'],
          'track_json': track['track_json'],
          'added_at': track['added_at'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      batch.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
      await batch.commit(noResult: true);
    });
  }

  Future<void> deletePlaylistTrack({
    required String playlistId,
    required String trackKey,
    required String playlistUpdatedAt,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        _tablePlaylistTracks,
        where: 'playlist_id = ? AND track_key = ?',
        whereArgs: [playlistId, trackKey],
      );
      await txn.update(
        _tablePlaylists,
        {'updated_at': playlistUpdatedAt},
        where: 'id = ?',
        whereArgs: [playlistId],
      );
    });
  }

  /// Wipes every collection table and rewrites them from a restored backup.
  ///
  /// [collectionsJson] must use the same shape as
  /// `LibraryCollectionsState.toJson()` (wishlist/loved/playlists/
  /// favoriteArtists/favoriteAlbums).
  /// Track entries carry a nested `track` map (stored as `track_json`); favorite
  /// artist/album entries are stored whole as `artist_json`/`album_json`.
  Future<void> replaceAllFromBackup(
    Map<String, dynamic> collectionsJson,
  ) async {
    final nowIso = DateTime.now().toIso8601String();

    List<Map<String, dynamic>> listOf(String key) {
      final raw = collectionsJson[key];
      if (raw is! List) return const [];
      return raw
          .whereType<Map<Object?, Object?>>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(growable: false);
    }

    final wishlist = listOf('wishlist');
    final loved = listOf('loved');
    final playlists = listOf('playlists');
    final favoriteArtists = listOf('favoriteArtists');
    final favoriteAlbums = listOf('favoriteAlbums');

    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(_tablePlaylistTracks);
      await txn.delete(_tablePlaylists);
      await txn.delete(_tableWishlist);
      await txn.delete(_tableLoved);
      await txn.delete(_tableFavoriteArtists);
      await txn.delete(_tableFavoriteAlbums);

      Future<void> insertTrackEntries(
        String table,
        List<Map<String, dynamic>> entries,
      ) async {
        for (final entry in entries) {
          final key = entry['key'] as String?;
          final track = entry['track'];
          if (key == null || key.isEmpty || track is! Map) continue;
          await txn.insert(table, {
            'track_key': key,
            'track_json': jsonEncode(track),
            'added_at': (entry['addedAt'] as String?) ?? nowIso,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }

      await insertTrackEntries(_tableWishlist, wishlist);
      await insertTrackEntries(_tableLoved, loved);

      for (final artist in favoriteArtists) {
        final key = artist['key'] as String?;
        if (key == null || key.isEmpty) continue;
        await txn.insert(_tableFavoriteArtists, {
          'artist_key': key,
          'artist_json': jsonEncode(artist),
          'added_at': (artist['addedAt'] as String?) ?? nowIso,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      for (final album in favoriteAlbums) {
        final key = album['key'] as String?;
        if (key == null || key.isEmpty) continue;
        await txn.insert(_tableFavoriteAlbums, {
          'album_key': key,
          'album_json': jsonEncode(album),
          'added_at': (album['addedAt'] as String?) ?? nowIso,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      for (final playlist in playlists) {
        final id = playlist['id'] as String?;
        if (id == null || id.isEmpty) continue;
        final createdAt = (playlist['createdAt'] as String?) ?? nowIso;
        final updatedAt = (playlist['updatedAt'] as String?) ?? createdAt;
        await txn.insert(_tablePlaylists, {
          'id': id,
          'name': (playlist['name'] as String?) ?? '',
          'cover_image_path': playlist['coverImagePath'] as String?,
          'created_at': createdAt,
          'updated_at': updatedAt,
        }, conflictAlgorithm: ConflictAlgorithm.replace);

        final tracksRaw = playlist['tracks'];
        if (tracksRaw is! List) continue;
        for (final trackEntry in tracksRaw.whereType<Map<Object?, Object?>>()) {
          final entry = Map<String, dynamic>.from(trackEntry);
          final key = entry['key'] as String?;
          final track = entry['track'];
          if (key == null || key.isEmpty || track is! Map) continue;
          await txn.insert(_tablePlaylistTracks, {
            'playlist_id': id,
            'track_key': key,
            'track_json': jsonEncode(track),
            'added_at': (entry['addedAt'] as String?) ?? nowIso,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    });

    _log.i('Restored collections from backup');
  }
}
