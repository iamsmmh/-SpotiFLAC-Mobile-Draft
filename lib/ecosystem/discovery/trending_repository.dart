/// Persisted trending shelves (Phase 9 storage).
///
/// The maths lives in `engine/discovery/trending_engine.dart`; this file only
/// stores the computed shelves in `ds_trending_statistics` so the home screen
/// can paint them from one indexed read instead of recomputing on every
/// scroll-back.
library;

import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_schema.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/engine/discovery/similarity_engine.dart';
import 'package:spotiflac_android/engine/discovery/trending_engine.dart';

/// One computed trending shelf.
class TrendingShelf {
  const TrendingShelf({
    required this.period,
    required this.entries,
    required this.computedAt,
  });

  final TrendingPeriod period;
  final List<TrendingEntry> entries;
  final DateTime computedAt;

  bool get isEmpty => entries.isEmpty;
}

/// Reads and writes `ds_trending_statistics`.
class TrendingRepository {
  TrendingRepository({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  /// Replaces every row for [shelf.period] in one transaction, so a reader
  /// never observes a half-written shelf.
  Future<void> save(TrendingShelf shelf) async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete(
        dsTrendingStatistics,
        where: 'period = ?',
        whereArgs: <Object?>[shelf.period.name],
      );
      final batch = txn.batch();
      for (final entry in shelf.entries) {
        final row = entry.toRow(shelf.computedAt);
        batch.insert(
          dsTrendingStatistics,
          <String, Object?>{
            'period': shelf.period.name,
            'track_key': entry.key,
            'label': entry.label,
            'subtitle': entry.subtitle,
            'cover_url': entry.coverUrl,
            'rank': entry.rank,
            'score': entry.score,
            'play_count': entry.playCount,
            'delta': entry.delta,
            'is_artist': entry.isArtist ? 1 : 0,
            'computed_at': row['computed_at'],
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Reads one shelf. Returns an empty shelf when nothing is stored yet.
  Future<TrendingShelf> read(TrendingPeriod period) async {
    final db = await _database.database;
    final rows = await db.query(
      dsTrendingStatistics,
      where: 'period = ?',
      whereArgs: <Object?>[period.name],
      orderBy: 'rank ASC',
    );
    final entries = <TrendingEntry>[];
    DateTime? computedAt;
    for (final row in rows) {
      int asInt(String key) {
        final value = row[key];
        return value is num ? value.toInt() : 0;
      }

      double asDouble(String key) {
        final value = row[key];
        return value is num ? value.toDouble() : 0;
      }

      computedAt ??=
          DateTime.tryParse(row['computed_at']?.toString() ?? '');
      entries.add(
        TrendingEntry(
          key: row['track_key']?.toString() ?? '',
          label: row['label']?.toString() ?? '',
          subtitle: row['subtitle']?.toString() ?? '',
          coverUrl: row['cover_url']?.toString(),
          rank: asInt('rank'),
          score: asDouble('score'),
          playCount: asInt('play_count'),
          delta: asDouble('delta'),
          period: period,
          isArtist: asInt('is_artist') == 1,
        ),
      );
    }
    return TrendingShelf(
      period: period,
      entries: List<TrendingEntry>.unmodifiable(entries),
      computedAt: computedAt ?? DateTime.now(),
    );
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(dsTrendingStatistics);
  }
}

// ---------------------------------------------------------------------------
// Similarity persistence (Phase 6 storage)
// ---------------------------------------------------------------------------

/// Reads and writes the persisted similarity graphs.
///
/// Similarity is the most expensive part of a refresh (quadratic in the number
/// of artists), so the top pairs per artist are stored and only recomputed
/// when the underlying taste actually changed.
class SimilarityStore {
  SimilarityStore({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  /// Stores [similarities] for [artistKey], replacing the previous set.
  Future<void> saveArtistSimilarities(
    String artistKey,
    List<ArtistSimilarity> similarities, {
    required DateTime computedAt,
  }) async {
    if (artistKey.isEmpty) return;
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete(
        dsArtistSimilarity,
        where: 'artist_key = ?',
        whereArgs: <Object?>[artistKey],
      );
      final batch = txn.batch();
      for (final entry in similarities) {
        batch.insert(
          dsArtistSimilarity,
          <String, Object?>{
            'artist_key': artistKey,
            'other_key': entry.artistKey,
            'label': entry.label,
            'score': entry.score,
            'genre_overlap': entry.genreOverlap,
            'tag_overlap': entry.tagOverlap,
            'colisten_overlap': entry.coListenOverlap,
            'playlist_overlap': entry.playlistOverlap,
            'computed_at': computedAt.toUtc().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Similar artists for one artist, best first. Empty when never computed.
  Future<List<ArtistSimilarity>> artistSimilarities(String artistKey) async {
    if (artistKey.isEmpty) return const <ArtistSimilarity>[];
    final db = await _database.database;
    final rows = await db.query(
      dsArtistSimilarity,
      where: 'artist_key = ?',
      whereArgs: <Object?>[artistKey],
      orderBy: 'score DESC',
    );
    return List<ArtistSimilarity>.unmodifiable(<ArtistSimilarity>[
      for (final row in rows)
        ArtistSimilarity(
          artistKey: row['other_key']?.toString() ?? '',
          label: row['label']?.toString() ?? '',
          score: _toDouble(row['score']),
          genreOverlap: _toDouble(row['genre_overlap']),
          tagOverlap: _toDouble(row['tag_overlap']),
          coListenOverlap: _toDouble(row['colisten_overlap']),
          playlistOverlap: _toDouble(row['playlist_overlap']),
        ),
    ]);
  }

  /// Stores track-level neighbours (Track Radio seeds).
  Future<void> saveTrackSimilarities(
    String trackKey,
    Map<String, double> similarities, {
    required DateTime computedAt,
  }) async {
    if (trackKey.isEmpty || similarities.isEmpty) return;
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete(
        dsTrackSimilarity,
        where: 'track_key = ?',
        whereArgs: <Object?>[trackKey],
      );
      final batch = txn.batch();
      for (final entry in similarities.entries) {
        batch.insert(
          dsTrackSimilarity,
          <String, Object?>{
            'track_key': trackKey,
            'other_key': entry.key,
            'score': entry.value,
            'computed_at': computedAt.toUtc().toIso8601String(),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  Future<Map<String, double>> trackSimilarities(String trackKey) async {
    if (trackKey.isEmpty) return const <String, double>{};
    final db = await _database.database;
    final rows = await db.query(
      dsTrackSimilarity,
      where: 'track_key = ?',
      whereArgs: <Object?>[trackKey],
      orderBy: 'score DESC',
    );
    return <String, double>{
      for (final row in rows)
        row['other_key']?.toString() ?? '': _toDouble(row['score']),
    };
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.transaction((txn) async {
      await txn.delete(dsArtistSimilarity);
      await txn.delete(dsTrackSimilarity);
    });
  }

  double _toDouble(Object? value) => value is num ? value.toDouble() : 0;
}
