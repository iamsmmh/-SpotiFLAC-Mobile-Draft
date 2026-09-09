/// Unified playback decision engine: one player, three origins.
///
/// [PlaybackManager] is the single entry point for hybrid playback:
///
///   * downloaded file exists → [LocalPlaybackSource],
///   * else verified cache hit → [CachePlaybackSource],
///   * else (online) → [StreamingPlaybackSource].
///
/// The policy itself is the existing pure planner ([PlaybackSourceLadder]);
/// the manager gathers the facts, routes to the owning source, and owns the
/// cross-cutting runtime that must exist exactly once: mixed-queue building
/// with lazy stream resolution, next-track preloading at 75%, network
/// pause/resume, download-completion hot-swap, stream-URL failure recovery,
/// and gapless/crossfade policy application.
///
/// Everything renders through one [PlaybackBackend] (the audio_service
/// handler in production), so there is still exactly one queue, one media
/// session, one notification, one lyrics flow, and one ReplayGain path.
/// Queue logic, lyrics, and normalization are never duplicated here — they
/// stay inside the handler and the existing providers.
///
/// Hook coexistence: the Smart Play engine installs non-chained global hooks
/// ([playbackFailureListener]/[deferredStreamResolver]). The manager chains
/// *outside* whatever is installed when [installHooks] runs (production
/// boots the engine first) and delegates every foreign media id, so both
/// engines keep working regardless of install order.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart'
    show AudioProcessingState, MediaItem, PlaybackState;
import 'package:spotiflac_android/core/data/network_switch_policy.dart'
    show NetworkSwitchAction, NetworkSwitchPolicy;
import 'package:spotiflac_android/engine/crossfade_policy.dart'
    show CrossfadeSettings;
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/cache/playback_source_ladder.dart'
    show PlaybackSourceFacts, PlaybackSourceKind, PlaybackSourceLadder;
import 'package:spotiflac_android/services/music_player_service.dart'
    show
        DeferredStreamResolver,
        MusicPlayerHandler,
        PlayableMedia,
        PlaybackFailureListener,
        deferredStreamResolver,
        initMusicPlayer,
        playbackFailureListener,
        setDeferredStreamResolver,
        setPlaybackCrossfade,
        setPlaybackFailureListener,
        setPlaybackGaplessEnabled;
import 'package:spotiflac_android/services/playback/cache_playback_service.dart'
    show CachePlaybackSource, PlaybackCacheHit;
import 'package:spotiflac_android/services/playback/local_playback_service.dart'
    show LocalPlaybackSource, LocalTrackPathBatchResolver;
import 'package:spotiflac_android/services/playback/playback_source.dart';
import 'package:spotiflac_android/services/playback/streaming_playback_service.dart'
    show StreamingPlaybackSource;
import 'package:spotiflac_android/utils/logger.dart';

final _logPlayback = AppLogger('PlaybackManager');

/// Snapshot of the user/network policy the manager routes with.
///
/// Plain value object (no Riverpod): production maps [EngineSettings] onto
/// it in the provider layer and pushes updates via [PlaybackManager.updatePolicy].
class PlaybackPolicy {
  const PlaybackPolicy({
    this.streamingEnabled = true,
    this.cacheEnabled = true,
    this.offlineMode = false,
    this.gaplessEnabled = true,
    this.crossfadeSeconds = 0,
    this.crossfadeSmart = true,
    this.preloadNextTrack = true,
    this.preloadThreshold = PlaybackManager.defaultPreloadThreshold,
    this.autoRecoverStreams = true,
    this.maxAutoRecoveriesPerTrack = 2,
  });

  final bool streamingEnabled;
  final bool cacheEnabled;
  final bool offlineMode;
  final bool gaplessEnabled;

  /// Crossfade overlap in seconds; clamped to 0–12 when applied.
  final int crossfadeSeconds;
  final bool crossfadeSmart;
  final bool preloadNextTrack;

  /// Progress ratio of the current item that triggers the next preload.
  final double preloadThreshold;
  final bool autoRecoverStreams;
  final int maxAutoRecoveriesPerTrack;

  /// Crossfade seconds as applied to the player (0 = off, max 12).
  int get effectiveCrossfadeSeconds => crossfadeSeconds.clamp(0, 12).toInt();

  PlaybackPolicy copyWith({
    bool? streamingEnabled,
    bool? cacheEnabled,
    bool? offlineMode,
    bool? gaplessEnabled,
    int? crossfadeSeconds,
    bool? crossfadeSmart,
    bool? preloadNextTrack,
    double? preloadThreshold,
    bool? autoRecoverStreams,
    int? maxAutoRecoveriesPerTrack,
  }) => PlaybackPolicy(
    streamingEnabled: streamingEnabled ?? this.streamingEnabled,
    cacheEnabled: cacheEnabled ?? this.cacheEnabled,
    offlineMode: offlineMode ?? this.offlineMode,
    gaplessEnabled: gaplessEnabled ?? this.gaplessEnabled,
    crossfadeSeconds: crossfadeSeconds ?? this.crossfadeSeconds,
    crossfadeSmart: crossfadeSmart ?? this.crossfadeSmart,
    preloadNextTrack: preloadNextTrack ?? this.preloadNextTrack,
    preloadThreshold: preloadThreshold ?? this.preloadThreshold,
    autoRecoverStreams: autoRecoverStreams ?? this.autoRecoverStreams,
    maxAutoRecoveriesPerTrack:
        maxAutoRecoveriesPerTrack ?? this.maxAutoRecoveriesPerTrack,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackPolicy &&
          other.streamingEnabled == streamingEnabled &&
          other.cacheEnabled == cacheEnabled &&
          other.offlineMode == offlineMode &&
          other.gaplessEnabled == gaplessEnabled &&
          other.crossfadeSeconds == crossfadeSeconds &&
          other.crossfadeSmart == crossfadeSmart &&
          other.preloadNextTrack == preloadNextTrack &&
          other.preloadThreshold == preloadThreshold &&
          other.autoRecoverStreams == autoRecoverStreams &&
          other.maxAutoRecoveriesPerTrack == maxAutoRecoveriesPerTrack;

  @override
  int get hashCode => Object.hash(
    streamingEnabled,
    cacheEnabled,
    offlineMode,
    gaplessEnabled,
    crossfadeSeconds,
    crossfadeSmart,
    preloadNextTrack,
    preloadThreshold,
    autoRecoverStreams,
    maxAutoRecoveriesPerTrack,
  );
}

/// One routing verdict for one track.
class PlaybackDecision {
  const PlaybackDecision({
    required this.track,
    required this.kind,
    this.localPath,
    this.cacheHit,
    this.reason = '',
  });

  final Track track;
  final PlaybackSourceKind kind;

  /// Resolved file path when [kind] is [PlaybackSourceKind.localLibrary].
  final String? localPath;

  /// Verified hit when [kind] is [PlaybackSourceKind.streamCache].
  final PlaybackCacheHit? cacheHit;

  /// Human-readable reason (ladder verdict; diagnostics + tests).
  final String reason;

  bool get isPlayable => kind != PlaybackSourceKind.unavailable;
}

/// Fired after a download is registered in the library so playback
/// availability can update (future plays go local; a live stream hot-swaps).
class PlaybackDownloadEvent {
  const PlaybackDownloadEvent({
    this.trackId = '',
    this.isrc = '',
    this.filePath = '',
  });

  /// Download-history `spotifyId` (the downloaded [Track.id]).
  final String trackId;
  final String isrc;
  final String filePath;
}

typedef PlaybackDownloadListener = void Function(PlaybackDownloadEvent event);

/// Process-global download hook, installed by [PlaybackManager].
///
/// Null until a manager installs itself; the download history notifies it
/// best-effort after every successful persist.
PlaybackDownloadListener? playbackDownloadListener;

/// Pure preload trigger: true once [position] reaches [threshold] of
/// [duration]. Unknown durations never trigger.
bool shouldPreloadAt({
  required Duration position,
  required Duration duration,
  double threshold = PlaybackManager.defaultPreloadThreshold,
}) {
  if (duration <= Duration.zero || position < Duration.zero) return false;
  if (threshold <= 0) return true;
  return position.inMilliseconds >=
      (duration.inMilliseconds * threshold).round();
}

/// Builds a lazily-resolved queue item for [track].
///
/// The concrete source (local path, cache path, or fresh stream URL) is
/// resolved by [PlaybackManager.resolveDeferred] when playback reaches the
/// item, so long queues never pre-resolve dozens of expiring URLs.
PlayableMedia deferredMediaForTrack(Track track) {
  return playableMediaForTrack(
    track,
    mediaId: track.id,
    source: PlayableMedia.deferredStreamUriFor(track.id),
    playbackMode: 'stream',
    sourceLabel: 'Unified playback',
  );
}

class _ManagedItem {
  const _ManagedItem({
    required this.track,
    required this.kind,
    required this.decision,
  });

  final Track track;
  final PlaybackSourceKind kind;
  final PlaybackDecision decision;
}

/// The unified playback decision engine. See the library docs for the full
/// contract.
class PlaybackManager {
  PlaybackManager({
    required PlaybackBackend backend,
    required LocalPlaybackSource localSource,
    required CachePlaybackSource cacheSource,
    required StreamingPlaybackSource streamingSource,
    PlaybackPolicy policy = const PlaybackPolicy(),
    LocalTrackPathBatchResolver? batchPathResolver,
    void Function(bool enabled)? gaplessApplier,
    void Function(CrossfadeSettings settings)? crossfadeApplier,
    void Function(Track track)? engineTrackRegistrar,
    DateTime Function()? clock,
  }) : _backend = backend,
       _local = localSource,
       _cache = cacheSource,
       _streaming = streamingSource,
       _policy = policy,
       _batchPaths = batchPathResolver,
       _gaplessApplier = gaplessApplier ?? setPlaybackGaplessEnabled,
       _crossfadeApplier = crossfadeApplier ?? setPlaybackCrossfade,
       _engineTrackRegistrar = engineTrackRegistrar,
       _clock = clock ?? DateTime.now {
    _failureHook = _onPlaybackFailure;
    _deferredHook = _resolveDeferredChained;
  }

  /// Default progress ratio that preloads the next queue item.
  static const double defaultPreloadThreshold = 0.75;

  final PlaybackBackend _backend;
  final LocalPlaybackSource _local;
  final CachePlaybackSource _cache;
  final StreamingPlaybackSource _streaming;
  final LocalTrackPathBatchResolver? _batchPaths;
  final void Function(bool enabled) _gaplessApplier;
  final void Function(CrossfadeSettings settings) _crossfadeApplier;
  final void Function(Track track)? _engineTrackRegistrar;
  final DateTime Function() _clock;

  PlaybackPolicy _policy;
  bool _initialized = false;
  bool _disposed = false;

  final Map<String, Track> _tracks = <String, Track>{};
  final Map<String, _ManagedItem> _media = <String, _ManagedItem>{};
  List<String> _queueOrder = const <String>[];
  String _currentMediaId = '';
  final Set<String> _preloaded = <String>{};
  final Map<String, int> _recoveries = <String, int>{};

  StreamSubscription<PlaybackSourceState>? _stateSub;
  StreamSubscription<PlaybackProgress>? _progressSub;
  StreamSubscription<Iterable<String>>? _networkSub;
  PlaybackSourceState _latestState = PlaybackSourceState.idle;

  bool _hooksInstalled = false;
  late final PlaybackFailureListener _failureHook;
  late final DeferredStreamResolver _deferredHook;
  PlaybackFailureListener? _previousFailureListener;
  DeferredStreamResolver? _previousDeferredResolver;
  PlaybackDownloadListener? _downloadHook;

  Iterable<String>? _previousTransports;
  DateTime _lastNetworkCleanupAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _networkOffline = false;
  bool _autoPaused = false;

  PlaybackPolicy get policy => _policy;
  bool get isInitialized => _initialized;
  PlaybackBackend get backend => _backend;
  LocalPlaybackSource get localSource => _local;
  CachePlaybackSource get cacheSource => _cache;
  StreamingPlaybackSource get streamingSource => _streaming;

  /// THE player state stream (the backend's; shared by every source).
  Stream<PlaybackSourceState> get state => _backend.state;
  PlaybackSourceState get latestState => _latestState;
  Duration get currentPosition => _backend.currentPosition;
  Duration get duration => _backend.duration;
  String get currentTrackId => _backend.currentTrackId;
  String get currentMediaId => _currentMediaId;

  Track? get currentTrack => _media[_currentMediaId]?.track;
  PlaybackSourceKind? get currentKind => _media[_currentMediaId]?.kind;
  PlaybackDecision? get currentDecision => _media[_currentMediaId]?.decision;

  List<String> get queueMediaIds => List<String>.unmodifiable(_queueOrder);

  /// True while playback is paused by the network watcher (auto-resumable).
  bool get autoPaused => _autoPaused;
  bool get networkOffline => _networkOffline;

  /// Maps a manager-owned media id back to its logical track id ('' when
  /// foreign). Installed on the backend so state/progress carry track ids.
  String trackIdForMediaId(String mediaId) {
    return _media[mediaId]?.track.id ?? '';
  }

  /// Returns the source owning [kind] (null when unavailable).
  PlaybackSource? sourceForKind(PlaybackSourceKind kind) {
    switch (kind) {
      case PlaybackSourceKind.localLibrary:
        return _local;
      case PlaybackSourceKind.streamCache:
        return _cache;
      case PlaybackSourceKind.providerStream:
      case PlaybackSourceKind.previewStream:
        return _streaming;
      case PlaybackSourceKind.unavailable:
        return null;
    }
  }

  /// Boots the layer: backend, sources, audio policy, listeners, hooks.
  /// Idempotent; safe to call before any play request.
  Future<void> initialize() async {
    if (_initialized || _disposed) return;
    _streaming.urlResolver.isOfflineCheck = () => _networkOffline;
    await _backend.ensureReady();
    await _local.initialize();
    await _cache.initialize();
    await _streaming.initialize();
    applyAudioPolicy();
    _stateSub ??= _backend.state.listen(_onBackendState);
    _progressSub ??= _backend.progress.listen(_onProgress);
    installHooks();
    installAsDownloadListener();
    _initialized = true;
  }

  /// Applies gapless + crossfade from the current policy to the player.
  void applyAudioPolicy() {
    _gaplessApplier(_policy.gaplessEnabled);
    _crossfadeApplier(
      CrossfadeSettings(
        seconds: _policy.effectiveCrossfadeSeconds,
        smart: _policy.crossfadeSmart,
      ),
    );
  }

  /// Pushes a new policy (re-applies the audio knobs when initialized).
  void updatePolicy(PlaybackPolicy next) {
    if (_disposed || next == _policy) return;
    _policy = next;
    if (_initialized) applyAudioPolicy();
  }

  /// Routes [track] to local → cache → stream (never probes the network:
  /// stream candidates resolve when playback or preload reaches them).
  Future<PlaybackDecision> decide(
    Track track, {
    String? knownLocalPath,
  }) async {
    _tracks[track.id] = track;
    final localPath = knownLocalPath ?? await _localPathOf(track);
    PlaybackCacheHit? cacheHit;
    if (localPath == null && _policy.cacheEnabled) {
      cacheHit = await _cacheHitOf(track);
    }
    final plan = const PlaybackSourceLadder().resolve(
      PlaybackSourceFacts(
        hasLocalFile: localPath != null,
        hasVerifiedCache: cacheHit != null,
        hasProviderStream: _policy.streamingEnabled && !_policy.offlineMode,
        // Preview candidates are ranked *inside* the streaming resolver;
        // they are never a separate route here.
        hasPreviewStream: false,
        // The ladder keeps local + verified-cache playable while offline;
        // only the stream routes drop out. Uses the watcher's last-known
        // state (no probe), so pre-watch decisions stay optimistic.
        offline: _policy.offlineMode || _networkOffline,
      ),
    );
    return PlaybackDecision(
      track: track,
      kind: plan.kind,
      localPath: localPath,
      cacheHit: cacheHit,
      reason: plan.reason,
    );
  }

  /// Plays one track through its routed source.
  Future<void> playTrack(Track track) async {
    _requireReady();
    await _playDecision(await decide(track));
  }

  /// Plays a mixed queue (downloaded, cached, and streaming items in any
  /// order) starting at [startIndex].
  ///
  /// Local and cached items queue concretely; stream items queue lazily and
  /// resolve when playback reaches them. Unplayable tracks are skipped;
  /// an all-unplayable list throws [PlaybackSourceException].
  Future<void> playTracks(List<Track> tracks, {int startIndex = 0}) async {
    _requireReady();
    if (tracks.isEmpty) return;
    final safeStart = startIndex.clamp(0, tracks.length - 1);
    final ordered = safeStart == 0
        ? List<Track>.of(tracks, growable: false)
        : <Track>[...tracks.sublist(safeStart), ...tracks.sublist(0, safeStart)];
    final localPaths = await _batchLocalPaths(ordered);

    _media.clear();
    _preloaded.clear();
    _recoveries.clear();
    final items = <PlayableMedia>[];
    final order = <String>[];
    for (var i = 0; i < ordered.length; i++) {
      final track = ordered[i];
      _tracks[track.id] = track;
      final decision = await decide(
        track,
        knownLocalPath: i < localPaths.length ? localPaths[i] : null,
      );
      final media = _queueMediaFor(decision);
      if (media == null) continue;
      _registerOwned(decision, media.id);
      _engineTrackRegistrar?.call(track);
      items.add(media);
      order.add(media.id);
    }
    if (items.isEmpty) {
      throw const PlaybackSourceException(
        kind: 'unavailable',
        trackId: '',
        message: 'No playable track in the queue',
      );
    }
    _queueOrder = order;
    _currentMediaId = items.first.id;
    await _backend.setQueue(items);
  }

  /// Resolves a manager-owned deferred queue item to its concrete source.
  /// Returns null for foreign items (the caller chains to the previous
  /// resolver) and for tracks that cannot be resolved right now.
  Future<String?> resolveDeferred(PlayableMedia media) async {
    final item = _media[media.id];
    if (item == null) return null;
    final decision = await decide(item.track);
    _registerOwned(decision, media.id);
    switch (decision.kind) {
      case PlaybackSourceKind.localLibrary:
        final path = decision.localPath;
        if (path == null || path.isEmpty) return null;
        _backend.noteSourceExpiry(media.id, null);
        return path;
      case PlaybackSourceKind.streamCache:
        final hit = decision.cacheHit;
        if (hit == null) return null;
        await _cache.cache.registerPlay(item.track);
        _backend.noteSourceExpiry(media.id, null);
        return hit.filePath;
      case PlaybackSourceKind.providerStream:
      case PlaybackSourceKind.previewStream:
        final resolved = await _streaming.urlResolver.retry(item.track);
        if (resolved == null) return null;
        _backend.noteSourceExpiry(media.id, resolved.source.expiresAt);
        return resolved.source.url;
      case PlaybackSourceKind.unavailable:
        return null;
    }
  }

  /// Starts the network watcher: pause safely when connectivity drops,
  /// auto-resume on reconnect (queue position and state preserved).
  ///
  /// [transports] emits connectivity token sets (see `NetworkTransport`).
  /// Only sessions the watcher itself paused are resumed — a user-paused
  /// session stays paused.
  void watchNetwork(Stream<Iterable<String>> transports) {
    cancelNetworkWatch();
    _networkSub = transports.listen(
      _onNetworkTransports,
      onError: (_) {},
    );
  }

  void cancelNetworkWatch() {
    _networkSub?.cancel();
    _networkSub = null;
  }

  /// Best-effort download hook (never throws): drops the stale stream-URL
  /// cache entry and, when the finished track is the one currently
  /// streaming, hot-swaps it to the downloaded file at the live position.
  /// Future plays route locally because [decide] always checks local first.
  Future<void> notifyDownloadCompleted({
    required String trackId,
    String isrc = '',
    String filePath = '',
  }) async {
    try {
      if (trackId.isNotEmpty) _streaming.urlResolver.invalidate(trackId);
      final current = currentTrack;
      if (current == null) return;
      final matches =
          (trackId.isNotEmpty && current.id == trackId) ||
          (isrc.isNotEmpty &&
              (current.isrc ?? '').isNotEmpty &&
              current.isrc == isrc);
      if (!matches) return;
      if (currentKind == PlaybackSourceKind.localLibrary) return;
      var path = filePath.trim();
      if (path.isEmpty) {
        path = await _localPathOf(current) ?? '';
      }
      if (path.isEmpty) return;
      final oldId = _currentMediaId;
      final resumeAt = _backend.currentPosition;
      final media = _local.mediaFor(current, path);
      _registerOwned(
        PlaybackDecision(
          track: current,
          kind: PlaybackSourceKind.localLibrary,
          localPath: path,
          reason: 'Download completed; swapped to the local file',
        ),
        media.id,
      );
      _adoptReplacementId(oldId, media.id);
      await _backend.replaceCurrent(media, resumeAt: resumeAt);
      _logPlayback.i('Swapped "${current.name}" to its downloaded file');
    } catch (error) {
      _logPlayback.w('Download-completion handling failed: $error');
    }
  }

  /// Flushes the live session (background/terminate path).
  Future<void> persistSession() => _backend.persistSession();

  /// Installs the chained failure + deferred hooks (idempotent).
  void installHooks() {
    if (_hooksInstalled) return;
    _hooksInstalled = true;
    _previousFailureListener = playbackFailureListener;
    _previousDeferredResolver = deferredStreamResolver;
    setPlaybackFailureListener(_failureHook);
    setDeferredStreamResolver(_deferredHook);
  }

  /// Removes the chained hooks, restoring the previous ones (if still ours).
  void uninstallHooks() {
    if (!_hooksInstalled) return;
    _hooksInstalled = false;
    if (identical(playbackFailureListener, _failureHook)) {
      playbackFailureListener = _previousFailureListener;
    }
    if (identical(deferredStreamResolver, _deferredHook)) {
      setDeferredStreamResolver(_previousDeferredResolver);
    }
    _previousFailureListener = null;
    _previousDeferredResolver = null;
  }

  /// Installs this manager as the download-completion listener.
  void installAsDownloadListener() {
    _downloadHook ??= (PlaybackDownloadEvent event) {
      unawaited(
        notifyDownloadCompleted(
          trackId: event.trackId,
          isrc: event.isrc,
          filePath: event.filePath,
        ),
      );
    };
    playbackDownloadListener = _downloadHook;
  }

  /// Removes the download listener (only when it is still ours).
  void removeDownloadListener() {
    if (identical(playbackDownloadListener, _downloadHook)) {
      playbackDownloadListener = null;
    }
    _downloadHook = null;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    cancelNetworkWatch();
    await _stateSub?.cancel();
    await _progressSub?.cancel();
    _stateSub = null;
    _progressSub = null;
    uninstallHooks();
    removeDownloadListener();
    await _local.dispose();
    await _cache.dispose();
    await _streaming.dispose();
    // The backend (audio service) is intentionally left alive: it outlives
    // every manager by design.
  }

  void _requireReady() {
    if (!_initialized || _disposed) {
      throw StateError(
        'PlaybackManager.initialize() must complete before playback',
      );
    }
  }

  Future<String?> _localPathOf(Track track) async {
    try {
      return await _local.resolvePath(track);
    } catch (_) {
      return null;
    }
  }

  Future<PlaybackCacheHit?> _cacheHitOf(Track track) async {
    try {
      return await _cache.cache.lookup(track);
    } catch (_) {
      return null;
    }
  }

  Future<List<String?>> _batchLocalPaths(List<Track> tracks) async {
    final batch = _batchPaths;
    if (batch != null) {
      try {
        final paths = await batch(tracks);
        if (paths.length == tracks.length) return paths;
      } catch (_) {
        // Fall through to per-track resolution.
      }
    }
    final paths = <String?>[];
    for (final track in tracks) {
      paths.add(await _localPathOf(track));
    }
    return paths;
  }

  Future<void> _playDecision(PlaybackDecision decision) async {
    final source = sourceForKind(decision.kind);
    if (source == null) {
      throw PlaybackSourceException.unavailable(
        decision.track.id,
        decision.reason.isNotEmpty ? decision.reason : 'No playable source',
      );
    }
    final mediaId = _expectedMediaId(decision);
    _registerOwned(decision, mediaId);
    _engineTrackRegistrar?.call(decision.track);
    await source.play(decision.track);
    _currentMediaId = mediaId;
    _queueOrder = <String>[mediaId];
  }

  String _expectedMediaId(PlaybackDecision decision) {
    switch (decision.kind) {
      case PlaybackSourceKind.localLibrary:
        return LocalPlaybackSource.mediaIdForPath(decision.localPath ?? '');
      case PlaybackSourceKind.streamCache:
        final hit = decision.cacheHit;
        return CachePlaybackSource.mediaIdForCacheKey(
          hit?.entry.key ?? decision.track.id,
        );
      case PlaybackSourceKind.providerStream:
      case PlaybackSourceKind.previewStream:
        return StreamingPlaybackSource.mediaIdForTrack(decision.track);
      case PlaybackSourceKind.unavailable:
        return '';
    }
  }

  PlayableMedia? _queueMediaFor(PlaybackDecision decision) {
    switch (decision.kind) {
      case PlaybackSourceKind.localLibrary:
        final path = decision.localPath;
        if (path == null || path.isEmpty) return null;
        return _local.mediaFor(decision.track, path);
      case PlaybackSourceKind.streamCache:
        final hit = decision.cacheHit;
        if (hit == null) return null;
        return _cache.mediaFor(decision.track, hit);
      case PlaybackSourceKind.providerStream:
      case PlaybackSourceKind.previewStream:
        return deferredMediaForTrack(decision.track);
      case PlaybackSourceKind.unavailable:
        return null;
    }
  }

  void _registerOwned(PlaybackDecision decision, String mediaId) {
    if (mediaId.isEmpty) return;
    if (_media.length > 512) _media.clear();
    _media[mediaId] = _ManagedItem(
      track: decision.track,
      kind: decision.kind,
      decision: decision,
    );
  }

  void _adoptReplacementId(String oldId, String newId) {
    if (newId.isNotEmpty) _currentMediaId = newId;
    if (oldId.isEmpty || oldId == newId) return;
    _media.remove(oldId);
    _preloaded.remove(oldId);
    _recoveries.remove(oldId);
    _queueOrder = <String>[
      for (final id in _queueOrder) id == oldId ? newId : id,
    ];
  }

  void _onBackendState(PlaybackSourceState state) {
    _latestState = state;
    if (state.mediaId.isNotEmpty &&
        state.mediaId != _currentMediaId &&
        _media.containsKey(state.mediaId)) {
      _currentMediaId = state.mediaId;
      _preloaded.removeWhere((id) => !_queueOrder.contains(id));
    }
  }

  void _onProgress(PlaybackProgress tick) {
    if (!_policy.preloadNextTrack) return;
    if (tick.mediaId.isEmpty || !_media.containsKey(tick.mediaId)) return;
    if (_preloaded.contains(tick.mediaId)) return;
    if (!shouldPreloadAt(
      position: tick.position,
      duration: tick.duration,
      threshold: _policy.preloadThreshold,
    )) {
      return;
    }
    _preloaded.add(tick.mediaId);
    final next = _nextOwned(tick.mediaId);
    if (next == null) return;
    unawaited(_preloadOwned(next.track));
  }

  _ManagedItem? _nextOwned(String mediaId) {
    final index = _queueOrder.indexOf(mediaId);
    if (index < 0 || index + 1 >= _queueOrder.length) return null;
    return _media[_queueOrder[index + 1]];
  }

  Future<void> _preloadOwned(Track track) async {
    try {
      // Re-decided at trigger time: a download that finished mid-play turns
      // the upcoming stream into a local file with nothing left to warm.
      final decision = await decide(track);
      final source = sourceForKind(decision.kind);
      if (source == null) return;
      await source.preload(track);
    } catch (_) {
      // Best-effort: the natural advance resolves again anyway.
    }
  }

  void _onNetworkTransports(Iterable<String> current) {
    final now = _clock();
    final decision = NetworkSwitchPolicy.decide(
      current: current,
      previous: _previousTransports,
      now: now,
      lastCleanupAt: _lastNetworkCleanupAt,
      wifiOnlyMode: false,
      queueProcessing: false,
      queuePausedForWifi: false,
    );
    _previousTransports = List<String>.of(current, growable: false);
    if (decision.action == NetworkSwitchAction.recycleConnections) {
      _lastNetworkCleanupAt = now;
    }
    final wasOffline = _networkOffline;
    _networkOffline = decision.isOffline;
    if (decision.isOffline && !wasOffline) {
      // Going offline: pause safely, but only when audibly playing — a
      // user-paused session must never be auto-resumed later.
      if (_latestState.isPlaying) {
        _autoPaused = true;
        unawaited(() async {
          try {
            await _backend.pause();
          } catch (_) {
            _autoPaused = false;
          }
        }());
      }
    } else if (!decision.isOffline && wasOffline && _autoPaused) {
      // Reconnected after an auto-pause: resume only when still paused
      // (the user may have resumed manually while offline). The flag is
      // always cleared so a stale auto-pause can never trigger a wrongful
      // resume on a later reconnect.
      _autoPaused = false;
      if (!_latestState.isPlaying) {
        unawaited(() async {
          try {
            await _backend.resume();
          } catch (_) {
            // Resume failures surface through the backend state stream.
          }
        }());
      }
    }
  }

  void _onPlaybackFailure(PlayableMedia media, Object error) {
    final item = _media[media.id];
    if (item == null || item.kind == PlaybackSourceKind.localLibrary) {
      _previousFailureListener?.call(media, error);
      return;
    }
    unawaited(_recoverStream(item, media, error));
  }

  Future<void> _recoverStream(
    _ManagedItem item,
    PlayableMedia media,
    Object error,
  ) async {
    if (_disposed || !_policy.autoRecoverStreams) {
      _previousFailureListener?.call(media, error);
      return;
    }
    final attempts = _recoveries[media.id] ?? 0;
    if (attempts >= _policy.maxAutoRecoveriesPerTrack) {
      _previousFailureListener?.call(media, error);
      return;
    }
    _recoveries[media.id] = attempts + 1;
    try {
      // Expired/dead URL: regenerate (bypassing the cache) and hot-swap at
      // the live position. The same path serves the proactive expiry signal,
      // which arrives here as an ordinary refresh request.
      final fresh = await _streaming.urlResolver.refresh(item.track);
      if (fresh == null || _disposed) {
        _previousFailureListener?.call(media, error);
        return;
      }
      final resumeAt = _backend.currentPosition;
      final replacement = _streaming.mediaFor(item.track, fresh);
      _registerOwned(
        PlaybackDecision(
          track: item.track,
          kind: PlaybackSourceKind.providerStream,
          reason: 'Recovered with a fresh stream URL',
        ),
        replacement.id,
      );
      _backend.noteSourceExpiry(replacement.id, fresh.source.expiresAt);
      await _backend.replaceCurrent(replacement, resumeAt: resumeAt);
      _logPlayback.i('Recovered "${item.track.name}" with a fresh stream URL');
    } catch (recoveryError) {
      _logPlayback.w(
        'Stream recovery failed for "${item.track.name}": $recoveryError',
      );
      _previousFailureListener?.call(media, error);
    }
  }

  Future<String?> _resolveDeferredChained(PlayableMedia media) async {
    if (_media.containsKey(media.id)) return resolveDeferred(media);
    final previous = _previousDeferredResolver;
    if (previous == null) return null;
    try {
      return await previous(media);
    } catch (_) {
      return null;
    }
  }
}

/// Production [PlaybackBackend]: the single audio_service handler.
///
/// Maps the handler's media-item/playback-state streams onto the unified
/// [PlaybackSourceState]/[PlaybackProgress] streams. Gapless splicing,
/// crossfading, ReplayGain, lyrics, and session persistence all stay inside
/// the handler — this adapter only forwards and projects state.
class MusicPlayerPlaybackBackend implements PlaybackBackend {
  MusicPlayerPlaybackBackend({this.trackIdForMediaId});

  /// Maps queue media ids back to logical track ids (manager-owned).
  String Function(String mediaId)? trackIdForMediaId;

  MusicPlayerHandler? _handler;
  bool _bound = false;
  final List<StreamSubscription<dynamic>> _subscriptions =
      <StreamSubscription<dynamic>>[];

  late final StreamController<PlaybackSourceState> _states =
      StreamController<PlaybackSourceState>.broadcast();
  late final StreamController<PlaybackProgress> _ticks =
      StreamController<PlaybackProgress>.broadcast();

  PlaybackSourceState _latest = PlaybackSourceState.idle;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String _mediaId = '';
  String _trackId = '';
  bool _disposed = false;

  @override
  Future<void> ensureReady() async {
    if (_disposed) {
      throw StateError('MusicPlayerPlaybackBackend is disposed');
    }
    if (_handler != null) return;
    final handler = await initMusicPlayer();
    _handler = handler;
    _bind(handler);
  }

  @override
  Stream<PlaybackSourceState> get state => _states.stream;

  @override
  Stream<PlaybackProgress> get progress => _ticks.stream;

  @override
  Duration get currentPosition => _position;

  @override
  Duration get duration => _duration;

  @override
  String get currentTrackId => _trackId;

  @override
  String get currentMediaId => _mediaId;

  @override
  Future<void> playMedia(
    PlayableMedia media, {
    Duration startPosition = Duration.zero,
  }) async {
    final handler = await _requireHandler();
    await handler.setQueueAndPlay(<PlayableMedia>[media]);
    if (startPosition > Duration.zero) {
      await handler.seek(startPosition);
    }
  }

  @override
  Future<void> setQueue(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    final handler = await _requireHandler();
    await handler.setQueueAndPlay(items, initialIndex: initialIndex);
  }

  @override
  Future<void> pause() async {
    final handler = await _requireHandler();
    await handler.pause();
  }

  @override
  Future<void> resume() async {
    final handler = await _requireHandler();
    await handler.play();
  }

  @override
  Future<void> stop() async {
    final handler = await _requireHandler();
    await handler.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    final handler = await _requireHandler();
    await handler.seek(position);
  }

  @override
  Future<void> replaceCurrent(
    PlayableMedia media, {
    Duration resumeAt = Duration.zero,
  }) async {
    final handler = await _requireHandler();
    await handler.replaceCurrentAndPlay(media, resumeAt: resumeAt);
  }

  @override
  Future<void> persistSession() async {
    final handler = await _requireHandler();
    await handler.persistCurrentSession();
  }

  @override
  void noteSourceExpiry(String mediaId, DateTime? expiresAt) {
    _handler?.noteDeferredSourceExpiry(mediaId, expiresAt);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    // The audio handler itself is app-owned and intentionally left alive.
    _handler = null;
    _bound = false;
    await _states.close();
    await _ticks.close();
  }

  Future<MusicPlayerHandler> _requireHandler() async {
    if (_disposed) {
      throw const PlaybackSourceException(
        kind: 'backend-unavailable',
        trackId: '',
        message: 'Playback backend is disposed',
      );
    }
    await ensureReady();
    final handler = _handler;
    if (handler == null) {
      throw const PlaybackSourceException(
        kind: 'backend-unavailable',
        trackId: '',
        message: 'Audio service unavailable',
      );
    }
    return handler;
  }

  void _bind(MusicPlayerHandler handler) {
    if (_bound) return;
    _bound = true;
    _subscriptions.add(handler.mediaItem.listen(_onMediaItem));
    _subscriptions.add(handler.playbackState.listen(_onPlaybackState));
    _onMediaItem(handler.mediaItem.value);
    _onPlaybackState(handler.playbackState.value);
  }

  void _onMediaItem(MediaItem? item) {
    _mediaId = item?.id ?? '';
    _duration = item?.duration ?? Duration.zero;
    _trackId = _mediaId.isEmpty ? '' : _resolveTrackId(_mediaId);
    _emit();
  }

  void _onPlaybackState(PlaybackState playback) {
    _position = playback.position;
    _emit(statusOverride: _mapStatus(playback));
  }

  String _resolveTrackId(String mediaId) {
    try {
      return trackIdForMediaId?.call(mediaId) ?? '';
    } catch (_) {
      return '';
    }
  }

  PlaybackSourceStatus _mapStatus(PlaybackState playback) {
    switch (playback.processingState) {
      case AudioProcessingState.idle:
        return PlaybackSourceStatus.idle;
      case AudioProcessingState.loading:
      case AudioProcessingState.buffering:
        return PlaybackSourceStatus.loading;
      case AudioProcessingState.ready:
        return playback.playing
            ? PlaybackSourceStatus.playing
            : PlaybackSourceStatus.paused;
      case AudioProcessingState.completed:
        return PlaybackSourceStatus.stopped;
      case AudioProcessingState.error:
        return PlaybackSourceStatus.failed;
    }
  }

  void _emit({PlaybackSourceStatus? statusOverride}) {
    if (_disposed) return;
    final status = statusOverride ?? _latest.status;
    // Losing the media item means the session ended: report idle rather
    // than a stale transport state.
    final effective = _mediaId.isEmpty &&
            status != PlaybackSourceStatus.loading
        ? PlaybackSourceStatus.idle
        : status;
    _latest = PlaybackSourceState(
      status: effective,
      trackId: _trackId,
      mediaId: _mediaId,
      position: _position,
      duration: _duration,
    );
    _states.add(_latest);
    _ticks.add(
      PlaybackProgress(
        trackId: _trackId,
        mediaId: _mediaId,
        position: _position,
        duration: _duration,
      ),
    );
  }
}
