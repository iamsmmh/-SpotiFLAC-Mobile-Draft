import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/crossfade_policy.dart';
import 'package:spotiflac_android/engine/smart_play.dart';

/// Engine settings.
///
/// Deliberately separate from `AppSettings`: the engine owns a fast-moving
/// settings surface (quality profiles, failover knobs, glass rendering) that
/// would otherwise force a full `json_serializable` regeneration and a
/// settings migration on every tweak. Persistence keys are namespaced
/// `engine.*`; a version field keeps future migrations cheap.
class EngineSettings {
  static const String storageKey = 'engine_settings_v1';

  // ---- Streaming / Smart Play --------------------------------------------
  final bool streamingEnabled;
  final PlaybackModePreference playbackMode;
  final AudioQualityLevel qualityProfile;
  final bool localFirst;

  /// Network policy: which quality profile applies on each connection type.
  final AudioQualityLevel wifiProfile;
  final AudioQualityLevel mobileProfile;
  final AudioQualityLevel poorProfile;
  final AudioQualityLevel roamingProfile;
  final bool adaptiveQuality;

  final int maxStreamAttempts;
  final int streamTimeoutSeconds;
  final bool preloadNextTrack;
  final int preloadWindow;
  final bool autoRefreshExpiredUrls;
  final bool bufferPreviewStreams;

  /// Whether streaming previews may be written to the streaming cache.
  /// Off by default: preview URLs are ephemeral and cache behavior must
  /// follow provider terms.
  final bool cacheStreams;

  // ---- Offline mode & storage policy ----------------------------------------
  /// Restricts playback strictly to local storage: the engine reports an
  /// offline network profile, never resolves stream candidates and never
  /// attempts network-based downloads until the switch is turned off.
  final bool offlineMode;

  /// Maximum ephemeral cache footprint (app cache + temp dirs) in MiB.
  /// 0 = unlimited (no automatic pruning).
  final int maxCacheSizeMb;

  /// Whether the max-cache-size threshold is enforced automatically after
  /// playback/download activity and at startup.
  final bool autoCleanCache;

  // ---- Real-time audio pipeline --------------------------------------------
  /// Gapless transitions between consecutive queue items (skips source
  /// teardown for compatible lossless tracks).
  final bool gaplessEnabled;

  /// Crossfade overlap between consecutive queue items in seconds
  /// (0 = off, 1–12). Applied by the audio service with a second player.
  final int crossfadeSeconds;

  CrossfadeSettings get crossfade =>
      CrossfadeSettings(seconds: crossfadeSeconds, smart: crossfadeSmart);

  /// Smart crossfade: skip the overlap for album-continuous neighbours,
  /// lossless pairs that splice gaplessly, and very short tracks.
  final bool crossfadeSmart;

  /// Extra lookahead (seconds) buffered on low-bandwidth networks so a brief
  /// stall never interrupts playback.
  final int lowBandwidthBufferSeconds;

  /// Cap on how much of the next stream's head is pre-buffered (KiB).
  final int prebufferHeadBytesKb;

  // ---- Recovery / privacy --------------------------------------------------
  final bool saveEngineSavepoints;
  final bool trackListeningStats;

  // ---- Liquid Glass UI ------------------------------------------------------
  final bool glassUiEnabled;
  final double glassBlurSigma;
  final double glassTintAlpha;
  final bool glassSheenEnabled;
  final bool glassPointerGlow;
  final String visualizerStyle; // spectrum|waveform|circular|bars
  final bool visualizerPerformanceMode;
  final bool largeArtworkMode;

  // ---- Diagnostics -----------------------------------------------------------
  final bool diagnosticsEnabled;

  const EngineSettings({
    this.streamingEnabled = true,
    this.playbackMode = PlaybackModePreference.smart,
    this.qualityProfile = AudioQualityLevel.auto,
    this.localFirst = true,
    this.wifiProfile = AudioQualityLevel.lossless,
    this.mobileProfile = AudioQualityLevel.high,
    this.poorProfile = AudioQualityLevel.normal,
    this.roamingProfile = AudioQualityLevel.high,
    this.adaptiveQuality = true,
    this.maxStreamAttempts = 3,
    this.streamTimeoutSeconds = 12,
    this.preloadNextTrack = true,
    this.preloadWindow = 2,
    this.autoRefreshExpiredUrls = true,
    this.bufferPreviewStreams = true,
    this.cacheStreams = false,
    this.offlineMode = false,
    this.maxCacheSizeMb = 0,
    this.autoCleanCache = true,
    this.gaplessEnabled = true,
    this.crossfadeSeconds = 0,
    this.crossfadeSmart = true,
    this.lowBandwidthBufferSeconds = 30,
    this.prebufferHeadBytesKb = 512,
    this.saveEngineSavepoints = true,
    this.trackListeningStats = true,
    this.glassUiEnabled = true,
    this.glassBlurSigma = 18,
    this.glassTintAlpha = 0.16,
    this.glassSheenEnabled = true,
    this.glassPointerGlow = true,
    this.visualizerStyle = 'spectrum',
    this.visualizerPerformanceMode = false,
    this.largeArtworkMode = true,
    this.diagnosticsEnabled = true,
  });

  EngineSettings copyWith({
    bool? streamingEnabled,
    PlaybackModePreference? playbackMode,
    AudioQualityLevel? qualityProfile,
    bool? localFirst,
    AudioQualityLevel? wifiProfile,
    AudioQualityLevel? mobileProfile,
    AudioQualityLevel? poorProfile,
    AudioQualityLevel? roamingProfile,
    bool? adaptiveQuality,
    int? maxStreamAttempts,
    int? streamTimeoutSeconds,
    bool? preloadNextTrack,
    int? preloadWindow,
    bool? autoRefreshExpiredUrls,
    bool? bufferPreviewStreams,
    bool? cacheStreams,
    bool? offlineMode,
    int? maxCacheSizeMb,
    bool? autoCleanCache,
    bool? gaplessEnabled,
    int? crossfadeSeconds,
    bool? crossfadeSmart,
    int? lowBandwidthBufferSeconds,
    int? prebufferHeadBytesKb,
    bool? saveEngineSavepoints,
    bool? trackListeningStats,
    bool? glassUiEnabled,
    double? glassBlurSigma,
    double? glassTintAlpha,
    bool? glassSheenEnabled,
    bool? glassPointerGlow,
    String? visualizerStyle,
    bool? visualizerPerformanceMode,
    bool? largeArtworkMode,
    bool? diagnosticsEnabled,
  }) => EngineSettings(
    streamingEnabled: streamingEnabled ?? this.streamingEnabled,
    playbackMode: playbackMode ?? this.playbackMode,
    qualityProfile: qualityProfile ?? this.qualityProfile,
    localFirst: localFirst ?? this.localFirst,
    wifiProfile: wifiProfile ?? this.wifiProfile,
    mobileProfile: mobileProfile ?? this.mobileProfile,
    poorProfile: poorProfile ?? this.poorProfile,
    roamingProfile: roamingProfile ?? this.roamingProfile,
    adaptiveQuality: adaptiveQuality ?? this.adaptiveQuality,
    maxStreamAttempts: maxStreamAttempts ?? this.maxStreamAttempts,
    streamTimeoutSeconds: streamTimeoutSeconds ?? this.streamTimeoutSeconds,
    preloadNextTrack: preloadNextTrack ?? this.preloadNextTrack,
    preloadWindow: preloadWindow ?? this.preloadWindow,
    autoRefreshExpiredUrls:
        autoRefreshExpiredUrls ?? this.autoRefreshExpiredUrls,
    bufferPreviewStreams: bufferPreviewStreams ?? this.bufferPreviewStreams,
    cacheStreams: cacheStreams ?? this.cacheStreams,
    offlineMode: offlineMode ?? this.offlineMode,
    maxCacheSizeMb: maxCacheSizeMb ?? this.maxCacheSizeMb,
    autoCleanCache: autoCleanCache ?? this.autoCleanCache,
    gaplessEnabled: gaplessEnabled ?? this.gaplessEnabled,
    crossfadeSeconds: crossfadeSeconds ?? this.crossfadeSeconds,
    crossfadeSmart: crossfadeSmart ?? this.crossfadeSmart,
    lowBandwidthBufferSeconds:
        lowBandwidthBufferSeconds ?? this.lowBandwidthBufferSeconds,
    prebufferHeadBytesKb: prebufferHeadBytesKb ?? this.prebufferHeadBytesKb,
    saveEngineSavepoints: saveEngineSavepoints ?? this.saveEngineSavepoints,
    trackListeningStats: trackListeningStats ?? this.trackListeningStats,
    glassUiEnabled: glassUiEnabled ?? this.glassUiEnabled,
    glassBlurSigma: glassBlurSigma ?? this.glassBlurSigma,
    glassTintAlpha: glassTintAlpha ?? this.glassTintAlpha,
    glassSheenEnabled: glassSheenEnabled ?? this.glassSheenEnabled,
    glassPointerGlow: glassPointerGlow ?? this.glassPointerGlow,
    visualizerStyle: visualizerStyle ?? this.visualizerStyle,
    visualizerPerformanceMode:
        visualizerPerformanceMode ?? this.visualizerPerformanceMode,
    largeArtworkMode: largeArtworkMode ?? this.largeArtworkMode,
    diagnosticsEnabled: diagnosticsEnabled ?? this.diagnosticsEnabled,
  );

  QualityPolicy get qualityPolicy => QualityPolicy(
    wifiProfile: wifiProfile,
    mobileProfile: mobileProfile,
    poorProfile: poorProfile,
    roamingProfile: roamingProfile,
    autoProfile: adaptiveQuality,
  );

  Map<String, dynamic> toJson() => {
    'streaming_enabled': streamingEnabled,
    'playback_mode': playbackMode.name,
    'quality_profile': qualityProfile.name,
    'local_first': localFirst,
    'wifi_profile': wifiProfile.name,
    'mobile_profile': mobileProfile.name,
    'poor_profile': poorProfile.name,
    'roaming_profile': roamingProfile.name,
    'adaptive_quality': adaptiveQuality,
    'max_stream_attempts': maxStreamAttempts,
    'stream_timeout_seconds': streamTimeoutSeconds,
    'preload_next_track': preloadNextTrack,
    'preload_window': preloadWindow,
    'auto_refresh_expired_urls': autoRefreshExpiredUrls,
    'buffer_preview_streams': bufferPreviewStreams,
    'cache_streams': cacheStreams,
    'offline_mode': offlineMode,
    'max_cache_size_mb': maxCacheSizeMb,
    'auto_clean_cache': autoCleanCache,
    'gapless_enabled': gaplessEnabled,
    'crossfade_seconds': crossfadeSeconds,
    'crossfade_smart': crossfadeSmart,
    'low_bandwidth_buffer_seconds': lowBandwidthBufferSeconds,
    'prebuffer_head_bytes_kb': prebufferHeadBytesKb,
    'save_engine_savepoints': saveEngineSavepoints,
    'track_listening_stats': trackListeningStats,
    'glass_ui_enabled': glassUiEnabled,
    'glass_blur_sigma': glassBlurSigma,
    'glass_tint_alpha': glassTintAlpha,
    'glass_sheen_enabled': glassSheenEnabled,
    'glass_pointer_glow': glassPointerGlow,
    'visualizer_style': visualizerStyle,
    'visualizer_performance_mode': visualizerPerformanceMode,
    'large_artwork_mode': largeArtworkMode,
    'diagnostics_enabled': diagnosticsEnabled,
  };

  factory EngineSettings.fromJson(Map<String, dynamic> json) {
    AudioQualityLevel quality(String key, AudioQualityLevel fallback) =>
        _enumByName(AudioQualityLevel.values, json[key], fallback);
    PlaybackModePreference mode(
      String key,
      PlaybackModePreference fallback,
    ) => _enumByName(PlaybackModePreference.values, json[key], fallback);

    return EngineSettings(
      streamingEnabled: json['streaming_enabled'] as bool? ?? true,
      playbackMode: mode('playback_mode', PlaybackModePreference.smart),
      qualityProfile: quality('quality_profile', AudioQualityLevel.auto),
      localFirst: json['local_first'] as bool? ?? true,
      wifiProfile: quality('wifi_profile', AudioQualityLevel.lossless),
      mobileProfile: quality('mobile_profile', AudioQualityLevel.high),
      poorProfile: quality('poor_profile', AudioQualityLevel.normal),
      roamingProfile: quality('roaming_profile', AudioQualityLevel.high),
      adaptiveQuality: json['adaptive_quality'] as bool? ?? true,
      maxStreamAttempts: (json['max_stream_attempts'] as num?)?.toInt() ?? 3,
      streamTimeoutSeconds:
          (json['stream_timeout_seconds'] as num?)?.toInt() ?? 12,
      preloadNextTrack: json['preload_next_track'] as bool? ?? true,
      preloadWindow: (json['preload_window'] as num?)?.toInt() ?? 2,
      autoRefreshExpiredUrls:
          json['auto_refresh_expired_urls'] as bool? ?? true,
      bufferPreviewStreams: json['buffer_preview_streams'] as bool? ?? true,
      cacheStreams: json['cache_streams'] as bool? ?? false,
      offlineMode: json['offline_mode'] as bool? ?? false,
      maxCacheSizeMb: (json['max_cache_size_mb'] as num?)?.toInt() ?? 0,
      autoCleanCache: json['auto_clean_cache'] as bool? ?? true,
      gaplessEnabled: json['gapless_enabled'] as bool? ?? true,
      crossfadeSeconds: ((json['crossfade_seconds'] as num?)?.toInt() ?? 0)
          .clamp(0, CrossfadeSettings.maxSeconds),
      crossfadeSmart: json['crossfade_smart'] as bool? ?? true,
      lowBandwidthBufferSeconds:
          (json['low_bandwidth_buffer_seconds'] as num?)?.toInt() ?? 30,
      prebufferHeadBytesKb:
          (json['prebuffer_head_bytes_kb'] as num?)?.toInt() ?? 512,
      saveEngineSavepoints: json['save_engine_savepoints'] as bool? ?? true,
      trackListeningStats: json['track_listening_stats'] as bool? ?? true,
      glassUiEnabled: json['glass_ui_enabled'] as bool? ?? true,
      glassBlurSigma: (json['glass_blur_sigma'] as num?)?.toDouble() ?? 18,
      glassTintAlpha: (json['glass_tint_alpha'] as num?)?.toDouble() ?? 0.16,
      glassSheenEnabled: json['glass_sheen_enabled'] as bool? ?? true,
      glassPointerGlow: json['glass_pointer_glow'] as bool? ?? true,
      visualizerStyle: json['visualizer_style']?.toString() ?? 'spectrum',
      visualizerPerformanceMode:
          json['visualizer_performance_mode'] as bool? ?? false,
      largeArtworkMode: json['large_artwork_mode'] as bool? ?? true,
      diagnosticsEnabled: json['diagnostics_enabled'] as bool? ?? true,
    );
  }

  static T _enumByName<T extends Enum>(List<T> values, Object? name, T fallback) {
    final text = name?.toString();
    if (text == null) return fallback;
    for (final value in values) {
      if (value.name == text) return value;
    }
    return fallback;
  }
}

/// Reads engine settings from [prefs] (used at bootstrap in main.dart).
EngineSettings engineSettingsFromPrefs(SharedPreferences prefs) {
  final raw = prefs.getString(EngineSettings.storageKey);
  if (raw == null || raw.isEmpty) return const EngineSettings();
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const EngineSettings();
    return EngineSettings.fromJson(Map<String, dynamic>.from(decoded));
  } catch (_) {
    // Corrupted store must never crash the app at launch.
    return const EngineSettings();
  }
}

/// Overridden in main.dart with the bootstrap value, mirroring the
/// `initialSettingsProvider` pattern.
final initialEngineSettingsProvider = Provider<EngineSettings>(
  (ref) => const EngineSettings(),
);

final engineSettingsProvider = NotifierProvider<EngineSettingsNotifier,
    EngineSettings>(EngineSettingsNotifier.new);

class EngineSettingsNotifier extends Notifier<EngineSettings> {
  SharedPreferences? _prefs;

  @override
  EngineSettings build() => ref.watch(initialEngineSettingsProvider);

  Future<void> attach(SharedPreferences prefs) async {
    _prefs = prefs;
  }

  Future<void> _apply(EngineSettings next) async {
    state = next;
    try {
      final prefs = _prefs ?? await SharedPreferences.getInstance();
      _prefs = prefs;
      await prefs.setString(EngineSettings.storageKey, _encode(next));
    } catch (_) {
      // Persistence failure must not break the running session.
    }
  }

  Future<void> setStreamingEnabled(bool value) =>
      _apply(state.copyWith(streamingEnabled: value));

  Future<void> setPlaybackMode(PlaybackModePreference value) =>
      _apply(state.copyWith(playbackMode: value));

  Future<void> setQualityProfile(AudioQualityLevel value) =>
      _apply(state.copyWith(qualityProfile: value));

  Future<void> setLocalFirst(bool value) =>
      _apply(state.copyWith(localFirst: value));

  Future<void> setNetworkProfile(
    String profile, {
    required AudioQualityLevel level,
  }) {
    switch (profile) {
      case 'wifi':
        return _apply(state.copyWith(wifiProfile: level));
      case 'mobile':
        return _apply(state.copyWith(mobileProfile: level));
      case 'poor':
        return _apply(state.copyWith(poorProfile: level));
      case 'roaming':
        return _apply(state.copyWith(roamingProfile: level));
      default:
        return Future<void>.value();
    }
  }

  Future<void> setAdaptiveQuality(bool value) =>
      _apply(state.copyWith(adaptiveQuality: value));

  Future<void> setMaxStreamAttempts(int value) => _apply(
    state.copyWith(maxStreamAttempts: value.clamp(1, 8)),
  );

  Future<void> setStreamTimeoutSeconds(int value) => _apply(
    state.copyWith(streamTimeoutSeconds: value.clamp(3, 60)),
  );

  Future<void> setPreloadNextTrack(bool value) =>
      _apply(state.copyWith(preloadNextTrack: value));

  Future<void> setPreloadWindow(int value) =>
      _apply(state.copyWith(preloadWindow: value.clamp(1, 5)));

  Future<void> setAutoRefreshExpiredUrls(bool value) =>
      _apply(state.copyWith(autoRefreshExpiredUrls: value));

  Future<void> setBufferPreviewStreams(bool value) =>
      _apply(state.copyWith(bufferPreviewStreams: value));

  Future<void> setCacheStreams(bool value) =>
      _apply(state.copyWith(cacheStreams: value));

  Future<void> setOfflineMode(bool value) =>
      _apply(state.copyWith(offlineMode: value));

  Future<void> setMaxCacheSizeMb(int value) =>
      _apply(state.copyWith(maxCacheSizeMb: value.clamp(0, 16384)));

  Future<void> setAutoCleanCache(bool value) =>
      _apply(state.copyWith(autoCleanCache: value));

  Future<void> setGaplessEnabled(bool value) =>
      _apply(state.copyWith(gaplessEnabled: value));

  Future<void> setCrossfadeSeconds(int value) => _apply(
    state.copyWith(
      crossfadeSeconds: value.clamp(0, CrossfadeSettings.maxSeconds),
    ),
  );

  Future<void> setCrossfadeSmart(bool value) =>
      _apply(state.copyWith(crossfadeSmart: value));

  Future<void> setLowBandwidthBufferSeconds(int value) => _apply(
    state.copyWith(lowBandwidthBufferSeconds: value.clamp(5, 120)),
  );

  Future<void> setPrebufferHeadBytesKb(int value) => _apply(
    state.copyWith(prebufferHeadBytesKb: value.clamp(64, 8192)),
  );

  Future<void> setSaveEngineSavepoints(bool value) =>
      _apply(state.copyWith(saveEngineSavepoints: value));

  Future<void> setTrackListeningStats(bool value) =>
      _apply(state.copyWith(trackListeningStats: value));

  Future<void> setGlassUiEnabled(bool value) =>
      _apply(state.copyWith(glassUiEnabled: value));

  Future<void> setGlassBlurSigma(double value) =>
      _apply(state.copyWith(glassBlurSigma: value.clamp(4, 40)));

  Future<void> setGlassTintAlpha(double value) =>
      _apply(state.copyWith(glassTintAlpha: value.clamp(0.0, 0.45)));

  Future<void> setGlassSheenEnabled(bool value) =>
      _apply(state.copyWith(glassSheenEnabled: value));

  Future<void> setGlassPointerGlow(bool value) =>
      _apply(state.copyWith(glassPointerGlow: value));

  Future<void> setVisualizerStyle(String value) =>
      _apply(state.copyWith(visualizerStyle: value));

  Future<void> setVisualizerPerformanceMode(bool value) =>
      _apply(state.copyWith(visualizerPerformanceMode: value));

  Future<void> setLargeArtworkMode(bool value) =>
      _apply(state.copyWith(largeArtworkMode: value));

  Future<void> setDiagnosticsEnabled(bool value) =>
      _apply(state.copyWith(diagnosticsEnabled: value));

  static String _encode(EngineSettings settings) => jsonEncode(
    settings.toJson(),
  );
}

/// Convenience selectors for widgets that only need one knob.
final glassUiEnabledProvider = Provider<bool>(
  (ref) => ref.watch(engineSettingsProvider.select((s) => s.glassUiEnabled)),
);

final glassSheenEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(engineSettingsProvider.select((s) => s.glassSheenEnabled)),
);

final glassPointerGlowProvider = Provider<bool>(
  (ref) =>
      ref.watch(engineSettingsProvider.select((s) => s.glassPointerGlow)),
);

final engineStreamingEnabledProvider = Provider<bool>(
  (ref) =>
      ref.watch(engineSettingsProvider.select((s) => s.streamingEnabled)),
);

/// True while the user has forced local-only playback (offline mode).
final engineOfflineModeProvider = Provider<bool>(
  (ref) => ref.watch(engineSettingsProvider.select((s) => s.offlineMode)),
);

/// The configured max cache size in MiB (0 = unlimited).
final engineMaxCacheSizeMbProvider = Provider<int>(
  (ref) => ref.watch(engineSettingsProvider.select((s) => s.maxCacheSizeMb)),
);
