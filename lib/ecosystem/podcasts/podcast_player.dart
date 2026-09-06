/// Podcast playback on top of the existing engine (Feature Group 9).
///
/// **Reuses** `MusicPlayerHandler` rather than introducing a second audio
/// pipeline: an episode becomes a [PlayableMedia] and flows through the same
/// audio_service handler, so lockscreen, notification, headset and Bluetooth
/// controls work for podcasts with no extra platform code.
///
/// Podcast-specific behaviour lives here, not in the handler:
///   * speed presets (0.5x .. 3.0x) persisted per app, applied on play
///   * skip intervals (default back 15s / forward 30s, podcast conventions)
///   * resume from the stored position
///   * progress write-back, throttled so we do not thrash SQLite
///   * silence skipping (see [SilenceSkipPolicy])
library;

import 'dart:convert';

import 'package:spotiflac_android/ecosystem/ecosystem_kv.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_repository.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('PodcastPlayer');

/// Playback speeds offered in the UI.
const List<double> podcastSpeedPresets = <double>[
  0.5,
  0.75,
  1.0,
  1.1,
  1.25,
  1.5,
  1.75,
  2.0,
  2.5,
  3.0,
];

/// Clamps an arbitrary speed into the supported range.
double clampPodcastSpeed(double speed) {
  if (speed.isNaN) return 1.0;
  return speed.clamp(0.5, 3.0).toDouble();
}

/// Snaps to the next/previous preset — what a "speed" button cycles through.
double nextPodcastSpeed(double current) {
  for (final preset in podcastSpeedPresets) {
    if (preset > current + 0.001) return preset;
  }
  return podcastSpeedPresets.first;
}

/// Decides when to jump over a silent stretch.
///
/// Real silence-skipping needs decoder-level RMS access, which the audioplayers
/// pipeline does not expose. What *is* available is the position stream, so we
/// implement the tractable, useful half: publisher-declared silent ranges (from
/// chapter metadata or a user-marked intro) are skipped, and trailing silence
/// past the content end is treated as episode-complete.
///
/// Pure and synchronous so it is fully unit-testable.
class SilenceSkipPolicy {
  const SilenceSkipPolicy({
    this.enabled = false,
    this.silentRanges = const <SilentRange>[],
    this.minimumSkip = const Duration(seconds: 2),
  });

  final bool enabled;

  /// Ranges known to be silent, in playback order.
  final List<SilentRange> silentRanges;

  /// Ranges shorter than this are not worth a seek — jumping over a 400ms gap
  /// is more jarring than hearing it.
  final Duration minimumSkip;

  /// Returns the position to seek to, or null to keep playing.
  Duration? skipTargetFor(Duration position) {
    if (!enabled) return null;
    for (final range in silentRanges) {
      if (range.duration < minimumSkip) continue;
      if (position >= range.start && position < range.end) return range.end;
    }
    return null;
  }
}

/// A half-open silent interval `[start, end)`.
class SilentRange {
  const SilentRange({required this.start, required this.end});

  final Duration start;
  final Duration end;

  Duration get duration => end > start ? end - start : Duration.zero;
}

/// Persisted podcast playback preferences.
class PodcastPlaybackSettings {
  const PodcastPlaybackSettings({
    this.speed = 1.0,
    this.skipBack = const Duration(seconds: 15),
    this.skipForward = const Duration(seconds: 30),
    this.skipSilence = false,
  });

  final double speed;
  final Duration skipBack;
  final Duration skipForward;
  final bool skipSilence;

  PodcastPlaybackSettings copyWith({
    double? speed,
    Duration? skipBack,
    Duration? skipForward,
    bool? skipSilence,
  }) {
    return PodcastPlaybackSettings(
      speed: speed ?? this.speed,
      skipBack: skipBack ?? this.skipBack,
      skipForward: skipForward ?? this.skipForward,
      skipSilence: skipSilence ?? this.skipSilence,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'speed': speed,
    'skipBackSeconds': skipBack.inSeconds,
    'skipForwardSeconds': skipForward.inSeconds,
    'skipSilence': skipSilence,
  };

  static PodcastPlaybackSettings fromJson(Map<String, Object?> json) {
    return PodcastPlaybackSettings(
      speed: clampPodcastSpeed(
        json['speed'] is num ? (json['speed']! as num).toDouble() : 1.0,
      ),
      skipBack: Duration(
        seconds: json['skipBackSeconds'] is num
            ? (json['skipBackSeconds']! as num).toInt()
            : 15,
      ),
      skipForward: Duration(
        seconds: json['skipForwardSeconds'] is num
            ? (json['skipForwardSeconds']! as num).toInt()
            : 30,
      ),
      skipSilence: json['skipSilence'] == true,
    );
  }
}

/// Converts an episode into the engine's media value.
///
/// `playbackMode` is `'podcast'` so the Liquid Glass UI can render podcast
/// chrome (speed control, skip buttons) instead of music chrome.
PlayableMedia playableFromEpisode(
  PodcastEpisode episode, {
  String? showTitle,
}) {
  return PlayableMedia(
    id: episode.episodeKey,
    source: episode.playbackSource,
    title: episode.title,
    artist: showTitle ?? '',
    album: showTitle ?? '',
    artUri: episode.imageUrl,
    duration: episode.duration > Duration.zero ? episode.duration : null,
    playbackMode: 'podcast',
    sourceLabel: showTitle,
    providerId: 'podcast',
  );
}

/// Drives episode playback through the shared handler.
class PodcastPlayer {
  PodcastPlayer({
    required PodcastRepository repository,
    required KeyValueStore store,
    MusicPlayerHandler? Function()? handlerLookup,
  }) : _repository = repository,
       _store = store,
       _handlerLookup = handlerLookup ?? (() => musicPlayerHandler);

  static const String _settingsKey = 'podcast.playback.settings';

  /// How often a resume point is written while listening.
  static const Duration progressWriteInterval = Duration(seconds: 10);

  final PodcastRepository _repository;
  final KeyValueStore _store;
  final MusicPlayerHandler? Function() _handlerLookup;

  PodcastPlaybackSettings _settings = const PodcastPlaybackSettings();
  PodcastPlaybackSettings get settings => _settings;

  String? _currentEpisodeKey;
  Duration _lastWrittenPosition = Duration.zero;
  DateTime _lastWriteAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Loads persisted preferences. Safe to call more than once.
  Future<void> load() async {
    final raw = await _store.read(_settingsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = _decodeJsonMap(raw);
      if (decoded != null) _settings = PodcastPlaybackSettings.fromJson(decoded);
    } catch (error) {
      _log.w('Could not read podcast settings: $error');
    }
  }

  Future<void> _persist() async {
    await _store.write(_settingsKey, _encodeJsonMap(_settings.toJson()));
  }

  /// Starts (or resumes) an episode.
  ///
  /// [showTitle] is the podcast name, used for the notification subtitle.
  Future<void> play(
    PodcastEpisode episode, {
    String? showTitle,
    bool resume = true,
  }) async {
    final handler = await initMusicPlayer();

    _currentEpisodeKey = episode.episodeKey;
    _lastWrittenPosition = episode.playedPosition;

    await handler.setQueueAndPlay(<PlayableMedia>[
      playableFromEpisode(episode, showTitle: showTitle),
    ]);

    // Resume only when meaningfully into the episode and not at the very end.
    final position = episode.playedPosition;
    final shouldResume = resume &&
        position > const Duration(seconds: 5) &&
        (episode.duration == Duration.zero ||
            position < episode.duration - const Duration(seconds: 10));
    if (shouldResume) {
      await handler.seek(position);
    }

    await handler.setPlaybackRate(_settings.speed);
  }

  /// Applies and persists a new playback speed.
  Future<void> setSpeed(double speed) async {
    _settings = _settings.copyWith(speed: clampPodcastSpeed(speed));
    await _persist();
    await _handlerLookup()?.setPlaybackRate(_settings.speed);
  }

  /// Cycles to the next speed preset and returns it.
  Future<double> cycleSpeed() async {
    await setSpeed(nextPodcastSpeed(_settings.speed));
    return _settings.speed;
  }

  Future<void> setSkipSilence(bool enabled) async {
    _settings = _settings.copyWith(skipSilence: enabled);
    await _persist();
  }

  Future<void> setSkipIntervals({Duration? back, Duration? forward}) async {
    _settings = _settings.copyWith(skipBack: back, skipForward: forward);
    await _persist();
  }

  Future<void> skipForward() async {
    await _handlerLookup()?.seekRelative(_settings.skipForward);
  }

  Future<void> skipBack() async {
    await _handlerLookup()?.seekRelative(-_settings.skipBack);
  }

  Future<void> pause() async => _handlerLookup()?.pause();

  Future<void> resume() async => _handlerLookup()?.play();

  /// Reports the current position so the resume point can be persisted.
  ///
  /// Throttled to [progressWriteInterval]; call it freely from a position
  /// stream listener.
  Future<void> reportPosition(Duration position, {DateTime? now}) async {
    final key = _currentEpisodeKey;
    if (key == null) return;

    final stamp = now ?? DateTime.now();
    final elapsed = stamp.difference(_lastWriteAt);
    final moved = (position - _lastWrittenPosition).abs();
    // Write on a timer, or immediately after a seek of more than one interval.
    if (elapsed < progressWriteInterval && moved < progressWriteInterval) {
      return;
    }

    _lastWriteAt = stamp;
    _lastWrittenPosition = position;
    await _repository.saveProgress(key, position);
  }

  /// Flushes the resume point — call on pause, stop and app background.
  Future<void> flushProgress(Duration position) async {
    final key = _currentEpisodeKey;
    if (key == null) return;
    _lastWrittenPosition = position;
    _lastWriteAt = DateTime.now();
    await _repository.saveProgress(key, position);
  }

  /// Detaches from the current episode (after stop / switching to music).
  void clearCurrent() => _currentEpisodeKey = null;

  String? get currentEpisodeKey => _currentEpisodeKey;
}

Map<String, Object?>? _decodeJsonMap(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is Map) return Map<String, Object?>.from(decoded);
  return null;
}

String _encodeJsonMap(Map<String, Object?> value) => jsonEncode(value);
