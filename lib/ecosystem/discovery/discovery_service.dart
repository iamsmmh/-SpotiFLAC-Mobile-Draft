/// The discovery orchestrator: one entry point that turns on-device data into
/// the personalised home (Phases 1–10, wired together).
///
/// Responsibilities, in order:
///
///   1. roll up new listening events into day buckets (incremental, watermarked);
///   2. rebuild the listening profile when it is stale;
///   3. build the candidate pool + similarity map **once** and share it;
///   4. regenerate only the shelves whose refresh key has turned over
///      (week / day / TTL) and serve the rest from their stores;
///   5. return one immutable [DiscoveryHome] for the UI to render.
///
/// Performance contract (Phase 12), and how each line is met:
///
///   * *home < 500 ms* — a warm `home()` is SQLite reads plus list assembly.
///     Generation only happens when a refresh key turns over, and the UI reads
///     the previous result while that runs.
///   * *generation < 1 s* — candidate windows are capped before the scorer runs
///     (`candidateCap`), similarity is computed once per refresh, and every
///     pass records its wall-clock cost in `computeMs` so the budget is
///     observable in logs rather than assumed.
///   * *background only* — [refresh] is fire-and-forget from the provider
///     layer; it coalesces concurrent calls onto one in-flight future and is
///     rate-limited by [minRefreshInterval], so scrolling or rapid tab switches
///     cannot trigger a storm of passes.
library;

import 'dart:async';

import 'package:spotiflac_android/ecosystem/discovery/continue_listening_repository.dart';
import 'package:spotiflac_android/ecosystem/discovery/playlist_generators.dart';
import 'package:spotiflac_android/ecosystem/discovery/radio_service.dart';
import 'package:spotiflac_android/ecosystem/discovery/recommendation_cache.dart';
import 'package:spotiflac_android/ecosystem/discovery/recommendation_engine.dart';
import 'package:spotiflac_android/ecosystem/discovery/recommendation_repository.dart';
import 'package:spotiflac_android/ecosystem/discovery/shelf_stores.dart';
import 'package:spotiflac_android/ecosystem/discovery/trending_repository.dart';
import 'package:spotiflac_android/ecosystem/discovery/user_profile_engine.dart';
import 'package:spotiflac_android/ecosystem/history/listening_history.dart';
import 'package:spotiflac_android/ecosystem/discovery/listening_statistics_repository.dart';
import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/mood_engine.dart';
import 'package:spotiflac_android/engine/discovery/similarity_engine.dart';
import 'package:spotiflac_android/engine/discovery/trending_engine.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('Discovery');

// ---------------------------------------------------------------------------
// Home payload
// ---------------------------------------------------------------------------

/// Everything the discovery home renders, in one immutable value.
class DiscoveryHome {
  const DiscoveryHome({
    this.continueListening,
    this.recentlyPlayed = const <ScoredTrack>[],
    this.dailyMixes = const <GeneratedShelf>[],
    this.discoverWeekly,
    this.newReleases = const <ScoredTrack>[],
    this.recommendedForYou = const <ScoredTrack>[],
    this.trendingWeek = const <TrendingEntry>[],
    this.trendingMonth = const <TrendingEntry>[],
    this.fastestGrowing = const <TrendingEntry>[],
    this.emergingArtists = const <TrendingEntry>[],
    this.topArtists = const <TasteEntry>[],
    this.topAlbums = const <TasteEntry>[],
    this.topGenres = const <TasteEntry>[],
    this.radioStations = const <RadioStationSummary>[],
    this.moods = const <Mood, GeneratedShelf>{},
    this.similarArtists = const <ArtistSimilarity>[],
    this.habits = const ListeningHabits(),
    this.generatedAt,
    this.computeMs = 0,
    this.isColdStart = true,
    this.profileTrackCount = 0,
  });

  static const DiscoveryHome empty = DiscoveryHome();

  final ContinueListeningEntry? continueListening;
  final List<ScoredTrack> recentlyPlayed;
  final List<GeneratedShelf> dailyMixes;
  final GeneratedShelf? discoverWeekly;
  final List<ScoredTrack> newReleases;
  final List<ScoredTrack> recommendedForYou;

  final List<TrendingEntry> trendingWeek;
  final List<TrendingEntry> trendingMonth;
  final List<TrendingEntry> fastestGrowing;
  final List<TrendingEntry> emergingArtists;

  final List<TasteEntry> topArtists;
  final List<TasteEntry> topAlbums;
  final List<TasteEntry> topGenres;

  final List<RadioStationSummary> radioStations;
  final Map<Mood, GeneratedShelf> moods;

  /// Similar to the user's strongest artist — the home-screen teaser for the
  /// full Similar Artists section.
  final List<ArtistSimilarity> similarArtists;

  final ListeningHabits habits;
  final DateTime? generatedAt;

  /// Wall-clock cost of the pass that produced this payload.
  final int computeMs;

  /// True when the user has no listening history yet: the UI shows the
  /// onboarding state instead of empty shelves.
  final bool isColdStart;

  final int profileTrackCount;

  bool get hasAnyContent =>
      !isColdStart ||
      continueListening != null ||
      recentlyPlayed.isNotEmpty ||
      radioStations.isNotEmpty;
}

// ---------------------------------------------------------------------------
// Service
// ---------------------------------------------------------------------------

/// Owns the discovery pipeline.
class DiscoveryService {
  DiscoveryService({
    required this.inputProvider,
    required this.poolSource,
    ListeningStatisticsRepository? statistics,
    UserProfileRepository? profiles,
    UserProfileEngine? profileEngine,
    RecommendationRepository? repository,
    RecommendationCache? cache,
    DiscoverWeeklyStore? weeklyStore,
    DailyMixStore? mixStore,
    MoodPlaylistStore? moodStore,
    TrendingRepository? trending,
    SimilarityStore? similarityStore,
    ContinueListeningRepository? continueListening,
    RadioService? radio,
    RecommendationEngine? engine,
    DiscoverWeeklyGenerator? weeklyGenerator,
    DailyMixGenerator? mixGenerator,
    MoodPlaylistGenerator? moodGenerator,
    TrendingEngine? trendingEngine,
    ListeningHistoryRepository? history,
    this.minRefreshInterval = const Duration(minutes: 10),
    this.profileRefreshInterval = const Duration(hours: 6),
    this.coListenRefreshInterval = const Duration(hours: 12),
  }) : _statistics = statistics ?? ListeningStatisticsRepository(),
       _profiles = profiles ?? UserProfileRepository(),
       _profileEngine = profileEngine ?? const UserProfileEngine(),
       _repository = repository ?? RecommendationRepository(),
       _cache = cache ?? RecommendationCache(),
       _weeklyStore = weeklyStore ?? DiscoverWeeklyStore(),
       _mixStore = mixStore ?? DailyMixStore(),
       _moodStore = moodStore ?? MoodPlaylistStore(),
       _trending = trending ?? TrendingRepository(),
       _similarityStore = similarityStore ?? SimilarityStore(),
       _continueListening =
           continueListening ?? ContinueListeningRepository(),
       _radio = radio ?? RadioService(poolSource: poolSource),
       _engine = engine ?? const RecommendationEngine(),
       _weeklyGenerator = weeklyGenerator ?? const DiscoverWeeklyGenerator(),
       _mixGenerator = mixGenerator ?? const DailyMixGenerator(),
       _moodGenerator = moodGenerator ?? const MoodPlaylistGenerator(),
       _trendingEngine = trendingEngine ?? const TrendingEngine(),
       _history = history ?? ListeningHistoryRepository();

  /// Supplies favorites/playlists from the collections store. Called once per
  /// pool build; the provider layer implements it with a `ref.read`.
  final Future<DiscoveryLibraryInput> Function() inputProvider;

  /// Lets the radio share this service's pool instead of building its own.
  final RadioPoolSource poolSource;

  final ListeningStatisticsRepository _statistics;
  final UserProfileRepository _profiles;
  final UserProfileEngine _profileEngine;
  final RecommendationRepository _repository;
  final RecommendationCache _cache;
  final DiscoverWeeklyStore _weeklyStore;
  final DailyMixStore _mixStore;
  final MoodPlaylistStore _moodStore;
  final TrendingRepository _trending;
  final SimilarityStore _similarityStore;
  final ContinueListeningRepository _continueListening;
  final RadioService _radio;
  final RecommendationEngine _engine;
  final DiscoverWeeklyGenerator _weeklyGenerator;
  final DailyMixGenerator _mixGenerator;
  final MoodPlaylistGenerator _moodGenerator;
  final TrendingEngine _trendingEngine;
  final ListeningHistoryRepository _history;

  final Duration minRefreshInterval;
  final Duration profileRefreshInterval;
  final Duration coListenRefreshInterval;

  Future<DiscoveryHome>? _inFlight;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  DiscoveryHome _last = DiscoveryHome.empty;

  /// Shared per-refresh scratch, rebuilt by [_refresh].
  DiscoveryCandidatePool? _pool;
  ListeningProfile? _profile;
  Map<String, Set<String>> _coListen = const <String, Set<String>>{};
  DateTime _coListenBuiltAt = DateTime.fromMillisecondsSinceEpoch(0);
  Map<String, List<ArtistSimilarity>> _similarityMap =
      const <String, List<ArtistSimilarity>>{};

  /// The most recent payload, whatever its age. The UI renders this first and
  /// swaps in the fresh one when the background pass lands.
  DiscoveryHome get last => _last;

  bool get isRefreshing => _inFlight != null;

  RadioService get radio => _radio;
  ContinueListeningRepository get continueListening => _continueListening;
  RecommendationCache get cache => _cache;
  SimilarityStore get similarityStore => _similarityStore;

  /// Reads the home payload, refreshing in the background when allowed.
  ///
  /// [force] bypasses the rate limit (pull-to-refresh).
  Future<DiscoveryHome> home({bool force = false}) async {
    final existing = _inFlight;
    if (existing != null) return existing;
    if (!force &&
        DateTime.now().difference(_lastRefresh) < minRefreshInterval &&
        _last.generatedAt != null) {
      return _last;
    }
    final future = _refresh(force: force).whenComplete(() {
      _inFlight = null;
    });
    _inFlight = future;
    return future;
  }

  /// Fire-and-forget refresh for app resume / post-playback hooks.
  void scheduleRefresh() {
    if (_inFlight != null) return;
    if (DateTime.now().difference(_lastRefresh) < minRefreshInterval) return;
    unawaited(home());
  }

  // -------------------------------------------------------------------------
  // The pass
  // -------------------------------------------------------------------------

  Future<DiscoveryHome> _refresh({required bool force}) async {
    final stopwatch = Stopwatch()..start();
    final now = DateTime.now();
    try {
      // 1. Fold new events into the day buckets. Incremental + watermarked.
      final rolled = await _statistics.rollUp();
      if (rolled > 0) _log.i('Rolled up $rolled events');

      // 2. Profile: rebuild when stale or when the roll-up changed anything.
      final profile = await _ensureProfile(now: now, dirty: rolled > 0);

      // 3. Candidate pool + shared indexes.
      final input = await inputProvider();
      final pool = await _repository.loadPool(input: input);
      _pool = pool;

      // 4. Co-listen graph (expensive: cached across passes).
      if (force ||
          _coListen.isEmpty ||
          now.difference(_coListenBuiltAt) > coListenRefreshInterval) {
        _coListen = await _repository.coListenGraph();
        _coListenBuiltAt = now;
      }

      final vectors = _repository.artistVectors(
        pool,
        artistAffinity: profile.artistAffinity,
      );
      final context = RecommendationContext(
        pool: pool,
        profile: profile,
        now: now,
        artistVectors: vectors,
        coListenGraph: _coListen,
      );

      // 5. Similarity map — computed once, shared by every shelf.
      _similarityMap = context.isCold
          ? const <String, List<ArtistSimilarity>>{}
          : _engine.artistSimilarityMap(context);

      // 6. Shelves. Each one decides for itself whether it must regenerate.
      final weekly = await _discoverWeekly(context, force: force);
      final mixes = await _dailyMixes(context, force: force);
      final moods = await _moodShelves(context, force: force);
      final trending = await _trendingShelves(context, force: force);
      final recommended = _engine.recommendForYou(
        context,
        limit: 30,
        similarityMap: _similarityMap,
      );
      final releases = _engine.newReleases(context, limit: 20);
      final recently = _engine.recentlyPlayed(context, limit: 20);

      final stations = await _radio.stations(limit: 8);
      final resume = await _continueListening.primary();

      final strongest = profile.artists.isEmpty
          ? ''
          : profile.artists.first.key;
      final similar = strongest.isEmpty
          ? const <ArtistSimilarity>[]
          : _similarityMap[strongest] ?? const <ArtistSimilarity>[];

      final home = DiscoveryHome(
        continueListening: resume,
        recentlyPlayed: recently,
        dailyMixes: mixes,
        discoverWeekly: weekly,
        newReleases: releases.items,
        recommendedForYou: recommended.items,
        trendingWeek: trending[TrendingPeriod.week] ?? const <TrendingEntry>[],
        trendingMonth:
            trending[TrendingPeriod.month] ?? const <TrendingEntry>[],
        fastestGrowing:
            trending[TrendingPeriod.velocity] ?? const <TrendingEntry>[],
        emergingArtists:
            trending[TrendingPeriod.emerging] ?? const <TrendingEntry>[],
        topArtists: profile.artists.take(12).toList(growable: false),
        topAlbums: profile.albums.take(12).toList(growable: false),
        topGenres: profile.genres.take(12).toList(growable: false),
        radioStations: stations,
        moods: moods,
        similarArtists: similar.take(10).toList(growable: false),
        habits: profile.habits,
        generatedAt: now,
        computeMs: stopwatch.elapsedMilliseconds,
        isColdStart: profile.isCold && pool.isEmpty,
        profileTrackCount: profile.tracks.length,
      );

      _last = home;
      _lastRefresh = now;

      // 7. Housekeeping: bounded growth. Runs after the payload is built so a
      // slow delete can never delay the UI.
      unawaited(_housekeep(now));

      _log.i(
        'Discovery refresh in ${home.computeMs} ms — '
        '${pool.tracks.length} candidates, '
        '${recommended.computeMs} ms scoring ${recommended.candidateCount}',
      );
      return home;
    } catch (error, stack) {
      // Fail-open: a discovery failure must never take the app down. The last
      // good payload stays on screen and the error is logged for diagnosis.
      _log.e('Discovery refresh failed', error, stack);
      _lastRefresh = now;
      return _last.generatedAt == null
          ? DiscoveryHome(generatedAt: now, computeMs: stopwatch.elapsedMilliseconds)
          : _last;
    }
  }

  // -------------------------------------------------------------------------
  // Profile
  // -------------------------------------------------------------------------

  Future<ListeningProfile> _ensureProfile({
    required DateTime now,
    required bool dirty,
  }) async {
    final cached = await _profiles.load();
    final fresh =
        cached != null &&
        cached.generatedAt != null &&
        now.difference(cached.generatedAt!) < profileRefreshInterval;
    if (cached != null && fresh && !dirty) return cached;

    final pool = _pool ??
        await _repository.loadPool(input: await inputProvider());
    final habitsAggregate = await _statistics.habits();
    final input = await inputProvider();

    final built = _profileEngine.build(
      signals: pool.signals.values,
      metadata: pool.byKey,
      habits: habitsAggregate.habits,
      now: now,
      favoriteTrackKeys: input.favoriteTrackKeys,
      favoriteArtistKeys: input.favoriteArtistKeys,
      favoriteAlbumKeys: input.favoriteAlbumKeys,
    );
    await _profiles.save(built);
    _profile = built;
    return built;
  }

  // -------------------------------------------------------------------------
  // Shelves
  // -------------------------------------------------------------------------

  Future<GeneratedShelf?> _discoverWeekly(
    RecommendationContext context, {
    required bool force,
  }) async {
    final weekKey = _weeklyGenerator.weekKey(context.now);
    if (!force) {
      final stored = await _weeklyStore.read(weekKey);
      if (stored != null && !stored.shelf.isEmpty) return stored.shelf;
    }
    if (context.isCold) {
      final stored = await _weeklyStore.read(weekKey);
      return stored?.shelf;
    }
    final shelf = _weeklyGenerator.generate(
      context,
      similarityMap: _similarityMap,
    );
    if (shelf.isEmpty) return null;

    final gems = shelf.items
        .where(
          (entry) =>
              (context.pool.signals[entry.track.key]?.playCount ?? 0) <= 2,
        )
        .length;
    final cutoff = context.now.subtract(const Duration(days: 90));
    final fresh = shelf.items
        .where((entry) {
          final released = entry.track.releaseDate;
          return released != null && released.isAfter(cutoff);
        })
        .length;

    await _weeklyStore.save(
      StoredDiscoverWeekly(
        weekKey: weekKey,
        shelf: shelf,
        generatedAt: context.now,
        hiddenGemCount: gems,
        newReleaseCount: fresh,
      ),
    );
    return shelf;
  }

  Future<List<GeneratedShelf>> _dailyMixes(
    RecommendationContext context, {
    required bool force,
  }) async {
    final day = dayKey(context.now);
    if (!force) {
      final stored = await _mixStore.read(day);
      if (stored.isNotEmpty) {
        return stored.map((mix) => mix.shelf).toList(growable: false);
      }
    }
    if (context.isCold || context.pool.isEmpty) {
      final stored = await _mixStore.read(day);
      return stored.map((mix) => mix.shelf).toList(growable: false);
    }
    final generated = _mixGenerator.generate(context);
    if (generated.isEmpty) return const <GeneratedShelf>[];

    await _mixStore.saveAll(<StoredDailyMix>[
      for (final shelf in generated)
        StoredDailyMix(
          mixId: shelf.id,
          dayKey: day,
          position: generated.indexOf(shelf),
          shelf: shelf,
          generatedAt: context.now,
          clusterGenres: shelf.seedLabels,
        ),
    ]);
    return generated;
  }

  Future<Map<Mood, GeneratedShelf>> _moodShelves(
    RecommendationContext context, {
    required bool force,
  }) async {
    if (!force) {
      final stored = await _moodStore.readAll();
      // A complete set, or any set at all for a cold profile, is served as
      // is; a partial set falls through and gets regenerated in full.
      if (stored.length == allMoods.length) return stored;
      if (context.isCold && stored.isNotEmpty) return stored;
    }
    if (context.pool.isEmpty) return _moodStore.readAll();

    final generated = _moodGenerator.generate(context);
    for (final entry in generated.entries) {
      if (entry.value.isEmpty) continue;
      await _moodStore.save(entry.key, entry.value);
    }
    return _moodStore.readAll();
  }

  Future<Map<TrendingPeriod, List<TrendingEntry>>> _trendingShelves(
    RecommendationContext context, {
    required bool force,
  }) async {
    final signals = context.pool.signals.values.toList();
    final result = <TrendingPeriod, List<TrendingEntry>>{};
    if (signals.isEmpty) {
      for (final period in TrendingPeriod.values) {
        result[period] = (await _trending.read(period)).entries;
      }
      return result;
    }

    final shelves = <TrendingShelf>[
      TrendingShelf(
        period: TrendingPeriod.week,
        entries: _trendingEngine.topOfWeek(signals, now: context.now),
        computedAt: context.now,
      ),
      TrendingShelf(
        period: TrendingPeriod.month,
        entries: _trendingEngine.topOfMonth(signals, now: context.now),
        computedAt: context.now,
      ),
      TrendingShelf(
        period: TrendingPeriod.velocity,
        entries: _trendingEngine.fastestGrowing(signals, now: context.now),
        computedAt: context.now,
      ),
      TrendingShelf(
        period: TrendingPeriod.emerging,
        entries: _trendingEngine.emergingArtists(
          await _statistics.artistSignals(),
          now: context.now,
        ),
        computedAt: context.now,
      ),
    ];

    for (final shelf in shelves) {
      if (shelf.isEmpty) {
        result[shelf.period] = (await _trending.read(shelf.period)).entries;
        continue;
      }
      await _trending.save(shelf);
      result[shelf.period] = shelf.entries;
    }
    return result;
  }

  // -------------------------------------------------------------------------
  // Housekeeping
  // -------------------------------------------------------------------------

  Future<void> _housekeep(DateTime now) async {
    try {
      await _cache.evictExpired();
      await _weeklyStore.pruneOlderThan();
      await _mixStore.pruneOlderThan(dayKey(now));
      await _radio.pruneClosedSessions();
    } catch (error) {
      // Housekeeping is best-effort; never propagate.
      _log.w('Discovery housekeeping skipped: $error');
    }
  }

  // -------------------------------------------------------------------------
  // Similar Artists (Phase 6 surface)
  // -------------------------------------------------------------------------

  /// Similar artists for the artist screen, persisted so the section renders
  /// instantly on the next visit.
  Future<List<ArtistSimilarity>> similarArtistsFor(
    String artistKey, {
    int limit = 12,
    bool force = false,
  }) async {
    if (!force) {
      final stored = await _similarityStore.artistSimilarities(artistKey);
      if (stored.isNotEmpty) return stored.take(limit).toList(growable: false);
    }
    final pool = _pool ?? await _repository.loadPool(input: await inputProvider());
    final profile =
        _profile ?? (await _profiles.load()) ?? ListeningProfile.empty;
    final vectors = _repository.artistVectors(pool);
    final context = RecommendationContext(
      pool: pool,
      profile: profile,
      now: DateTime.now(),
      artistVectors: vectors,
      coListenGraph: _coListen,
    );
    final ranked = _engine
        .similarArtists(context, artistKey, limit: limit)
        .map(
          (entry) => entry.withTracks(
            _engine.topTracksForArtist(context, entry.artistKey),
            _engine
                .recommendedAlbums(context, entry.artistKey)
                .map((album) => album.label)
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
    await _similarityStore.saveArtistSimilarities(
      artistKey,
      ranked,
      computedAt: DateTime.now(),
    );
    return ranked;
  }

  /// Top tracks + albums for one artist (the Similar Artists detail rows).
  Future<ArtistDetail> artistDetail(String artistKey, {int limit = 5}) async {
    final pool = _pool ?? await _repository.loadPool(input: await inputProvider());
    final profile =
        _profile ?? (await _profiles.load()) ?? ListeningProfile.empty;
    final context = RecommendationContext(
      pool: pool,
      profile: profile,
      now: DateTime.now(),
      artistVectors: _repository.artistVectors(pool),
      coListenGraph: _coListen,
    );
    return ArtistDetail(
      artistKey: artistKey,
      topTracks: _engine.topTracksForArtist(context, artistKey, limit: limit),
      albums: _engine.recommendedAlbums(context, artistKey),
    );
  }

  /// Drops every in-memory index. Called after a library rescan or a download
  /// so the next pass sees the new files.
  void invalidate() {
    _pool = null;
    _profile = null;
    _coListen = const <String, Set<String>>{};
    _similarityMap = const <String, List<ArtistSimilarity>>{};
    _radio.invalidatePool();
  }

  /// Erases everything the discovery module owns. Leaves the raw listening
  /// history (owned by `history/`) and every pre-existing store untouched.
  Future<void> eraseDiscoveryData() async {
    await _statistics.clear();
    await _profiles.clear();
    await _cache.clear();
    await _weeklyStore.clear();
    await _mixStore.clear();
    await _moodStore.clear();
    await _trending.clear();
    await _similarityStore.clear();
    await _continueListening.clear();
    await _radio.clear();
    invalidate();
    _last = DiscoveryHome.empty;
    _log.i('Discovery data erased');
  }

  /// Diagnostic snapshot for the settings screen.
  Future<DiscoveryDiagnostics> diagnostics() async {
    final pool = _pool;
    return DiscoveryDiagnostics(
      candidateCount: pool?.tracks.length ?? 0,
      artistCount: pool?.byArtist.length ?? 0,
      genreCount: pool?.byGenre.length ?? 0,
      cachedShelves: await _cache.count(),
      profileTracks: _profile?.tracks.length ?? 0,
      lastRefresh: _last.generatedAt,
      lastComputeMs: _last.computeMs,
      historyEvents: await _history.totalPlayCount(),
      similarityPairs: _similarityMap.values.fold<int>(
        0,
        (sum, list) => sum + list.length,
      ),
    );
  }
}

/// Top tracks and albums of one artist.
class ArtistDetail {
  const ArtistDetail({
    required this.artistKey,
    this.topTracks = const <ScoredTrack>[],
    this.albums = const <AlbumSuggestion>[],
  });

  final String artistKey;
  final List<ScoredTrack> topTracks;
  final List<AlbumSuggestion> albums;
}

/// Observable cost of the pipeline — surfaced in Settings so the Phase 12
/// budget is something a user can check, not something only the author claims.
class DiscoveryDiagnostics {
  const DiscoveryDiagnostics({
    this.candidateCount = 0,
    this.artistCount = 0,
    this.genreCount = 0,
    this.cachedShelves = 0,
    this.profileTracks = 0,
    this.lastRefresh,
    this.lastComputeMs = 0,
    this.historyEvents = 0,
    this.similarityPairs = 0,
  });

  final int candidateCount;
  final int artistCount;
  final int genreCount;
  final int cachedShelves;
  final int profileTracks;
  final DateTime? lastRefresh;
  final int lastComputeMs;
  final int historyEvents;
  final int similarityPairs;

  /// True when the last pass met the Phase 12 generation budget.
  bool get withinBudget => lastComputeMs <= 1000;

  @override
  String toString() =>
      'DiscoveryDiagnostics(candidates=$candidateCount, artists=$artistCount, '
      'genres=$genreCount, cache=$cachedShelves, profile=$profileTracks, '
      'lastMs=$lastComputeMs)';
}
