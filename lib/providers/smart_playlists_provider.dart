/// Riverpod wiring for smart playlists (Feature Group 6).
///
/// Materializes the six built-ins on demand from the same stores the
/// history/favorites/analytics pages read, persists definition overrides +
/// freshness metadata, and exposes an auto-refresh policy so playlists
/// rebuild quietly after listening activity (never blocking playback).
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotimusic/ecosystem/ecosystem.dart';
import 'package:spotimusic/providers/ecosystem_providers.dart';
import 'package:spotimusic/models/track.dart';
import 'package:spotimusic/providers/library_collections_provider.dart';
import 'package:spotimusic/providers/playback_statistics_provider.dart';
import 'package:spotimusic/providers/recommendation_provider.dart';
import 'package:spotimusic/services/library_database.dart';

final smartPlaylistStoreProvider = Provider<SmartPlaylistStore>((ref) {
  return SmartPlaylistStore(
    preferences: ref.watch(ecosystemPreferencesProvider),
    database: ref.watch(ecosystemDatabaseProvider),
  );
});

/// Definition list (persisted overrides applied over the six built-ins).
final smartPlaylistDefinitionsProvider =
    FutureProvider<List<SmartPlaylistDefinition>>((ref) {
      return ref.watch(smartPlaylistStoreProvider).definitions();
    });

/// Assembles the engine input from on-device stores.
Future<SmartPlaylistInput> buildSmartPlaylistInput(Ref ref) async {
  final repository = ref.read(listeningHistoryRepositoryProvider);
  final history = await repository.allAggregates();
  final collections = ref.read(libraryCollectionsProvider);
  final favoritesIndex = await ref.read(favoritesIndexProvider.future);
  final stats = ref.read(playbackStatisticsProvider);
  final service = ref.read(recommendationServiceProvider);
  final profile = buildRecommendationProfile(
    stats: stats,
    collections: collections,
  );
  final recommendations = await service.recommend(
    profile,
    maxItemsPerSection: 25,
  );

  // Library recents: newest scanned local rows.
  final recent = await LibraryDatabase.instance.getQueueTrackPage(
    // 'newest' → the query builder's default ordering (added, descending).
    QueueLibraryDbQuery(limit: 200, sortMode: 'newest'),
  );
  final library = <SmartLibraryEntry?>[
    for (final row in recent)
      () {
        final source = row['source']?.toString() ?? '';
        final item = row['item'];
        if (source == 'local' && item is Map<String, dynamic>) {
          final local = LocalLibraryItem.fromJson(item);
          return SmartLibraryEntry(
            track: Track(
              id: local.id,
              name: local.trackName,
              artistName: local.artistName,
              albumName: local.albumName,
              coverUrl: local.coverPath,
              isrc: local.isrc,
              duration: local.duration ?? 0,
              source: 'local',
            ),
            scannedAt: local.scannedAt,
          );
        }
        return null;
      }(),
  ].whereType<SmartLibraryEntry>().toList(growable: false);

  return SmartPlaylistInput(
    history: history,
    library: library,
    favorites: favoritesIndex.entries,
    recommendations: recommendations,
    dailySeed: recommendationDailySeed(),
  );
}

/// All materialized playlists (auto-refreshed when stale).
final smartPlaylistsProvider =
    FutureProvider<List<SmartPlaylist>>((ref) async {
      final store = ref.watch(smartPlaylistStoreProvider);
      final definitions = await ref.watch(smartPlaylistDefinitionsProvider.future);
      final input = await buildSmartPlaylistInput(ref);
      final engine = const SmartPlaylistEngine();
      final states = await store.states();
      const policy = SmartPlaylistRefreshPolicy();
      final results = <SmartPlaylist>[];
      for (final definition in definitions) {
        if (!definition.enabled) continue;
        final playlist = engine.generate(definition, input);
        results.add(playlist);
        if (policy.shouldRefresh(states[definition.kind.name])) {
          await store.recordMaterialization(playlist);
        }
      }
      return results;
    });

/// One playlist by kind (detail screens).
final smartPlaylistProvider = FutureProvider.family<SmartPlaylist?,
    SmartPlaylistKind>((ref, kind) async {
  final playlists = await ref.watch(smartPlaylistsProvider.future);
  for (final playlist in playlists) {
    if (playlist.definition.kind == kind) return playlist;
  }
  return null;
});

/// Enables/disables one definition (settings surface).
Future<void> setSmartPlaylistEnabled(
  Ref ref,
  SmartPlaylistKind kind,
  bool enabled,
) async {
  final store = ref.read(smartPlaylistStoreProvider);
  final definitions = await store.definitions();
  await store.saveDefinitions(
    <SmartPlaylistDefinition>[
      for (final definition in definitions)
        definition.kind == kind
            ? definition.copyWith(enabled: enabled)
            : definition,
    ],
  );
  ref.invalidate(smartPlaylistDefinitionsProvider);
  ref.invalidate(smartPlaylistsProvider);
}
