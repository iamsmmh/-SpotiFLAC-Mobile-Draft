/// Persistence for the three generated-shelf families (Phases 3, 4, 5).
///
/// Each family has its own table because each has its own refresh key —
/// ISO week, UTC day and a plain TTL — and its own bookkeeping columns. Sharing
/// one generic cache row would push that logic into the readers, which is
/// exactly where a subtle "stale shelf" bug would hide.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_schema.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/mood_engine.dart';

// ===========================================================================
// Discover Weekly
// ===========================================================================

/// One stored week of Discover Weekly.
class StoredDiscoverWeekly {
  const StoredDiscoverWeekly({
    required this.weekKey,
    required this.shelf,
    required this.generatedAt,
    this.hiddenGemCount = 0,
    this.newReleaseCount = 0,
  });

  final String weekKey;
  final GeneratedShelf shelf;
  final DateTime generatedAt;
  final int hiddenGemCount;
  final int newReleaseCount;
}

/// Reads and writes `ds_discover_weekly`.
class DiscoverWeeklyStore {
  DiscoverWeeklyStore({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  Future<StoredDiscoverWeekly?> read(String weekKey) async {
    final db = await _database.database;
    final rows = await db.query(
      dsDiscoverWeekly,
      where: 'week_key = ?',
      whereArgs: <Object?>[weekKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    int asInt(String key) {
      final value = row[key];
      return value is num ? value.toInt() : 0;
    }

    final items = _decodeItems(row['items_json']?.toString());
    final seeds = _decodeStrings(row['seed_artists_json']?.toString());
    final generatedAt =
        DateTime.tryParse(row['generated_at']?.toString() ?? '') ??
        DateTime.now();
    return StoredDiscoverWeekly(
      weekKey: weekKey,
      shelf: GeneratedShelf(
        id: discoverWeeklyDefaultId,
        title: 'Discover Weekly',
        subtitle: seeds.isEmpty
            ? '${items.length} picks for this week'
            : 'Based on ${seeds.take(2).join(' and ')}',
        items: items,
        generatedAt: generatedAt,
        expiresAt: DateTime.tryParse(row['expires_at']?.toString() ?? ''),
        seedLabels: seeds,
        accentSeed: seeds.isEmpty ? null : seeds.first,
      ),
      generatedAt: generatedAt,
      hiddenGemCount: asInt('hidden_gem_count'),
      newReleaseCount: asInt('new_release_count'),
    );
  }

  Future<void> save(StoredDiscoverWeekly entry) async {
    final db = await _database.database;
    await db.insert(
      dsDiscoverWeekly,
      <String, Object?>{
        'week_key': entry.weekKey,
        'items_json': _encodeItems(entry.shelf.items),
        'seed_artists_json': _encodeStrings(entry.shelf.seedLabels),
        'generated_at': entry.generatedAt.toUtc().toIso8601String(),
        'expires_at': (entry.shelf.expiresAt ?? entry.generatedAt)
            .toUtc()
            .toIso8601String(),
        'track_count': entry.shelf.trackCount,
        'hidden_gem_count': entry.hiddenGemCount,
        'new_release_count': entry.newReleaseCount,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Drops weeks older than [keepWeeks]; the current week is never touched.
  Future<int> pruneOlderThan({int keepWeeks = 8}) async {
    final db = await _database.database;
    final cutoff = DateTime.now().subtract(Duration(days: keepWeeks * 7));
    return db.delete(
      dsDiscoverWeekly,
      where: 'generated_at < ?',
      whereArgs: <Object?>[cutoff.toUtc().toIso8601String()],
    );
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(dsDiscoverWeekly);
  }
}

/// Shelf id used when a stored row predates the id column.
const String discoverWeeklyDefaultId = 'discover-weekly';

// ===========================================================================
// Daily Mixes
// ===========================================================================

/// One stored mix.
class StoredDailyMix {
  const StoredDailyMix({
    required this.mixId,
    required this.dayKey,
    required this.position,
    required this.shelf,
    required this.generatedAt,
    this.clusterGenres = const <String>[],
  });

  final String mixId;
  final String dayKey;
  final int position;
  final GeneratedShelf shelf;
  final DateTime generatedAt;
  final List<String> clusterGenres;
}

/// Reads and writes `ds_daily_mixes`.
class DailyMixStore {
  DailyMixStore({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  /// Mixes for [day], in position order. Empty when nothing was generated yet.
  Future<List<StoredDailyMix>> read(String day) async {
    final db = await _database.database;
    final rows = await db.query(
      dsDailyMixes,
      where: 'day_key = ?',
      whereArgs: <Object?>[day],
      orderBy: 'position ASC',
    );
    final mixes = <StoredDailyMix>[];
    for (final row in rows) {
      int asInt(String key) {
        final value = row[key];
        return value is num ? value.toInt() : 0;
      }

      final mixId = row['mix_id']?.toString() ?? '';
      if (mixId.isEmpty) continue;
      final generatedAt =
          DateTime.tryParse(row['generated_at']?.toString() ?? '') ??
          DateTime.now();
      final seeds = _decodeStrings(row['seed_labels_json']?.toString());
      mixes.add(
        StoredDailyMix(
          mixId: mixId,
          dayKey: day,
          position: asInt('position'),
          shelf: GeneratedShelf(
            id: mixId,
            title: row['title']?.toString() ?? 'Daily Mix',
            subtitle: row['subtitle']?.toString() ?? '',
            items: _decodeItems(row['items_json']?.toString()),
            generatedAt: generatedAt,
            expiresAt: DateTime.tryParse(row['expires_at']?.toString() ?? ''),
            seedLabels: seeds,
            accentSeed: row['subtitle']?.toString(),
          ),
          generatedAt: generatedAt,
          clusterGenres: seeds,
        ),
      );
    }
    return List<StoredDailyMix>.unmodifiable(mixes);
  }

  /// Replaces the whole day in one transaction so a reader never sees a
  /// partially written set of five.
  Future<void> saveAll(List<StoredDailyMix> mixes) async {
    if (mixes.isEmpty) return;
    final db = await _database.database;
    final day = mixes.first.dayKey;
    await db.transaction((txn) async {
      await txn.delete(
        dsDailyMixes,
        where: 'day_key = ?',
        whereArgs: <Object?>[day],
      );
      final batch = txn.batch();
      for (final mix in mixes) {
        batch.insert(
          dsDailyMixes,
          <String, Object?>{
            'mix_id': mix.mixId,
            'day_key': mix.dayKey,
            'position': mix.position,
            'title': mix.shelf.title,
            'subtitle': mix.shelf.subtitle,
            'cluster_json': _encodeStrings(mix.clusterGenres),
            'items_json': _encodeItems(mix.shelf.items),
            'seed_labels_json': _encodeStrings(mix.shelf.seedLabels),
            'generated_at': mix.generatedAt.toUtc().toIso8601String(),
            'expires_at': (mix.shelf.expiresAt ?? mix.generatedAt)
                .toUtc()
                .toIso8601String(),
            'track_count': mix.shelf.trackCount,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// Deletes mixes from previous days.
  Future<int> pruneOlderThan(String day) async {
    final db = await _database.database;
    return db.delete(
      dsDailyMixes,
      where: 'day_key < ?',
      whereArgs: <Object?>[day],
    );
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(dsDailyMixes);
  }
}

// ===========================================================================
// Mood playlists
// ===========================================================================

/// Reads and writes `ds_mood_profiles`.
class MoodPlaylistStore {
  MoodPlaylistStore({EcosystemDatabase? database})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;

  Future<GeneratedShelf?> read(Mood mood) async {
    final db = await _database.database;
    final rows = await db.query(
      dsMoodProfiles,
      where: 'mood = ?',
      whereArgs: <Object?>[mood.name],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final expiresAt = DateTime.tryParse(row['expires_at']?.toString() ?? '');
    if (expiresAt == null || DateTime.now().isAfter(expiresAt)) return null;
    final generatedAt =
        DateTime.tryParse(row['generated_at']?.toString() ?? '') ??
        DateTime.now();
    return GeneratedShelf(
      id: 'mood-${mood.name}',
      title: row['label']?.toString() ?? moodProfiles[mood]!.label,
      items: _decodeItems(row['items_json']?.toString()),
      generatedAt: generatedAt,
      expiresAt: expiresAt,
    );
  }

  Future<void> save(Mood mood, GeneratedShelf shelf) async {
    final db = await _database.database;
    final generatedAt = shelf.generatedAt ?? DateTime.now();
    await db.insert(
      dsMoodProfiles,
      <String, Object?>{
        'mood': mood.name,
        'label': shelf.title.isEmpty
            ? moodProfiles[mood]!.label
            : shelf.title,
        'items_json': _encodeItems(shelf.items),
        'generated_at': generatedAt.toUtc().toIso8601String(),
        'expires_at': (shelf.expiresAt ?? generatedAt.add(const Duration(days: 3)))
            .toUtc()
            .toIso8601String(),
        'track_count': shelf.trackCount,
        'bpm_evidence_count': shelf.items
            .where((entry) => entry.track.bpm != null)
            .length,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Every stored mood shelf, in catalogue order. Missing or expired moods are
  /// simply absent, so the UI renders what actually exists.
  Future<Map<Mood, GeneratedShelf>> readAll() async {
    final result = <Mood, GeneratedShelf>{};
    for (final mood in allMoods) {
      final shelf = await read(mood);
      if (shelf != null && !shelf.isEmpty) result[mood] = shelf;
    }
    return Map<Mood, GeneratedShelf>.unmodifiable(result);
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(dsMoodProfiles);
  }
}

// ---------------------------------------------------------------------------
// Shared codecs
// ---------------------------------------------------------------------------

/// Encodes a scored-item list compactly (track + score + first reason).
String _encodeItems(List<ScoredTrack> items) {
  return _encode(<Object?>[
    for (final entry in items)
      <String, Object?>{
        't': entry.track.toJson(),
        's': entry.score,
        if (entry.breakdown.reasons.isNotEmpty)
          'r': entry.breakdown.reasons.first.code,
      },
  ]);
}

List<ScoredTrack> _decodeItems(String? raw) {
  final decoded = _decode(raw);
  if (decoded is! List) return const <ScoredTrack>[];
  final items = <ScoredTrack>[];
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final track = DiscoveryTrack.fromJson(entry['t']);
    if (track == null) continue;
    final score = entry['s'];
    final reason = entry['r']?.toString();
    items.add(
      ScoredTrack(
        track: track,
        score: score is num ? score.toDouble() : 0,
        breakdown: reason == null || reason.isEmpty
            ? const ScoreBreakdown()
            : ScoreBreakdown(
                reasons: <RecommendationReason>[
                  RecommendationReason(reason, reasonLabel(reason)),
                ],
              ),
      ),
    );
  }
  return List<ScoredTrack>.unmodifiable(items);
}

String _encodeStrings(List<String> values) => _encode(values);

List<String> _decodeStrings(String? raw) {
  final decoded = _decode(raw);
  if (decoded is! List) return const <String>[];
  return List<String>.unmodifiable(
    decoded.whereType<Object>().map((entry) => entry.toString()),
  );
}

String _encode(Object? value) => jsonEncode(value);

/// Tolerant decode: a truncated column degrades to "no data" instead of
/// throwing during a home-screen read.
Object? _decode(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  try {
    return jsonDecode(value);
  } on FormatException {
    return null;
  }
}

/// Human-readable label for a reason code, so a restored shelf can explain
/// itself without re-running the scorer.
String reasonLabel(String code) {
  switch (code) {
    case 'recent':
      return 'Played recently';
    case 'frequency':
      return 'You play this often';
    case 'favorite':
      return 'In your library';
    case 'favoriteArtist':
      return 'An artist you follow';
    case 'artist':
      return 'Sounds like an artist you love';
    case 'genre':
      return 'Matches your genres';
    case 'album':
      return 'From an album you know';
    default:
      return 'Picked for you';
  }
}
