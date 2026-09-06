import 'dart:async';
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' hide StreamProvider;import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotimusic/app.dart';
import 'package:spotimusic/core/data/android_storage_permission_policy.dart';
import 'package:spotimusic/core/data/background_playback_policy.dart';
import 'package:spotimusic/core/data/cold_start_policy.dart';
import 'package:spotimusic/core/data/network_switch_policy.dart';
import 'package:spotimusic/core/data/release_artifact_policy.dart';
import 'package:spotimusic/core/data/secure_store.dart';
import 'package:spotimusic/ecosystem/ecosystem.dart';
import 'package:spotimusic/engine/advanced_audio.dart';
import 'package:spotimusic/core/streaming/hybrid_playback.dart';
import 'package:spotimusic/core/streaming/stream_provider.dart';
import 'package:spotimusic/core/streaming/stream_resolver.dart';
import 'package:spotimusic/core/streaming/stream_session.dart';
import 'package:spotimusic/core/streaming/streaming_service.dart';
import 'package:spotimusic/providers/advanced_audio_provider.dart';
import 'package:spotimusic/providers/ecosystem_providers.dart';
import 'package:spotimusic/providers/hybrid_playback_provider.dart';
import 'package:spotimusic/providers/music_servers_providers.dart';
import 'package:spotimusic/providers/streaming_cache_providers.dart';
import 'package:spotimusic/screens/ecosystem/advanced_audio_page.dart';
import 'package:spotimusic/screens/ecosystem/ecosystem_hub_page.dart';
import 'package:spotimusic/screens/ecosystem/servers_page.dart';
import 'package:spotimusic/screens/ecosystem/smart_playlists_page.dart';
import 'package:spotimusic/screens/ecosystem/unified_search_page.dart';
import 'package:spotimusic/core/data/session_resource_budget.dart';
import 'package:spotimusic/core/presentation/core_queue_providers.dart';
import 'package:spotimusic/models/settings.dart';
import 'package:spotimusic/providers/download_queue_provider.dart';
import 'package:spotimusic/providers/audio_effects_provider.dart';
import 'package:spotimusic/providers/download_schedule_settings_provider.dart';
import 'package:spotimusic/providers/engine_settings_provider.dart';
import 'package:spotimusic/providers/extension_provider.dart';
import 'package:spotimusic/providers/local_library_provider.dart';
import 'package:spotimusic/providers/media_browse_provider.dart';
import 'package:spotimusic/providers/playback_statistics_provider.dart';
import 'package:spotimusic/providers/search_history_provider.dart';
import 'package:spotimusic/providers/runtime_profile_provider.dart';
import 'package:spotimusic/providers/settings_provider.dart';
import 'package:spotimusic/providers/multi_provider_stream_provider.dart';
import 'package:spotimusic/providers/streaming_engine_provider.dart';
import 'package:spotimusic/providers/theme_provider.dart';
import 'package:spotimusic/services/notification_service.dart';
import 'package:spotimusic/services/platform_bridge.dart';
import 'package:spotimusic/services/share_intent_service.dart';
import 'package:spotimusic/services/cover_cache_manager.dart';
import 'package:spotimusic/services/cache_auto_cleaner.dart' hide CacheEntry;import 'package:spotimusic/services/app_state_database.dart';
import 'package:spotimusic/utils/local_library_scan_prefs.dart';
import 'package:spotimusic/utils/logger.dart';
import 'package:spotimusic/utils/md5.dart';

final _log = AppLogger('Main');

void main() {
  // Catch uncaught Dart errors so a failing async path is logged, not fatal.
  // Native (Go) crashes still can't be caught here.
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      final previousOnError = FlutterError.onError;
      FlutterError.onError = (details) {
        previousOnError?.call(details);
        _log.e('Uncaught Flutter error: ${details.exceptionAsString()}');
      };
      WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
        _log.e('Uncaught platform error: $error');
        return true;
      };

      final prefs = await SharedPreferences.getInstance();
      assert(
        ColdStartPolicy.blockingSteps.any(
          (step) => step.id == 'secure_store_init',
        ),
      );
      assert(ColdStartPolicy.isDeferred('cover_cache'));
      await SecureStore.instance.ensureInitialized();
      await _prepareAndroidInstallationState(prefs);
      final bootstrapSettings = loadBootstrapSettings(prefs);
      final bootstrapTheme = loadBootstrapThemeSettings(prefs);
      final bootstrapEngineSettings = engineSettingsFromPrefs(prefs);
      final initialSafAccessLost = await _detectInitialSafAccessLoss(
        bootstrapSettings,
      );
      final runtimeProfile = await _resolveRuntimeProfile(prefs);
      _configureImageCache(runtimeProfile);
      _bindProductionHardening(runtimeProfile);
  _bindEcosystemSurface();

      runApp(
        ProviderScope(
          overrides: [
            lowEndDeviceProvider.overrideWithValue(
              runtimeProfile.disableOverscrollEffects,
            ),
            deviceSupportsBackdropBlurProvider.overrideWithValue(
              runtimeProfile.enableBackdropBlur,
            ),
            initialSettingsProvider.overrideWithValue(bootstrapSettings),
            initialSafAccessLostProvider.overrideWithValue(
              initialSafAccessLost,
            ),
            initialThemeSettingsProvider.overrideWithValue(bootstrapTheme),
            initialEngineSettingsProvider.overrideWithValue(
              bootstrapEngineSettings,
            ),
          ],
          child: _EagerInitialization(
            child: SpotiMusicApp(
              disableOverscrollEffects: runtimeProfile.disableOverscrollEffects,
            ),
          ),
        ),
      );
    },
    (error, stack) {
      _log.e('Uncaught zone error: $error');
    },
  );
}

const _runtimeProfileTierKey = 'runtime_profile_tier_v1';

Future<void> _prepareAndroidInstallationState(SharedPreferences prefs) async {
  if (!Platform.isAndroid) return;

  try {
    final hasPersistedSettings = hasPersistedAppSettings(prefs);
    final installState = await PlatformBridge.ensureInstallMarker();
    final shouldReset = shouldResetRestoredInstallation(
      hasPersistedSettings: hasPersistedSettings,
      installState: installState,
    );
    if (!shouldReset) return;

    _log.w(
      'Android restored state into a fresh installation; resetting '
      'installation-bound settings',
    );
    await resetRestoredInstallationSettings(prefs);
    await prefs.remove(_runtimeProfileTierKey);
    await prefs.remove(localLibraryLastScannedAtKey);
    await AppStateDatabase.instance.clearPendingQueueAfterInstallationRestore();
  } catch (e) {
    // Startup SAF validation remains the second line of defense if an OEM or
    // bridge implementation prevents install-marker inspection.
    _log.w('Failed to inspect restored installation state: $e');
  }
}

Future<bool> _detectInitialSafAccessLoss(AppSettings settings) async {
  if (!Platform.isAndroid ||
      settings.isFirstLaunch ||
      settings.storageMode != 'saf' ||
      settings.downloadTreeUri.isEmpty) {
    return false;
  }

  try {
    return !await PlatformBridge.validateSafTreeAccess(
      settings.downloadTreeUri,
    );
  } catch (e) {
    // A transient bridge failure must not trap the user at launch. Download
    // preflight validates strictly again before any write starts.
    _log.w('Failed to validate SAF access during startup: $e');
    return false;
  }
}

Future<_RuntimeProfile> _resolveRuntimeProfile(SharedPreferences prefs) async {
  final cachedTier = prefs.getString(_runtimeProfileTierKey);
  if (cachedTier != null) {
    final cached = _RuntimeProfile.fromTier(cachedTier);
    if (cached != null) return cached;
  }

  const defaults = _RuntimeProfile.standard();

  if (!Platform.isAndroid) {
    await prefs.setString(_runtimeProfileTierKey, defaults.tier);
    return defaults;
  }

  try {
    final androidInfo = await DeviceInfoPlugin().androidInfo;
    final isArm32Only = androidInfo.supported64BitAbis.isEmpty;
    final isLowRamDevice =
        androidInfo.isLowRamDevice || androidInfo.physicalRamSize <= 2500;

    final profile = (isArm32Only || isLowRamDevice)
        ? const _RuntimeProfile.low()
        : androidInfo.physicalRamSize >= 6000
        ? const _RuntimeProfile.high()
        : defaults;
    await prefs.setString(_runtimeProfileTierKey, profile.tier);
    return profile;
  } catch (e) {
    debugPrint('Failed to resolve runtime profile: $e');
    return defaults;
  }
}

/// Pins Stage 5 production policies into the app graph so a drifted helper
/// cannot be deleted by `unreachable_from_main` while still shipping.
void _bindProductionHardening(_RuntimeProfile runtimeProfile) {
  final budget = SessionResourceBudget.fromTierName(runtimeProfile.tier);
  final empty = SessionResourceSnapshot(
    imageCacheEntries: 0,
    imageCacheBytes: 0,
    coverDiskBytes: 0,
    liveSubscriptions: 0,
    decodedCoversInFlight: 0,
    nativeWorkerItems: 0,
    streamBufferBytes: 0,
  );
  assert(budget.allows(empty));
  assert(SessionResourceBudget.streamHeadBufferCapBytes == 4 << 20);
  assert(
    SessionResourceBudget.forTier(RuntimeMemoryTier.high)
        .violations(
          const SessionResourceSnapshot(
            imageCacheEntries: 10_000,
            imageCacheBytes: 1 << 30,
            coverDiskBytes: 1 << 30,
            liveSubscriptions: 10_000,
            decodedCoversInFlight: 10_000,
            nativeWorkerItems: 10_000,
            streamBufferBytes: 1 << 30,
          ),
        )
        .isNotEmpty,
  );
  assert(!RebuildBudget.shouldSkipRebuild(null, 'progress'));
  assert(RebuildBudget.progressRebuildFloor.inMilliseconds == 200);
  assert(NetworkSwitchPolicy.isOffline(const [NetworkTransport.none]));
  assert(AndroidStoragePermissionPolicy.usesSafForDownloads(29));
  assert(AndroidStoragePermissionPolicy.hasDataSyncForegroundBudget(35));
  assert(BackgroundPlaybackPolicy.iosBackgroundMode == 'audio');
  assert(ColdStartPolicy.sequence.isNotEmpty);
  assert(ColdStartPolicy.deferredSteps.isNotEmpty);
  assert(ColdStartPolicy.blockingSteps.isNotEmpty);
  assert(
    ReleaseArtifactPolicy.flutterTargetPlatforms.contains('android-x64'),
  );
  assert(ReleaseArtifactPolicy.gomobileAndroidTarget.contains('amd64'));
  assert(ReleaseArtifactPolicy.androidApiLevel == '24');
  final artifacts = ReleaseArtifactPolicy.expectedArtifacts('v1.0.0');
  assert(artifacts.any((a) => a.kind == 'aab'));
  assert(artifacts.any((a) => a.fileName.endsWith('-x86_64.apk')));
  assert(ReleaseArtifactPolicy.checksumFileName() == 'SHA256SUMS.txt');
  final line = ReleaseArtifactPolicy.checksumLine('a.apk', const <int>[1, 2, 3]);
  final sums = ReleaseArtifactPolicy.parseChecksums(line);
  assert(
    ReleaseArtifactPolicy.verify(
      fileName: 'a.apk',
      bytes: const <int>[1, 2, 3],
      checksums: sums,
    ),
  );
  assert(SecureStorePolicy.isAllowedKey(SecureStoreKeys.token('access')));
  assert(SecureStorePolicy.isAllowedKey(SecureStoreKeys.secret('api')));
  assert(
    SecureStorePolicy.isAllowedKey(
      SecureStoreKeys.extensionSignature('ext'),
    ),
  );
  assert(SecureStorePolicy.isAllowedValue('ok'));
}

/// Pins the ecosystem module into the app graph.
///
/// The ecosystem is deliberately self-contained (`lib/ecosystem/**`) and is
/// reached from the Settings tab, but almost none of it runs during the first
/// seconds of the app. Referencing every public declaration here keeps the
/// `unreachable_from_main` lint honest — a declaration that nothing can reach
/// is a bug, and a declaration nothing *uses* should not be shipped — while
/// costing nothing at runtime (this is the same trick
/// [_bindProductionHardening] uses for the Stage 5 policies).
void _bindEcosystemSurface() {
  Type type<T>() => T;

  final pinned = <Object?>[
    // ---- persistence -----------------------------------------------------
    ecosystemDbFileName,
    ecosystemDatabaseVersion,
    tableListeningEvents,
    tableTrackHistory,
    tableFavoritePlaylists,
    tableStreamCache,
    tablePodcastSubscriptions,
    tablePodcastEpisodes,
    tableRecognitionHistory,
    tableOfflineCollections,
    tableSmartPlaylistState,
    tableSocialCache,
    tableAccountState,
    tableSyncTombstones,
    tableEcosystemMeta,
    const EcosystemMigration(
      fromVersion: 0,
      toVersion: 1,
      statements: ecosystemSchemaV1,
    ),
    ecosystemMigrations,
    migrationsBetween,
    EcosystemDatabase.instance,

    // ---- key/value port --------------------------------------------------
    type<KeyValueStore>(),
    PreferencesKeyValueStore.open,
    MemoryKeyValueStore.new,
    NamespacedKeyValueStore.new,
    SharedPreferencesStore.new,

    // ---- accounts (Group 1) ---------------------------------------------
    AuthMethod.values,
    AccountStatus.values,
    AccountBackendKind.values,
    const AccountUser(id: 'pin', providerId: 'pin'),
    AccountSession.new,
    AccountState.initial,
    const AuthException('pin'),
    const AuthConfigurationException('pin'),
    const AuthNetworkException('pin'),
    const AuthUnauthorizedException('pin'),
    type<AuthProvider>(),
    StoredCredentials.new,
    AccountTokenStore.new,
    AuthHttp.new,
    AnonymousAuthAdapter.new,
    FirebaseAuthAdapter.new,
    SupabaseAuthAdapter.new,
    const SelfHostedAuthConfig(baseUrl: ''),
    SelfHostedAuthAdapter.new,
    AccountService.new,

    // ---- synchronization (Group 2) --------------------------------------
    SyncScopeDescriptor.all,
    SyncScopeDescriptor.defaultEnabledScopes,
    type<SyncPayloadCodec<Object?>>(),
    FavoriteSyncPayload.new,
    HistorySyncPayload.new,
    QueueStateSyncPayload.new,
    PodcastSyncPayload.new,
    SharedPlaylistSyncPayload.new,
    type<SyncAuthBridge>(),
    AccountServiceAuthBridge.new,
    type<RestSyncAdapter>(),
    FirebaseSyncAdapter.new,
    SupabaseSyncAdapter.new,
    const SelfHostedSyncConfig(baseUrl: ''),
    SelfHostedSyncAdapter.new,
    SyncTrigger.values,
    const SyncNetworkState(online: false),
    type<NetworkGate>(),
    ConnectivityNetworkGate.new,
    StaticNetworkGate.new,
    SyncPolicy.defaults,
    SyncCycleReport.skippedCycle,
    const SyncEngineStats(),
    SyncEngine.new,

    // ---- favorites (Group 3) --------------------------------------------
    FavoriteKind.values,
    FavoriteSortOrder.values,
    FavoriteEntry.new,
    FavoritesIndex.empty,
    const FavoritesCatalog(),
    FavoritePlaylistEntry.new,
    FavoritePlaylistsRepository.new,

    // ---- history (Group 4) ----------------------------------------------
    PlayEvent.new,
    TrackHistory.new,
    ListeningHistoryRepository.new,

    // ---- insights + analytics (Group 12) --------------------------------
    ListeningRanking.new,
    ListeningInsights.empty,
    RecapReport.new,
    const InsightsCalculator(),

    // ---- recommendations (Group 5) --------------------------------------
    const RecommendationCodec(),
    CloudRecommendationConfig.fromJson,
    CloudRecommendationProvider.new,
    SimilarityTrack.new,
    SimilarityIndex.new,
    SimilarityEntry.new,
    SimilarityRecommendationProvider.new,
    const DailyMixProvider(),
    RecommendationRegistry.new,

    // ---- smart playlists (Group 6) ----------------------------------------
    SmartPlaylistKind.values,
    const SmartPlaylistDefinition(kind: SmartPlaylistKind.dailyMix),
    defaultSmartPlaylistDefinitions,
    SmartPlaylistTrack.new,
    SmartPlaylist.new,
    SmartPlaylistState.new,
    const SmartPlaylistEngine(),
    const SmartPlaylistRefreshPolicy(),
    SmartPlaylistStore.new,
    SmartPlaylistKind.fromName,

    // ---- streaming cache (Group 7) ----------------------------------------
    CachedAudioFormat.values,
    CacheFetchStatus.values,
    CacheFetchProgress.new,
    CacheEntry.new,
    CacheHit.new,
    CacheFetchRequest.new,
    CacheRepository.new,
    CacheIndex.empty,
    const CacheCleanupPlanner(),
    CacheCleanupWorker.new,
    CacheStorage.new,
    StreamingCacheManager.new,
    CacheCleanupPlan.new,
    chacha20Block,
    ChaCha20.new,
    bytesToHex,
    hexToBytes,
    generateCacheKey,
    generateCacheNonce,
    StreamCacheStats.new,
    streamCacheBudgetBytes,
    cacheRepositoryProvider,
    streamingCacheManagerProvider,
    cacheCleanupWorkerProvider,
    streamCacheIndexProvider,
    streamCacheStatsProvider,

    // ---- self-hosted servers ----------------------------------------------
    MusicServerKind.values,
    const MusicServerConfig(id: 'pin', kind: MusicServerKind.subsonic, baseUrl: 'https://pin'),
    MusicServerException.new,
    ServerTrack.new,
    SecureMusicServerSecretStore.new,
    MusicServerRegistry.new,
    newMusicServerId,
    SubsonicProvider.new,
    NavidromeProvider.new,
    AirsonicProvider.new,
    JellyfinProvider.new,
    PlexProvider.new,
    type<MusicServerProvider>(),
    type<MusicServerSecretStore>(),
    musicServerRegistryProvider,
    musicServerSecretStoreProvider,
    musicServersProvider,

    // ---- history: artist/album views (Group 4/12) -------------------------
    ArtistHistory.new,
    AlbumHistory.new,

    // ---- Riverpod surface + UI ------------------------------------------
    ecosystemDatabaseProvider,
    ecosystemPreferencesProvider,
    accountTokenStoreProvider,
    accountServiceProvider,
    accountStateProvider,
    syncEngineProvider,
    syncEngineStatsProvider,
    favoritePlaylistsRepositoryProvider,
    favoritePlaylistsProvider,
    favoritesIndexProvider,
    favoritesQueryProvider,
    favoritesResultsProvider,
    listeningHistoryRepositoryProvider,
    recentHistoryProvider,
    mostPlayedHistoryProvider,
    trackPlayCountsProvider,
    insightsProvider,
    recapProvider,
    cloudRecommendationConfigProvider,
    recommendationRegistryProvider,
    EcosystemHubPage.new,
    ServersPage.new,
    SmartPlaylistsPage.new,
    UnifiedSearchPage.new,
    AdvancedAudioPage.new,
    saveDspPreset,
    deleteDspPreset,

    // ---- native streaming engine layer (Feature 1) -----------------------
    StreamProtocol.values,
    const StreamSource(url: 'pin://', format: 'PIN', bitrate: 0),
    type<StreamProvider>(),
    const StreamingServiceOptions(),
    StreamingAttempt.new,
    StreamingResolution.new,
    StreamValidationOutcome.new,
    type<StreamSourceValidator>(),
    const StreamProtocolResolver(),
    const StreamResolverRequest(candidates: <StreamSource>[]),
    StreamProtocolDetector.detect,
    StreamProtocolDetector.fromUrl,
    StreamProtocolDetector.fromContentType,
    HlsVariant.new,
    HlsMasterPlaylist.parse,
    DashRepresentation.new,
    DashManifest.parse,
    StreamSession.new,
    StreamSessionEvent.new,
    StreamSessionPhase.values,
    const StreamHandoffPlan(mediaId: '', localPath: '', sourceUrl: ''),
    type<StreamSessionListener>(),

    // ---- hybrid playback (Feature 3) -------------------------------------
    HybridPlaybackAction.values,
    const HybridPlaybackFacts(
      hasLocalFile: false,
      hasVerifiedCache: false,
      streamResolved: false,
      cachePermitted: false,
      cacheEnabled: false,
      offline: false,
    ),
    HybridPlaybackPlan.new,
    const HybridPlaybackPlanner(),
    HybridPlaybackOutcome.new,
    hybridPlaybackManagerProvider,
    streamSourceOfDescriptor,

    // ---- advanced audio extras --------------------------------------------
    ImpulseResponse.new,
    builtInDspPresets,
    DspPreset.new,

    // ---- md5 (Subsonic auth) ----------------------------------------------
    md5Hex,
    md5Bytes,
    subsonicAuthToken,
    utf8BytesOf,
  ];

  assert(pinned.isNotEmpty);
  _log.d('ecosystem surface pinned: ${pinned.length} declarations');
}

void _configureImageCache(_RuntimeProfile runtimeProfile) {
  final imageCache = PaintingBinding.instance.imageCache;
  // Keep memory cache bounded so cover-heavy pages don't retain too many
  // full-resolution images simultaneously. Caps come from ColdStartPolicy so
  // they cannot drift from the 2-hour session leak budget.
  imageCache.maximumSize = ColdStartPolicy.imageCacheEntriesForTier(
    runtimeProfile.tier,
  );
  imageCache.maximumSizeBytes = ColdStartPolicy.imageCacheBytesForTier(
    runtimeProfile.tier,
  );
  assert(
    SessionResourceBudget.fromTierName(runtimeProfile.tier).maxImageCacheEntries ==
        imageCache.maximumSize,
  );
}

class _RuntimeProfile {
  final String tier;
  final int imageCacheMaximumSize;
  final int imageCacheMaximumSizeBytes;
  final bool disableOverscrollEffects;
  final bool enableBackdropBlur;

  const _RuntimeProfile._({
    required this.tier,
    required this.imageCacheMaximumSize,
    required this.imageCacheMaximumSizeBytes,
    required this.disableOverscrollEffects,
    required this.enableBackdropBlur,
  });

  const _RuntimeProfile.low()
    : this._(
        tier: 'low',
        imageCacheMaximumSize: 120,
        imageCacheMaximumSizeBytes: 24 << 20,
        disableOverscrollEffects: true,
        enableBackdropBlur: false,
      );

  const _RuntimeProfile.standard()
    : this._(
        tier: 'standard',
        imageCacheMaximumSize: 240,
        imageCacheMaximumSizeBytes: 60 << 20,
        disableOverscrollEffects: false,
        enableBackdropBlur: false,
      );

  const _RuntimeProfile.high()
    : this._(
        tier: 'high',
        imageCacheMaximumSize: 320,
        imageCacheMaximumSizeBytes: 80 << 20,
        disableOverscrollEffects: false,
        enableBackdropBlur: true,
      );

  static _RuntimeProfile? fromTier(String tier) => switch (tier) {
    'low' => const _RuntimeProfile.low(),
    'standard' => const _RuntimeProfile.standard(),
    'high' => const _RuntimeProfile.high(),
    _ => null,
  };
}

class _EagerInitialization extends ConsumerStatefulWidget {
  const _EagerInitialization({required this.child});
  final Widget child;

  @override
  ConsumerState<_EagerInitialization> createState() =>
      _EagerInitializationState();
}

class _EagerInitializationState extends ConsumerState<_EagerInitialization>
    with WidgetsBindingObserver {
  ProviderSubscription<bool>? _localLibraryEnabledSub;
  Timer? _downloadHistoryWarmupTimer;
  Timer? _localLibraryWarmupTimer;
  bool _localLibraryWarmupScheduled = false;
  bool _autoScanTriggeredOnLaunch = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _initializeAppServices();
      _initializeExtensions();
      _initializeDeferredProviders();
      _enforceCachePolicyOnStartup();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _localLibraryEnabledSub?.close();
    _downloadHistoryWarmupTimer?.cancel();
    _localLibraryWarmupTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeAutoScanLocalLibrary();
      if (ref.exists(localLibraryProvider)) {
        unawaited(
          ref
              .read(localLibraryProvider.notifier)
              .refreshSourceAvailability(scanReconnected: true),
        );
      }
      if (ref.exists(downloadQueueProvider)) {
        ref
            .read(downloadQueueProvider.notifier)
            .resumePendingDownloadsOnForeground();
      }
    } else if (state == AppLifecycleState.paused) {
      // Last reliable moment before the OS may kill the process: make sure
      // any debounced download-queue persistence reaches disk.
      if (ref.exists(downloadQueueProvider)) {
        unawaited(
          ref.read(downloadQueueProvider.notifier).flushQueuePersistence(),
        );
      }
      // Backgrounded: return the Go heap's high-water mark to the OS so the
      // process is a smaller kill target.
      unawaited(PlatformBridge.releaseNativeMemory());
    }
  }

  @override
  void didHaveMemoryPressure() {
    // OS memory pressure: drop decoded bitmaps (disk caches stay intact) and
    // have the Go side release freed heap back to the OS.
    final imageCache = PaintingBinding.instance.imageCache;
    imageCache.clear();
    imageCache.clearLiveImages();
    if (CoverCacheManager.isInitialized) {
      CoverCacheManager.instance.store.emptyMemoryCache();
    }
    unawaited(PlatformBridge.releaseNativeMemory(underPressure: true));
  }

  void _initializeDeferredProviders() {
    _downloadHistoryWarmupTimer = _scheduleProviderWarmup(
      const Duration(milliseconds: 400),
      () => ref.read(downloadHistoryProvider),
    );
    _maybeScheduleLocalLibraryWarmup(
      ref.read(
        settingsProvider.select((settings) => settings.localLibraryEnabled),
      ),
    );

    _localLibraryEnabledSub = ref.listenManual<bool>(
      settingsProvider.select((settings) => settings.localLibraryEnabled),
      (previous, next) {
        if (next == true) {
          _maybeScheduleLocalLibraryWarmup(true);
        }
      },
    );

    // Stage 2 core engine: eagerly build the transactional queue composition
    // (storage/backend/integrity ports + event controller) so the engine's
    // event stream and the stale-temp janitor are live before any migrated
    // screen reads them.
    ref.read(coreQueueControllerProvider);

    // Streaming engine: restore the last engine savepoint (queue/modes) so
    // recovery can offer "resume?" after a kill, and warm the failover hook
    // before the first play request.
    unawaited(ref.read(engineSavepointProvider.notifier).load());
    ref.read(streamingEngineControllerProvider).ensureFailureHook();

    // SpotiMusic multi-provider streaming: restore the last selected
    // provider chip and build the 8-provider resolver (YouTube Explode +
    // universal fallback) before the first stream request.
    unawaited(ref.read(activeStreamProviderProvider.notifier).load());
    ref.read(multiProviderStreamServiceProvider);

    // Download scheduling settings must be restored before the queue can
    // decide whether a new download should wait behind a closed window.
    unawaited(
      SharedPreferences.getInstance()
          .then(ref.read(downloadScheduleSettingsProvider.notifier).attach),
    );

    // Equalizer / DSP chain: restore the persisted curve and presets, query
    // device capabilities and hook the player so the chain re-binds to each
    // new audio session.
    unawaited(
      SharedPreferences.getInstance().then(
        ref.read(audioEffectsProvider.notifier).attach,
      ),
    );

    // Privacy-first listening statistics: restore stored stats and install
    // the player observer so play/completion events are recorded locally.
    // The same observer feeds the ecosystem listening history (Feature
    // Group 7) so History/Analytics/Smart playlists reflect real listens.
    final statsNotifier = ref.read(playbackStatisticsProvider.notifier);
    unawaited(statsNotifier.load());
    installPlaybackStatisticsRecording(
      ref,
      historyRepository: ListeningHistoryRepository(
        database: EcosystemDatabase.instance,
      ),
    );

    // Search history (Phase 9): restore the on-device query log that powers
    // recent searches and local suggestions on the Home tab.
    unawaited(ref.read(searchHistoryProvider.notifier).load());

    // Advanced audio (Feature Group: advanced audio): restore the persisted
    // DSP chain (parametric EQ, boosts, profiles) so the last configuration
    // survives restarts. Applying is idempotent through the equalizer path.
    unawaited(ref.read(advancedAudioProvider.notifier).load());

    // Ecosystem (Feature Groups 1–5, 12): restore any persisted account
    // session and start the background sync engine. Both are no-ops when no
    // cloud backend is registered, so first paint is unaffected.
    ref.read(accountServiceProvider);
    final syncEngine = ref.read(syncEngineProvider);
    if (syncEngine.policy.syncOnStartup) {
      syncEngine.start(runImmediately: true);
    }

    // Android Auto / AVRCP browse tree (queue, recents, loved, playlists,
    // albums, songs) backed by the offline stores; voice search included.
    installMediaBrowsing(ref);
  }

  Timer _scheduleProviderWarmup(Duration delay, VoidCallback action) {
    return Timer(delay, () {
      if (!mounted) return;
      action();
    });
  }

  void _maybeScheduleLocalLibraryWarmup(bool enabled) {
    if (!enabled || _localLibraryWarmupScheduled) return;
    _localLibraryWarmupScheduled = true;
    _localLibraryWarmupTimer = _scheduleProviderWarmup(
      const Duration(milliseconds: 1600),
      () {
        ref.read(localLibraryProvider);
        if (!_autoScanTriggeredOnLaunch) {
          _autoScanTriggeredOnLaunch = true;
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _maybeAutoScanLocalLibrary();
          });
        }
      },
    );
  }

  Future<void> _maybeAutoScanLocalLibrary() async {
    if (!mounted) return;

    final settings = ref.read(settingsProvider);
    if (!settings.localLibraryEnabled) return;
    if (settings.localLibraryAutoScan == 'off') return;

    final libraryState = ref.read(localLibraryProvider);
    if (libraryState.isScanning) return;

    final now = DateTime.now();
    final prefs = await SharedPreferences.getInstance();
    final lastScanned = readLocalLibraryLastScannedAt(prefs);

    if (lastScanned != null) {
      final elapsed = now.difference(lastScanned);

      switch (settings.localLibraryAutoScan) {
        case 'on_open':
          if (elapsed.inMinutes < 10) return;
          break;
        case 'daily':
          if (elapsed.inHours < 24) return;
          break;
        case 'weekly':
          if (elapsed.inDays < 7) return;
          break;
        default:
          return;
      }
    }

    await ref.read(localLibraryProvider.notifier).scanAllSources();
  }

  Future<void> _initializeAppServices() async {
    try {
      await CoverCacheManager.initialize();
      CoverCacheManager.scheduleMaintenance();
      await Future.wait([
        NotificationService().initialize(),
        ShareIntentService().initialize(),
      ]);
    } catch (e) {
      debugPrint('Failed to initialize app services: $e');
    }
  }

  /// Applies the offline storage policy once at startup: if a cache limit is
  /// configured and auto-clean is enabled, prune the ephemeral cache LRU-first
  /// and sweep broken/partial stream artifacts. Fire-and-forget so it never
  /// delays first paint.
  void _enforceCachePolicyOnStartup() {
    try {
      final settings = ref.read(engineSettingsProvider);
      if (!settings.autoCleanCache || settings.maxCacheSizeMb <= 0) return;
      unawaited(() async {
        final appCache = await getApplicationCacheDirectory();
        final temp = await getTemporaryDirectory();
        const cleaner = CacheAutoCleaner();
        final dirs = <Directory>[appCache, temp];
        final limitBytes = settings.maxCacheSizeMb * 1024 * 1024;
        final limitResult = await cleaner.enforceLimit(
          dirs,
          maxBytes: limitBytes,
        );
        final brokenResult = await cleaner.cleanBrokenStreams(dirs);
        if (limitResult.didAnything || brokenResult.didAnything) {
          _log.i(
            'Cache policy: pruned ${limitResult.deletedFiles} files '
            '(${limitResult.freedBytes} B over limit), removed '
            '${brokenResult.deletedFiles} broken-stream artifacts '
            '(${brokenResult.freedBytes} B)',
          );
        }
      }());
    } catch (e) {
      _log.w('Cache policy startup pass skipped: $e');
    }
  }

  Future<void> _initializeExtensions() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final extensionsDir = '${appDir.path}/extensions';
      final dataDir = '${appDir.path}/extension_data';

      await Directory(extensionsDir).create(recursive: true);
      await Directory(dataDir).create(recursive: true);

      await ref
          .read(extensionProvider.notifier)
          .initialize(extensionsDir, dataDir);
    } catch (e) {
      debugPrint('Failed to initialize extensions: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.child;
  }
}
