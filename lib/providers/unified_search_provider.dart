/// Unified search wiring (Feature Group: search).
///
/// Binds real sources into `engine/unified_search.dart`:
///   * local library + downloads — the *existing* library search
///     (`AppMediaBrowseSource.searchMedia`, the same SQLite full-text path
///     the queue and voice search use);
///   * extension providers — the exact backend-search entry point the Home
///     search uses (`PlatformBridge.searchTracksWithMetadataProviders`);
///   * self-hosted servers (Feature 5);
///   * podcasts (iTunes directory search);
///   * stream cache hits (instant offline starts).
///
/// The Home search surface keeps its extension-first flow unchanged; this
/// engine is the "Search everywhere" aggregation exposed from the
/// Ecosystem hub and available to any surface that wants cross-source
/// results.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotimusic/engine/unified_search.dart';
import 'package:spotimusic/ecosystem/cache/cache_models.dart';
import 'package:spotimusic/ecosystem/servers/music_server_models.dart';
import 'package:spotimusic/models/track.dart';
import 'package:spotimusic/providers/ecosystem_providers.dart';
import 'package:spotimusic/providers/media_browse_provider.dart';
import 'package:spotimusic/providers/music_servers_providers.dart';
import 'package:spotimusic/providers/streaming_cache_providers.dart';
import 'package:spotimusic/services/music_player_service.dart';
import 'package:spotimusic/services/platform_bridge.dart';
import 'package:spotimusic/utils/fuzzy_match.dart';

final unifiedSearchEngineProvider = Provider<UnifiedSearchEngine>((ref) {
  return UnifiedSearchEngine(
    sources: <UnifiedSearchSource>[
      UnifiedSearchSource(
        id: 'on_device',
        kind: UnifiedSearchSourceKind.localLibrary,
        search: (query) => _searchOnDevice(ref, query),
      ),
      UnifiedSearchSource(
        id: 'extensions',
        kind: UnifiedSearchSourceKind.extension,
        search: (query) => _searchExtensions(query),
      ),
      UnifiedSearchSource(
        id: 'servers',
        kind: UnifiedSearchSourceKind.server,
        search: (query) => _searchServers(ref, query),
      ),
      UnifiedSearchSource(
        id: 'podcasts',
        kind: UnifiedSearchSourceKind.podcast,
        search: (query) => _searchPodcasts(ref, query),
      ),
      UnifiedSearchSource(
        id: 'cache',
        kind: UnifiedSearchSourceKind.downloads,
        search: (query) => _searchCache(ref, query),
      ),
    ],
  );
});

final unifiedSearchQueryProvider =
    NotifierProvider<UnifiedSearchQueryController, String>(
      UnifiedSearchQueryController.new,
    );

class UnifiedSearchQueryController extends Notifier<String> {
  @override
  String build() => '';

  void set(String value) => state = value;
}

final unifiedSearchResultsProvider =
    FutureProvider<UnifiedSearchOutcome>((ref) async {
      final query = ref.watch(unifiedSearchQueryProvider);
      if (query.trim().isEmpty) {
        return const UnifiedSearchOutcome(
          results: <UnifiedSearchResult>[],
          respondedSourceIds: <String>{},
          failedSourceIds: <String>{},
        );
      }
      final engine = ref.watch(unifiedSearchEngineProvider);
      // Re-run when the server list changes (add/remove/edit).
      ref.watch(musicServersProvider);
      return engine.search(query);
    });

// ---------------------------------------------------------------------------
// Source implementations
// ---------------------------------------------------------------------------

Future<List<UnifiedSearchItem>> _searchOnDevice(Ref ref, String query) async {
  final tree = ref.read(mediaBrowseTreeProvider);
  final media = await tree.source.searchMedia(query, limit: 20);
  final ranked = fuzzyRank<PlayableMedia>(
    query,
    media,
    textOf: (item) => item.title,
    secondaryTextOf: (item) => item.artist,
    limit: 20,
  );
  return <UnifiedSearchItem>[
    for (final hit in ranked)
      UnifiedSearchItem(
        kind: UnifiedSearchSourceKind.localLibrary,
        sourceId: 'on_device',
        title: hit.item.title,
        subtitle: hit.item.artist,
        imageUrl: hit.item.artUri,
        track: Track(
          id: hit.item.id,
          name: hit.item.title,
          artistName: hit.item.artist,
          albumName: hit.item.album,
          coverUrl: hit.item.artUri,
          duration: hit.item.duration == null
              ? 0
              : hit.item.duration!.inSeconds,
          source: 'local',
        ),
        sourceScore: hit.score,
        playableLocally: true,
      ),
  ];
}

Future<List<UnifiedSearchItem>> _searchExtensions(String query) async {
  try {
    final raw = await PlatformBridge.searchTracksWithMetadataProviders(
      query,
      limit: 20,
    );
    final tracks = <Track>[
      for (final Map<String, dynamic> entry in raw) Track.fromBackendMap(entry),
    ];
    return <UnifiedSearchItem>[
      for (var i = 0; i < tracks.length; i++)
        UnifiedSearchItem(
          kind: UnifiedSearchSourceKind.extension,
          sourceId: 'extensions',
          title: tracks[i].name,
          subtitle: tracks[i].artistName,
          imageUrl: tracks[i].coverUrl,
          track: tracks[i],
          sourceScore: tracks.isEmpty
              ? 0.5
              : 1.0 - (i / tracks.length) * 0.5,
        ),
    ];
  } catch (_) {
    return const <UnifiedSearchItem>[];
  }
}

Future<List<UnifiedSearchItem>> _searchServers(
  Ref ref,
  String query,
) async {
  final registry = ref.read(musicServerRegistryProvider);
  final results = <UnifiedSearchItem>[];
  final futures = <Future<void>>[
    for (final provider in registry.enabledProviders)
      () async {
        try {
          final found = await provider.search(query, limit: 15);
          for (var i = 0; i < found.length; i++) {
            results.add(
              UnifiedSearchItem(
                kind: UnifiedSearchSourceKind.server,
                sourceId: provider.id,
                title: found[i].title,
                subtitle: found[i].artist,
                imageUrl: found[i].coverUrl,
                track: found[i].toTrack(provider.config),
                sourceScore: found.isEmpty
                    ? 0.5
                    : 1.0 - (i / found.length) * 0.5,
              ),
            );
          }
        } on MusicServerException {
          // Offline server: contributes nothing to this run.
        }
      }(),
  ];
  await Future.wait(futures);
  return results;
}

Future<List<UnifiedSearchItem>> _searchPodcasts(
  Ref ref,
  String query,
) async {
  final search = ref.read(podcastSearchProvider);
  try {
    final results = await search.search(query, limit: 10);
    return <UnifiedSearchItem>[
      for (var i = 0; i < results.length; i++)
        UnifiedSearchItem(
          kind: UnifiedSearchSourceKind.podcast,
          sourceId: 'podcasts',
          title: results[i].title,
          subtitle: results[i].author,
          imageUrl: results[i].imageUrl,
          sourceScore: results.isEmpty
              ? 0.5
              : 1.0 - (i / results.length) * 0.5,
        ),
    ];
  } catch (_) {
    return const <UnifiedSearchItem>[];
  }
}

Future<List<UnifiedSearchItem>> _searchCache(Ref ref, String query) async {
  final manager = ref.read(streamingCacheManagerProvider);
  final playable = <CacheEntry>[
    for (final entry in manager.index.all)
      if (entry.isPlayable) entry,
  ];
  final ranked = fuzzyRank<CacheEntry>(
    query,
    playable,
    textOf: (entry) => entry.title,
    secondaryTextOf: (entry) => entry.artist,
    limit: 15,
  );
  return <UnifiedSearchItem>[
    for (final hit in ranked)
      UnifiedSearchItem(
        kind: UnifiedSearchSourceKind.downloads,
        sourceId: 'cache',
        title: hit.item.title,
        subtitle: hit.item.artist,
        track: Track(
          id: hit.item.trackKey,
          name: hit.item.title,
          artistName: hit.item.artist,
          albumName: '',
          duration: hit.item.durationMs ~/ 1000,
          source: 'cache',
        ),
        sourceScore: hit.score,
        playableLocally: true,
      ),
  ];
}
