/// Riverpod wiring for the ecosystem modules (Feature Groups 1–5, 12).
///
/// Convention followed from the rest of the app: providers are thin — they
/// compose services and expose immutable state; all logic lives in
/// `lib/ecosystem/**`, which is pure Dart and unit-testable.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/ecosystem/ecosystem.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/provider_accounts_provider.dart'
    show secureStoreProvider;
import 'package:spotiflac_android/providers/sync_provider.dart';

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

/// The ecosystem SQLite store (history, favorite playlists, cache, podcasts…).
final ecosystemDatabaseProvider = Provider<EcosystemDatabase>((ref) {
  return EcosystemDatabase.instance;
});

/// Shared preferences namespace for ecosystem settings.
final ecosystemPreferencesProvider = Provider<KeyValueStore>((ref) {
  return SharedPreferencesStore(SharedPreferences.getInstance());
});

// ---------------------------------------------------------------------------
// Feature Group 1 — accounts
// ---------------------------------------------------------------------------

final accountTokenStoreProvider = Provider<AccountTokenStore>((ref) {
  return AccountTokenStore(ref.watch(secureStoreProvider));
});

/// The app-wide account service. Restores any persisted session on first read.
final accountServiceProvider = Provider<AccountService>((ref) {
  final service = AccountService(
    tokenStore: ref.watch(accountTokenStoreProvider),
    preferences: ref.watch(ecosystemPreferencesProvider),
  );
  ref.onDispose(service.dispose);
  unawaited(service.restoreSession());
  return service;
});

/// Live account state (signed-out / guest / signing-in / signed-in / error).
final accountStateProvider = StreamProvider<AccountState>((ref) {
  return ref.watch(accountServiceProvider).changes;
});

// ---------------------------------------------------------------------------
// Feature Group 2 — synchronization
// ---------------------------------------------------------------------------

/// Background sync scheduler around the existing orchestrator + backend.
final syncEngineProvider = Provider<SyncEngine>((ref) {
  final engine = SyncEngine(
    backend: ref.watch(cloudSyncBackendProvider),
    orchestrator: ref.watch(syncOrchestratorProvider),
  );
  ref.onDispose(engine.dispose);
  return engine;
});

/// Live engine counters (failures, next retry, totals).
final syncEngineStatsProvider = StreamProvider<SyncEngineStats>((ref) {
  return ref.watch(syncEngineProvider).statsStream;
});

// ---------------------------------------------------------------------------
// Feature Group 3 — favorites
// ---------------------------------------------------------------------------

final favoritePlaylistsRepositoryProvider =
    Provider<FavoritePlaylistsRepository>((ref) {
      return FavoritePlaylistsRepository(
        database: ref.watch(ecosystemDatabaseProvider),
      );
    });

/// Favorite playlists (the one favorites kind with its own storage).
final favoritePlaylistsProvider =
    FutureProvider<List<FavoritePlaylistEntry>>((ref) async {
      return ref.watch(favoritePlaylistsRepositoryProvider).all();
    });

/// Unified, pre-indexed view of all four favorites kinds.
///
/// Tracks/albums/artists are projected from the *existing* collections store
/// (no duplicated rows); playlists come from the ecosystem database.
final favoritesIndexProvider = FutureProvider<FavoritesIndex>((ref) async {
  final collections = ref.watch(libraryCollectionsProvider);
  final playlists = await ref.watch(favoritePlaylistsProvider.future);
  final entries = <FavoriteEntry>[
    for (final entry in collections.loved)
      FavoriteEntry(
        key: entry.key,
        kind: FavoriteKind.track,
        title: entry.track.name,
        subtitle: entry.track.artistName,
        coverUrl: entry.track.coverUrl,
        addedAt: entry.addedAt,
        track: entry.track,
        albumId: entry.track.albumId,
        artistId: entry.track.artistId,
      ),
    for (final entry in collections.favoriteAlbums)
      FavoriteEntry(
        key: entry.key,
        kind: FavoriteKind.album,
        title: entry.name,
        subtitle: entry.artistName ?? '',
        coverUrl: entry.imageUrl,
        addedAt: entry.addedAt,
        albumId: entry.albumId,
        artistId: entry.artistId,
      ),
    for (final entry in collections.favoriteArtists)
      FavoriteEntry(
        key: entry.key,
        kind: FavoriteKind.artist,
        title: entry.name,
        subtitle: 'Artist',
        coverUrl: entry.imageUrl,
        addedAt: entry.addedAt,
        artistId: entry.artistId,
      ),
    for (final entry in playlists) entry.toFavoriteEntry(),
  ];
  return const FavoritesCatalog().build(entries);
});

/// Mutable view state for the favorites page.
class FavoritesQuery {
  const FavoritesQuery({
    this.search = '',
    this.kinds = const <FavoriteKind>{},
    this.sort = FavoriteSortOrder.recentlyAdded,
  });

  final String search;
  final Set<FavoriteKind> kinds;
  final FavoriteSortOrder sort;

  FavoritesQuery copyWith({
    String? search,
    Set<FavoriteKind>? kinds,
    FavoriteSortOrder? sort,
  }) {
    return FavoritesQuery(
      search: search ?? this.search,
      kinds: kinds ?? this.kinds,
      sort: sort ?? this.sort,
    );
  }
}

class FavoritesQueryController extends Notifier<FavoritesQuery> {
  @override
  FavoritesQuery build() => const FavoritesQuery();

  void setSearch(String value) => state = state.copyWith(search: value);

  void toggleKind(FavoriteKind kind) {
    final next = <FavoriteKind>{...state.kinds};
    if (!next.add(kind)) next.remove(kind);
    state = state.copyWith(kinds: next);
  }

  void setSort(FavoriteSortOrder sort) => state = state.copyWith(sort: sort);
}

final favoritesQueryProvider =
    NotifierProvider<FavoritesQueryController, FavoritesQuery>(
      FavoritesQueryController.new,
    );

/// Sorted + filtered result for the current query.
final favoritesResultsProvider = Provider<AsyncValue<List<FavoriteEntry>>>((
  ref,
) {
  final query = ref.watch(favoritesQueryProvider);
  final indexAsync = ref.watch(favoritesIndexProvider);
  // trackPlayCountsProvider is a FutureProvider, so unwrap it: while the
  // aggregates are still loading, sort with no counts rather than failing —
  // "Most played" simply settles once the history query resolves.
  final playCounts =
      ref.watch(trackPlayCountsProvider).value ?? const <String, int>{};
  return indexAsync.when(
    data: (index) => AsyncValue<List<FavoriteEntry>>.data(
      const FavoritesCatalog().query(
        index,
        search: query.search,
        kinds: query.kinds,
        sort: query.sort,
        playCounts: playCounts,
      ),
    ),
    loading: () => const AsyncValue<List<FavoriteEntry>>.loading(),
    error: (error, stack) =>
        AsyncValue<List<FavoriteEntry>>.error(error, stack),
  );
});

// ---------------------------------------------------------------------------
// Feature Group 4 — listening history
// ---------------------------------------------------------------------------

final listeningHistoryRepositoryProvider =
    Provider<ListeningHistoryRepository>((ref) {
      return ListeningHistoryRepository(
        database: ref.watch(ecosystemDatabaseProvider),
      );
    });

/// Most recent play events (unique per track).
final recentHistoryProvider = FutureProvider<List<PlayEvent>>((ref) async {
  return ref
      .watch(listeningHistoryRepositoryProvider)
      .recentEvents(limit: 100, uniqueTracks: true);
});

/// All-time most played tracks.
final mostPlayedHistoryProvider = FutureProvider<List<TrackHistory>>((
  ref,
) async {
  return ref.watch(listeningHistoryRepositoryProvider).mostPlayed(limit: 50);
});

/// track key → play count, used for "Most played" sorting in favorites.
final trackPlayCountsProvider = FutureProvider<Map<String, int>>((ref) async {
  final aggregates = await ref
      .watch(listeningHistoryRepositoryProvider)
      .allAggregates();
  return <String, int>{
    for (final entry in aggregates) entry.trackKey: entry.playCount,
  };
});

/// Insights over the last [days] days.
final insightsProvider =
    FutureProvider.family<ListeningInsights, int>((ref, days) async {
      final repository = ref.watch(listeningHistoryRepositoryProvider);
      final now = DateTime.now();
      final events = await repository.eventsBetween(
        now.subtract(Duration(days: days)),
        now,
      );
      return const InsightsCalculator().compute(
        events,
        rangeStart: now.subtract(Duration(days: days)),
        rangeEnd: now,
      );
    });

/// Yearly recap for [year].
final recapProvider = FutureProvider.family<RecapReport, int>((ref, year) async {
  final repository = ref.watch(listeningHistoryRepositoryProvider);
  final now = DateTime.now();
  final events = await repository.eventsBetween(
    DateTime.utc(year),
    DateTime.utc(year + 1),
  );
  return const InsightsCalculator().buildRecap(
    events,
    year: year,
    now: now,
  );
});

// ---------------------------------------------------------------------------
// Feature Group 5 — recommendations
// ---------------------------------------------------------------------------

/// Holds the cloud recommender configuration.
///
/// `StateProvider` was removed in Riverpod 3, so this follows the repository's
/// `NotifierProvider` convention.
class CloudRecommendationConfigNotifier
    extends Notifier<CloudRecommendationConfig> {
  @override
  CloudRecommendationConfig build() =>
      const CloudRecommendationConfig(baseUrl: '');

  void set(CloudRecommendationConfig config) => state = config;
}

/// Cloud recommender configuration (empty ⇒ only on-device providers run).
final cloudRecommendationConfigProvider =
    NotifierProvider<
      CloudRecommendationConfigNotifier,
      CloudRecommendationConfig
    >(CloudRecommendationConfigNotifier.new);

/// Assembles the provider chain: cloud → similarity → daily mix → local.
final recommendationRegistryProvider = Provider<RecommendationRegistry>((ref) {
  final config = ref.watch(cloudRecommendationConfigProvider);
  return RecommendationRegistry(
    cloud: CloudRecommendationProvider(config: config),
  );
});

// ---------------------------------------------------------------------------
// Feature Group 9 — podcasts
// ---------------------------------------------------------------------------

/// Subscriptions + episodes store, with live RSS fetching.
final podcastRepositoryProvider = Provider<PodcastRepository>((ref) {
  return PodcastRepository(database: ref.watch(ecosystemDatabaseProvider));
});

/// Filesystem side of podcasts: downloads, retention, repair.
final podcastLibraryProvider = Provider<PodcastLibrary>((ref) {
  final library = PodcastLibrary(
    repository: ref.watch(podcastRepositoryProvider),
  );
  ref.onDispose(library.dispose);
  return library;
});

/// Directory search (iTunes; no key required).
final podcastSearchProvider = Provider<PodcastSearchProvider>((ref) {
  final provider = ITunesPodcastSearchProvider();
  ref.onDispose(provider.dispose);
  return provider;
});

/// Episode playback through the shared audio_service handler.
final podcastPlayerProvider = Provider<PodcastPlayer>((ref) {
  final player = PodcastPlayer(
    repository: ref.watch(podcastRepositoryProvider),
    store: ref.watch(ecosystemPreferencesProvider),
  );
  unawaited(player.load());
  return player;
});

/// All subscribed feeds, alphabetical.
final podcastSubscriptionsProvider =
    FutureProvider<List<PodcastSubscription>>((ref) async {
      return ref.watch(podcastRepositoryProvider).subscriptions();
    });

/// Newest episodes across every subscription.
final podcastLatestEpisodesProvider =
    FutureProvider<List<PodcastEpisode>>((ref) async {
      return ref.watch(podcastRepositoryProvider).latestEpisodes();
    });

/// Episodes started but not finished — "continue listening".
final podcastInProgressProvider =
    FutureProvider<List<PodcastEpisode>>((ref) async {
      return ref.watch(podcastRepositoryProvider).inProgressEpisodes();
    });

/// Episodes of one feed, newest first.
final podcastEpisodesProvider =
    FutureProvider.family<List<PodcastEpisode>, String>((ref, feedUrl) async {
      return ref.watch(podcastRepositoryProvider).episodes(feedUrl);
    });

// ---------------------------------------------------------------------------
// Feature Group 10 — music recognition
// ---------------------------------------------------------------------------

/// Holds the user-supplied AcoustID key.
///
/// `StateProvider` was removed in Riverpod 3, so this follows the repository's
/// `NotifierProvider` convention.
class AcoustIdApiKeyNotifier extends Notifier<String> {
  @override
  String build() => '';

  /// Stores a new key; whitespace-only input clears it, which switches the
  /// provider back to "unavailable" instead of issuing doomed requests.
  void set(String apiKey) => state = apiKey.trim();
}

/// User-supplied AcoustID key (empty ⇒ recognition reports "unavailable").
final acoustIdApiKeyProvider =
    NotifierProvider<AcoustIdApiKeyNotifier, String>(
      AcoustIdApiKeyNotifier.new,
    );

/// On-device Chromaprint fingerprinting via the bundled FFmpeg.
final fingerprintEngineProvider = Provider<FingerprintEngine>((ref) {
  return const ChromaprintFingerprintEngine();
});

/// Recognition backends, in priority order.
final recognitionProvidersProvider =
    Provider<List<RecognitionProvider>>((ref) {
      final apiKey = ref.watch(acoustIdApiKeyProvider);
      final provider = AcoustIdRecognitionProvider(apiKey: apiKey);
      ref.onDispose(provider.dispose);
      return <RecognitionProvider>[provider];
    });

/// Past identifications.
final recognitionHistoryRepositoryProvider =
    Provider<RecognitionHistoryRepository>((ref) {
      return RecognitionHistoryRepository(
        database: ref.watch(ecosystemDatabaseProvider),
      );
    });

/// Recent recognition hits, newest first.
final recognitionHistoryProvider =
    FutureProvider<List<RecognitionResult>>((ref) async {
      return ref.watch(recognitionHistoryRepositoryProvider).recent();
    });

// ---------------------------------------------------------------------------
// Feature Group 11 — optional social layer
// ---------------------------------------------------------------------------

/// Social flag storage. Everything is off until the user opts in.
final socialSettingsProvider = Provider<SocialSettings>((ref) {
  return SocialSettings(ref.watch(ecosystemPreferencesProvider));
});

/// Current social flags; defaults to fully disabled.
final socialFlagsProvider = FutureProvider<SocialFeatureFlags>((ref) async {
  return ref.watch(socialSettingsProvider).read();
});

/// Backend for the social layer. Null until a provider is configured, which
/// keeps the module local-only by default.
final socialBackendProvider = Provider<SocialBackend?>((ref) => null);

final socialCacheProvider = Provider<SocialCache>((ref) {
  return SocialCache(database: ref.watch(ecosystemDatabaseProvider));
});

final profileSystemProvider = Provider<ProfileSystem>((ref) {
  return ProfileSystem(
    settings: ref.watch(socialSettingsProvider),
    backend: ref.watch(socialBackendProvider),
    cache: ref.watch(socialCacheProvider),
  );
});

final playlistSharingProvider = Provider<PlaylistSharing>((ref) {
  return PlaylistSharing(
    settings: ref.watch(socialSettingsProvider),
    backend: ref.watch(socialBackendProvider),
    cache: ref.watch(socialCacheProvider),
  );
});

final followSystemProvider = Provider<FollowSystem>((ref) {
  return FollowSystem(
    settings: ref.watch(socialSettingsProvider),
    backend: ref.watch(socialBackendProvider),
  );
});

final activityFeedProvider = Provider<ActivityFeed>((ref) {
  return ActivityFeed(
    settings: ref.watch(socialSettingsProvider),
    backend: ref.watch(socialBackendProvider),
    cache: ref.watch(socialCacheProvider),
  );
});
