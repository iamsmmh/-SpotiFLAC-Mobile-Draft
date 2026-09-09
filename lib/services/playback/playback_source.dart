/// Unified playback source contract for the hybrid playback layer.
///
/// The application renders audio through exactly one player — the shared
/// audio_service handler ([MusicPlayerHandler]). The classes in this file
/// formalize that constraint:
///
///   * [PlaybackBackend] is the single-player port every source drives. The
///     production implementation ([MusicPlayerPlaybackBackend]) delegates to
///     the audio service; tests substitute fakes.
///   * [PlaybackSource] is the per-origin contract (downloaded file, verified
///     cache copy, network stream). Sources resolve their own media and hand
///     it to the shared backend — they never own a player, a queue, lyrics,
///     or ReplayGain state.
///   * [SharedBackendPlaybackSource] implements every transport member
///     ([PlaybackSource.pause]/[PlaybackSource.resume]/[PlaybackSource.stop]/
///     [PlaybackSource.seek] and the state/position accessors) by delegating
///     to the backend, so all sources feed the same player state stream with
///     zero duplicated code paths.
///
/// Source selection (local → cache → stream) lives in the decision engine
/// ([PlaybackManager]); source ranking within one origin lives in the
/// existing planners ([PlaybackSourceLadder], [StreamProtocolResolver]).
import 'dart:async';

import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/cache/playback_source_ladder.dart'
    show PlaybackSourceKind;
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia;

/// Transport-level status of the single shared player.
enum PlaybackSourceStatus {
  /// Nothing loaded.
  idle,

  /// Resolving or preparing a source.
  loading,

  /// Audible playback in progress.
  playing,

  /// Loaded and paused.
  paused,

  /// Stopped (or the queue completed).
  stopped,

  /// The last operation failed; see [PlaybackSourceState.message].
  failed,
}

/// One snapshot of the shared player, projected through the unified layer.
class PlaybackSourceState {
  const PlaybackSourceState({
    required this.status,
    this.trackId = '',
    this.mediaId = '',
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.message = '',
  });

  /// Convenience idle snapshot (no track loaded).
  static const PlaybackSourceState idle = PlaybackSourceState(
    status: PlaybackSourceStatus.idle,
  );

  final PlaybackSourceStatus status;

  /// Logical track id when the backend could map the media item back to a
  /// [Track]; empty when idle or when the item is foreign to the manager.
  final String trackId;

  /// Queue media id of the current item; empty when idle.
  final String mediaId;

  final Duration position;
  final Duration duration;

  /// Human-readable detail for [PlaybackSourceStatus.failed] (and optional
  /// diagnostics for other states); empty otherwise.
  final String message;

  bool get isPlaying => status == PlaybackSourceStatus.playing;
  bool get isLoading => status == PlaybackSourceStatus.loading;
  bool get hasTrack => trackId.isNotEmpty;

  PlaybackSourceState copyWith({
    PlaybackSourceStatus? status,
    String? trackId,
    String? mediaId,
    Duration? position,
    Duration? duration,
    String? message,
  }) => PlaybackSourceState(
    status: status ?? this.status,
    trackId: trackId ?? this.trackId,
    mediaId: mediaId ?? this.mediaId,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    message: message ?? this.message,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackSourceState &&
          other.status == status &&
          other.trackId == trackId &&
          other.mediaId == mediaId &&
          other.position == position &&
          other.duration == duration &&
          other.message == message;

  @override
  int get hashCode =>
      Object.hash(status, trackId, mediaId, position, duration, message);

  @override
  String toString() =>
      'PlaybackSourceState(${status.name}, track=$trackId, media=$mediaId, '
      'position=$position, duration=$duration'
      '${message.isEmpty ? '' : ', $message'})';
}

/// Throttled playback progress of the current item.
///
/// Emitted by [PlaybackBackend.progress]; the manager uses it for the
/// next-track preload trigger (75% of the current item by default).
class PlaybackProgress {
  const PlaybackProgress({
    required this.trackId,
    required this.mediaId,
    required this.position,
    required this.duration,
  });

  final String trackId;
  final String mediaId;
  final Duration position;
  final Duration duration;

  /// Playback ratio in 0..1 (0 when the duration is unknown).
  double get ratio {
    if (duration <= Duration.zero) return 0;
    if (position <= Duration.zero) return 0;
    final value =
        position.inMilliseconds / duration.inMilliseconds.toDouble();
    return value.clamp(0.0, 1.0).toDouble();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaybackProgress &&
          other.trackId == trackId &&
          other.mediaId == mediaId &&
          other.position == position &&
          other.duration == duration;

  @override
  int get hashCode => Object.hash(trackId, mediaId, position, duration);

  @override
  String toString() =>
      'PlaybackProgress(track=$trackId, media=$mediaId, '
      'position=$position, duration=$duration)';
}

/// Typed failure raised by [PlaybackSource.play]/[PlaybackSource.preload].
///
/// Sources never crash the player: unplayable tracks surface as this
/// exception so the manager can fall through to the next source kind (or
/// report the dead end) without touching queue, lyrics, or gain state.
class PlaybackSourceException implements Exception {
  const PlaybackSourceException({
    required this.kind,
    required this.trackId,
    this.message = '',
    this.retryable = false,
  });

  /// The track cannot be played from this source right now.
  const PlaybackSourceException.unavailable(
    String trackId, [
    String message = '',
    bool retryable = false,
  ]) : this(
         kind: 'unavailable',
         trackId: trackId,
         message: message,
         retryable: retryable,
       );

  /// Machine-readable failure kind (`unavailable`, `backend-unavailable`, …).
  final String kind;

  final String trackId;
  final String message;

  /// Whether retrying later (reconnect, refresh) could plausibly succeed.
  final bool retryable;

  @override
  String toString() =>
      'PlaybackSourceException($kind, track=$trackId'
      '${message.isEmpty ? '' : ', $message'})';
}

/// The single shared player every [PlaybackSource] drives.
///
/// Exactly one backend exists per process: the production implementation
/// wraps the audio_service handler (single queue, single media session,
/// single notification). Sources hand it fully-resolved [PlayableMedia];
/// transport, gapless splicing, crossfading, ReplayGain, lyrics, and session
/// persistence all stay inside the handler — this port only forwards.
abstract class PlaybackBackend {
  /// Brings the underlying player up (idempotent).
  Future<void> ensureReady();

  /// THE player state stream. Every source returns this same stream.
  Stream<PlaybackSourceState> get state;

  /// Throttled progress ticks for the current item.
  Stream<PlaybackProgress> get progress;

  Duration get currentPosition;
  Duration get duration;

  /// Logical track id of the current item ('' when idle or unmapped).
  String get currentTrackId;

  /// Queue media id of the current item ('' when idle).
  String get currentMediaId;

  /// Replaces the queue with [media] and starts it.
  Future<void> playMedia(
    PlayableMedia media, {
    Duration startPosition = Duration.zero,
  });

  /// Replaces the whole queue and starts at [initialIndex].
  Future<void> setQueue(List<PlayableMedia> items, {int initialIndex = 0});

  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> seek(Duration position);

  /// Swaps the current queue item's source and replays it at [resumeAt]
  /// without touching the rest of the queue (stream failover, local swap).
  Future<void> replaceCurrent(
    PlayableMedia media, {
    Duration resumeAt = Duration.zero,
  });

  /// Flushes the live queue/position to the persisted session (background).
  Future<void> persistSession();

  /// Notes when the stream a deferred item resolved to expires (null clears
  /// it) so the player can refresh the URL before the CDN rejects it.
  void noteSourceExpiry(String mediaId, DateTime? expiresAt);

  /// Releases backend-owned subscriptions. Must NOT stop audio or dispose
  /// the audio service itself, which outlives any manager.
  Future<void> dispose();
}

/// One playable origin: downloaded file, cache copy, or network stream.
///
/// Lifecycle: [initialize] once, then [play]/[preload] per track.
/// Transport members ([pause], [resume], [stop], [seek]) and the state
/// accessors always act on the shared player, never on a per-source one.
abstract class PlaybackSource {
  /// Which origin this source serves (see [PlaybackSourceKind]).
  PlaybackSourceKind get kind;

  /// Prepares the source (idempotent). Never starts audio.
  Future<void> initialize();

  /// Plays [track] from this origin on the shared player.
  ///
  /// Throws [PlaybackSourceException] when the track is not playable from
  /// this origin.
  Future<void> play(Track track);

  Future<void> pause();
  Future<void> resume();
  Future<void> stop();
  Future<void> seek(Duration position);

  /// Warms [track] (resolve + validate the source) without starting audio.
  ///
  /// Best-effort from the manager's perspective; throws
  /// [PlaybackSourceException] when the track cannot be warmed.
  Future<void> preload(Track track);

  /// The shared player state stream (identical object for every source).
  Stream<PlaybackSourceState> get state;

  Duration get currentPosition;
  Duration get duration;

  /// Logical track id of the current item ('' when idle).
  String get currentTrackId;

  Future<void> dispose();
}

/// Base class implementing every transport member via the shared [backend].
///
/// Concrete sources only implement [PlaybackSource.kind],
/// [PlaybackSource.initialize], [PlaybackSource.play], and
/// [PlaybackSource.preload] — transport can never diverge between origins.
abstract class SharedBackendPlaybackSource implements PlaybackSource {
  SharedBackendPlaybackSource({required this.backend});

  final PlaybackBackend backend;

  @override
  Future<void> pause() => backend.pause();

  @override
  Future<void> resume() => backend.resume();

  @override
  Future<void> stop() => backend.stop();

  @override
  Future<void> seek(Duration position) => backend.seek(position);

  @override
  Stream<PlaybackSourceState> get state => backend.state;

  @override
  Duration get currentPosition => backend.currentPosition;

  @override
  Duration get duration => backend.duration;

  @override
  String get currentTrackId => backend.currentTrackId;

  @override
  Future<void> dispose() async {}
}

/// Builds the queue currency ([PlayableMedia]) for [track] from a resolved
/// [source] (file path, cache path, or stream URL).
///
/// Title/artist fallbacks stay with the handler (localized "Unknown …"
/// strings); this helper only normalizes the artwork reference into a form
/// the media session accepts (remote URL, content URI, or file URI).
PlayableMedia playableMediaForTrack(
  Track track, {
  required String mediaId,
  required String source,
  String? playbackMode,
  String? qualityLabel,
  String? sourceLabel,
  String? providerId,
  DateTime? expiresAt,
}) {
  return PlayableMedia(
    id: mediaId,
    source: source,
    title: track.name,
    artist: track.artistName,
    album: track.albumName,
    artUri: _normalizeArtUri(track.coverUrl),
    duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
    explicit: track.isExplicit,
    playbackMode: playbackMode,
    qualityLabel: qualityLabel,
    sourceLabel: sourceLabel,
    providerId: providerId,
    expiresAt: expiresAt,
  );
}

String? _normalizeArtUri(String? cover) {
  final value = cover?.trim() ?? '';
  if (value.isEmpty) return null;
  if (value.startsWith('http://') ||
      value.startsWith('https://') ||
      value.startsWith('content://') ||
      value.startsWith('file://')) {
    return value;
  }
  return Uri.file(value).toString();
}
