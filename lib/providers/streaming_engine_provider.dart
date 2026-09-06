import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotimusic/engine/adaptive_buffer.dart';
import 'package:spotimusic/engine/audio_characteristics.dart';
import 'package:spotimusic/engine/playback_session.dart';
import 'package:spotimusic/engine/smart_play.dart';
import 'package:spotimusic/engine/streaming_engine.dart';
import 'package:spotimusic/engine/track_identity.dart';
import 'package:spotimusic/models/track.dart';
import 'package:spotimusic/models/download_item.dart';
import 'package:spotimusic/providers/download_queue_provider.dart';
import 'package:spotimusic/providers/engine_settings_provider.dart';
import 'package:spotimusic/providers/multi_provider_stream_provider.dart';
import 'package:spotimusic/providers/music_player_provider.dart';
import 'package:spotimusic/providers/music_servers_providers.dart';
import 'package:spotimusic/providers/playback_provider.dart';
import 'package:spotimusic/providers/server_stream_adapter.dart';
import 'package:spotimusic/providers/settings_provider.dart';
import 'package:spotimusic/providers/streaming_cache_providers.dart';
import 'package:spotimusic/ecosystem/cache/cache_cleanup_worker.dart';
import 'package:spotimusic/ecosystem/cache/cache_models.dart';
import 'package:spotimusic/ecosystem/cache/streaming_cache_manager.dart';
import 'package:spotimusic/services/library_database.dart';
import 'package:spotimusic/services/multi_provider_stream_service.dart';
import 'package:spotimusic/services/music_player_service.dart';
import 'package:spotimusic/utils/file_access.dart';
import 'package:spotimusic/utils/string_utils.dart';

/// ---------------------------------------------------------------------------
/// Stream source adapters
/// ---------------------------------------------------------------------------

/// An adapter produces [StreamDescriptor]s for a track. Extensions register
/// here (see [streamSourceAdaptersProvider]) — the engine never talks to a
/// provider directly, so a new extension only adds an adapter.
abstract class StreamSourceAdapter {
  String get id;

  Future<List<StreamDescriptor>> candidatesFor(Track track);
}

/// Adapter for the provider-supplied 30-second preview URLs (Deezer previews
/// and similar authorized metadata flows).
class PreviewStreamAdapter implements StreamSourceAdapter {
  const PreviewStreamAdapter();

  @override
  String get id => 'preview';

  @override
  Future<List<StreamDescriptor>> candidatesFor(Track track) async {
    final preview = track.previewUrl?.trim() ?? '';
    if (preview.isEmpty) return const [];
    return [
      StreamDescriptor(
        id: 'preview:${track.id}',
        providerId: 'preview',
        kind: StreamSourceKind.httpStream,
        uri: preview,
        quality: AudioQualityLevel.low,
        characteristics: AudioCharacteristics(
          codec: 'MP3',
          bitrateKbps: 128,
          lossless: false,
          sourceLabel: track.source,
        ),
        priority: 10,
      ),
    ];
  }
}

/// Adapter that exposes the existing multi-provider resolver (YouTube Music
/// universal fallback, SoundCloud, preview URLs, credential-gated lossless
/// providers) to the streaming engine as [StreamDescriptor] candidates.
///
/// This is the designed registration point ("Streaming provider integrations
/// are extensions implementing the StreamSourceAdapter API"): Smart Play's
/// stream branch now ranks *real* full streams alongside previews, and
/// provider health/failover applies to them exactly like any other source.
class MultiProviderStreamAdapter implements StreamSourceAdapter {
  final MultiProviderStreamService service;
  final StreamProviderId preferredProvider;

  /// Injection point used by tests to avoid real provider traffic.
  final Future<ResolvedStream?> Function(
    StreamTrackRequest request,
    StreamProviderId preferred,
  )? resolveOverride;

  const MultiProviderStreamAdapter({
    required this.service,
    this.preferredProvider = StreamProviderId.youtube,
    this.resolveOverride,
  });

  @override
  String get id => 'multi_provider';

  @override
  Future<List<StreamDescriptor>> candidatesFor(Track track) async {
    final resolve = resolveOverride;
    try {
      final resolved = resolve != null
          ? await resolve(StreamTrackRequest.fromTrack(track), preferredProvider)
          : await service.resolveStream(
              StreamTrackRequest.fromTrack(track),
              preferredProvider: preferredProvider,
            );
      if (resolved == null) return const [];
      return [_descriptorFrom(resolved, track)];
    } on StreamResolutionException {
      // No playable source anywhere in the chain: not an error, just no
      // candidates (the resolver already logged the details).
      return const [];
    } catch (_) {
      // Unexpected transport errors must not break candidate aggregation.
      return const [];
    }
  }

  StreamDescriptor _descriptorFrom(ResolvedStream resolved, Track track) {
    // 30-second previews stay below full streams in the ranking: they are a
    // last-resort source, never a preferred one.
    final isPreview = resolved.isPreview;
    final bitrate = resolved.bitrateKbps ?? 0;
    final quality = isPreview
        ? AudioQualityLevel.low
        : resolved.isLossless
        ? AudioQualityLevel.lossless
        : bitrate >= 320
        ? AudioQualityLevel.high
        : bitrate >= 128
        ? AudioQualityLevel.normal
        : AudioQualityLevel.low;
    return StreamDescriptor(
      id: 'stream:${resolved.provider.name}:${track.id}',
      providerId: resolved.provider.name,
      kind: StreamSourceKind.httpStream,
      uri: resolved.uri.toString(),
      quality: quality,
      characteristics: AudioCharacteristics(
        codec: resolved.codec?.toUpperCase(),
        bitrateKbps: resolved.bitrateKbps,
        lossless: resolved.isLossless,
        sourceLabel: resolved.qualityLabel,
      ),
      expiresAt: resolved.expiresAt,
      validFrom: DateTime.now(),
      // Progressive CDN URLs (YouTube/SoundCloud) are ephemeral, signed and
      // terms-restricted: never persist them to the playback cache.
      cachePermitted: false,
      priority: isPreview ? 12 : 5,
    );
  }
}

final streamSourceAdaptersProvider = Provider<List<StreamSourceAdapter>>((
  ref,
) {
  final service = ref.watch(multiProviderStreamServiceProvider);
  final preferred = ref.watch(activeStreamProviderProvider);
  return [
    const PreviewStreamAdapter(),
    MultiProviderStreamAdapter(service: service, preferredProvider: preferred),
    // Self-hosted servers (Feature Group: servers) join the ranked chain
    // behind the first-party providers; an unreachable server contributes
    // no candidates and never blocks the rest.
    ServerStreamAdapter(registry: ref.watch(musicServerRegistryProvider)),
  ];
});

/// Validates stream URLs before handing them to the audio engine.
///
/// Uses a single-byte ranged GET (HEAD is not supported by every CDN) so a
/// misbehaving URL fails fast instead of buffering a full file.
class HttpStreamPreflightValidator implements StreamPreflightValidator {
  final Duration timeout;
  final http.Client _client;

  HttpStreamPreflightValidator({
    this.timeout = const Duration(seconds: 12),
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  Future<StreamPreflightResult> validate(StreamDescriptor source) async {
    if (!source.uri.startsWith('http://') &&
        !source.uri.startsWith('https://')) {
      return StreamPreflightResult.failure('Unsupported URI scheme');
    }
    final stopwatch = Stopwatch()..start();
    try {
      final request = http.Request('GET', Uri.parse(source.uri))
        ..headers['Range'] = 'bytes=0-0'
        ..headers['Accept'] = 'audio/*, application/octet-stream';
      final response = await _client
          .send(request)
          .timeout(timeout, onTimeout: () {
        throw TimeoutException('preflight timed out');
      });
      stopwatch.stop();
      // Drain only the first chunk; never download the payload.
      unawaited(response.stream.take(1).drain<void>().catchError((_) {}));
      if (response.statusCode < 200 || response.statusCode >= 400) {
        return StreamPreflightResult.failure(
          'HTTP ${response.statusCode}',
        );
      }
      final contentType = response.headers['content-type'];
      return StreamPreflightResult.success(
        latencyMs: stopwatch.elapsedMilliseconds,
        contentType: contentType,
        contentLengthBytes: _contentLength(response.headers),
      );
    } on TimeoutException {
      return StreamPreflightResult.failure('Timed out');
    } on Exception catch (e) {
      return StreamPreflightResult.failure(e.toString());
    }
  }

  static int? _contentLength(Map<String, String> headers) {
    final raw = headers['content-length'];
    return raw == null ? null : int.tryParse(raw);
  }
}

/// Warms the head of a stream URL (a bounded ranged GET) so the next-track
/// switch reuses an established connection and a warm HTTP cache. Bytes are
/// drained and discarded — never persisted — so the warm-up respects the
/// same terms-of-use guardrails as the rest of the engine.
class StreamHeadWarmer {
  final http.Client _client;
  final Duration timeout;

  StreamHeadWarmer({
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _client = client ?? http.Client();

  /// Whether the engine may pull extra bytes for [source]. Preview streams are
  /// warmed only when the user enabled "buffer preview streams"; other sources
  /// only when the provider explicitly permits caching.
  bool permittedFor(
    StreamDescriptor source, {
    required bool bufferPreviewStreams,
  }) {
    if (!source.uri.startsWith('http://') &&
        !source.uri.startsWith('https://')) {
      return false;
    }
    if (source.kind == StreamSourceKind.httpStream) return bufferPreviewStreams;
    return source.cachePermitted;
  }

  /// Returns `(bytesReceived, elapsedMs)`, or null when the warm-up failed.
  Future<(int, int)?> warmHead(StreamDescriptor source, int maxBytes) async {
    final cap = maxBytes.clamp(1, 4 * 1024 * 1024);
    final stopwatch = Stopwatch()..start();
    try {
      final request = http.Request('GET', Uri.parse(source.uri))
        ..headers['Range'] = 'bytes=0-${cap - 1}'
        ..headers['Accept'] = 'audio/*, application/octet-stream';
      final response = await _client.send(request).timeout(
        timeout,
        onTimeout: () => throw TimeoutException('head warm-up timed out'),
      );
      var received = 0;
      await for (final chunk in response.stream) {
        received += chunk.length;
        if (received >= cap) break;
      }
      stopwatch.stop();
      return (received, stopwatch.elapsedMilliseconds);
    } catch (_) {
      stopwatch.stop();
      return null;
    }
  }
}

/// Monitors the current network type for profile-aware decisions.
class NetworkStatusMonitor {
  final Connectivity _connectivity;
  int? _lastLatencyMs;

  NetworkStatusMonitor({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  void noteLatency(int? latencyMs) {
    if (latencyMs != null && latencyMs > 0) _lastLatencyMs = latencyMs;
  }

  NetworkProfile _poorOr(NetworkProfile profile) {
    final latency = _lastLatencyMs;
    if (latency == null || latency < 1500) return profile;
    // A saturating link is a "poor" network even on Wi-Fi.
    return NetworkProfile.poor;
  }

  Future<NetworkProfile> current() async {
    try {
      final results = await _connectivity.checkConnectivity();
      final result = results.isNotEmpty ? results.first : ConnectivityResult.none;
      return _poorOr(switch (result) {
        ConnectivityResult.wifi || ConnectivityResult.ethernet ||
        ConnectivityResult.vpn => NetworkProfile.wifi,
        ConnectivityResult.mobile || ConnectivityResult.bluetooth ||
        ConnectivityResult.other || ConnectivityResult.satellite =>
            NetworkProfile.mobile,
        ConnectivityResult.none => NetworkProfile.offline,
      });
    } catch (_) {
      return NetworkProfile.offline;
    }
  }
}

/// ---------------------------------------------------------------------------
/// Engine playback context (shown by the mini/full player)
/// ---------------------------------------------------------------------------

class EnginePlayContext {
  final String trackId;
  final SmartPlayMode mode;
  final String? providerId;
  final AudioQualityLevel quality;
  final AudioCharacteristics characteristics;
  final String? localPath;
  final bool offline;
  final DateTime startedAt;

  EnginePlayContext({
    required this.trackId,
    required this.mode,
    required this.quality,
    required this.characteristics,
    this.providerId,
    this.localPath,
    this.offline = false,
    DateTime? startedAt,
  }) : startedAt = startedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  EnginePlayContext copyWith({
    SmartPlayMode? mode,
    String? providerId,
    AudioQualityLevel? quality,
    AudioCharacteristics? characteristics,
    String? localPath,
    bool? offline,
  }) => EnginePlayContext(
    trackId: trackId,
    mode: mode ?? this.mode,
    providerId: providerId ?? this.providerId,
    quality: quality ?? this.quality,
    characteristics: characteristics ?? this.characteristics,
    localPath: localPath ?? this.localPath,
    offline: offline ?? this.offline,
    startedAt: startedAt,
  );

  String get sourceLabel => switch (mode) {
    SmartPlayMode.local => 'Local',
    SmartPlayMode.stream => providerId ?? 'Stream',
    SmartPlayMode.download ||
    SmartPlayMode.downloadAndPlay => 'Download',
    SmartPlayMode.unavailable => 'Unavailable',
  };
}

final enginePlayContextProvider =
    NotifierProvider<EnginePlayContextNotifier, EnginePlayContext?>(
      EnginePlayContextNotifier.new,
    );

class EnginePlayContextNotifier extends Notifier<EnginePlayContext?> {
  @override
  EnginePlayContext? build() => null;

  void publish(EnginePlayContext context) => state = context;

  void clear() => state = null;
}

/// ---------------------------------------------------------------------------
/// Playback result + failure reporting
/// ---------------------------------------------------------------------------

enum EnginePlayFailureKind { noLocalFile, streamFailed, downloadFailed }

class EnginePlayResult {
  final bool started;
  final SmartPlayDecision decision;
  final EnginePlayFailureKind? failure;
  final String? message;

  const EnginePlayResult({
    required this.started,
    required this.decision,
    this.failure,
    this.message,
  });
}

/// ---------------------------------------------------------------------------
/// Engine controller
/// ---------------------------------------------------------------------------

class StreamingEngineController {
  StreamingEngineController._(
    this._ref, {
    StreamPreflightValidator? validator,
    NetworkStatusMonitor? network,
  }) : _validator = validator ?? HttpStreamPreflightValidator(),
       _network = network ?? NetworkStatusMonitor();

  final Ref _ref;

  final ProviderHealthRegistry health = ProviderHealthRegistry();
  final EngineEventLog log = EngineEventLog();
  final BandwidthMonitor bandwidth = BandwidthMonitor();
  final StreamIntegrityLog integrity = StreamIntegrityLog();
  late final StreamSourceResolver _resolver = StreamSourceResolver(
    health: health,
  );
  late final StreamingSessionController _session = StreamingSessionController(
    resolver: _resolver,
    health: health,
    log: log,
  );
  final StreamPreflightValidator _validator;
  late final StreamPreloader _preloader = StreamPreloader(
    validator: _validator,
    log: log,
  );
  final NetworkStatusMonitor _network;
  final StreamHeadWarmer _headWarmer = StreamHeadWarmer();

  /// Adaptive-bitrate policy handed to the providers that publish a bitrate
  /// ladder. `balanced` leaves ~25% headroom so a jittery link keeps playing
  /// instead of stalling at the top rung.
  final AdaptiveBitrateSelector _bitrateSelector =
      const AdaptiveBitrateSelector();

  final Map<String, Track> _trackByMediaId = {};
  final List<String> _trackByMediaIdOrder = [];
  static const int _maxTrackedMediaIds = 256;

  /// The concrete stream each deferred queue item last resolved to. Failover
  /// for a deferred item must exclude *this* URL (the placeholder source in
  /// the queue never matches a candidate) and charge *this* provider.
  final Map<String, StreamDescriptor> _deferredSourceByMediaId = {};
  Timer? _downloadReadyTimer;
  bool _failureHookInstalled = false;
  bool _failedHookReentrant = false;

  SmartPlayEngine get smartPlay => const SmartPlayEngine();

  ProviderHealthRegistry get providerHealth => health;
  EngineEventLog get eventLog => log;
  StreamSessionState get sessionState => _session.state;
  StreamPreloader get preloader => _preloader;
  BandwidthMonitor get bandwidthMonitor => bandwidth;
  StreamIntegrityLog get integrityLog => integrity;

  /// The engine-owned track for a playing media id (used by "details" flows).
  Track? trackFor(String mediaId) => _trackByMediaId[mediaId];

  /// Registers a track that another surface (e.g. the media browse tree)
  /// enqueues as a deferred item, so [resolveDeferredSource] can resolve it
  /// with full metadata (ISRC, cover) instead of the placeholder's title only.
  void registerTrackForDeferred(Track track) =>
      _registerTrack(track.id, track);

  /// Registers a media id -> track mapping, bounded LRU-style so a long
  /// listening session cannot grow the registry without limit.
  void _registerTrack(String mediaId, Track track) {
    if (_trackByMediaId.containsKey(mediaId)) {
      _trackByMediaIdOrder
        ..remove(mediaId)
        ..add(mediaId);
      _trackByMediaId[mediaId] = track;
      return;
    }
    _trackByMediaId[mediaId] = track;
    _trackByMediaIdOrder.add(mediaId);
    while (_trackByMediaIdOrder.length > _maxTrackedMediaIds) {
      final evicted = _trackByMediaIdOrder.removeAt(0);
      _trackByMediaId.remove(evicted);
      _deferredSourceByMediaId.remove(evicted);
    }
  }

  /// Installs (once) the runtime playback-failure hook and the lazy
  /// deferred-source resolver in the audio service.
  void ensureFailureHook() {
    if (_failureHookInstalled) return;
    _failureHookInstalled = true;
    setPlaybackFailureListener((media, error) {
      unawaited(_onPlaybackFailure(media, error));
    });
    setDeferredStreamResolver((media) => resolveDeferredSource(media));
  }

  Future<NetworkProfile> currentNetworkProfile() async {
    // Offline mode forces local-only playback: report offline so the Smart
    // Play ladder never streams or schedules a network download, and so the
    // adapters are never consulted for candidates.
    if (_ref.read(engineSettingsProvider).offlineMode) {
      return NetworkProfile.offline;
    }
    return _network.current();
  }

  /// All streaming candidates for [track], in adapter order.
  Future<List<StreamDescriptor>> candidatesFor(Track track) async {
    final adapters = _ref.read(streamSourceAdaptersProvider);
    _publishAdaptiveBitrate(adapters);
    final result = <StreamDescriptor>[];
    for (final adapter in adapters) {
      try {
        final candidates = await adapter.candidatesFor(track);
        result.addAll(candidates);
      } catch (e) {
        log.add(
          EngineEvent.warning(
            'adapter',
            '${adapter.id} failed to produce candidates: $e',
          ),
        );
      }
    }
    return result;
  }

  /// Looks up an already-downloaded *or locally imported* copy so Smart Play
  /// can go local. Verifies the file still exists before returning it.
  /// Feeds the engine's live bandwidth estimate into the multi-provider
  /// service so ladder-based providers pick a rung the link can sustain.
  ///
  /// Only runs when a ladder-capable adapter is actually registered: reading
  /// the provider otherwise would spin up a real resolver (YouTube client +
  /// HTTP client) for queues that never use it.
  void _publishAdaptiveBitrate(List<StreamSourceAdapter> adapters) {
    final usesLadder = adapters.any(
      (adapter) => adapter is MultiProviderStreamAdapter,
    );
    if (!usesLadder) return;
    final service = _ref.read(multiProviderStreamServiceProvider);
    service.configureAdaptiveBitrate(
      selector: _bitrateSelector,
      bandwidthProvider: () => bandwidth.smoothedBytesPerSecond ?? 0,
    );
  }

  /// Library + download-history lookup for a whole queue. A broken local
  /// store must not block playback: on failure every track is treated as
  /// not downloaded, so the queue still streams.
  Future<List<String?>> _resolveLocalPathsOrStream(List<Track> tracks) async {
    try {
      return await _ref
          .read(playbackProvider.notifier)
          .resolveTrackFilePaths(tracks);
    } catch (e) {
      log.add(
        EngineEvent.warning('local', 'Queue library lookup failed: $e'),
      );
      return List<String?>.filled(tracks.length, null);
    }
  }

  Future<String?> downloadedPathFor(Track track) async {
    try {
      final localLibrary = await LibraryDatabase.instance.findExisting(
        isrc: track.isrc,
        trackName: track.name,
        artistName: track.artistName,
      );
      final localPath = localLibrary?['filePath']?.toString().trim() ?? '';
      if (localPath.isNotEmpty && await fileExists(localPath)) {
        return localPath;
      }
    } catch (e) {
      log.add(
        EngineEvent.warning('local', 'Library lookup failed: $e'),
      );
    }
    try {
      final item = await _ref
          .read(downloadHistoryProvider.notifier)
          .findExistingTrackAsync(
            HistoryLookupRequest(
              spotifyId: track.id,
              isrc: track.isrc,
              trackName: track.name,
              artistName: track.artistName,
            ),
          );
      final path = item?.filePath.trim() ?? '';
      if (path.isEmpty) return null;
      return await fileExists(path) ? path : null;
    } catch (e) {
      log.add(EngineEvent.warning('local', 'Download lookup failed: $e'));
      return null;
    }
  }

  /// Resolves a deferred queue item (see [PlayableMedia.deferredStreamUriFor])
  /// to a concrete local path or fresh stream URL at play time. Returns null
  /// when the track cannot be resolved; the player then stops gracefully.
  Future<String?> resolveDeferredSource(PlayableMedia media) async {
    ensureFailureHook();
    final known = _trackByMediaId[media.id];
    final track =
        known ??
        Track(
          id: media.id,
          name: media.title,
          artistName: media.artist,
          albumName: media.album,
          coverUrl: media.artUri,
          duration: media.duration?.inSeconds ?? 0,
          source: 'app',
        );
    if (known == null) {
      _registerTrack(media.id, track);
    }
    final decision = await decide(track);
    switch (decision.mode) {
      case SmartPlayMode.local:
        _deferredSourceByMediaId.remove(media.id);
        musicPlayerHandler?.noteDeferredSourceExpiry(media.id, null);
        final path = await downloadedPathFor(track);
        if (path == null) {
          log.add(
            EngineEvent.warning(
              'queue',
              'Deferred item ${track.name}: local file disappeared',
            ),
          );
          return null;
        }
        _ref.read(enginePlayContextProvider.notifier).publish(
              _contextFor(
                track,
                decision,
                offline: decision.networkProfile.isOffline,
              ).copyWith(localPath: path),
            );
        return path;
      case SmartPlayMode.stream:
        final source = await resolveStreamSource(track, decision);
        if (source == null) {
          log.add(
            EngineEvent.warning(
              'queue',
              'Deferred item ${track.name}: no stream source resolved',
            ),
          );
          return null;
        }
        _deferredSourceByMediaId[media.id] = source;
        musicPlayerHandler?.noteDeferredSourceExpiry(
          media.id,
          source.expiresAt,
        );
        _session.markSuccess(source);
        _ref.read(enginePlayContextProvider.notifier).publish(
              EnginePlayContext(
                trackId: track.id,
                mode: SmartPlayMode.stream,
                providerId: source.providerId,
                quality: source.quality,
                characteristics: source.characteristics,
                offline: false,
                startedAt: DateTime.now(),
              ),
            );
        return source.uri;
      case SmartPlayMode.download:
      case SmartPlayMode.downloadAndPlay:
        // A queued download cannot start playback from the resolver (it must
        // complete first); be honest instead of blocking the queue.
        log.add(
          EngineEvent.info(
            'queue',
            'Deferred item ${track.name} resolves to download - '
            'queueing download and stopping queue playback',
          ),
        );
        await _startDownload(track, decision);
        return null;
      case SmartPlayMode.unavailable:
        log.add(
          EngineEvent.warning(
            'queue',
            'Deferred item ${track.name} unavailable: '
            '${decision.reason ?? ''}',
          ),
        );
        return null;
    }
  }

  /// Builds the Smart Play decision for [track].
  Future<SmartPlayDecision> decide(
    Track track, {
    String? localPath,
  }) async {
    final settings = _ref.read(engineSettingsProvider);
    final network = await currentNetworkProfile();
    var effectiveLocalPath = localPath ?? await downloadedPathFor(track);
    // Cache-first (Feature 7): a verified cached copy plays like a local
    // file — instant start, works offline, no network round-trip.
    if (effectiveLocalPath == null || effectiveLocalPath.isEmpty) {
      try {
        final trackKey = CanonicalTrackKey.fromInput(
          TrackIdentityInput.fromTrack(track),
        ).stableId;
        final hit = await _ref
            .read(streamingCacheManagerProvider)
            .lookupPlayable(trackKey);
        if (hit != null) {
          effectiveLocalPath = hit.filePath;
        }
      } catch (_) {
        // Cache lookup must never block the decision ladder.
      }
    }
    final candidates = shouldAttemptStreamResolution(
          streamingEnabled: settings.streamingEnabled,
          network: network,
        )
        ? await candidatesFor(track)
        : const <StreamDescriptor>[];
    return smartPlay.decide(
      SmartPlayInput(
        trackId: track.id,
        title: track.name,
        artist: track.artistName,
        album: track.albumName,
        isrc: track.isrc,
        durationSeconds: track.duration,
        localPath: effectiveLocalPath,
        streamCandidates: candidates,
        downloadAvailable: settings.streamingEnabled,
        streamingEnabled: settings.streamingEnabled,
        networkProfile: network,
        modePreference: settings.playbackMode,
        requestQuality: settings.qualityPolicy.levelFor(network),
        localFirst: settings.localFirst,
      ),
    );
  }

  /// Full "press Play" path. Never throws for user-facing conditions — every
  /// dead end becomes an [EnginePlayResult] with a readable reason.
  Future<EnginePlayResult> playTrack(
    Track track, {
    String? localPath,
  }) async {
    ensureFailureHook();
    final decision = await decide(track, localPath: localPath);
    _ref.read(enginePlayContextProvider.notifier).publish(
      _contextFor(track, decision, offline: decision.networkProfile.isOffline),
    );

    if (decision.mode == SmartPlayMode.local) {
      return _startLocal(track, decision);
    }
    if (decision.mode == SmartPlayMode.stream) {
      return _startStream(track, decision);
    }
    if (decision.mode == SmartPlayMode.downloadAndPlay) {
      return _startDownloadAndPlay(track, decision);
    }
    if (decision.mode == SmartPlayMode.download) {
      return _startDownload(track, decision);
    }
    return EnginePlayResult(
      started: false,
      decision: decision,
      failure: EnginePlayFailureKind.noLocalFile,
      message: decision.steps.isEmpty
          ? 'No source available'
          : 'No source available (${decision.steps.last.detail})',
    );
  }

  /// Starts a full queue with Smart Play applied per track. The first track
  /// runs the complete decision ladder (local -> stream -> download & play);
  /// the remainder are queued as either direct local items or deferred engine
  /// items whose source is resolved lazily when playback reaches them, so a
  /// long queue never pre-resolves dozens of provider URLs up front.
  ///
  /// [resolvedPaths] may carry pre-resolved local file paths aligned with
  /// [tracks] as passed (before [startIndex] rotation) - e.g. the batch
  /// lookup performed by the playback provider. When omitted the engine
  /// resolves paths itself.
  Future<EnginePlayResult> playTracks(
    List<Track> tracks, {
    int startIndex = 0,
    String? localPath,
    List<String?>? resolvedPaths,
  }) async {
    ensureFailureHook();
    if (tracks.isEmpty) {
      return EnginePlayResult(
        started: false,
        decision: SmartPlayDecision.unavailable(
          SmartPlayInput(trackId: '', title: '', artist: ''),
          const [],
          'Empty queue',
        ),
      );
    }
    final safeStart = startIndex.clamp(0, tracks.length - 1);
    final ordered = safeStart == 0
        ? List<Track>.of(tracks, growable: false)
        : <Track>[
            ...tracks.sublist(safeStart),
            ...tracks.sublist(0, safeStart),
          ];
    final hasPaths = resolvedPaths != null &&
        resolvedPaths.length == tracks.length;
    var paths = hasPaths
        ? List<String?>.of(resolvedPaths, growable: false)
        : await _resolveLocalPathsOrStream(ordered);
    if (safeStart != 0 && hasPaths) {
      paths = <String?>[
        ...paths.sublist(safeStart),
        ...paths.sublist(0, safeStart),
      ];
    }

    final first = ordered.first;
    final firstResult = await playTrack(
      first,
      localPath: localPath ?? paths.first,
    );

    if (!firstResult.started &&
        firstResult.decision.mode != SmartPlayMode.downloadAndPlay &&
        firstResult.decision.mode != SmartPlayMode.download) {
      return firstResult;
    }

    // Queue the remainder after the started item. Local copies play directly;
    // everything else is deferred to play time (a fresh Smart Play decision
    // per track: a file downloaded in the meantime is picked up, and stream
    // URLs are never stale).
    final remainder = <PlayableMedia>[];
    for (var i = 1; i < ordered.length; i++) {
      final track = ordered[i];
      _registerTrack(track.id, track);
      final path = i < paths.length ? paths[i] : null;
      if (path != null && path.trim().isNotEmpty) {
        remainder.add(_localMediaFor(track, path));
      } else {
        remainder.add(_deferredMediaFor(track));
      }
    }
    if (remainder.isNotEmpty) {
      final controller = _ref.read(musicPlayerControllerProvider);
      unawaited(controller.addAllToQueue(remainder));
    }

    // Preload the next tracks so the natural next-track switch is instant.
    final upcoming = ordered
        .skip(1)
        .take(_ref.read(engineSettingsProvider).preloadWindow)
        .toList(growable: false);
    unawaited(_preloadUpcoming(upcoming));
    return firstResult;
  }

  PlayableMedia _localMediaFor(Track track, String path) => PlayableMedia(
    id: path,
    source: path,
    title: track.name.isEmpty ? 'Unknown title' : track.name,
    artist: track.artistName.isEmpty ? 'Unknown artist' : track.artistName,
    album: track.albumName,
    artUri: normalizeRemoteHttpUrl(track.coverUrl),
    duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
    explicit: track.isExplicit,
    playbackMode: 'local',
  );

  PlayableMedia _deferredMediaFor(Track track) => PlayableMedia(
    id: track.id,
    source: PlayableMedia.deferredStreamUriFor(track.id),
    title: track.name.isEmpty ? 'Unknown title' : track.name,
    artist: track.artistName.isEmpty ? 'Unknown artist' : track.artistName,
    album: track.albumName,
    artUri: normalizeRemoteHttpUrl(track.coverUrl),
    duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
    explicit: track.isExplicit,
    playbackMode: 'stream',
    sourceLabel: 'Smart Play',
  );

  Future<void> _preloadUpcoming(List<Track> upcoming) async {
    try {
      final settings = _ref.read(engineSettingsProvider);
      if (!settings.preloadNextTrack || upcoming.isEmpty) return;
      final profile = await currentNetworkProfile();
      final policy = StreamBufferPolicy.auto.forProfile(profile);
      const planner = AdaptiveBufferPlanner();
      for (final track in upcoming) {
        final candidates = await candidatesFor(track);
        if (candidates.isEmpty) continue;
        final ranked = _resolver.candidates(
          candidates,
          requested: settings.qualityPolicy.levelFor(profile),
        );
        if (ranked.isEmpty) continue;
        final selected = ranked.first;
        // Preflight the URL (validity + latency) as before.
        _preloader.plan(
          [track.id],
          window: 1,
          resolver: (id) => selected,
        );
        // Adaptive buffering: on healthy links pull just enough ahead to
        // absorb jitter; on poor links open a deeper low-bandwidth buffer
        // window.
        final decision = planner.plan(
          profile: profile,
          policy: policy,
          bitrateKbps: selected.characteristics.bitrateKbps,
          measuredBytesPerSecond: bandwidth.smoothedBytesPerSecond,
          preloadEnabled: settings.preloadNextTrack,
          lowBandwidthBufferSeconds: settings.lowBandwidthBufferSeconds,
          prebufferHeadBytes: settings.prebufferHeadBytesKb * 1024,
        );
        if (decision.headBytes > 0 &&
            _headWarmer.permittedFor(
              selected,
              bufferPreviewStreams: settings.bufferPreviewStreams,
            )) {
          unawaited(_warmHeadAndRecord(selected, decision.headBytes));
        }
      }
    } catch (e) {
      // Best-effort lookahead: never let a stale preload (e.g. the owning
      // provider was disposed after an async gap, or the network died while
      // probing candidates) surface as an unhandled async error.
      log.add(EngineEvent.warning('buffer', 'Preload skipped: $e'));
    }
  }

  Future<void> _warmHeadAndRecord(StreamDescriptor source, int maxBytes) async {
    try {
      final result = await _headWarmer.warmHead(source, maxBytes);
      if (result == null) return;
      final bytes = result.$1;
      final elapsedMs = result.$2;
      if (bytes <= 0) return;
      final bps = elapsedMs > 0
          ? ((bytes / (elapsedMs / 1000)).round()).clamp(0, 1 << 40)
          : 0;
      bandwidth.record(
        BandwidthSample(
          at: DateTime.now(),
          bytes: bytes,
          latencyMs: elapsedMs,
          bytesPerSecond: bps,
          providerId: source.providerId,
        ),
      );
      log.add(
        EngineEvent.info(
          'buffer',
          'Pre-buffered ${formatBandwidth(bps)} head for next track '
          '(${source.providerId})',
        ),
      );
    } catch (e) {
      // Background probe: a failure must not become an unhandled async error.
      log.add(EngineEvent.warning('buffer', 'Head warm-up failed: $e'));
    }
  }

  EnginePlayContext _contextFor(
    Track track,
    SmartPlayDecision decision, {
    required bool offline,
  }) => EnginePlayContext(
    trackId: track.id,
    mode: decision.mode,
    providerId: decision.source?.providerId,
    quality: decision.actualQuality,
    characteristics: decision.source?.characteristics ??
        AudioCharacteristics.fromTrack(track),
    offline: offline,
    startedAt: DateTime.now(),
  );

  Future<EnginePlayResult> _startLocal(
    Track track,
    SmartPlayDecision decision,
  ) async {
    final settings = _ref.read(engineSettingsProvider);
    if (!settings.streamingEnabled && decision.mode != SmartPlayMode.local) {
      // Should not happen (decision already honors the switch), but guard it.
      return EnginePlayResult(
        started: false,
        decision: decision,
        failure: EnginePlayFailureKind.noLocalFile,
        message: 'Streaming disabled and no local file',
      );
    }
    try {
      final localPath = await downloadedPathFor(track);
      if (localPath == null) {
        return EnginePlayResult(
          started: false,
          decision: decision,
          failure: EnginePlayFailureKind.noLocalFile,
          message: 'Local file no longer exists',
        );
      }
      await _ref.read(playbackProvider.notifier).playLocalPath(
        path: localPath,
        title: track.name,
        artist: track.artistName,
        album: track.albumName,
        coverUrl: track.coverUrl ?? '',
        track: track,
      );
      _ref.read(enginePlayContextProvider.notifier).publish(
        EnginePlayContext(
          trackId: track.id,
          mode: SmartPlayMode.local,
          quality: decision.actualQuality,
          characteristics: decision.source?.characteristics ??
              AudioCharacteristics.fromTrack(track),
          localPath: localPath,
          offline: decision.networkProfile.isOffline,
          startedAt: DateTime.now(),
        ),
      );
      log.add(EngineEvent.info('play', 'Local: ${track.name} — $localPath'));
      return EnginePlayResult(started: true, decision: decision);
    } catch (e) {
      log.add(EngineEvent.error('play', 'Local playback failed: $e'));
      return EnginePlayResult(
        started: false,
        decision: decision,
        failure: EnginePlayFailureKind.noLocalFile,
        message: e.toString(),
      );
    }
  }

  Future<EnginePlayResult> _startStream(
    Track track,
    SmartPlayDecision decision,
  ) async {
    final source = await resolveStreamSource(track, decision);
    if (source == null) {
      final lastFailure = _session.state.lastFailure;
      return EnginePlayResult(
        started: false,
        decision: decision,
        failure: EnginePlayFailureKind.streamFailed,
        message: lastFailure?.toString() ?? 'No usable stream source',
      );
    }
    return _startPlayback(track, decision, source);
  }

  /// Resolves + preflights the stream source for [decision], walking the
  /// ranked provider chain on preflight failures (bounded by the configured
  /// attempt budget). Returns the validated source, or null when the chain is
  /// exhausted.
  Future<StreamDescriptor?> resolveStreamSource(
    Track track,
    SmartPlayDecision decision,
  ) async {
    final initial = decision.source;
    if (initial == null) return null;

    var selected = initial;
    var outcome = _session.resolve(
      [selected],
      requested: decision.requestedQuality,
    );
    if (outcome.resolved == null) {
      // The Smart Play pick may be expired or health-filtered right now;
      // consult the full ranked candidate chain before giving up.
      final candidates = await candidatesFor(track);
      outcome = _session.resolve(
        candidates,
        requested: decision.requestedQuality,
      );
      if (outcome.resolved == null) {
        return null;
      }
    }
    selected = outcome.resolved!;

    // URL-expiry handling: when the policy flags the source as near expiry,
    // re-query the adapters for a fresh URL before playing. Bounded to a
    // single refresh round so a provider that keeps issuing stale URLs cannot
    // stall playback forever.
    if (outcome.needsUrlRefresh &&
        _ref.read(engineSettingsProvider).autoRefreshExpiredUrls) {
      log.add(
        EngineEvent.info(
          'stream',
          'Refreshing expired/near-expiry URL for ${track.name}',
        ),
      );
      final refreshed = await candidatesFor(track);
      final ranked = _resolver.candidates(
        refreshed,
        requested: decision.requestedQuality,
      );
      if (ranked.isNotEmpty) {
        selected = ranked.first;
        outcome = _session.resolve(
          [selected],
          requested: decision.requestedQuality,
        );
        if (outcome.resolved != null) {
          selected = outcome.resolved!;
        }
      }
    }
    if (_session.state.phase == StreamPhase.refreshingUrl) {
      // Refresh was disabled or produced no fresher candidate; proceed with
      // the best source we have so the user is never stuck on a spinner.
      _session.proceedWithoutRefresh(selected);
    }

    // Preflight with bounded provider failover: every attempt records health
    // and integrity; URIs already tried are never re-selected.
    final tried = <String>{};
    var attempt = 0;
    final maxAttempts = _maxAttempts();
    while (true) {
      attempt += 1;
      tried.add(selected.uri);
      if (await _preflightSource(selected)) {
        return selected;
      }
      if (attempt >= maxAttempts) {
        return null;
      }
      final failure = StreamFailure(
        kind: StreamFailureKind.network,
        providerId: selected.providerId,
        attempt: attempt,
        message: 'preflight failed',
      );
      final candidates = await candidatesFor(track);
      final ranked = _resolver
          .candidates(candidates, requested: decision.requestedQuality)
          .where((candidate) => !tried.contains(candidate.uri))
          .toList(growable: false);
      final next = _session.onFailure(failure, selected, ranked);
      if (next == null) {
        return null;
      }
      selected = next;
    }
  }

  /// Single-source preflight: records latency, bandwidth and stream-integrity
  /// results. Provider *health* is recorded by the session transitions
  /// (`onFailure` / `markSuccess`) so each attempt is counted exactly once.
  /// Returns whether the source is playable.
  Future<bool> _preflightSource(StreamDescriptor source) async {
    final preflight = await _validator.validate(source);
    _network.noteLatency(preflight.latencyMs);
    bandwidth.recordPreflight(
      latencyMs: preflight.latencyMs,
      contentLengthBytes: preflight.contentLengthBytes,
      providerId: source.providerId,
    );
    if (!preflight.ok) {
      integrity.add(
        StreamIntegrityRecord.failure(
          providerId: source.providerId,
          uri: source.uri,
          category: 'preflight',
          message: preflight.error ?? 'Preflight failed',
        ),
      );
      log.add(
        EngineEvent.error(
          'stream',
          'Preflight failed (${source.providerId}): ${preflight.error}',
        ),
      );
      return false;
    }
    integrity.add(
      StreamIntegrityRecord.success(
        providerId: source.providerId,
        uri: source.uri,
        category: 'preflight',
        message: 'Preflight ok',
      ),
    );
    return true;
  }

  /// Starts playback of an already-validated [source] through the shared
  /// audio_service player.
  Future<EnginePlayResult> _startPlayback(
    Track track,
    SmartPlayDecision decision,
    StreamDescriptor source,
  ) async {
    final media = _playableFor(track, source);
    _registerTrack(media.id, track);
    final controller = _ref.read(musicPlayerControllerProvider);
    try {
      // Progressive URL playback: the audio player streams in real time; the
      // engine only preflight-validates and owns failover.
      await controller.playAll([media]);
      _session.markSuccess(source);
      _ref.read(enginePlayContextProvider.notifier).publish(
        EnginePlayContext(
          trackId: track.id,
          mode: SmartPlayMode.stream,
          providerId: source.providerId,
          quality: source.quality,
          characteristics: source.characteristics,
          offline: false,
          startedAt: DateTime.now(),
        ),
      );
      // Cache-while-listening (Feature 7): when the provider's terms and
      // the user's cache toggle allow it, the same bytes are fetched to
      // the stream cache in the background — playback never waits for it,
      // and the next play of this track starts from the verified copy.
      unawaited(_maybeCacheWhileListening(track, source));
      return EnginePlayResult(
        started: true,
        decision: decision.copyWithSource(source),
      );
    } catch (e) {
      return EnginePlayResult(
        started: false,
        decision: decision,
        failure: EnginePlayFailureKind.streamFailed,
        message: e.toString(),
      );
    }
  }

  /// Background cache fetch for a playing stream. Never throws onto the
  /// playback path; a failed/cancelled fetch only means "no offline copy
  /// this time".
  Future<void> _maybeCacheWhileListening(
    Track track,
    StreamDescriptor source,
  ) async {
    if (!source.cachePermitted) return;
    if (!_ref.read(engineSettingsProvider).cacheStreams) return;
    if (source.isLocal) return;
    try {
      final manager = _ref.read(streamingCacheManagerProvider);
      final trackKey = CanonicalTrackKey.fromInput(
        TrackIdentityInput.fromTrack(track),
      ).stableId;
      final result = await manager.startFetch(
        CacheFetchRequest(
          trackKey: trackKey,
          title: track.name,
          artist: track.artistName,
          url: source.uri,
          durationMs: track.duration * 1000,
          sourceUrl: source.uri,
        ),
      );
      if (result.status != CacheFetchStatus.completed ||
          result.entry == null) {
        return;
      }
      log.add(
        EngineEvent.info(
          'cache',
          'Cached "${track.name}" '
          '(${result.entry!.bytes} bytes, ${result.entry!.audioFormat.label})',
        ),
      );
      // LRU budget enforcement follows the existing engine cache setting.
      final settings = _ref.read(engineSettingsProvider);
      if (settings.autoCleanCache && settings.maxCacheSizeMb > 0) {
        await _ref
            .read(cacheCleanupWorkerProvider)
            .run(
              planner: CacheCleanupPlanner(
                budgetBytes: streamCacheBudgetBytes(settings.maxCacheSizeMb),
              ),
            );
      }
      // NOTE: the live local swap for single-track plays is owned by the
      // hybrid playback manager (Feature 3); queue playback benefits on
      // the next play of this track, which the cache-first lookup serves.
    } catch (_) {
      // Cache failures are invisible by design.
    }
  }

  Future<EnginePlayResult> _startDownloadAndPlay(
    Track track,
    SmartPlayDecision decision,
  ) async {
    final result = await _startDownload(track, decision);
    if (result.started || (result.failure == null && !result.started)) {
      // Queued successfully: watch completion and start local playback.
      _watchDownloadAndPlay(track);
    }
    return result;
  }

  /// Queues [track] for download through the existing queue subsystem.
  Future<EnginePlayResult> _startDownload(
    Track track,
    SmartPlayDecision decision,
  ) async {
    final settings = _ref.read(settingsProvider);
    final service = track.source?.trim().isNotEmpty == true
        ? track.source!
        : settings.defaultService;
    try {
      _ref
          .read(downloadQueueProvider.notifier)
          .addMultipleToQueue([track], service);
    } catch (e) {
      return EnginePlayResult(
        started: false,
        decision: decision,
        failure: EnginePlayFailureKind.downloadFailed,
        message: e.toString(),
      );
    }
    log.add(EngineEvent.info('download', 'Queued ${track.name} for download'));
    return EnginePlayResult(started: false, decision: decision);
  }

  /// Watches the download queue for the track's completion, then starts local
  /// playback automatically (the "Download & Play" branch of Smart Play).
  void _watchDownloadAndPlay(Track track) {
    _downloadReadyTimer?.cancel();
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    _downloadReadyTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (DateTime.now().isAfter(deadline)) {
        timer.cancel();
        log.add(
          EngineEvent.warning('download', 'Timed out waiting for ${track.name}'),
        );
        return;
      }
      final state = _ref.read(downloadQueueProvider);
      final completed = state.items.any(
        (item) =>
            item.track.id == track.id &&
            item.status == DownloadStatus.completed,
      );
      if (!completed) return;
      timer.cancel();
      log.add(
        EngineEvent.info('download', 'Download completed — starting ${track.name}'),
      );
      unawaited(_startLocalAfterDownload(track));
    });
  }

  Future<void> _startLocalAfterDownload(Track track) async {
    await Future<void>.delayed(const Duration(milliseconds: 600));
    final path = await downloadedPathFor(track);
    if (path == null) {
      log.add(EngineEvent.warning('download', 'Newly downloaded file not found'));
      return;
    }
    final decision = await decide(track, localPath: path);
    await _startLocal(track, decision);
  }

  PlayableMedia _playableFor(Track track, StreamDescriptor source) {
    return PlayableMedia(
      id: track.id,
      source: source.uri,
      title: track.name.isEmpty ? 'Unknown title' : track.name,
      artist: track.artistName.isEmpty ? 'Unknown artist' : track.artistName,
      album: track.albumName,
      artUri: normalizeRemoteHttpUrl(track.coverUrl),
      duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
      bitDepth: source.characteristics.bitDepth,
      sampleRate: source.characteristics.sampleRateHz,
      bitrate: source.characteristics.bitrateKbps,
      format: source.characteristics.codec,
      playbackMode: 'stream',
      qualityLabel: source.characteristics.compactLabel,
      sourceLabel: source.providerId,
      providerId: source.providerId,
      explicit: track.isExplicit,
      trackGainDb: source.characteristics.trackGainDb,
      albumGainDb: source.characteristics.albumGainDb,
      trackPeak: source.characteristics.trackPeak,
      expiresAt: source.expiresAt,
    );
  }

  Future<void> _onPlaybackFailure(PlayableMedia media, Object error) async {
    if (_failedHookReentrant) return;
    _failedHookReentrant = true;
    try {
      await _handlePlaybackFailure(media, error);
    } catch (hookError) {
      // The failover path must never surface an unhandled async error (e.g.
      // provider container already disposed during app teardown).
      log.add(
        EngineEvent.error('stream', 'Failover hook error: $hookError'),
      );
    } finally {
      _failedHookReentrant = false;
    }
  }

  Future<void> _handlePlaybackFailure(PlayableMedia media, Object error) async {
    {
      final track = _trackByMediaId[media.id];
      if (track == null) return; // Not engine-owned; the player already handled it.
      final proactiveRefresh = error is StreamUrlExpiringSignal;
      // A deferred queue item failed through the stream it *resolved to*; the
      // placeholder source in the queue carries neither URL nor provider.
      final deferredSource = media.isDeferredStream
          ? _deferredSourceByMediaId[media.id]
          : null;
      final failedUri = deferredSource?.uri ?? media.source;
      final providerId =
          deferredSource?.providerId ??
          media.providerId ??
          media.sourceLabel ??
          'unknown';
      if (proactiveRefresh) {
        log.add(
          EngineEvent.info(
            'stream',
            'Refreshing expiring URL for ${track.name} ($providerId)',
          ),
        );
      } else {
        log.add(
          EngineEvent.error(
            'stream',
            'Playback failed for ${track.name} (attempt ${_session.state.attempt + 1})',
          ),
        );
        integrity.add(
          StreamIntegrityRecord.failure(
            providerId: providerId,
            uri: failedUri,
            category: 'playback',
            message: error.toString(),
          ),
        );
      }
      final failure = StreamFailure(
        kind: proactiveRefresh ? StreamFailureKind.urlExpired : _classify(error),
        providerId: providerId,
        attempt: _session.state.attempt + 1,
        message: error.toString(),
      );
      // The dead URL must not be served again from the resolver cache: every
      // adapter is asked for a *fresh* candidate set.
      _invalidateResolvedStreams(track);
      final candidates = await candidatesFor(track);
      final ranked = _resolver.candidates(
        candidates,
        requested: _ref
            .read(engineSettingsProvider)
            .qualityPolicy
            .levelFor(await currentNetworkProfile()),
      );
      // Exclude the source that just failed.
      final alternatives = ranked
          .where((candidate) => candidate.uri != failedUri)
          .toList(growable: false);
      StreamDescriptor? next;
      if (proactiveRefresh) {
        // Nothing failed yet: prefer the same provider's fresh URL, do not
        // charge the provider's health, and fall through the ranking only
        // when it produced nothing.
        final sameProvider = alternatives
            .where((candidate) => candidate.providerId == providerId)
            .toList(growable: false);
        next = sameProvider.isNotEmpty
            ? sameProvider.first
            : (alternatives.isNotEmpty ? alternatives.first : null);
        if (next == null) {
          log.add(
            EngineEvent.warning(
              'stream',
              'No fresh URL for ${track.name}; keeping current source',
            ),
          );
          return;
        }
      } else {
        next = _session.onFailure(
          failure,
          deferredSource ?? _descriptorFromMedia(media),
          alternatives,
        );
      }
      if (next == null) {
        log.add(
          EngineEvent.error(
            'stream',
            'No fallback source for ${track.name}',
          ),
        );
        // The chain is exhausted for *this* track; do not strand the queue
        // on a stopped item when there is a next one to play.
        await _advancePastUnplayable(track);
        return;
      }
      // Retry once after a short backoff even for the same source, then give
      // up — the player has already stopped, so the user sees a fresh attempt.
      // A proactive refresh is not a failure: swap immediately, no backoff.
      final delay = proactiveRefresh
          ? null
          : _session.retryDelay(failure, _maxAttempts());
      if (delay != null) {
        await Future<void>.delayed(delay);
      }
      final handler = musicPlayerHandler;
      // Capture where the dead source stopped so failover resumes seamlessly
      // at the same position ($t) instead of restarting from 0:00.
      final resumeAt = handler == null
          ? Duration.zero
          : (await handler.currentPlaybackPosition() ?? Duration.zero);
      if (handler == null) {
        final fallbackDecision = await decide(track);
        _deferredSourceByMediaId.remove(media.id);
        if (await _preflightSource(next)) {
          await _startPlayback(track, fallbackDecision, next);
        }
        return;
      }
      integrity.add(
        StreamIntegrityRecord.fallback(
          providerId: next.providerId,
          uri: next.uri,
          category: proactiveRefresh ? 'refresh' : 'fallback',
          message:
              'Switched from $providerId to '
              '${next.providerId} at ${resumeAt.inSeconds}s',
        ),
      );
      var chosen = next;
      if (!await _preflightSource(chosen)) {
        // The replacement is dead on arrival: charge it and try the chain
        // once more (bounded by the attempt budget through onFailure).
        final failedUri = chosen.uri;
        final second = _session.onFailure(
          StreamFailure(
            kind: StreamFailureKind.network,
            providerId: chosen.providerId,
            attempt: _session.state.attempt + 1,
            message: 'preflight failed',
          ),
          chosen,
          alternatives
              .where((candidate) => candidate.uri != failedUri)
              .toList(growable: false),
        );
        if (second == null || !await _preflightSource(second)) {
          if (!proactiveRefresh) await _advancePastUnplayable(track);
          return;
        }
        chosen = second;
      }
      // The queue item becomes a concrete stream item from here on.
      _deferredSourceByMediaId.remove(media.id);
      handler.noteDeferredSourceExpiry(media.id, null);
      await handler.replaceCurrentAndPlay(
        _playableFor(track, chosen),
        resumeAt: resumeAt,
      );
      _session.markSuccess(chosen);
      _ref.read(enginePlayContextProvider.notifier).publish(
        EnginePlayContext(
          trackId: track.id,
          mode: SmartPlayMode.stream,
          providerId: chosen.providerId,
          quality: chosen.quality,
          characteristics: chosen.characteristics,
          offline: false,
          startedAt: DateTime.now(),
        ),
      );
    }
  }

  /// Drops the resolver-side cache entries for [track] so the next candidate
  /// query goes back to the providers instead of replaying a URL that just
  /// failed (or is about to expire).
  void _invalidateResolvedStreams(Track track) {
    final adapters = _ref.read(streamSourceAdaptersProvider);
    final usesResolver = adapters.any(
      (adapter) => adapter is MultiProviderStreamAdapter,
    );
    if (!usesResolver) return;
    try {
      _ref
          .read(multiProviderStreamServiceProvider)
          .invalidate(StreamTrackRequest.fromTrack(track));
    } catch (e) {
      log.add(EngineEvent.warning('stream', 'Cache invalidation failed: $e'));
    }
  }

  /// When every source for the current track is exhausted, keep the listening
  /// session alive by moving on to the next queue item (if any). The player
  /// is already stopped at this point, so this never interrupts audio.
  Future<void> _advancePastUnplayable(Track track) async {
    final handler = musicPlayerHandler;
    if (handler == null) return;
    final queue = handler.queue.value;
    final item = handler.mediaItem.value;
    if (item == null || queue.length < 2) return;
    final index = queue.indexWhere((entry) => entry.id == item.id);
    if (index < 0 || index >= queue.length - 1) return;
    log.add(
      EngineEvent.warning(
        'queue',
        'Skipping ${track.name}: no playable source; advancing queue',
      ),
    );
    try {
      await handler.skipToNext();
    } catch (e) {
      log.add(EngineEvent.warning('queue', 'Auto-advance failed: $e'));
    }
  }

  StreamDescriptor _descriptorFromMedia(PlayableMedia media) => StreamDescriptor(
    id: media.id,
    providerId: media.providerId ?? media.sourceLabel ?? 'unknown',
    kind: StreamSourceKind.httpStream,
    uri: media.source,
    quality: AudioQualityLevel.fromLabel(media.qualityLabel),
  );

  static StreamFailureKind _classify(Object error) {
    final text = error.toString().toLowerCase();
    if (text.contains('timeout')) return StreamFailureKind.timeout;
    if (text.contains('expired') || text.contains('403')) {
      return StreamFailureKind.urlExpired;
    }
    if (text.contains('404') ||
        text.contains('cannot') ||
        text.contains('failed')) {
      return StreamFailureKind.network;
    }
    return StreamFailureKind.network;
  }

  int _maxAttempts() => _ref.read(engineSettingsProvider).maxStreamAttempts;

  /// Persists an engine-level savepoint (queue + modes + position) in the app
  /// state database so the diagnostics/recovery flows have a second,
  /// engine-specific record beyond the player's own.
  Future<void> savePlaybackSavepoint({
    required List<SessionQueueEntry> entries,
    required int index,
    required Duration position,
    required bool shuffle,
    required SessionRepeatMode repeat,
    required double volume,
    required double playbackRate,
  }) async {
    if (!_ref.read(engineSettingsProvider).saveEngineSavepoints) return;
    final savepoint = PlaybackSavepoint(
      entries: entries,
      currentIndex: index,
      positionMs: position.inMilliseconds,
      shuffle: shuffle ? SessionShuffleMode.on : SessionShuffleMode.off,
      repeat: repeat,
      volume: volume,
      playbackRate: playbackRate,
    );
    await _ref
        .read(engineSavepointProvider.notifier)
        .save(savepoint);
  }

  Map<String, dynamic> diagnosticsJson() => {
    'version': 1,
    'engine': 'streaming',
    'session': _session.state.toJson(),
    'health': health.toJson(),
    'events': log.toJson(),
  };
}

/// Savepoint persistence (SharedPreferences-backed, engine-owned).
final engineSavepointProvider =
    NotifierProvider<EngineSavepointNotifier, PlaybackSavepoint?>(
      EngineSavepointNotifier.new,
    );

class EngineSavepointNotifier extends Notifier<PlaybackSavepoint?> {
  static const String _key = 'engine_savepoint_v1';

  @override
  PlaybackSavepoint? build() {
    // No-op build: `load()` is called from app bootstrap. Keeping the state
    // null until then means a cold-start never shows a stale queue.
    return null;
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      state = PlaybackSavepoint.fromJson(decoded).sanitize();
    } catch (_) {
      // Best-effort: a corrupt savepoint must never break startup.
    }
  }

  Future<void> save(PlaybackSavepoint savepoint) async {
    state = savepoint.sanitize();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(savepoint.toJson()));
    } catch (_) {
      // Best-effort.
    }
  }

  Future<void> clear() async {
    state = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {
      // Best-effort.
    }
  }
}

/// ---------------------------------------------------------------------------
/// Sleep timer
/// ---------------------------------------------------------------------------

class SleepTimerState {
  final Duration? remaining;
  final bool endOfTrack;
  final DateTime? startedAt;

  const SleepTimerState({this.remaining, this.endOfTrack = false, this.startedAt});

  bool get isActive => remaining != null || endOfTrack;

  String? get label {
    if (remaining == null) return null;
    final minutes = (remaining!.inSeconds / 60).ceil();
    final seconds = remaining!.inSeconds % 60;
    if (minutes >= 1) return '$minutes min';
    return '${seconds}s';
  }
}

final sleepTimerProvider =
    NotifierProvider<SleepTimerNotifier, SleepTimerState>(
      SleepTimerNotifier.new,
    );

class SleepTimerNotifier extends Notifier<SleepTimerState> {
  Timer? _ticker;
  DateTime? _deadline;

  @override
  SleepTimerState build() {
    ref.onDispose(() => _ticker?.cancel());
    return const SleepTimerState();
  }

  void start(Duration duration) {
    _ticker?.cancel();
    _deadline = DateTime.now().add(duration);
    state = SleepTimerState(
      remaining: duration,
      startedAt: DateTime.now(),
    );
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final deadline = _deadline;
      if (deadline == null) {
        stop();
        return;
      }
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        stop();
        ref.read(musicPlayerControllerProvider).pause();
        return;
      }
      state = SleepTimerState(
        remaining: remaining,
        startedAt: state.startedAt,
      );
    });
  }

  void endOfTrack() {
    _ticker?.cancel();
    state = SleepTimerState(endOfTrack: true, startedAt: DateTime.now());
  }

  void stop() {
    _ticker?.cancel();
    _deadline = null;
    state = const SleepTimerState();
  }
}

/// Whether the engine may ask stream adapters for candidates right now.
///
/// Offline mode and a detected-offline network both disable resolution so the
/// play path never performs network work; local playback remains available.
bool shouldAttemptStreamResolution({
  required bool streamingEnabled,
  required NetworkProfile network,
}) => streamingEnabled && !network.isOffline;

/// ---------------------------------------------------------------------------
/// Provider wiring
/// ---------------------------------------------------------------------------

/// Preflight validator used by the engine controller. Overridable in tests.
final streamPreflightValidatorProvider = Provider<StreamPreflightValidator>(
  (ref) => HttpStreamPreflightValidator(),
);

/// Network status monitor used by the engine controller. Overridable in
/// tests (the connectivity plugin has no test-channel implementation).
final networkStatusMonitorProvider = Provider<NetworkStatusMonitor>(
  (ref) => NetworkStatusMonitor(),
);

final streamingEngineControllerProvider = Provider<StreamingEngineController>(
  (ref) => StreamingEngineController._(
    ref,
    validator: ref.watch(streamPreflightValidatorProvider),
    network: ref.watch(networkStatusMonitorProvider),
  ),
);

final engineDiagnosticsProvider = Provider<StreamingDiagnostics>(
  (ref) {
    final engine = ref.watch(streamingEngineControllerProvider);
    final state = engine.sessionState;
    return StreamingDiagnostics(
      health: engine.providerHealth,
      log: engine.eventLog,
      session: state,
      bandwidth: engine.bandwidthMonitor,
      integrity: engine.integrityLog,
    );
  },
);
