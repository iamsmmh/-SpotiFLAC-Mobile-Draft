/// Generated-shelf cache (Phase 11 `RecommendationCache`, Phase 12 budget).
///
/// Every expensive generation — Discover Weekly, Daily Mixes, mood playlists,
/// trending — writes its result here with a TTL. The UI reads the cache first
/// and refreshes in the background, so a cold start paints in one SQLite read
/// instead of waiting for a rebuild.
///
/// Entries are also versioned by [engineVersion]: bumping it invalidates every
/// row, which is how a scoring change reaches existing users without leaving
/// stale shelves on screen.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_schema.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('DiscoveryCache');

/// Bump to invalidate every cached shelf after a scoring change.
const int discoveryEngineVersion = 1;

/// TTL + cache key per shelf family.
class CachePolicy {
  const CachePolicy({
    required this.kind,
    required this.ttl,
    this.key,
  });

  /// Value stored in the `kind` column; also the eviction unit.
  final String kind;

  final Duration ttl;

  /// Explicit cache key; when null the key is derived from [kind].
  final String? key;

  String keyFor([String suffix = '']) =>
      suffix.isEmpty ? (key ?? kind) : '${key ?? kind}:$suffix';
}

/// The shelf families the app caches.
class DiscoveryCacheKeys {
  const DiscoveryCacheKeys._();

  static const CachePolicy discoverWeekly = CachePolicy(
    kind: 'discover_weekly',
    ttl: Duration(days: 7),
  );
  static const CachePolicy dailyMixes = CachePolicy(
    kind: 'daily_mixes',
    ttl: Duration(hours: 20),
  );
  static const CachePolicy mood = CachePolicy(
    kind: 'mood',
    ttl: Duration(days: 3),
  );
  static const CachePolicy trending = CachePolicy(
    kind: 'trending',
    ttl: Duration(hours: 6),
  );
  static const CachePolicy recommendedForYou = CachePolicy(
    kind: 'recommended_for_you',
    ttl: Duration(hours: 12),
  );
  static const CachePolicy similarArtists = CachePolicy(
    kind: 'similar_artists',
    ttl: Duration(days: 3),
  );
  static const CachePolicy newReleases = CachePolicy(
    kind: 'new_releases',
    ttl: Duration(days: 2),
  );
  static const CachePolicy home = CachePolicy(
    kind: 'home',
    ttl: Duration(hours: 6),
  );
}

/// One cached entry.
class CachedShelf {
  const CachedShelf({
    required this.shelf,
    required this.kind,
    required this.generatedAt,
    required this.expiresAt,
    this.computeMs = 0,
  });

  final GeneratedShelf shelf;
  final String kind;
  final DateTime generatedAt;
  final DateTime expiresAt;
  final int computeMs;

  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

/// SQLite-backed shelf cache.
class RecommendationCache {
  RecommendationCache({
    EcosystemDatabase? database,
    this.engineVersion = discoveryEngineVersion,
  }) : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;
  final int engineVersion;

  /// Reads one entry, or null when missing/expired/version-mismatched.
  Future<CachedShelf?> read(String cacheKey) async {
    final db = await _database.database;
    final rows = await db.query(
      dsRecommendationCache,
      where: 'cache_key = ?',
      whereArgs: <Object?>[cacheKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final version = row['engine_version'];
    if (version is num && version.toInt() != engineVersion) return null;
    final expiresAt =
        DateTime.tryParse(row['expires_at']?.toString() ?? '');
    if (expiresAt == null || DateTime.now().isAfter(expiresAt)) return null;

    final shelf = decodeShelf(row['payload_json']?.toString());
    if (shelf == null) return null;
    final generatedAt =
        DateTime.tryParse(row['generated_at']?.toString() ?? '') ??
        DateTime.now();
    return CachedShelf(
      shelf: shelf,
      kind: row['kind']?.toString() ?? '',
      generatedAt: generatedAt,
      expiresAt: expiresAt,
      computeMs: row['compute_ms'] is num
          ? (row['compute_ms']! as num).toInt()
          : 0,
    );
  }

  /// Writes one entry, replacing any previous value for [cacheKey].
  Future<void> write(
    String cacheKey,
    GeneratedShelf shelf, {
    required CachePolicy policy,
    required DateTime generatedAt,
    int computeMs = 0,
  }) async {
    final db = await _database.database;
    final expiresAt = generatedAt.add(policy.ttl);
    await db.insert(
      dsRecommendationCache,
      <String, Object?>{
        'cache_key': cacheKey,
        'kind': policy.kind,
        'payload_json': encodeShelf(shelf),
        'generated_at': generatedAt.toUtc().toIso8601String(),
        'expires_at': expiresAt.toUtc().toIso8601String(),
        'track_count': shelf.trackCount,
        'engine_version': engineVersion,
        'compute_ms': computeMs,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Reads every entry of a kind (Daily Mixes cache five shelves under one
  /// kind, one key per position).
  Future<List<CachedShelf>> readKind(String kind) async {
    final db = await _database.database;
    final rows = await db.query(
      dsRecommendationCache,
      where: 'kind = ? AND engine_version = ?',
      whereArgs: <Object?>[kind, engineVersion],
      orderBy: 'cache_key ASC',
    );
    final now = DateTime.now();
    final results = <CachedShelf>[];
    for (final row in rows) {
      final expiresAt =
          DateTime.tryParse(row['expires_at']?.toString() ?? '');
      if (expiresAt == null || now.isAfter(expiresAt)) continue;
      final shelf = decodeShelf(row['payload_json']?.toString());
      if (shelf == null) continue;
      results.add(
        CachedShelf(
          shelf: shelf,
          kind: kind,
          generatedAt:
              DateTime.tryParse(row['generated_at']?.toString() ?? '') ?? now,
          expiresAt: expiresAt,
          computeMs: row['compute_ms'] is num
              ? (row['compute_ms']! as num).toInt()
              : 0,
        ),
      );
    }
    return List<CachedShelf>.unmodifiable(results);
  }

  Future<void> invalidate(String cacheKey) async {
    final db = await _database.database;
    await db.delete(
      dsRecommendationCache,
      where: 'cache_key = ?',
      whereArgs: <Object?>[cacheKey],
    );
  }

  Future<void> invalidateKind(String kind) async {
    final db = await _database.database;
    await db.delete(
      dsRecommendationCache,
      where: 'kind = ?',
      whereArgs: <Object?>[kind],
    );
  }

  /// Deletes entries whose TTL has passed. Cheap, indexed on `expires_at`,
  /// and called from the same background pass that regenerates the shelves.
  Future<int> evictExpired() async {
    final db = await _database.database;
    final count = await db.delete(
      dsRecommendationCache,
      where: 'expires_at < ?',
      whereArgs: <Object?>[DateTime.now().toUtc().toIso8601String()],
    );
    if (count > 0) _log.i('Evicted $count expired cache entries');
    return count;
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(dsRecommendationCache);
  }

  /// Total cached rows — surfaced in Settings so the user can see the cost.
  Future<int> count() async {
    final db = await _database.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS total FROM $dsRecommendationCache',
    );
    final value = rows.first['total'];
    return value is num ? value.toInt() : 0;
  }
}

// ---------------------------------------------------------------------------
// Shelf codec
// ---------------------------------------------------------------------------

/// Serialises a shelf, including per-track scores and reasons.
String encodeShelf(GeneratedShelf shelf) {
  return jsonEncode(<String, Object?>{
    'id': shelf.id,
    'title': shelf.title,
    'subtitle': shelf.subtitle,
    'generatedAt': shelf.generatedAt?.toUtc().toIso8601String(),
    'expiresAt': shelf.expiresAt?.toUtc().toIso8601String(),
    'seeds': shelf.seedLabels,
    if (shelf.accentSeed != null) 'accent': shelf.accentSeed,
    'items': shelf.items
        .map(
          (entry) => <String, Object?>{
            'track': entry.track.toJson(),
            'score': entry.score,
            'source': entry.source,
            'reasons': entry.breakdown.reasons
                .map((reason) => reason.toJson())
                .toList(growable: false),
          },
        )
        .toList(growable: false),
  });
}

/// Parses a shelf; returns null on a truncated or malformed payload so a
/// corrupt row degrades to "regenerate" instead of crashing the home screen.
GeneratedShelf? decodeShelf(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(value);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final json = Map<String, Object?>.from(decoded);

  final items = <ScoredTrack>[];
  final rawItems = json['items'];
  if (rawItems is List) {
    for (final entry in rawItems) {
      if (entry is! Map) continue;
      final track = DiscoveryTrack.fromJson(entry['track']);
      if (track == null) continue;
      final reasons = <RecommendationReason>[];
      final rawReasons = entry['reasons'];
      if (rawReasons is List) {
        for (final rawReason in rawReasons) {
          final reason = RecommendationReason.fromJson(rawReason);
          if (reason != null) reasons.add(reason);
        }
      }
      final score = entry['score'];
      items.add(
        ScoredTrack(
          track: track,
          score: score is num ? score.toDouble() : 0,
          breakdown: ScoreBreakdown(
            reasons: List<RecommendationReason>.unmodifiable(reasons),
          ),
          source: entry['source']?.toString() ?? 'cache',
        ),
      );
    }
  }

  final id = json['id']?.toString() ?? '';
  if (id.isEmpty) return null;

  final rawSeeds = json['seeds'];
  final seeds = rawSeeds is List
      ? rawSeeds.whereType<Object>().map((e) => e.toString()).toList()
      : const <String>[];

  return GeneratedShelf(
    id: id,
    title: json['title']?.toString() ?? '',
    subtitle: json['subtitle']?.toString() ?? '',
    items: List<ScoredTrack>.unmodifiable(items),
    generatedAt: DateTime.tryParse(json['generatedAt']?.toString() ?? ''),
    expiresAt: DateTime.tryParse(json['expiresAt']?.toString() ?? ''),
    seedLabels: List<String>.unmodifiable(seeds),
    accentSeed: json['accent']?.toString(),
  );
}
