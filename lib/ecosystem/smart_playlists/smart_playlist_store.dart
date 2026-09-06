/// Smart playlist persistence (Feature Group 6).
///
/// Definitions (enabled/order/tuning) live in the ecosystem key-value
/// store; materialization metadata (last refresh, row counts) lives in
/// `ec_smart_playlist_state`. The store never keeps the track lists —
/// they are cheap to rebuild and always fresh by construction.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_kv.dart';
import 'package:spotiflac_android/ecosystem/smart_playlists/smart_playlist_models.dart';

/// Decides when a playlist should re-materialize.
class SmartPlaylistRefreshPolicy {
  const SmartPlaylistRefreshPolicy({
    this.minInterval = const Duration(minutes: 10),
    this.maxInterval = const Duration(hours: 12),
  });

  final Duration minInterval;
  final Duration maxInterval;

  /// True when the cached state is stale enough to justify a rebuild.
  bool shouldRefresh(SmartPlaylistState? state, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final last = state?.lastMaterializedAt;
    if (last == null) return true;
    return at.difference(last) >= minInterval;
  }

  /// True when the cached state is so old the UI should show a "refreshing"
  /// affordance rather than trust counts.
  bool isStale(SmartPlaylistState? state, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final last = state?.lastMaterializedAt;
    if (last == null) return true;
    return at.difference(last) >= maxInterval;
  }
}

class SmartPlaylistStore {
  SmartPlaylistStore({
    required KeyValueStore preferences,
    EcosystemDatabase? database,
  }) : _preferences = preferences,
       _database = database ?? EcosystemDatabase.instance;

  static const String definitionsKey = 'smart_playlists_v1';

  final KeyValueStore _preferences;
  final EcosystemDatabase _database;

  /// Loads persisted definitions; fresh installs get the six built-ins in
  /// display order.
  Future<List<SmartPlaylistDefinition>> definitions() async {
    final raw = await _preferences.read(definitionsKey);
    if (raw == null || raw.isEmpty) {
      return defaultSmartPlaylistDefinitions();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return defaultSmartPlaylistDefinitions();
      final loaded = <SmartPlaylistDefinition>[
        for (final Object? entry in decoded)
          SmartPlaylistDefinition.fromJson(entry),
      ];
      // Preserve the canonical order and pick up new kinds added later.
      final merged = <SmartPlaylistDefinition>[];
      for (final fallback in defaultSmartPlaylistDefinitions()) {
        final match = loaded.firstWhere(
          (definition) => definition.kind == fallback.kind,
          orElse: () => fallback,
        );
        merged.add(match);
      }
      return merged;
    } catch (_) {
      return defaultSmartPlaylistDefinitions();
    }
  }

  Future<void> saveDefinitions(List<SmartPlaylistDefinition> definitions) =>
      _preferences.write(definitionsKey, jsonEncode(definitions));

  Future<Map<String, SmartPlaylistState>> states() async {
    final db = await _database.database;
    final rows = await db.query(tableSmartPlaylistState);
    return <String, SmartPlaylistState>{
      for (final row in rows)
        row['playlist_id']?.toString() ?? '': SmartPlaylistState.fromRow(row),
    };
  }

  Future<void> recordMaterialization(SmartPlaylist playlist) async {
    final db = await _database.database;
    await db.insert(
      tableSmartPlaylistState,
      <String, Object?>{
        'playlist_id': playlist.definition.kind.name,
        'definition_json': jsonEncode(playlist.definition.toJson()),
        'last_materialized_at':
            playlist.materializedAt.toUtc().toIso8601String(),
        'last_track_count': playlist.tracks.length,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearStates() async {
    final db = await _database.database;
    await db.delete(tableSmartPlaylistState);
  }
}

/// The six built-ins (display order).
List<SmartPlaylistDefinition> defaultSmartPlaylistDefinitions() =>
    <SmartPlaylistDefinition>[
      const SmartPlaylistDefinition(
        kind: SmartPlaylistKind.recentlyPlayed,
        daysWindow: 30,
      ),
      const SmartPlaylistDefinition(
        kind: SmartPlaylistKind.mostPlayed,
        minPlayCount: 2,
      ),
      const SmartPlaylistDefinition(kind: SmartPlaylistKind.favorites),
      const SmartPlaylistDefinition(kind: SmartPlaylistKind.recentlyAdded),
      const SmartPlaylistDefinition(
        kind: SmartPlaylistKind.discoverMix,
        limit: 25,
      ),
      const SmartPlaylistDefinition(kind: SmartPlaylistKind.dailyMix, limit: 40),
    ];
