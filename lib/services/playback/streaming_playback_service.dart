/// Streaming playback source for the unified playback layer.
///
/// [StreamingPlaybackSource] plays non-downloaded tracks from network stream
/// URLs on the shared player. URL discovery, ranking, validation, expiry
/// handling, and retry/backoff live in [StreamUrlResolver], which reuses the
/// protocol negotiation the engine already ships ([StreamProtocolResolver]:
/// HLS variant selection, static-DASH narrowing, progressive preference)
/// instead of reimplementing it.
///
/// Mid-playback failures (expired signed URLs, CDN drops, network changes)
/// are recovered by the manager's chained failure hook, which refreshes the
/// URL through this same resolver and hot-swaps it at the live position.
library;

import 'dart:async';
import 'dart:collection';

import 'package:spotiflac_android/core/streaming/stream_provider.dart'
    show StreamProtocol, StreamSource;
import 'package:spotiflac_android/core/streaming/stream_resolver.dart'
    show ManifestFetcher, StreamProtocolResolver, StreamResolverRequest;
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/cache/playback_source_ladder.dart'
    show PlaybackSourceKind;
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia;
import 'package:spotiflac_android/services/playback/playback_source.dart';

/// Produces the raw stream candidates for [track] (provider adapters).
typedef StreamCandidateFetcher = Future<List<StreamSource>> Function(Track track);

/// Preflight-validates one candidate (bounded ranged GET in production).
typedef StreamUrlValidator = Future<bool> Function(StreamSource source);

/// Sleeps between retry rounds (injectable so tests skip the wall clock).
typedef StreamRetryDelayer = Future<void> Function(Duration delay);

Future<void> _defaultRetryDelay(Duration delay) {
  return Future<void>.delayed(delay);
}

/// One validated, playable stream URL for one track.
class ResolvedStreamUrl {
  const ResolvedStreamUrl({
    required this.trackId,
    required this.source,
    required this.resolvedAt,
  });

  final String trackId;
  final StreamSource source;
  final DateTime resolvedAt;

  bool isExpiredAt(DateTime now) {
    final expiry = source.expiresAt;
    if (expiry == null) return false;
    return !now.isBefore(expiry);
  }

  /// Whether the URL should be regenerated before (re)use: already expired
  /// URLs always qualify; live ones qualify inside [leadTime] of expiry so
  /// playback never starts on a URL that dies seconds later.
  bool needsRefreshAt(DateTime now, Duration leadTime) {
    final expiry = source.expiresAt;
    if (expiry == null) return false;
    if (!now.isBefore(expiry)) return true;
    return !now.isBefore(expiry.subtract(leadTime));
  }

  @override
  String toString() =>
      'ResolvedStreamUrl(track=$trackId, url=${source.url}, '
      'provider=${source.providerId}, expiresAt=${source.expiresAt})';
}

/// Lifecycle owner for stream URLs: resolve, refresh, validate, retry.
///
/// Resolution never throws for user-facing conditions (no candidates,
/// offline, every candidate rejected): those resolve to null so the caller
/// can degrade gracefully. Only the source's [StreamingPlaybackSource.play]
/// translates null into a [PlaybackSourceException].
class StreamUrlResolver {
  StreamUrlResolver({
    required StreamCandidateFetcher fetchCandidates,
    required StreamUrlValidator validateSource,
    StreamProtocolResolver protocolResolver = const StreamProtocolResolver(),
    ManifestFetcher? manifestFetch,
    int? Function()? bandwidthProvider,
    bool preferLossless = true,
    bool allowHls = true,
    bool allowDash = true,
    Duration refreshLeadTime = const Duration(minutes: 2),
    bool Function()? isOffline,
    StreamRetryDelayer retryDelay = _defaultRetryDelay,
    DateTime Function()? clock,
    int maxCacheEntries = 64,
  }) : _fetch = fetchCandidates,
       _validateSource = validateSource,
       _protocols = protocolResolver,
       _manifestFetch = manifestFetch,
       _bandwidthProvider = bandwidthProvider,
       _preferLossless = preferLossless,
       _allowHls = allowHls,
       _allowDash = allowDash,
       _refreshLeadTime = refreshLeadTime,
       _retryDelay = retryDelay,
       _clock = clock ?? DateTime.now,
       _maxCacheEntries = maxCacheEntries < 1 ? 1 : maxCacheEntries {
    isOfflineCheck = isOffline;
  }

  /// Backoff between retry rounds: 1s, then 2s, then 4s.
  static const List<Duration> retryDelays = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
  ];

  /// Retry rounds after the initial attempt (1 initial + 3 retries).
  static const int maxRetries = 3;

  final StreamCandidateFetcher _fetch;
  final StreamUrlValidator _validateSource;
  final StreamProtocolResolver _protocols;
  final ManifestFetcher? _manifestFetch;
  final int? Function()? _bandwidthProvider;
  final bool _preferLossless;
  final bool _allowHls;
  final bool _allowDash;
  final Duration _refreshLeadTime;
  final StreamRetryDelayer _retryDelay;
  final DateTime Function() _clock;
  final int _maxCacheEntries;

  /// Runtime offline flag, flipped by the manager's network watcher. When
  /// set and true, resolution serves only fresh cache hits and [retry]
  /// aborts immediately instead of burning the backoff budget offline.
  bool Function()? isOfflineCheck;

  final LinkedHashMap<String, ResolvedStreamUrl> _cache =
      LinkedHashMap<String, ResolvedStreamUrl>();

  bool _isOfflineNow() {
    try {
      return isOfflineCheck?.call() ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Resolves [track] to a validated stream URL.
  ///
  /// Serves a fresh cache hit without network; regenerates URLs that are
  /// expired or inside the refresh lead time; fails over across ranked
  /// candidates (skipping expired ones) until one validates. Returns null
  /// when nothing is playable.
  Future<ResolvedStreamUrl?> resolve(
    Track track, {
    bool forceRefresh = false,
  }) async {
    final now = _clock();
    final cached = _cache[track.id];
    if (!forceRefresh && cached != null && !cached.isExpiredAt(now)) {
      if (!cached.needsRefreshAt(now, _refreshLeadTime)) return cached;
      // Near-expiry: try for a fresh URL but keep the usable one as the
      // fallback so a regeneration failure never breaks imminent playback.
      return await _resolveFresh(track, now: now) ?? cached;
    }
    return _resolveFresh(track, now: now);
  }

  /// Regenerates the stream URL for [track], bypassing the cache.
  Future<ResolvedStreamUrl?> refresh(Track track) {
    return resolve(track, forceRefresh: true);
  }

  /// Validates one candidate. Never throws: any failure (including a
  /// throwing validator) reports false.
  Future<bool> validate(StreamSource source) async {
    if (source.url.trim().isEmpty) return false;
    try {
      return await _validateSource(source);
    } catch (_) {
      return false;
    }
  }

  /// Resolves [track] with bounded exponential-backoff retries.
  ///
  /// One initial round plus up to [maxRetries] further rounds, sleeping
  /// [retryDelays] between rounds. Aborts early (without sleeping) when the
  /// device is offline. Returns the first validated URL, or null when every
  /// round failed.
  Future<ResolvedStreamUrl?> retry(Track track) async {
    for (var attempt = 0; ; attempt++) {
      final resolved = await resolve(track, forceRefresh: attempt > 0);
      if (resolved != null) return resolved;
      if (attempt >= maxRetries) return null;
      if (_isOfflineNow()) return null;
      final delayIndex = attempt < retryDelays.length
          ? attempt
          : retryDelays.length - 1;
      await _retryDelay(retryDelays[delayIndex]);
    }
  }

  /// Drops the cached URL for [trackId] (download completed, source died).
  void invalidate(String trackId) {
    _cache.remove(trackId);
  }

  /// Drops every cached URL.
  void clear() {
    _cache.clear();
  }

  /// Number of cached URLs (diagnostics/tests).
  int get cachedUrlCount => _cache.length;

  Future<ResolvedStreamUrl?> _resolveFresh(
    Track track, {
    required DateTime now,
  }) async {
    if (_isOfflineNow()) {
      final cached = _cache[track.id];
      if (cached != null && !cached.isExpiredAt(now)) return cached;
      return null;
    }
    List<StreamSource> candidates;
    try {
      candidates = await _fetch(track);
    } catch (_) {
      return null;
    }
    if (candidates.isEmpty) return null;
    final ranked = _protocols.orderCandidates(
      StreamResolverRequest(
        candidates: candidates,
        bandwidthBps: _bandwidthProvider?.call(),
        preferLossless: _preferLossless,
        allowHls: _allowHls,
        allowDash: _allowDash,
      ),
    );
    for (final candidate in ranked) {
      if (_isExpiredAt(candidate, now)) continue;
      final narrowed = await _narrow(candidate);
      if (_isExpiredAt(narrowed, now)) continue;
      if (await validate(narrowed)) {
        final resolved = ResolvedStreamUrl(
          trackId: track.id,
          source: narrowed,
          resolvedAt: now,
        );
        _store(track.id, resolved);
        return resolved;
      }
    }
    return null;
  }

  Future<StreamSource> _narrow(StreamSource candidate) async {
    final fetch = _manifestFetch;
    if (fetch == null) return candidate;
    if (candidate.protocol == StreamProtocol.progressive) return candidate;
    try {
      return await _protocols.narrow(
        candidate,
        fetch: fetch,
        bandwidthBps: _bandwidthProvider?.call(),
      );
    } catch (_) {
      return candidate;
    }
  }

  /// Expiry test against the injected clock. [StreamSource.isExpired] reads
  /// the wall clock, which would desync candidate filtering from a fake
  /// clock and skip candidates that are still valid at [now].
  bool _isExpiredAt(StreamSource source, DateTime now) {
    final expiry = source.expiresAt;
    if (expiry == null) return false;
    return !now.isBefore(expiry);
  }

  void _store(String trackId, ResolvedStreamUrl resolved) {
    _cache.remove(trackId);
    _cache[trackId] = resolved;
    while (_cache.length > _maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }
}

/// Plays network streams on the shared player.
///
/// Playback itself is the handler's progressive-URL path (the same one the
/// Smart Play engine uses); this source owns resolution quality: ranked
/// candidates, preflight validation, expiry-aware caching, and
/// backoff-bounded retries.
class StreamingPlaybackSource extends SharedBackendPlaybackSource {
  StreamingPlaybackSource({
    required super.backend,
    required StreamUrlResolver urlResolver,
  }) : _urls = urlResolver;

  final StreamUrlResolver _urls;

  StreamUrlResolver get urlResolver => _urls;

  /// Queue media id for a stream item: the track id (engine parity, so a
  /// deferred item that resolves to a stream keeps its identity).
  static String mediaIdForTrack(Track track) => track.id;

  @override
  PlaybackSourceKind get kind => PlaybackSourceKind.providerStream;

  @override
  Future<void> initialize() => backend.ensureReady();

  @override
  Future<void> play(Track track) async {
    final resolved = await _urls.retry(track);
    if (resolved == null) {
      throw PlaybackSourceException.unavailable(
        track.id,
        'No playable stream for "${track.name}"',
        true,
      );
    }
    await backend.playMedia(_mediaFor(track, resolved));
  }

  @override
  Future<void> preload(Track track) async {
    final resolved = await _urls.resolve(track);
    if (resolved == null) {
      throw PlaybackSourceException.unavailable(
        track.id,
        'Stream not resolvable for "${track.name}"',
        true,
      );
    }
  }

  PlayableMedia mediaFor(Track track, ResolvedStreamUrl resolved) {
    return _mediaFor(track, resolved);
  }

  PlayableMedia _mediaFor(Track track, ResolvedStreamUrl resolved) {
    final source = resolved.source;
    final providerId = source.providerId.trim().isNotEmpty
        ? source.providerId.trim()
        : 'Stream';
    return playableMediaForTrack(
      track,
      mediaId: mediaIdForTrack(track),
      source: source.url,
      playbackMode: 'stream',
      qualityLabel: _qualityLabel(source),
      sourceLabel: source.label.trim().isNotEmpty
          ? source.label.trim()
          : providerId,
      providerId: source.providerId.trim().isNotEmpty
          ? source.providerId.trim()
          : null,
      expiresAt: source.expiresAt,
    );
  }

  static String? _qualityLabel(StreamSource source) {
    final parts = <String>[];
    final format = source.format.trim().toUpperCase();
    if (format.isNotEmpty) parts.add(format);
    if (source.bitrate > 0) parts.add('${source.bitrate}kbps');
    if (parts.isEmpty) {
      return source.protocol == StreamProtocol.progressive
          ? null
          : source.protocol.label;
    }
    return parts.join(' ');
  }
}
