/// Production wiring for the unified hybrid playback layer.
///
/// This provider composes [PlaybackManager] from the systems the app already
/// ships — no new pipelines:
///
///   * local resolution → library + download-history batch lookup,
///   * stream candidates → the streaming engine's adapters,
///   * stream validation → the engine's ranged-GET preflight validator,
///   * quality/bandwidth → the engine's bandwidth monitor,
///   * rendering → the single audio_service handler,
///   * policy → [EngineSettings] (gapless, crossfade, offline, cache toggles).
///
/// Hook order matters: the engine installs its non-chained hooks first, then
/// the manager chains outside them and delegates foreign media ids back.
library;

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/core/data/network_switch_policy.dart'
    show NetworkTransport;
import 'package:spotiflac_android/core/streaming/stream_provider.dart'
    show StreamSource;
import 'package:spotiflac_android/core/streaming/stream_resolver.dart'
    show StreamProtocolDetector;
import 'package:spotiflac_android/engine/streaming_engine.dart'
    show StreamDescriptor, StreamDescriptorText, StreamSourceKind;
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart'
    show EngineSettings, engineSettingsProvider;
import 'package:spotiflac_android/providers/playback_provider.dart'
    show playbackProvider;
import 'package:spotiflac_android/providers/streaming_engine_provider.dart'
    show
        streamPreflightValidatorProvider,
        streamingEngineControllerProvider;
import 'package:spotiflac_android/services/playback/playback.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _logPlaybackManagerProvider = AppLogger('PlaybackManagerProvider');

/// Maps [EngineSettings] onto the manager's plain policy snapshot.
PlaybackPolicy playbackPolicyFromEngineSettings(EngineSettings settings) {
  return PlaybackPolicy(
    streamingEnabled: settings.streamingEnabled,
    cacheEnabled: settings.cacheStreams,
    offlineMode: settings.offlineMode,
    gaplessEnabled: settings.gaplessEnabled,
    crossfadeSeconds: settings.crossfadeSeconds,
    crossfadeSmart: settings.crossfadeSmart,
    preloadNextTrack: settings.preloadNextTrack,
  );
}

/// Maps a connectivity result onto a [NetworkTransport] token.
String playbackTransportToken(ConnectivityResult result) {
  switch (result) {
    case ConnectivityResult.wifi:
      return NetworkTransport.wifi;
    case ConnectivityResult.ethernet:
      return NetworkTransport.ethernet;
    case ConnectivityResult.vpn:
      return NetworkTransport.vpn;
    case ConnectivityResult.mobile:
      return NetworkTransport.mobile;
    case ConnectivityResult.none:
      return NetworkTransport.none;
    case ConnectivityResult.bluetooth:
    case ConnectivityResult.satellite:
    case ConnectivityResult.other:
      return NetworkTransport.other;
  }
}

/// Live connectivity token sets for [PlaybackManager.watchNetwork].
Stream<Iterable<String>> playbackNetworkTransports({
  Connectivity? connectivity,
}) {
  final source = connectivity ?? Connectivity();
  return source.onConnectivityChanged.map(
    (results) => results.map(playbackTransportToken).toList(growable: false),
  );
}

/// Resolves `<appCache>/playback_cache` (created lazily by the manager).
Future<Directory> resolvePlaybackCacheDirectory() async {
  final base = await getApplicationCacheDirectory();
  return Directory('${base.path}/playback_cache');
}

/// Fetches HLS/DASH manifest text for protocol narrowing. Null on any
/// failure; manifests are small, so oversized bodies are rejected.
Future<String?> fetchPlaybackManifestText(
  Uri uri, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 8),
}) async {
  final owned = client == null;
  final httpClient = client ?? http.Client();
  try {
    final response = await httpClient
        .get(uri, headers: const <String, String>{'Accept': '*/*'})
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    if (response.bodyBytes.length > 4 * 1024 * 1024) return null;
    return response.body;
  } catch (_) {
    return null;
  } finally {
    if (owned) httpClient.close();
  }
}

/// Projects an engine [StreamDescriptor] onto the resolver's [StreamSource].
StreamSource playbackStreamSourceFromDescriptor(StreamDescriptor descriptor) {
  return StreamSource(
    url: descriptor.uri,
    format: descriptor.characteristics.codec ?? '',
    bitrate: descriptor.characteristics.bitrateKbps ?? 0,
    protocol: StreamProtocolDetector.detect(descriptor.uri),
    providerId: descriptor.providerId,
    expiresAt: descriptor.expiresAt,
    cachePermitted: descriptor.cachePermitted,
    label: descriptor.displayLabel,
  );
}

StreamDescriptor _descriptorFromStreamSource(StreamSource source) {
  return StreamDescriptor(
    id: source.url,
    providerId: source.providerId,
    kind: StreamSourceKind.httpStream,
    uri: source.url,
    expiresAt: source.expiresAt,
  );
}

final playbackManagerProvider = Provider<PlaybackManager>((ref) {
  final engine = ref.read(streamingEngineControllerProvider);
  // Engine first: its failure/deferred hooks are non-chained, so the
  // manager (chained) must install outside them to delegate foreign ids.
  engine.ensureFailureHook();

  final backend = MusicPlayerPlaybackBackend();
  final settings = ref.read(engineSettingsProvider);
  final manager = PlaybackManager(
    backend: backend,
    localSource: LocalPlaybackSource(backend: backend),
    cacheSource: CachePlaybackSource(
      backend: backend,
      cache: PlaybackCacheManager(
        resolveRoot: resolvePlaybackCacheDirectory,
        maxSizeBytes: settings.maxCacheSizeMb > 0
            ? settings.maxCacheSizeMb * 1024 * 1024
            : 0,
      ),
    ),
    streamingSource: StreamingPlaybackSource(
      backend: backend,
      urlResolver: StreamUrlResolver(
        fetchCandidates: (Track track) async {
          final descriptors = await engine.candidatesFor(track);
          return descriptors
              .map(playbackStreamSourceFromDescriptor)
              .toList(growable: false);
        },
        validateSource: (StreamSource source) async {
          final result = await ref
              .read(streamPreflightValidatorProvider)
              .validate(_descriptorFromStreamSource(source));
          return result.ok;
        },
        manifestFetch: (Uri uri) => fetchPlaybackManifestText(uri),
        bandwidthProvider: () =>
            engine.bandwidthMonitor.smoothedBytesPerSecond,
      ),
    ),
    policy: playbackPolicyFromEngineSettings(settings),
    batchPathResolver: (List<Track> tracks) =>
        ref.read(playbackProvider.notifier).resolveTrackFilePaths(tracks),
    engineTrackRegistrar: engine.registerTrackForDeferred,
  );
  backend.trackIdForMediaId = manager.trackIdForMediaId;

  ref.listen<EngineSettings>(engineSettingsProvider, (
    EngineSettings? previous,
    EngineSettings next,
  ) {
    manager.updatePolicy(playbackPolicyFromEngineSettings(next));
    if (previous?.maxCacheSizeMb != next.maxCacheSizeMb) {
      manager.cacheSource.cache.maxSizeBytes = next.maxCacheSizeMb > 0
          ? next.maxCacheSizeMb * 1024 * 1024
          : 0;
    }
  });

  ref.onDispose(() {
    unawaited(manager.dispose());
  });

  // Eager, best-effort boot: chained hooks, audio policy, network watcher.
  // A failure here only disables the unified layer — the engine-owned play
  // paths never depended on the manager and keep working.
  unawaited(
    Future<void>(() async {
      try {
        await manager.initialize();
        manager.watchNetwork(playbackNetworkTransports());
      } catch (error) {
        _logPlaybackManagerProvider.w('Unified playback unavailable: $error');
      }
    }),
  );

  return manager;
});
