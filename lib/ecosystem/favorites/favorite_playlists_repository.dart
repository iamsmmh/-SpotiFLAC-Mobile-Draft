/// Storage for **favorite playlists** (Feature Group 3).
///
/// Tracks/albums/artists favorites are owned by the pre-existing collections
/// store; playlists are the one kind the app had no notion of, so they get
/// their own table (`ec_favorite_playlists`) in the ecosystem database.
library;

import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/ecosystem/favorites/favorites.dart';

class FavoritePlaylistEntry {
  const FavoritePlaylistEntry({
    required this.playlistId,
    required this.title,
    this.coverPath,
    this.trackCount = 0,
    required this.addedAt,
  });

  final String playlistId;
  final String title;
  final String? coverPath;
  final int trackCount;
  final DateTime addedAt;

  FavoriteEntry toFavoriteEntry() => FavoriteEntry(
    key: 'playlist:$playlistId',
    kind: FavoriteKind.playlist,
    title: title,
    subtitle: _pluralizeTracks(trackCount),
    coverUrl: coverPath,
    addedAt: addedAt,
    playlistId: playlistId,
  );

  Map<String, Object?> toRow() => <String, Object?>{
    'playlist_id': playlistId,
    'title': title,
    'cover_path': coverPath,
    'track_count': trackCount,
    'added_at': addedAt.toUtc().toIso8601String(),
  };

  static FavoritePlaylistEntry fromRow(Map<String, Object?> row) {
    return FavoritePlaylistEntry(
      playlistId: row['playlist_id']?.toString() ?? '',
      title: row['title']?.toString() ?? '',
      coverPath: row['cover_path']?.toString(),
      trackCount: row['track_count'] is num
          ? (row['track_count']! as num).toInt()
          : 0,
      addedAt:
          DateTime.tryParse(row['added_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  static String _pluralizeTracks(int count) =>
      count == 1 ? '1 track' : '$count tracks';
}

class FavoritePlaylistsRepository {
  FavoritePlaylistsRepository({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  Future<List<FavoritePlaylistEntry>> all() async {
    final db = await _database.database;
    final rows = await db.query(
      tableFavoritePlaylists,
      orderBy: 'added_at DESC',
    );
    return rows
        .map(FavoritePlaylistEntry.fromRow)
        .where((entry) => entry.playlistId.isNotEmpty)
        .toList(growable: false);
  }

  Future<bool> isFavorite(String playlistId) async {
    final db = await _database.database;
    final rows = await db.query(
      tableFavoritePlaylists,
      where: 'playlist_id = ?',
      whereArgs: <Object?>[playlistId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> add(FavoritePlaylistEntry entry) async {
    final db = await _database.database;
    await db.insert(
      tableFavoritePlaylists,
      entry.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> remove(String playlistId) async {
    final db = await _database.database;
    await db.delete(
      tableFavoritePlaylists,
      where: 'playlist_id = ?',
      whereArgs: <Object?>[playlistId],
    );
  }

  Future<void> updateTrackCount(String playlistId, int trackCount) async {
    final db = await _database.database;
    await db.update(
      tableFavoritePlaylists,
      <String, Object?>{'track_count': trackCount},
      where: 'playlist_id = ?',
      whereArgs: <Object?>[playlistId],
    );
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(tableFavoritePlaylists);
  }
}
