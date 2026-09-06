import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart'
    show AudioSession, AudioSessionConfiguration, AudioInterruptionType;
import 'package:audioplayers/audioplayers.dart';
import 'package:spotimusic/core/data/background_playback_policy.dart';
import 'package:spotimusic/core/monitoring/crash_reporter.dart';
import 'package:spotimusic/engine/audio_characteristics.dart';
import 'package:spotimusic/engine/crossfade_policy.dart';
import 'package:spotimusic/engine/gapless_policy.dart';
import 'package:spotimusic/engine/replay_gain.dart';
import 'package:spotimusic/services/app_state_database.dart';
import 'package:spotimusic/services/media_browse_tree.dart';
import 'package:spotimusic/services/platform_bridge.dart';
import 'package:spotimusic/utils/int_utils.dart';
import 'package:spotimusic/utils/logger.dart';
import 'package:spotimusic/utils/string_utils.dart';

final _log = AppLogger('MusicPlayer');

String _playbackUnknownTitle = 'Unknown title';
String _playbackUnknownArtist = 'Unknown artist';

void updateMusicPlayerStrings({
  required String unknownTitle,
  required String unknownArtist,
}) {
  _playbackUnknownTitle = unknownTitle;
  _playbackUnknownArtist = unknownArtist;
}

bool _playbackNormalizationEnabled = false;
bool _playbackGaplessEnabled = true;
CrossfadeSettings _playbackCrossfade = const CrossfadeSettings.off();
MusicPlayerHandler? _activeMusicPlayerHandler;

/// Enables/disables ReplayGain volume normalization and re-applies it to the
/// track currently playing.
void setPlaybackNormalizationEnabled(bool enabled) {
  if (_playbackNormalizationEnabled == enabled) return;
  _playbackNormalizationEnabled = enabled;
  _activeMusicPlayerHandler?.reapplyNormalization();
}

/// Enables/disables gapless transitions between consecutive queue items. When
/// enabled, the handler skips source teardown between compatible tracks so a
/// FLAC→FLAC (or other lossless) sequence splices without a silence gap.
void setPlaybackGaplessEnabled(bool enabled) {
  _playbackGaplessEnabled = enabled;
}

/// Configures crossfading between consecutive queue items. The handler
/// overlaps the tail of the playing track with the head of the next one on a
/// second player and ramps both with an equal-power curve; see
/// [CrossfadePolicy] for when smart mode skips the overlap.
void setPlaybackCrossfade(CrossfadeSettings settings) {
  _playbackCrossfade = settings;
}

/// Parses a dynamic value to a finite double, or returns null. Accepts [num]
/// and parseable [String] values; rejects NaN and infinities.
double? readFiniteDouble(dynamic value) {
  if (value == null) return null;
  final parsed = value is num ? value.toDouble() : double.tryParse('$value');
  if (parsed == null || !parsed.isFinite) return null;
  return parsed;
}

final AudioContext _musicAudioContext = AudioContext(
  android: const AudioContextAndroid(
    audioFocus: AndroidAudioFocus.none,
    contentType: AndroidContentType.music,
    usageType: AndroidUsageType.media,
    stayAwake: true,
  ),
);

class PlayableMedia {
  final String id;
  final String source;
  final String title;
  final String artist;
  final String album;
  final String? artUri;
  final Duration? duration;
  final int? bitDepth;
  final int? sampleRate;
  final int? bitrate;
  final String? format;
  final bool explicit;

  /// Engine-side context carried through audio_service for the Liquid Glass
  /// UI: 'local' | 'stream' | 'download'.
  final String? playbackMode;

  /// Display quality label (e.g. "MP3 128kbps").
  final String? qualityLabel;

  /// Provider display name for the source chip.
  final String? sourceLabel;

  /// Stable provider id used by the health registry / failover hook.
  final String? providerId;

  /// ReplayGain loudness metadata (dB gains + linear peak). For local files
  /// these are probed from tags at play time; for streams they are carried by
  /// the engine from the resolved `StreamDescriptor`.
  final double? trackGainDb;
  final double? albumGainDb;
  final double? trackPeak;

  /// When a signed stream URL stops being valid (null = unknown/long-lived).
  /// Carried from the resolved `StreamDescriptor` so the player can hand the
  /// item back to the engine for a proactive refresh *before* the CDN starts
  /// rejecting range requests mid-track.
  final DateTime? expiresAt;

  const PlayableMedia({
    required this.id,
    required this.source,
    required this.title,
    required this.artist,
    this.album = '',
    this.artUri,
    this.duration,
    this.bitDepth,
    this.sampleRate,
    this.bitrate,
    this.format,
    this.explicit = false,
    this.playbackMode,
    this.qualityLabel,
    this.sourceLabel,
    this.providerId,
    this.trackGainDb,
    this.albumGainDb,
    this.trackPeak,
    this.expiresAt,
  });

  bool get isContentUri => source.startsWith('content://');

  /// Progressive URL sources (http/https). The engine resolves these with the
  /// streaming engine and plays them with [UrlSource].
  bool get isRemoteHttp =>
      source.startsWith('http://') || source.startsWith('https://');

  /// Scheme for queue items whose real source (local file or fresh stream
  /// URL) is resolved lazily by the streaming engine when playback reaches
  /// them. Long queues cannot resolve every stream URL up front (providers
  /// rate-limit and URLs expire), so the engine defers resolution to play
  /// time via [deferredStreamResolver].
  static const String deferredStreamScheme = 'deferred-stream';

  bool get isDeferredStream => source.startsWith('$deferredStreamScheme://');

  /// Builds a deferred queue item for [trackId]. The engine owns the mapping
  /// media id → track and resolves a concrete source at play time.
  static String deferredStreamUriFor(String trackId) =>
      '$deferredStreamScheme://track/${Uri.encodeComponent(trackId)}';

  /// Technical characteristics used for gapless-transition planning.
  AudioCharacteristics get characteristics => AudioCharacteristics(
    codec: format,
    sampleRateHz: sampleRate,
    bitDepth: bitDepth,
    bitrateKbps: bitrate,
    lossless: GaplessPolicy.isGaplessCapableCodec(format),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'source': source,
    'title': title,
    'artist': artist,
    'album': album,
    if (artUri != null && artUri!.isNotEmpty) 'artUri': artUri,
    if (duration != null) 'durationMs': duration!.inMilliseconds,
    if (bitDepth != null && bitDepth! > 0) 'bitDepth': bitDepth,
    if (sampleRate != null && sampleRate! > 0) 'sampleRate': sampleRate,
    if (bitrate != null && bitrate! > 0) 'bitrate': bitrate,
    if (format != null && format!.trim().isNotEmpty) 'format': format,
    if (explicit) 'explicit': true,
    if (playbackMode != null && playbackMode!.trim().isNotEmpty)
      'playbackMode': playbackMode,
    if (qualityLabel != null && qualityLabel!.trim().isNotEmpty)
      'qualityLabel': qualityLabel,
    if (sourceLabel != null && sourceLabel!.trim().isNotEmpty)
      'sourceLabel': sourceLabel,
    if (providerId != null && providerId!.trim().isNotEmpty)
      'providerId': providerId,
    if (trackGainDb != null) 'trackGainDb': trackGainDb,
    if (albumGainDb != null) 'albumGainDb': albumGainDb,
    if (trackPeak != null) 'trackPeak': trackPeak,
    if (expiresAt != null) 'expiresAtMs': expiresAt!.millisecondsSinceEpoch,
  };

  static PlayableMedia? fromJson(Map<String, dynamic> json) {
    final id = normalizeOptionalString(json['id']?.toString());
    final source = normalizeOptionalString(json['source']?.toString());
    if (id == null || source == null) {
      return null;
    }
    final durationMs = readPositiveInt(json['durationMs']);
    return PlayableMedia(
      id: id,
      source: source,
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      album: json['album']?.toString() ?? '',
      artUri: normalizeCoverReference(json['artUri']?.toString()),
      duration: (durationMs != null && durationMs > 0)
          ? Duration(milliseconds: durationMs)
          : null,
      bitDepth: readPositiveInt(json['bitDepth']),
      sampleRate: readPositiveInt(json['sampleRate']),
      bitrate: readPositiveInt(json['bitrate']),
      format: json['format']?.toString(),
      explicit: parseExplicitFlag(json['explicit']) == true,
      playbackMode: json['playbackMode']?.toString(),
      qualityLabel: json['qualityLabel']?.toString(),
      sourceLabel: json['sourceLabel']?.toString(),
      providerId: json['providerId']?.toString(),
      trackGainDb: readFiniteDouble(json['trackGainDb']),
      albumGainDb: readFiniteDouble(json['albumGainDb']),
      trackPeak: readFiniteDouble(json['trackPeak']),
      expiresAt: _readEpochMs(json['expiresAtMs']),
    );
  }

  static DateTime? _readEpochMs(dynamic value) {
    final ms = readPositiveInt(value);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  MediaItem toMediaItem({String? resolvedSource}) {
    return MediaItem(
      id: id,
      title: title.isEmpty ? _playbackUnknownTitle : title,
      artist: artist.isEmpty ? _playbackUnknownArtist : artist,
      album: album.isEmpty ? null : album,
      duration: duration,
      artUri: (artUri != null && artUri!.isNotEmpty)
          ? Uri.tryParse(artUri!)
          : null,
      extras: {
        'source': source,
        if (resolvedSource != null && resolvedSource.isNotEmpty)
          'resolvedSource': resolvedSource,
        if (bitDepth != null && bitDepth! > 0) 'bit_depth': bitDepth,
        if (sampleRate != null && sampleRate! > 0) 'sample_rate': sampleRate,
        if (bitrate != null && bitrate! > 0) 'bitrate': bitrate,
        if (format != null && format!.trim().isNotEmpty)
          'format': format!.trim(),
        if (explicit) 'explicit': true,
        if (playbackMode != null && playbackMode!.trim().isNotEmpty)
          'playback_mode': playbackMode!.trim(),
        if (qualityLabel != null && qualityLabel!.trim().isNotEmpty)
          'quality_label': qualityLabel!.trim(),
        if (sourceLabel != null && sourceLabel!.trim().isNotEmpty)
          'source_label': sourceLabel!.trim(),
        if (providerId != null && providerId!.trim().isNotEmpty)
          'provider_id': providerId!.trim(),
        if (trackGainDb != null) 'track_gain_db': trackGainDb,
        if (albumGainDb != null) 'album_gain_db': albumGainDb,
        if (trackPeak != null) 'track_peak': trackPeak,
        if (expiresAt != null)
          'expires_at_ms': expiresAt!.millisecondsSinceEpoch,
      },
    );
  }
}

/// Technical audio metadata carried with a queue item. This is available
/// immediately when tracks change, before a fresh file probe completes.
Map<String, dynamic> playbackAudioMetadataFromMediaItem(MediaItem item) {
  final extras = item.extras;
  if (extras == null || extras.isEmpty) return const {};

  final metadata = <String, dynamic>{};
  final bitDepth = readPositiveInt(extras['bit_depth']);
  final sampleRate = readPositiveInt(extras['sample_rate']);
  final bitrate = readPositiveInt(extras['bitrate']);
  final format = extras['format']?.toString().trim();
  final explicit = parseExplicitFlag(extras['explicit']);
  if (bitDepth != null) metadata['bit_depth'] = bitDepth;
  if (sampleRate != null) metadata['sample_rate'] = sampleRate;
  if (bitrate != null) metadata['bitrate'] = bitrate;
  if (format != null && format.isNotEmpty) metadata['format'] = format;
  if (explicit != null) metadata['explicit'] = explicit;
  return metadata;
}

/// Combines the immediate queue metadata with the richer file probe while
/// retaining known quality fields when a decoder omits or reports them as 0.
Map<String, dynamic> mergePlaybackFileMetadata(
  Map<String, dynamic> fallback,
  Map<String, dynamic> probed,
) {
  final merged = <String, dynamic>{...fallback, ...probed};
  for (final key in const ['bit_depth', 'sample_rate', 'bitrate']) {
    if (readPositiveInt(probed[key]) == null &&
        readPositiveInt(fallback[key]) != null) {
      merged[key] = fallback[key];
    }
  }
  final probedFormat = probed['format']?.toString().trim();
  final fallbackFormat = fallback['format']?.toString().trim();
  if ((probedFormat == null || probedFormat.isEmpty) &&
      fallbackFormat != null &&
      fallbackFormat.isNotEmpty) {
    merged['format'] = fallbackFormat;
  }
  return merged;
}

typedef PlaybackMetadataReader =
    Future<Map<String, dynamic>> Function(String path);

/// Reads playback metadata with a small bounded retry window for transient
/// cold-start/native bridge failures.
///
/// The native bridge reports some read failures as an `error` field instead
/// of throwing. Treat both forms identically so Now Playing does not cache an
/// empty Lyrics view until the route is reopened. A successful response with
/// no lyrics is still final and is never retried.
Future<Map<String, dynamic>> readPlaybackFileMetadataWithRetry(
  String path, {
  PlaybackMetadataReader? reader,
  List<Duration> retryDelays = const [
    Duration.zero,
    Duration(milliseconds: 250),
    Duration(milliseconds: 750),
  ],
}) async {
  final read = reader ?? PlatformBridge.readFileMetadata;
  final delays = retryDelays.isEmpty ? const [Duration.zero] : retryDelays;
  Object? lastError;
  var lastStack = StackTrace.current;

  for (final delay in delays) {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    try {
      final metadata = await read(path);
      final reportedError = metadata['error']?.toString().trim() ?? '';
      if (reportedError.isEmpty) return metadata;
      lastError = StateError(reportedError);
      lastStack = StackTrace.current;
    } catch (error, stack) {
      lastError = error;
      lastStack = stack;
    }
  }

  Error.throwWithStackTrace(
    lastError ?? StateError('Metadata reader returned no result'),
    lastStack,
  );
}

/// Returns a safe source-start position for restored playback. A completed
/// snapshot starts over instead of immediately completing again on resume.
Duration normalizedPlaybackResumePosition(
  Duration position, {
  Duration? duration,
}) {
  if (position <= Duration.zero) return Duration.zero;
  if (duration != null && duration > Duration.zero && position >= duration) {
    return Duration.zero;
  }
  return position;
}

class MusicPlayerHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  /// The player carrying the *current* queue item. During a crossfade the
  /// incoming track starts on the standby player and the two swap roles, so
  /// every event handler filters on `identical(player, _player)`.
  AudioPlayer _player = AudioPlayer(playerId: 'music-player');

  /// Second player used for crossfades; created on first use and kept for
  /// reuse (each swap parks the finished outgoing player here).
  AudioPlayer? _standbyPlayer;

  /// The fading-out player of an in-flight crossfade, or null.
  _CrossfadeOutgoing? _outgoing;
  Timer? _crossfadeTimer;

  /// Play generation for which a crossfade was already triggered (so the
  /// position stream cannot start a second one for the same track).
  int _crossfadeTriggeredGeneration = -1;

  /// Cached crossfade plan for the current play generation.
  _CrossfadePlan? _crossfadePlan;

  /// Normalisation volume applied to the current item; the fade ramps scale
  /// against it so ReplayGain is preserved through the overlap.
  double _activeNormalizationVolume = 1.0;
  AudioSession? _audioSession;
  final List<PlayableMedia> _media = [];
  final List<MediaItem> _queueItems = [];
  final Map<String, String> _resolvedPathCache = {};
  final Map<String, Future<String?>> _pendingSourceResolutions = {};
  final List<String> _resolvedPathOrder = [];
  final Set<String> _pendingResolvedPathDeletes = {};
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  int _index = -1;
  int _playRequestGeneration = 0;
  String? _activeResolvedPath;
  bool _disposed = false;
  bool _initialized = false;
  bool _sourceReady = false;
  Future<void>? _activePlayOperation;

  bool _shuffle = false;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  final Random _random = Random();
  final List<int> _recent = [];
  final List<int> _playHistory = [];

  /// Indices already played in the current shuffle cycle. Shuffle has to end
  /// once every track has had a turn (unless repeat-all is on), and the
  /// anti-repetition window in [_recent] is deliberately shorter than the
  /// queue, so it cannot answer "has everything played yet?".
  final Set<int> _shufflePlayed = <int>{};

  // True when playback was paused because another app took audio focus.
  bool _pausedByInterruption = false;
  bool _interruptionActive = false;
  bool _userPaused = false;
  // Position saved with the restored session; applied on the first play().
  Duration? _pendingRestorePosition;
  bool _restoringSession = false;
  int _switchingGeneration = 0;
  Duration _lastBroadcastPosition = Duration.zero;
  DateTime? _lastPositionBroadcastAt;
  DateTime? _lastPeriodicPersistAt;
  Future<void> _sessionWriteTail = Future<void>.value();
  static const Duration _positionBroadcastInterval = Duration(
    milliseconds: 500,
  );
  static const Duration _positionPersistInterval = Duration(seconds: 10);
  static const int _maxResolvedPathCacheEntries = 64;

  /// Proactive stream-URL refresh (see [PlayableMedia.expiresAt]). Armed per
  /// play request for remote sources with a known expiry; cancelled on any
  /// track change/stop so a stale timer can never refresh the wrong item.
  Timer? _expiryRefreshTimer;
  static const Duration _expiryRefreshLeadTime = Duration(minutes: 2);
  static const Duration _expiryRefreshMinDelay = Duration(seconds: 30);

  /// Expiry of the concrete stream a *deferred* queue item resolved to. The
  /// engine reports it right after resolution (the deferred placeholder
  /// itself carries no expiry).
  final Map<String, DateTime> _deferredSourceExpiry = {};

  /// Runtime (post-`play()`) failures already forwarded for the current play
  /// generation. audioplayers may report the same underlying error more than
  /// once (platform error + log event); the failover hook must run once.
  int _runtimeFailureGeneration = -1;

  MusicPlayerHandler() {
    _activeMusicPlayerHandler = this;
    _init();
  }

  void _init() {
    if (_initialized) return;
    _initialized = true;
    _bindPlayer(_player);
    unawaited(_configureAudioSession());
  }

  /// Subscribes to one engine player. Events are only acted upon while that
  /// player is the active [_player]; the outgoing half of a crossfade is
  /// deliberately mute (its completion/stop must never advance the queue).
  void _bindPlayer(AudioPlayer player) {
    player.setReleaseMode(ReleaseMode.stop);
    unawaited(player.setAudioContext(_musicAudioContext));
    bool active() => identical(player, _player);

    _subscriptions.addAll([
      player.onPlayerStateChanged.listen((state) {
        if (!active()) return;
        if (_switchingGeneration != 0 &&
            (state == PlayerState.stopped ||
                state == PlayerState.completed ||
                state == PlayerState.disposed)) {
          _log.d('Ignoring transient $state event while switching tracks');
          return;
        }
        if (state == PlayerState.completed && _shouldIgnoreComplete) {
          if (_userPaused || _interruptionActive) {
            _broadcastState(playerState: PlayerState.paused);
          }
          return;
        }
        _broadcastState(playerState: state);
      }),
      player.onPositionChanged.listen((position) {
        if (active()) _handlePositionChanged(position);
      }),
      player.onDurationChanged.listen((duration) {
        if (!active()) return;
        final current = mediaItem.value;
        if (current != null && duration > Duration.zero) {
          mediaItem.add(current.copyWith(duration: duration));
        }
      }),
      player.onPlayerComplete.listen((_) {
        if (!active()) return;
        unawaited(_handlePlayerComplete());
      }),
      // Runtime failures (CDN drop, expired signed URL, decoder error) arrive
      // on the event stream's *error* channel after play() has already
      // returned. Without this listener they were only logged by the plugin
      // and a streamed track silently stopped; now they reach the streaming
      // engine's failover hook exactly like a synchronous play() failure.
      player.eventStream.listen(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (active()) _handleRuntimePlaybackError(error);
        },
      ),
    ]);
  }

  /// Forwards an asynchronous player error for the current item to the
  /// failover hook (once per play generation) and reflects the stop in the
  /// broadcast state so the UI never shows "playing" for a dead source.
  void _handleRuntimePlaybackError(Object error) {
    if (_disposed) return;
    if (_index < 0 || _index >= _media.length) return;
    // Errors raised while a source is still being prepared also fail the
    // pending play() future (audioplayers awaits the prepared event), and
    // that path already reports to the failover hook. Only *post*-prepare
    // failures are handled here.
    if (_switchingGeneration != 0 || !_sourceReady) return;
    final generation = _playRequestGeneration;
    if (_runtimeFailureGeneration == generation) return;
    _runtimeFailureGeneration = generation;
    final media = _media[_index];
    _log.e('Runtime playback error for ${media.title}: $error');
    _reportPlaybackFailure('runtime-error', media, error);
    _cancelExpiryRefresh();
    _sourceReady = false;
    final listener = playbackFailureListener;
    if (listener != null && (media.isRemoteHttp || media.isDeferredStream)) {
      listener(media, error);
    }
    _broadcastState(playerState: PlayerState.stopped);
  }

  void _cancelExpiryRefresh() {
    _expiryRefreshTimer?.cancel();
    _expiryRefreshTimer = null;
  }

  /// Records when the stream a deferred item just resolved to will expire
  /// (null clears it). Called by the streaming engine from its deferred
  /// resolver, before the handler starts the source.
  void noteDeferredSourceExpiry(String mediaId, DateTime? expiresAt) {
    if (expiresAt == null) {
      _deferredSourceExpiry.remove(mediaId);
      return;
    }
    if (_deferredSourceExpiry.length > 64) _deferredSourceExpiry.clear();
    _deferredSourceExpiry[mediaId] = expiresAt;
  }

  /// Arms a one-shot refresh for a remote source whose signed URL expires at
  /// a known time. The refresh is delegated to the engine through the same
  /// failure hook used for failover, with a synthetic "expired" error, so the
  /// engine re-resolves and swaps the source at the live position.
  void _armExpiryRefresh(PlayableMedia media, String resolved, int generation) {
    _cancelExpiryRefresh();
    final expiresAt =
        media.expiresAt ??
        (media.isDeferredStream ? _deferredSourceExpiry[media.id] : null);
    if (expiresAt == null || !_isHttpSource(resolved)) return;
    if (playbackFailureListener == null) return;
    final now = DateTime.now();
    // Already expired: the source is played as-is and a real error (not a
    // proactive refresh) drives failover, so a short-lived replacement URL
    // can never loop refresh -> resolve -> refresh.
    if (!expiresAt.isAfter(now)) return;
    var delay = expiresAt.subtract(_expiryRefreshLeadTime).difference(now);
    if (delay < _expiryRefreshMinDelay) delay = _expiryRefreshMinDelay;
    _expiryRefreshTimer = Timer(delay, () {
      _expiryRefreshTimer = null;
      if (_disposed || generation != _playRequestGeneration) return;
      if (_index < 0 || _index >= _media.length) return;
      if (!identical(_media[_index], media)) return;
      // Only refresh while audio is actually running; a paused stream is
      // refreshed lazily by the next play() -> engine resolution.
      if (_player.state != PlayerState.playing) return;
      _log.i('Stream URL for ${media.title} is about to expire; refreshing');
      playbackFailureListener?.call(
        media,
        const StreamUrlExpiringSignal(),
      );
    });
  }

  /// Phase 10: playback failures feed the crash reporter (breadcrumb for
  /// context + a non-fatal `playback` event). Reporting is best-effort and
  /// disabled (no-op) unless a DSN was configured at bootstrap.
  void _reportPlaybackFailure(String phase, PlayableMedia media, Object error) {
    final reporter = CrashReporter.instance;
    if (!reporter.isEnabled) return;
    reporter.addBreadcrumb(
      'playback failed: ${media.title}',
      category: CrashCategory.playback,
      level: CrashSeverity.warning,
      data: {'phase': phase},
    );
    unawaited(
      reporter.captureError(
        error,
        null,
        category: CrashCategory.playback,
        severity: CrashSeverity.error,
        context: {
          'phase': phase,
          'title': media.title,
          'artist': media.artist,
          'is_remote': media.isRemoteHttp,
          'is_deferred': media.isDeferredStream,
        },
        fingerprint: ['playback', phase],
      ),
    );
  }

  /// Phase 10: successful track starts are the single most useful breadcrumb
  /// when triaging a later failure.
  void _reportTrackStarted(PlayableMedia media) {
    final reporter = CrashReporter.instance;
    if (!reporter.isEnabled) return;
    reporter.addBreadcrumb(
      'playing: ${media.title}',
      category: CrashCategory.playback,
      data: {'artist': media.artist},
    );
  }

  /// Configures the OS audio session and reacts to interruptions (e.g. another
  /// app like PowerAmp taking audio focus, or headphones unplugged) so playback
  /// pauses and the UI/notification reflect the real state instead of staying
  /// stuck on "playing".
  Future<void> _configureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      _audioSession = session;
      await session.configure(const AudioSessionConfiguration.music());
      // AudioSession initialization is intentionally asynchronous. The handler
      // may have been disposed while configuration awaited platform setup; do
      // not attach process-lifetime listeners to a dead player in that case.
      if (_disposed) return;

      _subscriptions.add(
        session.interruptionEventStream.listen((event) {
          _log.d(
            'Audio interruption ${event.begin ? 'began' : 'ended'} '
            'type=${event.type} player=${_player.state} '
            'playing=${playbackState.value.playing}',
          );
          final kind = _interruptionKind(event.type);
          if (event.begin) {
            final decision = BackgroundPlaybackPolicy.onInterruptionBegan(kind);
            switch (decision.action) {
              case BackgroundPlaybackAction.ignore:
                return;
              case BackgroundPlaybackAction.pauseAndMarkResumable:
                _interruptionActive = true;
                _pausedByInterruption =
                    _player.state == PlayerState.playing ||
                    playbackState.value.playing;
                unawaited(
                  _pauseForFocusLoss(
                    reason: decision.reason ?? 'audio interruption',
                  ),
                );
              case BackgroundPlaybackAction.pauseSticky:
                _interruptionActive = true;
                _pausedByInterruption = false;
                unawaited(
                  _pauseForFocusLoss(
                    reason: decision.reason ?? 'audio interruption',
                  ),
                );
              case BackgroundPlaybackAction.resume:
              case BackgroundPlaybackAction.stayPaused:
                return;
            }
          } else {
            final decision = BackgroundPlaybackPolicy.onInterruptionEnded(
              kind: kind,
              pausedByInterruption: _pausedByInterruption,
              userPaused: _userPaused,
            );
            _interruptionActive = false;
            switch (decision.action) {
              case BackgroundPlaybackAction.ignore:
                return;
              case BackgroundPlaybackAction.resume:
                _pausedByInterruption = false;
                unawaited(play());
              case BackgroundPlaybackAction.stayPaused:
              case BackgroundPlaybackAction.pauseSticky:
              case BackgroundPlaybackAction.pauseAndMarkResumable:
                _pausedByInterruption = false;
            }
          }
        }),
      );

      _subscriptions.add(
        session.becomingNoisyEventStream.listen((_) {
          final decision = BackgroundPlaybackPolicy.becomingNoisy;
          _pausedByInterruption = false;
          unawaited(
            _pauseForFocusLoss(reason: decision.reason ?? 'becoming noisy'),
          );
        }),
      );
    } catch (e) {
      _log.w('Failed to configure audio session: $e');
    }
  }

  AudioInterruptionKind _interruptionKind(AudioInterruptionType type) {
    return switch (type) {
      AudioInterruptionType.duck => AudioInterruptionKind.duck,
      AudioInterruptionType.pause => AudioInterruptionKind.pause,
      _ => AudioInterruptionKind.unknown,
    };
  }

  static bool _isHttpSource(String source) =>
      source.startsWith('http://') || source.startsWith('https://');

  bool get _shouldIgnoreComplete =>
      _switchingGeneration != 0 || _interruptionActive || _userPaused;

  Future<void> _pauseForFocusLoss({required String reason}) async {
    _log.i('Pausing internal player because of $reason');
    _playRequestGeneration++;
    _cancelExpiryRefresh();
    _switchingGeneration = 0;
    _endCrossfade();
    try {
      await _player.pause();
    } catch (e) {
      _log.w('Failed to pause after audio focus loss: $e');
    }
    // Force the UI/notification to reflect the pause even if the engine does
    // not emit a state-change event on focus loss.
    _broadcastState(playerState: PlayerState.paused);
    await _persistSession(position: await _currentPositionForPersist());
  }

  Future<void> _activateAudioSession() async {
    try {
      final session = _audioSession ?? await AudioSession.instance;
      _audioSession = session;
      final granted = await session.setActive(true);
      if (!granted) {
        _log.w('Audio focus request was not granted');
      }
    } catch (e) {
      _log.w('Failed to activate audio session: $e');
    }
  }

  AudioProcessingState _mapProcessingState(PlayerState state) {
    switch (state) {
      case PlayerState.playing:
      case PlayerState.paused:
        return AudioProcessingState.ready;
      case PlayerState.completed:
        return AudioProcessingState.completed;
      case PlayerState.stopped:
      case PlayerState.disposed:
        return AudioProcessingState.idle;
    }
  }

  void _broadcastState({PlayerState? playerState, bool? loading}) {
    final state = playerState ?? _player.state;
    final playing = state == PlayerState.playing;

    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.skipToPrevious,
          MediaAction.skipToNext,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: (loading == true)
            ? AudioProcessingState.loading
            : _mapProcessingState(state),
        playing: playing,
        shuffleMode: _shuffle
            ? AudioServiceShuffleMode.all
            : AudioServiceShuffleMode.none,
        repeatMode: _repeatMode,
      ),
    );
  }

  void _broadcastPosition(Duration position, {bool force = false}) {
    final now = DateTime.now();
    final lastAt = _lastPositionBroadcastAt;
    final elapsed = lastAt == null ? null : now.difference(lastAt);
    final moved = (position - _lastBroadcastPosition).abs();
    if (!force &&
        elapsed != null &&
        elapsed < _positionBroadcastInterval &&
        moved < _positionBroadcastInterval) {
      return;
    }
    _lastPositionBroadcastAt = now;
    _lastBroadcastPosition = position;
    playbackState.add(playbackState.value.copyWith(updatePosition: position));
  }

  void _handlePositionChanged(Duration position) {
    _broadcastPosition(position);
    if (_restoringSession ||
        _player.state != PlayerState.playing ||
        _media.isEmpty ||
        _index < 0 ||
        _index >= _media.length) {
      return;
    }

    _maybeStartCrossfade(position);

    final now = DateTime.now();
    final lastPersistAt = _lastPeriodicPersistAt;
    if (lastPersistAt != null &&
        now.difference(lastPersistAt) < _positionPersistInterval) {
      return;
    }
    _lastPeriodicPersistAt = now;
    unawaited(_persistSession(position: position));
  }

  /// Whether the transition from [previousIndex] to [next] may skip tearing
  /// down the source (a true gapless splice). Only compatible lossless items
  /// on the same transport qualify.
  bool _planGaplessTeardown(int previousIndex, PlayableMedia next) {
    if (!_playbackGaplessEnabled) return false;
    if (previousIndex < 0 || previousIndex >= _media.length) return false;
    if (previousIndex == _index) return false; // repeat-one / same-item replay
    final previous = _media[previousIndex];
    final decision = const GaplessPolicy().decide(
      enabled: true,
      current: previous.characteristics,
      next: next.characteristics,
      sameTransport: previous.isRemoteHttp == next.isRemoteHttp,
    );
    return decision.canSkipSourceTeardown;
  }

  // ---- Crossfade -----------------------------------------------------------

  /// Next queue index playback would advance to when the current item ends,
  /// or null when it would stop (end of queue, repeat-one, shuffle cycle
  /// complete). Mirrors [_onComplete] / [_advanceShuffled] without side
  /// effects, except that shuffle picks are random per call.
  int? _peekNextIndex() {
    if (_media.isEmpty || _index < 0 || _index >= _media.length) return null;
    if (_repeatMode == AudioServiceRepeatMode.one) return null;
    if (_shuffle) {
      if (_media.length <= 1) return null;
      if (_shufflePlayed.length >= _media.length &&
          _repeatMode != AudioServiceRepeatMode.all) {
        return null;
      }
      return _pickNextShuffle();
    }
    if (_index < _media.length - 1) return _index + 1;
    if (_repeatMode == AudioServiceRepeatMode.all) return 0;
    return null;
  }

  Duration? _currentTrackDuration(PlayableMedia media) {
    final item = mediaItem.value;
    if (item != null && item.id == media.id) {
      final duration = item.duration;
      if (duration != null && duration > Duration.zero) return duration;
    }
    final duration = media.duration;
    return duration != null && duration > Duration.zero ? duration : null;
  }

  /// Plans (and caches per play generation) the crossfade into the next
  /// item. Null when this transition must not crossfade.
  _CrossfadePlan? _crossfadePlanFor(int generation, PlayableMedia current) {
    final cached = _crossfadePlan;
    if (cached != null &&
        cached.generation == generation &&
        cached.nextIndex < _media.length &&
        _media[cached.nextIndex].id == cached.nextMediaId &&
        cached.settings == _playbackCrossfade &&
        cached.shuffle == _shuffle &&
        cached.repeatMode == _repeatMode) {
      return cached.decision.shouldCrossfade ? cached : null;
    }
    final settings = _playbackCrossfade;
    final nextIndex = settings.enabled ? _peekNextIndex() : null;
    if (nextIndex == null) {
      _crossfadePlan = null;
      return null;
    }
    final next = _media[nextIndex];
    final duration = _currentTrackDuration(current);
    // An unknown duration is re-evaluated on later ticks (the engine may
    // still report it); every other verdict is final for this generation.
    if (duration == null) return null;
    final decision = const CrossfadePolicy().decide(
      settings: settings,
      trackDuration: duration,
      current: current.characteristics,
      next: next.characteristics,
      sameTransport: current.isRemoteHttp == next.isRemoteHttp,
      gaplessEnabled: _playbackGaplessEnabled,
      sameAlbum:
          current.album.trim().isNotEmpty &&
          current.album.trim().toLowerCase() ==
              next.album.trim().toLowerCase(),
      sequentialNeighbours: !_shuffle && nextIndex == _index + 1,
      repeatOne: _repeatMode == AudioServiceRepeatMode.one,
    );
    final plan = _CrossfadePlan(
      generation: generation,
      nextIndex: nextIndex,
      nextMediaId: next.id,
      settings: settings,
      decision: decision,
      duration: duration,
      shuffle: _shuffle,
      repeatMode: _repeatMode,
    );
    _crossfadePlan = plan;
    return decision.shouldCrossfade ? plan : null;
  }

  void _maybeStartCrossfade(Duration position) {
    if (!_playbackCrossfade.enabled) return;
    if (!_sourceReady ||
        _switchingGeneration != 0 ||
        _outgoing != null ||
        _userPaused ||
        _interruptionActive) {
      return;
    }
    final generation = _playRequestGeneration;
    if (_crossfadeTriggeredGeneration == generation) return;
    final current = _media[_index];
    final plan = _crossfadePlanFor(generation, current);
    if (plan == null) return;
    if (!plan.decision.shouldStartAt(position, plan.duration)) return;
    // Sanity: a fade that would start in the first seconds of the track
    // means the duration metadata is wrong; let the track finish normally.
    if (position < const Duration(seconds: 3)) return;

    _crossfadeTriggeredGeneration = generation;
    _log.i(
      'Crossfade ${plan.decision.fade!.inMilliseconds}ms → '
      '${_media[plan.nextIndex].title} (${plan.decision.reason})',
    );
    if (_shuffle && _shufflePlayed.length >= _media.length) {
      // Repeat-all shuffle cycle boundary (see _advanceShuffled).
      _shufflePlayed.clear();
      _recent.clear();
    }
    // The outgoing track counts as listened to completion: nothing audible
    // is skipped, only overlapped.
    playbackStatsObserver?.onCompleted(current, plan.duration);
    // Swap roles synchronously: the current player keeps playing as the
    // outgoing half of the fade (its events are ignored from now on) and
    // the incoming track starts on the standby player.
    final incoming = _takeStandbyPlayer();
    _outgoing = _CrossfadeOutgoing(
      player: _player,
      volume: _activeNormalizationVolume,
      fade: plan.decision.fade!,
      endsAt: DateTime.now().add(plan.duration - position),
    );
    _player = incoming;
    unawaited(_playIndex(plan.nextIndex, crossfade: true));
  }

  /// Returns the idle second player, creating and binding it on first use.
  /// Any fade still running is ended first so its player can be reused.
  AudioPlayer _takeStandbyPlayer() {
    _endCrossfade();
    var standby = _standbyPlayer;
    if (standby == null) {
      standby = AudioPlayer(playerId: 'music-player-crossfade');
      _bindPlayer(standby);
    }
    _standbyPlayer = null;
    return standby;
  }

  /// Ends an in-flight crossfade immediately: the outgoing player stops and
  /// is parked as standby, and the active player is restored to its full
  /// normalised volume (a pause mid-ramp must not leave it half-faded).
  void _endCrossfade() {
    final timer = _crossfadeTimer;
    _crossfadeTimer = null;
    timer?.cancel();
    final outgoing = _outgoing;
    _outgoing = null;
    if (outgoing == null) return;
    _standbyPlayer = outgoing.player;
    unawaited(_stopQuietly(outgoing.player));
    if (timer != null) {
      unawaited(_setVolumeQuietly(_player, _activeNormalizationVolume));
    }
  }

  Future<void> _stopQuietly(AudioPlayer player) async {
    try {
      await player.stop();
    } catch (e) {
      _log.w('Failed to stop crossfade player: $e');
    }
  }

  Future<void> _setVolumeQuietly(AudioPlayer player, double volume) async {
    try {
      await player.setVolume(volume.clamp(0.0, 1.0));
    } catch (e) {
      _log.w('Failed to set crossfade volume: $e');
    }
  }

  /// Ramps the incoming player up and the outgoing one down over the fade
  /// with an equal-power curve, then stops the outgoing player.
  void _startCrossfadeRamp(int generation) {
    final outgoing = _outgoing;
    if (outgoing == null) return;
    final startedAt = DateTime.now();
    // Source preparation may have eaten into the overlap; never ramp past
    // the moment the outgoing track ends on its own.
    final remaining = outgoing.endsAt.difference(startedAt);
    final span = remaining < outgoing.fade ? remaining : outgoing.fade;
    final totalMs = span.inMilliseconds.clamp(200, 1 << 30);
    _crossfadeTimer?.cancel();
    _crossfadeTimer = Timer.periodic(const Duration(milliseconds: 60), (
      timer,
    ) {
      if (_disposed ||
          !identical(_outgoing, outgoing) ||
          generation != _playRequestGeneration) {
        timer.cancel();
        if (identical(_crossfadeTimer, timer)) _crossfadeTimer = null;
        return;
      }
      final elapsed = DateTime.now().difference(startedAt).inMilliseconds;
      final progress = elapsed / totalMs;
      final gains = CrossfadePolicy.equalPowerGains(progress);
      // Read live so a normalization toggle mid-fade lands on the ramp.
      unawaited(
        _setVolumeQuietly(_player, gains.incoming * _activeNormalizationVolume),
      );
      unawaited(
        _setVolumeQuietly(outgoing.player, gains.outgoing * outgoing.volume),
      );
      if (progress >= 1) {
        timer.cancel();
        if (identical(_crossfadeTimer, timer)) _crossfadeTimer = null;
        if (identical(_outgoing, outgoing)) {
          _outgoing = null;
          _standbyPlayer = outgoing.player;
          unawaited(_stopQuietly(outgoing.player));
        }
      }
    });
  }

  // ReplayGain normalization: resolved path -> volume multiplier.
  final Map<String, double> _normalizationVolumeCache = {};

  /// Volume multiplier from the file's ReplayGain/R128 tags (track gain,
  /// album gain fallback; Opus R128 tags are converted to ReplayGain dB by
  /// the Go reader). 1.0 when disabled, untagged, or unreadable. Positive
  /// gains clamp at 1.0 — setVolume can only attenuate.
  ///
  /// Remote streams carry their gain on [PlayableMedia] (from the resolved
  /// `StreamDescriptor`); local files are probed here.
  Future<double> _normalizationVolumeFor(String path, PlayableMedia media) async {
    if (!_playbackNormalizationEnabled) return 1.0;

    if (media.isRemoteHttp) {
      return ReplayGain.volume(
        trackGainDb: media.trackGainDb,
        albumGainDb: media.albumGainDb,
        trackPeak: media.trackPeak,
      );
    }
    if (media.isDeferredStream && _isHttpSource(path)) {
      // Deferred queue item that resolved to a stream URL: gains were carried
      // on the media by the engine, exactly like a pre-resolved URL source.
      return ReplayGain.volume(
        trackGainDb: media.trackGainDb,
        albumGainDb: media.albumGainDb,
        trackPeak: media.trackPeak,
      );
    }

    final cached = _normalizationVolumeCache[path];
    if (cached != null) return cached;

    var volume = 1.0;
    try {
      final metadata = await PlatformBridge.readFileMetadata(path);
      volume = ReplayGain.volume(
        trackGainDb: ReplayGain.parseGainDb(metadata['replaygain_track_gain']),
        albumGainDb: ReplayGain.parseGainDb(metadata['replaygain_album_gain']),
        trackPeak: ReplayGain.parsePeak(metadata['replaygain_track_peak']),
      );
    } catch (e) {
      _log.w('Failed to read gain tags for normalization: $e');
    }
    if (_normalizationVolumeCache.length > 128) {
      _normalizationVolumeCache.clear();
    }
    _normalizationVolumeCache[path] = volume;
    return volume;
  }

  /// Re-applies normalization to the playing track when the setting flips.
  void reapplyNormalization() {
    final index = _index;
    final generation = _playRequestGeneration;
    if (index < 0 || index >= _media.length) return;
    unawaited(() async {
      final media = _media[index];
      final resolved = media.isContentUri
          ? _resolvedPathCache[media.source]
          : media.source;
      if (resolved == null) return;
      final volume = await _normalizationVolumeFor(resolved, media);
      if (_index != index || generation != _playRequestGeneration) return;
      _activeNormalizationVolume = volume;
      if (_crossfadeTimer != null) return; // the ramp applies it
      try {
        await _player.setVolume(volume);
      } catch (e) {
        _log.w('Failed to apply normalization volume: $e');
      }
    }());
  }

  Future<String?> _resolveSource(PlayableMedia media) async {
    if (media.isDeferredStream) {
      // Engine-owned queue item: resolve a fresh local path / stream URL at
      // play time (Smart Play ladder re-runs, so an expired URL or a newly
      // downloaded file is both handled).
      final resolver = deferredStreamResolver;
      if (resolver == null) {
        _log.w('No deferred-stream resolver installed for ${media.title}');
        return null;
      }
      try {
        return await resolver(media);
      } catch (e) {
        _log.e('Deferred source resolution failed for ${media.title}: $e');
        return null;
      }
    }
    if (!media.isContentUri) return media.source;

    final cached = _resolvedPathCache[media.source];
    if (cached != null) return cached;
    final inFlight = _pendingSourceResolutions[media.source];
    if (inFlight != null) return inFlight;

    final resolution = () async {
      try {
        final tempPath = await PlatformBridge.copyContentUriToTemp(
          media.source,
        );
        if (tempPath == null || tempPath.isEmpty) return null;
        if (_disposed) {
          await _discardResolvedPath(tempPath);
          return null;
        }

        _resolvedPathCache[media.source] = tempPath;
        _resolvedPathOrder
          ..remove(media.source)
          ..add(media.source);
        while (_resolvedPathOrder.length > _maxResolvedPathCacheEntries) {
          final evictedSource = _resolvedPathOrder.removeAt(0);
          final evictedPath = _resolvedPathCache.remove(evictedSource);
          if (evictedPath != null) {
            unawaited(_discardResolvedPath(evictedPath));
          }
        }
        return tempPath;
      } catch (e) {
        _log.e('Failed to resolve content URI for playback: $e');
        return null;
      }
    }();
    _pendingSourceResolutions[media.source] = resolution;
    try {
      return await resolution;
    } finally {
      if (identical(_pendingSourceResolutions[media.source], resolution)) {
        _pendingSourceResolutions.remove(media.source);
      }
    }
  }

  Future<void> _discardResolvedPath(String path) async {
    if (path == _activeResolvedPath) {
      _pendingResolvedPathDeletes.add(path);
      return;
    }
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      _log.w('Failed to delete SAF playback temp file: $e');
    }
  }

  Future<void> _cleanupPendingResolvedPaths() async {
    final deletable = _pendingResolvedPathDeletes
        .where((path) => path != _activeResolvedPath)
        .toList(growable: false);
    for (final path in deletable) {
      _pendingResolvedPathDeletes.remove(path);
      await _discardResolvedPath(path);
    }
  }

  Future<void> _enqueueSessionWrite(Future<void> Function() operation) {
    final queued = _sessionWriteTail.then((_) async {
      try {
        await operation();
      } catch (e) {
        _log.w('Failed to update persisted playback session: $e');
      }
    });
    _sessionWriteTail = queued;
    return queued;
  }

  /// Persists queue, current index, and position so a killed process can
  /// restore the session paused on next launch. Position updates are throttled
  /// by [_handlePositionChanged], while lifecycle/pause writes flush exactly.
  Future<void> _persistSession({Duration? position}) {
    if (_restoringSession) return Future<void>.value();
    if (_media.isEmpty || _index < 0 || _index >= _media.length) {
      return _enqueueSessionWrite(
        AppStateDatabase.instance.clearPlaybackSession,
      );
    }
    final session = <String, dynamic>{
      'version': 1,
      'media': _media.map((m) => m.toJson()).toList(growable: false),
      'index': _index,
      'positionMs': (position ?? Duration.zero).inMilliseconds,
      'shuffle': _shuffle,
      'repeat': _repeatMode.name,
    };
    return _enqueueSessionWrite(
      () => AppStateDatabase.instance.savePlaybackSession(session),
    );
  }

  Future<Duration> _currentPositionForPersist() async {
    // During restore/source preparation the engine may report a stale zero (or
    // the previous source). The broadcast position already represents the
    // intended start point for the current queue item.
    if (!_sourceReady) return playbackState.value.position;
    try {
      final position = await _player.getCurrentPosition();
      if (position != null) return position;
    } catch (e) {
      _log.d('best-effort step failed: $e');
    }
    return playbackState.value.position;
  }

  /// Flushes the live engine position and every older queued session write.
  /// Called when the app leaves the foreground so a normal restart resumes at
  /// the latest audible point rather than the beginning of the track.
  Future<void> persistCurrentSession() async {
    if (_media.isEmpty || _index < 0 || _index >= _media.length) return;
    final position = await _currentPositionForPersist();
    _lastPeriodicPersistAt = DateTime.now();
    await _persistSession(position: position);
  }

  /// Restores a persisted session paused: queue and current track become
  /// visible (mini player included) without loading any source; the first
  /// play() prepares the source directly at the saved position.
  Future<void> restoreSession({
    required List<PlayableMedia> items,
    required int index,
    required Duration position,
    required bool shuffle,
    AudioServiceRepeatMode repeatMode = AudioServiceRepeatMode.none,
  }) async {
    if (items.isEmpty) return;
    // Never clobber a session the user already started this launch.
    if (_media.isNotEmpty || _index >= 0) return;
    _restoringSession = true;
    try {
      _media
        ..clear()
        ..addAll(items);
      _queueItems
        ..clear()
        ..addAll(items.map((m) => m.toMediaItem()));
      _index = index.clamp(0, items.length - 1);
      _shuffle = shuffle;
      _repeatMode = repeatMode;
      _pendingRestorePosition = position > Duration.zero ? position : null;
      _sourceReady = false;
      _lastPeriodicPersistAt = null;
      queue.add(List<MediaItem>.unmodifiable(_queueItems));
      mediaItem.add(_media[_index].toMediaItem());
      if (position > Duration.zero) {
        playbackState.add(
          playbackState.value.copyWith(updatePosition: position),
        );
      }
      // iOS 17+ kills an app that starts audio from the background without
      // an active session; the policy always restores paused.
      if (BackgroundPlaybackPolicy.restoreSessionPaused()) {
        _broadcastState(playerState: PlayerState.paused);
      }
    } finally {
      _restoringSession = false;
    }
  }

  bool _isCurrentPlayRequest(int generation, PlayableMedia media) {
    return generation == _playRequestGeneration &&
        _index >= 0 &&
        _index < _media.length &&
        _media[_index].id == media.id &&
        _media[_index].source == media.source;
  }

  Future<void> setQueueAndPlay(
    List<PlayableMedia> items, {
    int initialIndex = 0,
  }) async {
    if (items.isEmpty) return;
    _playRequestGeneration++;
    _media
      ..clear()
      ..addAll(items);
    _queueItems
      ..clear()
      ..addAll(items.map((m) => m.toMediaItem()));
    _recent.clear();
    _playHistory.clear();
    _shufflePlayed.clear();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    await _playIndex(initialIndex.clamp(0, items.length - 1));
  }

  Future<void> enqueue(PlayableMedia item, {bool playNext = false}) async {
    if (_media.isEmpty || _index < 0) {
      await setQueueAndPlay([item]);
      return;
    }
    final insertAt = playNext
        ? (_index + 1).clamp(0, _media.length)
        : _media.length;
    _media.insert(insertAt, item);
    _queueItems.insert(insertAt, item.toMediaItem());

    for (var i = 0; i < _recent.length; i++) {
      if (_recent[i] >= insertAt) _recent[i]++;
    }
    for (var i = 0; i < _playHistory.length; i++) {
      if (_playHistory[i] >= insertAt) _playHistory[i]++;
    }

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> enqueueAll(
    List<PlayableMedia> items, {
    bool playNext = false,
  }) async {
    if (items.isEmpty) return;
    if (_media.isEmpty || _index < 0) {
      await setQueueAndPlay(items);
      return;
    }
    var at = playNext ? (_index + 1).clamp(0, _media.length) : _media.length;
    for (final item in items) {
      _media.insert(at, item);
      _queueItems.insert(at, item.toMediaItem());
      for (var i = 0; i < _recent.length; i++) {
        if (_recent[i] >= at) _recent[i]++;
      }
      for (var i = 0; i < _playHistory.length; i++) {
        if (_playHistory[i] >= at) _playHistory[i]++;
      }
      at++;
    }
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  void moveQueueItem(int oldIndex, int newIndex) {
    if (oldIndex < 0 ||
        oldIndex >= _media.length ||
        newIndex < 0 ||
        newIndex >= _media.length ||
        oldIndex == newIndex) {
      return;
    }
    final media = _media.removeAt(oldIndex);
    final qi = _queueItems.removeAt(oldIndex);
    _media.insert(newIndex, media);
    _queueItems.insert(newIndex, qi);

    if (_index == oldIndex) {
      _index = newIndex;
    } else {
      if (oldIndex < _index && newIndex >= _index) {
        _index--;
      } else if (oldIndex > _index && newIndex <= _index) {
        _index++;
      }
    }

    _recent.clear();
    _playHistory.clear();
    _shufflePlayed.clear();

    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    _broadcastState();
    unawaited(_persistSession(position: playbackState.value.position));
  }

  Future<void> _playIndex(
    int index, {
    bool recordHistory = true,
    Duration startPosition = Duration.zero,
    bool crossfade = false,
  }) async {
    if (index < 0 || index >= _media.length) return;
    // A normal track change supersedes a pending restore. A restored start
    // keeps it until the source is actually ready so a transient failure can
    // be retried from the same position.
    if (startPosition <= Duration.zero) {
      _pendingRestorePosition = null;
    }
    final generation = ++_playRequestGeneration;
    _cancelExpiryRefresh();
    _crossfadePlan = null;
    // Any explicit track change cuts a running fade short; a crossfade
    // handoff keeps the outgoing player alive until the ramp finishes.
    if (!crossfade) _endCrossfade();
    final previousIndex = _index;
    _index = index;
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;

    if (recordHistory) {
      _playHistory.add(index);
      if (_playHistory.length > 200) _playHistory.removeAt(0);
      if (_shuffle) _shufflePlayed.add(index);
      _recent.add(index);
      final maxRecent = ((_media.length - 1) * 0.6).floor().clamp(
        1,
        _media.length > 1 ? _media.length - 1 : 1,
      );
      while (_recent.length > maxRecent) {
        _recent.removeAt(0);
      }
    }

    final media = _media[index];
    // Plan the gapless transition: between two compatible lossless items the
    // source teardown is skipped so the decoder splices without a gap.
    final skipSourceTeardown =
        !crossfade && _planGaplessTeardown(previousIndex, media);
    final effectiveStartPosition = normalizedPlaybackResumePosition(
      startPosition,
      duration: media.duration,
    );
    mediaItem.add(media.toMediaItem());
    _lastBroadcastPosition = Duration.zero;
    _lastPositionBroadcastAt = null;
    _broadcastPosition(effectiveStartPosition, force: true);
    // Claim the playing state up front (while the app is still in the
    // foreground window) so audio_service can start its foreground service
    // before the async source resolve below.
    _broadcastState(playerState: PlayerState.playing, loading: true);

    final resolved = await _resolveSource(media);
    if (!_isCurrentPlayRequest(generation, media)) return;
    if (resolved == null) {
      _log.e('No playable source for ${media.title}');
      _reportPlaybackFailure('resolve-source', media, StateError('no playable source'));
      _endCrossfade();
      _broadcastState(playerState: PlayerState.stopped);
      return;
    }

    try {
      await musicPlayerExclusiveAudioHook?.call();
    } catch (e) {
      _log.d('best-effort step failed: $e');
    }
    if (!_isCurrentPlayRequest(generation, media)) return;

    _switchingGeneration = generation;
    try {
      // Set before play() so the track never starts at the wrong loudness;
      // always set (1.0 when disabled/untagged) so a previous track's
      // attenuation can't leak into the next one.
      final normalizationVolume = await _normalizationVolumeFor(
        resolved,
        media,
      );
      if (!_isCurrentPlayRequest(generation, media)) return;
      await _player.setAudioContext(_musicAudioContext);
      if (!_isCurrentPlayRequest(generation, media)) return;
      await _activateAudioSession();
      if (!_isCurrentPlayRequest(generation, media)) return;
      if (crossfade) {
        // The standby player is already stopped; the outgoing one must keep
        // playing until the ramp ends.
        _log.d('Crossfade transition: starting next item on standby player');
      } else if (skipSourceTeardown) {
        _log.d('Gapless transition: skipping source teardown');
      } else {
        await _player.stop();
      }
      _sourceReady = false;
      if (!_isCurrentPlayRequest(generation, media)) return;
      _activeNormalizationVolume = normalizationVolume;
      await _player.setVolume(crossfade ? 0.0 : normalizationVolume);
      if (!_isCurrentPlayRequest(generation, media)) return;
      // Progressive HTTP sources play with UrlSource (the streaming engine
      // preflighted them); local/content URIs use DeviceFileSource. Deferred
      // items decide by their *resolved* source, which may be either.
      final source = _isHttpSource(resolved)
          ? UrlSource(resolved)
          : DeviceFileSource(resolved);
      await _player.play(
        source,
        position: effectiveStartPosition > Duration.zero
            ? effectiveStartPosition
            : null,
      );
      if (!_isCurrentPlayRequest(generation, media)) return;
      _sourceReady = true;
      _pendingRestorePosition = null;
      _activeResolvedPath = media.isContentUri ? resolved : null;
      await _cleanupPendingResolvedPaths();
      // Plain file paths were already published before loading. Re-publishing
      // them with an identical resolved path made Now Playing clear and probe
      // the same metadata twice on every Next. SAF needs this second event so
      // the UI can inspect its temporary local copy; deferred engine items
      // need it so lyrics/metadata flows see the concrete resolved source
      // instead of the placeholder URI.
      if (media.isContentUri || media.isDeferredStream) {
        mediaItem.add(media.toMediaItem(resolvedSource: resolved));
      }
      _broadcastPosition(effectiveStartPosition, force: true);
      _broadcastState(playerState: PlayerState.playing);
      _lastPeriodicPersistAt = DateTime.now();
      if (recordHistory) {
        playbackStatsObserver?.onStarted(media);
      }
      unawaited(_persistSession(position: effectiveStartPosition));
      _log.i('Playing: ${media.title}');
      _reportTrackStarted(media);
      if (crossfade) _startCrossfadeRamp(generation);
      playbackSourceStartedListener?.call();
      _armExpiryRefresh(media, resolved, generation);
      // Some files do not emit onDurationChanged reliably (stuck at 0:00);
      // poll the engine for the real duration as a fallback.
      unawaited(_ensureDurationKnown(index, generation));
    } catch (e) {
      if (!_isCurrentPlayRequest(generation, media)) return;
      _sourceReady = false;
      // A failed incoming track must not leave the outgoing one playing on
      // (its completion is ignored by design, so it would never advance).
      _endCrossfade();
      _log.e('Playback failed for ${media.title}: $e');
      _reportPlaybackFailure('start', media, e);
      // Engine hook (streaming failover) observes runtime failures first; the
      // player still goes to stopped so the UI never lies about state.
      playbackFailureListener?.call(media, e);
      _broadcastState(playerState: PlayerState.stopped);
    } finally {
      if (_switchingGeneration == generation) {
        _switchingGeneration = 0;
      }
    }
  }

  /// Replaces the current queue item's source and replays it without touching
  /// the rest of the queue. Used by the streaming engine's failover path to
  /// swap an expired/dead stream URL for the next ranked source. [resumeAt]
  /// resumes at the position where the dead source failed, so a mid-playback
  /// expiry is seamless for the listener.
  Future<void> replaceCurrentAndPlay(
    PlayableMedia item, {
    Duration? resumeAt,
  }) async {
    if (_index < 0 || _index >= _media.length) return;
    final current = _media[_index];
    // Engine-owned items only: pre-resolved progressive URLs *and* deferred
    // queue items (whose placeholder source resolved to a stream at play
    // time). Local files never go through failover.
    if (!current.isRemoteHttp && !current.isDeferredStream) return;
    _media[_index] = item;
    _queueItems[_index] = item.toMediaItem();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));
    mediaItem.add(item.toMediaItem());
    await _playIndex(
      _index,
      recordHistory: false,
      startPosition: resumeAt ?? Duration.zero,
    );
  }

  /// The best-known playback position for failover: the live engine position
  /// when available, otherwise the last broadcast position. Never throws.
  Future<Duration?> currentPlaybackPosition() async {
    try {
      return await _currentPositionForPersist();
    } catch (_) {
      return playbackState.value.position;
    }
  }

  Future<void> setVolume(double volume) async {
    try {
      await _player.setVolume(volume.clamp(0.0, 1.0));
    } catch (e) {
      _log.w('Failed to set volume: $e');
    }
  }

  Future<void> setPlaybackRate(double rate) async {
    try {
      await _player.setPlaybackRate(rate.clamp(0.5, 2.0));
    } catch (e) {
      _log.w('Failed to set playback rate: $e');
    }
  }

  Future<void> setBalance(double balance) async {
    try {
      await _player.setBalance(balance.clamp(-1.0, 1.0));
    } catch (e) {
      _log.w('Failed to set balance: $e');
    }
  }

  Future<void> seekRelative(Duration offset) async {
    final base = await _currentPositionForPersist();
    final target = base + offset;
    if (target < Duration.zero) {
      await seek(Duration.zero);
      return;
    }
    final current = mediaItem.value;
    if (current?.duration != null && current!.duration! > Duration.zero) {
      if (target > current.duration!) {
        await _handlePlayerComplete();
        return;
      }
    }
    await seek(target);
  }

  /// Resolves the real track duration when the initial metadata had none and
  /// the duration-changed event did not fire, so the seek bar and total time
  /// do not get stuck at 0:00.
  Future<void> _ensureDurationKnown(int index, int generation) async {
    for (var attempt = 0; attempt < 15; attempt++) {
      if (_index != index || generation != _playRequestGeneration) return;
      final current = mediaItem.value;
      final existing = current?.duration;
      if (existing != null && existing > Duration.zero) return;

      try {
        final d = await _player.getDuration();
        if (_index != index || generation != _playRequestGeneration) return;
        if (d != null && d > Duration.zero) {
          final item = mediaItem.value;
          if (item != null) {
            mediaItem.add(item.copyWith(duration: d));
          }
          return;
        }
      } catch (_) {
        // ignore and retry
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }

  /// Next track in shuffle order, or null when no candidate is left.
  int? _pickNextShuffle() {
    if (_media.length <= 1) return null;
    final pool = <int>[];
    for (var i = 0; i < _media.length; i++) {
      if (i != _index && !_recent.contains(i)) pool.add(i);
    }
    if (pool.isEmpty) {
      // The anti-repetition window is full: fall back to any other track.
      for (var i = 0; i < _media.length; i++) {
        if (i != _index) pool.add(i);
      }
    }
    if (pool.isEmpty) return null;
    return pool[_random.nextInt(pool.length)];
  }

  /// Advances a shuffled queue.
  ///
  /// A cycle ends when every track has been played once — with repeat-all the
  /// cycle restarts, otherwise playback stops, matching the sequential branch
  /// (previously a shuffled queue looped forever regardless of repeat mode).
  Future<void> _advanceShuffled() async {
    if (_media.length <= 1) {
      if (_repeatMode == AudioServiceRepeatMode.all && _media.isNotEmpty) {
        await _playIndex(_index, recordHistory: false);
      } else {
        _broadcastState(playerState: PlayerState.completed);
      }
      return;
    }
    if (_shufflePlayed.length >= _media.length) {
      if (_repeatMode != AudioServiceRepeatMode.all) {
        _broadcastState(playerState: PlayerState.completed);
        return;
      }
      _shufflePlayed.clear();
      _recent.clear();
    }
    final next = _pickNextShuffle();
    if (next == null) {
      _broadcastState(playerState: PlayerState.completed);
      return;
    }
    await _playIndex(next);
  }

  Future<void> _onComplete() async {
    if (_repeatMode == AudioServiceRepeatMode.one &&
        _index >= 0 &&
        _index < _media.length) {
      await _playIndex(_index, recordHistory: false);
      return;
    }
    if (_shuffle) {
      await _advanceShuffled();
      return;
    }
    if (_index >= 0 && _index < _media.length - 1) {
      await _playIndex(_index + 1);
    } else if (_repeatMode == AudioServiceRepeatMode.all && _media.isNotEmpty) {
      await _playIndex(0);
    } else {
      _broadcastState(playerState: PlayerState.completed);
    }
  }

  Future<void> _handlePlayerComplete() async {
    if (_shouldIgnoreComplete) {
      _log.d('Ignoring non-terminal player complete event');
      if (_userPaused || _interruptionActive) {
        _broadcastState(playerState: PlayerState.paused);
      }
      return;
    }

    final current = _index >= 0 && _index < _media.length
        ? _media[_index]
        : null;
    if (current != null) {
      // Non-blocking: duration may already be known from the media item or a
      // duration-changed event; a missing value is simply skipped upstream.
      playbackStatsObserver?.onCompleted(current, current.duration);
    }

    await _onComplete();
  }

  @override
  Future<void> play() async {
    final activeOperation = _activePlayOperation;
    if (activeOperation != null) {
      await activeOperation;
      return;
    }

    final operation = _playInternal();
    _activePlayOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_activePlayOperation, operation)) {
        _activePlayOperation = null;
      }
    }
  }

  Future<void> _playInternal() async {
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;
    if ((!_sourceReady ||
            _player.state == PlayerState.stopped ||
            _player.state == PlayerState.completed) &&
        _index >= 0 &&
        _index < _media.length) {
      await _playIndex(
        _index,
        recordHistory: false,
        startPosition: _pendingRestorePosition ?? Duration.zero,
      );
      return;
    }
    await _activateAudioSession();
    await _player.resume();
    _broadcastState(playerState: PlayerState.playing);
  }

  @override
  Future<void> pause() async {
    _log.i('Pausing internal player by user/control request');
    _playRequestGeneration++;
    _cancelExpiryRefresh();
    _switchingGeneration = 0;
    _userPaused = true;
    _pausedByInterruption = false;
    _endCrossfade();
    await _player.pause();
    _broadcastState(playerState: PlayerState.paused);
    await _persistSession(position: await _currentPositionForPersist());
  }

  @override
  Future<void> seek(Duration position) async {
    _endCrossfade();
    await _player.seek(position);
    _broadcastPosition(position, force: true);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    _shuffle = shuffleMode == AudioServiceShuffleMode.all;
    // Enabling shuffle starts a new cycle: the tracks already heard in
    // sequential order do not count towards the shuffled rotation.
    _shufflePlayed.clear();
    _broadcastState();
    if (_media.isNotEmpty && _index >= 0) {
      unawaited(_persistSession(position: playbackState.value.position));
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    // Group repeat has no meaning for a flat queue; treat it as all.
    _repeatMode = repeatMode == AudioServiceRepeatMode.group
        ? AudioServiceRepeatMode.all
        : repeatMode;
    _broadcastState();
    if (_media.isNotEmpty && _index >= 0) {
      unawaited(_persistSession(position: playbackState.value.position));
    }
  }

  @override
  Future<void> stop() async {
    _playRequestGeneration++;
    _cancelExpiryRefresh();
    _switchingGeneration = 0;
    _userPaused = true;
    _endCrossfade();
    _crossfadePlan = null;
    await _player.stop();
    _sourceReady = false;
    _activeResolvedPath = null;
    await _cleanupPendingResolvedPaths();
    _index = -1;
    _pausedByInterruption = false;
    _interruptionActive = false;
    _userPaused = false;
    _recent.clear();
    _playHistory.clear();
    _shufflePlayed.clear();
    _pendingRestorePosition = null;
    // An explicit stop ends the session for good; nothing to restore later.
    await _enqueueSessionWrite(AppStateDatabase.instance.clearPlaybackSession);
    // A stopped session has no current item; this also hides the mini player.
    mediaItem.add(null);
    _broadcastState(playerState: PlayerState.stopped);
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    final current = _index >= 0 && _index < _media.length
        ? _media[_index]
        : null;
    if (_shuffle) {
      if (_media.length > 1) {
        if (current != null) playbackStatsObserver?.onSkip?.call(current);
        final next = _pickNextShuffle();
        if (next != null) await _playIndex(next);
      }
      return;
    }
    if (_index < _media.length - 1) {
      if (current != null) playbackStatsObserver?.onSkip?.call(current);
      await _playIndex(_index + 1);
    }
  }

  @override
  Future<void> skipToPrevious() async {
    _endCrossfade();
    if (playbackState.value.position > const Duration(seconds: 3)) {
      await _player.seek(Duration.zero);
      _broadcastPosition(Duration.zero, force: true);
      return;
    }
    final current = _index >= 0 && _index < _media.length
        ? _media[_index]
        : null;
    if (_shuffle) {
      if (_playHistory.length >= 2) {
        _playHistory.removeLast();
        final prev = _playHistory.last;
        if (current != null) playbackStatsObserver?.onSkip?.call(current);
        await _playIndex(prev, recordHistory: false);
      } else {
        await _player.seek(Duration.zero);
        _broadcastPosition(Duration.zero, force: true);
      }
      return;
    }
    if (_index > 0) {
      if (current != null) playbackStatsObserver?.onSkip?.call(current);
      await _playIndex(_index - 1);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) => _playIndex(index);

  /// Snapshot of the queue as playable media (for the browse tree).
  List<PlayableMedia> currentQueueMedia() =>
      List<PlayableMedia>.unmodifiable(_media);

  /// Android Auto / AVRCP browsing. Delegates to the installed
  /// [MediaBrowseBinding] (library, playlists, albums, recents); without one
  /// (tests, very early startup) the queue is the whole tree, as before.
  @override
  Future<List<MediaItem>> getChildren(
    String parentMediaId, [
    Map<String, dynamic>? options,
  ]) async {
    final binding = MediaBrowseBinding.current;
    if (binding != null) {
      try {
        final page = _browsePage(options);
        return await binding.tree.children(parentMediaId, page: page);
      } catch (e) {
        _log.w('Browse children failed for $parentMediaId: $e');
      }
    }
    if (parentMediaId == AudioService.browsableRootId ||
        parentMediaId == AudioService.recentRootId) {
      return List<MediaItem>.unmodifiable(_queueItems);
    }
    return const [];
  }

  static int _browsePage(Map<String, dynamic>? options) {
    final raw = options?['android.media.browse.extra.PAGE'];
    if (raw is int && raw >= 0) return raw;
    return 0;
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    final index = _media.indexWhere((m) => m.id == mediaId);
    if (index < 0) return null;
    return _queueItems[index];
  }

  /// Plays a media id coming from the notification, a car head unit or a
  /// browse result. Queue items play in place; browse results start their
  /// enclosing container (album, playlist, section) from the tapped track.
  @override
  Future<void> playFromMediaId(
    String mediaId, [
    Map<String, dynamic>? extras,
  ]) async {
    final index = _media.indexWhere((m) => m.id == mediaId);
    final containerId = extras?[MediaBrowseTree.containerExtraKey]?.toString();
    if (index >= 0 &&
        (containerId == null || containerId == MediaBrowseTree.queueId)) {
      await _playIndex(index);
      return;
    }
    final binding = MediaBrowseBinding.current;
    if (binding == null) {
      if (index >= 0) await _playIndex(index);
      return;
    }
    try {
      final media = containerId == null
          ? null
          : await binding.tree.containerMedia(containerId);
      if (media != null && media.isNotEmpty) {
        var start = media.indexWhere((m) => m.id == mediaId);
        if (start < 0) start = 0;
        await binding.playContainer(media, start);
        return;
      }
    } catch (e) {
      _log.w('Browse play failed for $mediaId: $e');
    }
    if (index >= 0) await _playIndex(index);
  }

  /// Browse-service search (Android Auto search box, AVRCP search).
  @override
  Future<List<MediaItem>> search(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    final binding = MediaBrowseBinding.current;
    if (binding == null) return const [];
    try {
      return await binding.tree.search(query);
    } catch (e) {
      _log.w('Browse search failed: $e');
      return const [];
    }
  }

  /// Voice request ("play `<query>`"): plays the best offline match with the
  /// remaining results queued behind it. An empty query resumes playback.
  @override
  Future<void> playFromSearch(
    String query, [
    Map<String, dynamic>? extras,
  ]) async {
    if (query.trim().isEmpty) {
      await play();
      return;
    }
    final binding = MediaBrowseBinding.current;
    if (binding == null) return;
    try {
      final media = await binding.tree.source.searchMedia(query, limit: 50);
      if (media.isEmpty) {
        _log.i('Voice search "$query": no offline match');
        return;
      }
      await binding.playContainer(media, 0);
    } catch (e) {
      _log.w('Voice search failed: $e');
    }
  }

  @override
  Future<void> playMediaItem(MediaItem mediaItem) =>
      playFromMediaId(mediaItem.id);

  /// Called when a file is deleted from disk. Removes it from the queue and, if
  /// it is the track currently playing, stops or advances so a deleted song can
  /// no longer be played.
  Future<void> onSourceDeleted(String source) async {
    final target = source.trim();
    if (target.isEmpty || _media.isEmpty) return;

    final discardedPath = _resolvedPathCache.remove(target);
    _resolvedPathOrder.remove(target);
    if (discardedPath != null) {
      await _discardResolvedPath(discardedPath);
    }

    final wasCurrent =
        _index >= 0 &&
        _index < _media.length &&
        _media[_index].source == target;

    var removedBeforeCurrent = 0;
    final kept = <PlayableMedia>[];
    for (var i = 0; i < _media.length; i++) {
      if (_media[i].source == target) {
        if (i < _index) removedBeforeCurrent++;
        continue;
      }
      kept.add(_media[i]);
    }

    if (kept.length == _media.length) return; // nothing matched

    _media
      ..clear()
      ..addAll(kept);
    _queueItems
      ..clear()
      ..addAll(kept.map((m) => m.toMediaItem()));
    _recent.clear();
    _playHistory.clear();
    _shufflePlayed.clear();
    queue.add(List<MediaItem>.unmodifiable(_queueItems));

    if (_media.isEmpty) {
      await stop();
      return;
    }

    if (wasCurrent) {
      final nextIndex = _index.clamp(0, _media.length - 1);
      await _playIndex(nextIndex);
    } else {
      _index = (_index - removedBeforeCurrent).clamp(0, _media.length - 1);
      _broadcastState();
      unawaited(_persistSession(position: playbackState.value.position));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (identical(_activeMusicPlayerHandler, this)) {
      _activeMusicPlayerHandler = null;
    }
    _playRequestGeneration++;
    _cancelExpiryRefresh();
    _crossfadeTimer?.cancel();
    _crossfadeTimer = null;
    for (final sub in _subscriptions) {
      await sub.cancel();
    }
    _subscriptions.clear();
    _sourceReady = false;
    await _player.dispose();
    final outgoing = _outgoing?.player;
    _outgoing = null;
    if (outgoing != null) await outgoing.dispose();
    final standby = _standbyPlayer;
    _standbyPlayer = null;
    if (standby != null) await standby.dispose();
    _activeResolvedPath = null;
    final tempPaths = <String>{
      ..._resolvedPathCache.values,
      ..._pendingResolvedPathDeletes,
    };
    _resolvedPathCache.clear();
    _resolvedPathOrder.clear();
    _pendingResolvedPathDeletes.clear();
    for (final path in tempPaths) {
      await _discardResolvedPath(path);
    }
  }
}

MusicPlayerHandler? _handler;
Future<MusicPlayerHandler>? _initFuture;
final StreamController<MusicPlayerHandler> _handlerReadyController =
    StreamController<MusicPlayerHandler>.broadcast();

MusicPlayerHandler? get musicPlayerHandler => _handler;

Future<void> Function()? musicPlayerExclusiveAudioHook;

/// Runtime playback failure observer, installed by the streaming engine for
/// source failover (and left unset for plain local playback).
typedef PlaybackFailureListener = void Function(
  PlayableMedia media,
  Object error,
);

/// Passed to [PlaybackFailureListener] when a stream's signed URL is about to
/// expire and should be re-resolved proactively. The engine treats it as an
/// `urlExpired` failure: same-provider re-resolution at the live position,
/// and *not* a health penalty (nothing actually failed).
class StreamUrlExpiringSignal implements Exception {
  const StreamUrlExpiringSignal();

  @override
  String toString() => 'StreamUrlExpiringSignal: stream URL expiring soon';
}

PlaybackFailureListener? playbackFailureListener;

void setPlaybackFailureListener(PlaybackFailureListener listener) {
  playbackFailureListener = listener;
}

/// Invoked right after an engine player has started a source. The native
/// audio effects chain binds to player audio sessions, which only exist from
/// this moment on (and may change when a player is recreated), so the DSP
/// controller re-attaches here. Unset in tests / when effects are off.
void Function()? playbackSourceStartedListener;

/// Starts [media] from [startIndex]; installed by the app so the handler can
/// route browse taps through the same play path as the in-app UI.
typedef MediaBrowsePlayContainer =
    Future<void> Function(List<PlayableMedia> media, int startIndex);

/// The browse tree + play callback the audio service uses for Android Auto /
/// AVRCP browsing. Process-global like the other handler hooks because the
/// handler is created by `AudioService.init` outside any provider scope.
class MediaBrowseBinding {
  const MediaBrowseBinding({required this.tree, required this.playContainer});

  final MediaBrowseTree tree;
  final MediaBrowsePlayContainer playContainer;

  static MediaBrowseBinding? _current;
  static MediaBrowseBinding? get current => _current;

  static void install({
    required MediaBrowseTree tree,
    required MediaBrowsePlayContainer playContainer,
  }) {
    _current = MediaBrowseBinding(tree: tree, playContainer: playContainer);
  }

  static void uninstall() {
    _current = null;
  }
}

/// Lazy source resolver installed by the streaming engine for queue items
/// created with [PlayableMedia.deferredStreamUriFor]. Receives the deferred
/// media and returns a concrete local file path or stream URL (or null when
/// the track cannot be resolved, which stops playback gracefully).
typedef DeferredStreamResolver = Future<String?> Function(PlayableMedia media);

DeferredStreamResolver? deferredStreamResolver;

void setDeferredStreamResolver(DeferredStreamResolver? resolver) {
  deferredStreamResolver = resolver;
}

/// Runtime observer for privacy-first listening statistics. The callback is
/// installed by the statistics provider at app bootstrap; it is a plain
/// function pointer so the audio handler never needs to know about Riverpod.
/// The fading-out half of a crossfade.
class _CrossfadeOutgoing {
  final AudioPlayer player;

  /// Normalised volume the track was playing at (fade ramps scale it).
  final double volume;
  final Duration fade;

  /// When the outgoing track would end by itself.
  final DateTime endsAt;

  const _CrossfadeOutgoing({
    required this.player,
    required this.volume,
    required this.fade,
    required this.endsAt,
  });
}

/// Crossfade plan for one play generation.
class _CrossfadePlan {
  final int generation;
  final int nextIndex;
  final String nextMediaId;
  final CrossfadeSettings settings;
  final CrossfadeDecision decision;
  final Duration duration;
  final bool shuffle;
  final AudioServiceRepeatMode repeatMode;

  const _CrossfadePlan({
    required this.generation,
    required this.nextIndex,
    required this.nextMediaId,
    required this.settings,
    required this.decision,
    required this.duration,
    required this.shuffle,
    required this.repeatMode,
  });
}

class PlaybackStatsObserver {
  final void Function(PlayableMedia media) onStarted;
  final void Function(PlayableMedia media, Duration? listened) onCompleted;
  final void Function(PlayableMedia media)? onSkip;

  const PlaybackStatsObserver({
    required this.onStarted,
    required this.onCompleted,
    this.onSkip,
  });
}

PlaybackStatsObserver? playbackStatsObserver;

void setPlaybackStatsObserver(PlaybackStatsObserver? observer) {
  playbackStatsObserver = observer;
}

/// Flushes the current playback position if the player has been initialized.
Future<void> persistCurrentPlaybackSession() async {
  final handler = _handler;
  if (handler == null) return;
  await handler.persistCurrentSession();
}

Future<MusicPlayerHandler> initMusicPlayer() async {
  if (_handler != null) return _handler!;
  final existingFuture = _initFuture;
  if (existingFuture != null) return existingFuture;

  final future = _doInitMusicPlayer();
  _initFuture = future;
  return future;
}

Future<MusicPlayerHandler> _doInitMusicPlayer() async {
  try {
    final handler = await AudioService.init(
      builder: () => MusicPlayerHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId:
            BackgroundPlaybackPolicy.androidPlaybackChannelId,
        androidNotificationChannelName: 'Playback',
        androidNotificationChannelDescription:
            'Media controls for background playback',
        androidNotificationIcon: 'mipmap/ic_launcher',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
        androidNotificationClickStartsActivity: true,
        fastForwardInterval: Duration(seconds: 15),
        rewindInterval: Duration(seconds: 15),
      ),
    );
    _handler = handler;
    _handlerReadyController.add(handler);
    return handler;
  } catch (_) {
    _initFuture = null;
    rethrow;
  }
}

/// Restores the last persisted playback session (if any) into a freshly
/// initialized handler, paused. Entries whose plain file paths no longer
/// exist are dropped; content URIs are kept and fail gracefully at play time.
Future<void> restorePersistedPlaybackSession() async {
  try {
    final session = await AppStateDatabase.instance.getPlaybackSession();
    if (session == null) return;

    final rawMedia = session['media'];
    if (rawMedia is! List) {
      await AppStateDatabase.instance.clearPlaybackSession();
      return;
    }

    final items = <PlayableMedia>[];
    final keptOriginalIndices = <int>[];
    for (var i = 0; i < rawMedia.length; i++) {
      final entry = rawMedia[i];
      if (entry is! Map) continue;
      final media = PlayableMedia.fromJson(Map<String, dynamic>.from(entry));
      if (media == null) continue;
      // Deferred engine items are always kept: their real source is resolved
      // fresh at play time (a persisted URL/path would be stale anyway).
      if (!media.isContentUri &&
          !media.isDeferredStream &&
          !await File(media.source).exists()) {
        continue;
      }
      items.add(media);
      keptOriginalIndices.add(i);
    }
    if (items.isEmpty) {
      await AppStateDatabase.instance.clearPlaybackSession();
      return;
    }

    // Remap the saved index onto the surviving list; if the current track
    // itself was dropped, land on the nearest earlier survivor at 0:00.
    final savedIndex = (session['index'] as num?)?.toInt() ?? 0;
    var index = 0;
    for (var i = 0; i < keptOriginalIndices.length; i++) {
      if (keptOriginalIndices[i] <= savedIndex) index = i;
    }
    var position = Duration(
      milliseconds: (session['positionMs'] as num?)?.toInt() ?? 0,
    );
    if (keptOriginalIndices[index] != savedIndex) {
      position = Duration.zero;
    }

    final handler = await initMusicPlayer();
    await handler.restoreSession(
      items: items,
      index: index,
      position: position,
      shuffle: session['shuffle'] == true,
      repeatMode: AudioServiceRepeatMode.values.firstWhere(
        (mode) => mode.name == session['repeat'],
        orElse: () => AudioServiceRepeatMode.none,
      ),
    );
    _log.i(
      'Restored playback session: ${items.length} track(s), paused at '
      '${position.inSeconds}s',
    );
  } catch (e) {
    _log.w('Failed to restore playback session: $e');
  }
}

Stream<MediaItem?> musicPlayerMediaItemEvents() async* {
  final existing = _handler;
  if (existing != null) {
    yield existing.mediaItem.value;
    yield* existing.mediaItem;
    return;
  }
  yield null;
  await for (final handler in _handlerReadyController.stream) {
    yield handler.mediaItem.value;
    yield* handler.mediaItem;
    return;
  }
}

Stream<PlaybackState> musicPlayerPlaybackStateEvents() async* {
  final existing = _handler;
  if (existing != null) {
    yield existing.playbackState.value;
    yield* existing.playbackState;
    return;
  }
  await for (final handler in _handlerReadyController.stream) {
    yield handler.playbackState.value;
    yield* handler.playbackState;
    return;
  }
}

Stream<List<MediaItem>> musicPlayerQueueEvents() async* {
  final existing = _handler;
  if (existing != null) {
    yield existing.queue.value;
    yield* existing.queue;
    return;
  }
  yield const [];
  await for (final handler in _handlerReadyController.stream) {
    yield handler.queue.value;
    yield* handler.queue;
    return;
  }
}
