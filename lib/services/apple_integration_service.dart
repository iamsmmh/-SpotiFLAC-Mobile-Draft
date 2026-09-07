/// Apple ecosystem integration (Milestone 2) — Dart side.
///
/// Four independent method channels, one per native controller:
///
/// | Channel | Native | Purpose |
/// | --- | --- | --- |
/// | `…/audio_session` | `AudioSessionController` | interruptions, route changes |
/// | `…/airplay` | `AirPlayController` | AirPlay 2 route picker + state |
/// | `…/live_activity` | `LiveActivityController` | Dynamic Island / Live Activity |
/// | `…/siri` | `SiriIntentHandler` | "Hey Siri, play …" |
///
/// Everything here is a **no-op off iOS**. The services are safe to
/// construct and call on Android (and in tests, where there is no platform
/// channel at all): calls short-circuit on `Platform.isIOS` and every
/// invocation is wrapped so a `MissingPluginException` from an older build
/// degrades to "unsupported" instead of throwing into the caller. That is
/// what lets the player wire these unconditionally.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('AppleIntegration');

/// Whether the Apple-only surfaces can exist at all on this platform.
///
/// `defaultTargetPlatform` is not used: these channels are registered by the
/// iOS AppDelegate specifically, and a macOS/`iOS-on-Vision` host would not
/// have them.
bool get isAppleHost {
  if (kIsWeb) return false;
  try {
    return Platform.isIOS;
  } on UnsupportedError {
    return false;
  }
}

/// Runs a channel call, converting "the platform does not have this" into a
/// null result rather than an exception.
Future<T?> _guard<T>(String what, Future<T?> Function() body) async {
  if (!isAppleHost) return null;
  try {
    return await body();
  } on MissingPluginException {
    // An older iOS build without these channels: expected, not an error.
    return null;
  } on PlatformException catch (error, stack) {
    _log.e('$what failed: ${error.message}', error, stack);
    return null;
  } catch (error, stack) {
    _log.e('$what failed', error, stack);
    return null;
  }
}

// ---------------------------------------------------------------------------
// AVAudioSession
// ---------------------------------------------------------------------------

/// Why the audio route changed, as AVAudioSession reports it.
enum AudioRouteReason {
  unknown,
  newDeviceAvailable,
  oldDeviceUnavailable,
  categoryChange,
  override,
  wakeFromSleep,
  noSuitableRouteForCategory,
  routeConfigurationChange;

  static AudioRouteReason parse(Object? raw) {
    final name = raw?.toString();
    for (final value in AudioRouteReason.values) {
      if (value.name == name) return value;
    }
    return AudioRouteReason.unknown;
  }
}

/// One output port in the current route.
@immutable
class AudioOutput {
  final String name;
  final String type;
  final bool isAirPlay;
  final bool isBluetooth;
  final bool isHeadphones;
  final bool isBuiltIn;

  const AudioOutput({
    required this.name,
    required this.type,
    this.isAirPlay = false,
    this.isBluetooth = false,
    this.isHeadphones = false,
    this.isBuiltIn = false,
  });

  static AudioOutput? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString();
    if (name == null) return null;
    return AudioOutput(
      name: name,
      type: raw['type']?.toString() ?? '',
      isAirPlay: raw['isAirPlay'] == true,
      isBluetooth: raw['isBluetooth'] == true,
      isHeadphones: raw['isHeadphones'] == true,
      isBuiltIn: raw['isBuiltIn'] == true,
    );
  }
}

/// A route change delivered by the system.
@immutable
class AudioRouteChange {
  final AudioRouteReason reason;
  final List<AudioOutput> outputs;
  final bool isAirPlay;
  final bool isBluetooth;

  /// Whether the player must pause. True when the previous output went away
  /// (headphones unplugged, Bluetooth disconnected) — continuing would blast
  /// the track out of the built-in speaker.
  final bool shouldPause;

  const AudioRouteChange({
    required this.reason,
    required this.outputs,
    required this.isAirPlay,
    required this.isBluetooth,
    required this.shouldPause,
  });

  /// The user-visible output name ("AirPods Pro", "Kitchen HomePod").
  String get displayName => outputs.isEmpty ? '' : outputs.first.name;

  static AudioRouteChange parse(Object? raw) {
    final map = raw is Map ? raw : const <Object?, Object?>{};
    final outputs = <AudioOutput>[];
    final rawOutputs = map['outputs'];
    if (rawOutputs is List) {
      for (final entry in rawOutputs) {
        final output = AudioOutput.tryParse(entry);
        if (output != null) outputs.add(output);
      }
    }
    return AudioRouteChange(
      reason: AudioRouteReason.parse(map['reason']),
      outputs: outputs,
      isAirPlay: map['isAirPlay'] == true,
      isBluetooth: map['isBluetooth'] == true,
      shouldPause: map['shouldPause'] == true,
    );
  }
}

/// Bridges `AVAudioSession` interruptions and route changes into Dart.
///
/// The player subscribes to [onInterruptionBegan], [onInterruptionEnded] and
/// [onRouteChanged] to implement Apple's rules: pause on interruption, resume
/// only when the system says `shouldResume`, and pause when the output
/// disappears.
class AppleAudioSessionService {
  static const MethodChannel _channel = MethodChannel(
    'com.zarz.spotiflac/audio_session',
  );

  final _interruptionBegan = StreamController<void>.broadcast();
  final _interruptionEnded = StreamController<bool>.broadcast();
  final _routeChanged = StreamController<AudioRouteChange>.broadcast();
  final _mediaServicesReset = StreamController<void>.broadcast();

  bool _listening = false;

  /// Playback was interrupted (a call arrived, Siri started).
  Stream<void> get onInterruptionBegan => _interruptionBegan.stream;

  /// The interruption ended; the payload is the system's `shouldResume`
  /// hint. **Only resume when it is true** — resuming unconditionally is a
  /// HIG violation and a common rejection reason.
  Stream<bool> get onInterruptionEnded => _interruptionEnded.stream;

  /// The output route changed.
  Stream<AudioRouteChange> get onRouteChanged => _routeChanged.stream;

  /// The audio server restarted; every player object must be rebuilt.
  Stream<void> get onMediaServicesReset => _mediaServicesReset.stream;

  /// Starts listening. Idempotent.
  void start() {
    if (_listening || !isAppleHost) return;
    _listening = true;
    _channel.setMethodCallHandler(_handle);
  }

  Future<Object?> _handle(MethodCall call) async {
    switch (call.method) {
      case 'interruptionBegan':
        _interruptionBegan.add(null);
      case 'interruptionEnded':
        final args = call.arguments;
        final shouldResume = args is Map && args['shouldResume'] == true;
        _interruptionEnded.add(shouldResume);
      case 'routeChanged':
        _routeChanged.add(AudioRouteChange.parse(call.arguments));
      case 'mediaServicesReset':
        _mediaServicesReset.add(null);
      default:
        _log.d('unhandled audio session callback: ${call.method}');
    }
    return null;
  }

  /// Activates the audio session.
  Future<bool> activate() async =>
      await _guard('activate', () => _channel.invokeMethod<bool>('activate')) ??
      false;

  /// Deactivates the session, letting other apps resume.
  Future<bool> deactivate() async =>
      await _guard(
        'deactivate',
        () => _channel.invokeMethod<bool>('deactivate'),
      ) ??
      false;

  /// The current output route.
  Future<AudioRouteChange?> currentRoute() async {
    final raw = await _guard(
      'currentRoute',
      () => _channel.invokeMethod<Object?>('currentRoute'),
    );
    return raw == null ? null : AudioRouteChange.parse(raw);
  }

  /// Releases the streams.
  Future<void> dispose() async {
    _listening = false;
    await _interruptionBegan.close();
    await _interruptionEnded.close();
    await _routeChanged.close();
    await _mediaServicesReset.close();
  }
}

// ---------------------------------------------------------------------------
// AirPlay 2
// ---------------------------------------------------------------------------

/// The current AirPlay / external-output state.
@immutable
class AirPlayRoute {
  final String name;
  final List<String> names;
  final bool isAirPlay;
  final bool isExternal;

  const AirPlayRoute({
    this.name = '',
    this.names = const <String>[],
    this.isAirPlay = false,
    this.isExternal = false,
  });

  static AirPlayRoute parse(Object? raw) {
    if (raw is! Map) return const AirPlayRoute();
    final rawNames = raw['names'];
    return AirPlayRoute(
      name: raw['name']?.toString() ?? '',
      names: rawNames is List
          ? rawNames.map((e) => e.toString()).toList(growable: false)
          : const <String>[],
      isAirPlay: raw['isAirPlay'] == true,
      isExternal: raw['isExternal'] == true,
    );
  }
}

/// AirPlay 2 route discovery and the system route picker.
///
/// iOS does not allow programmatic route *selection* — only the system
/// picker can move audio to a speaker — so [showRoutePicker] is the whole
/// switching API. Discovery is implicit: the picker lists what is reachable.
class AirPlayService {
  static const MethodChannel _channel = MethodChannel(
    'com.zarz.spotiflac/airplay',
  );

  final _routeChanged = StreamController<AirPlayRoute>.broadcast();
  bool _listening = false;

  /// Emits whenever the output route changes.
  Stream<AirPlayRoute> get onRouteChanged => _routeChanged.stream;

  void start() {
    if (_listening || !isAppleHost) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'routeChanged') {
        _routeChanged.add(AirPlayRoute.parse(call.arguments));
      }
      return null;
    });
  }

  /// Presents the system AirPlay picker.
  Future<bool> showRoutePicker() async =>
      await _guard(
        'showRoutePicker',
        () => _channel.invokeMethod<bool>('showRoutePicker'),
      ) ??
      false;

  /// The current route, or null off iOS.
  Future<AirPlayRoute?> currentRoute() async {
    final raw = await _guard(
      'airplay.currentRoute',
      () => _channel.invokeMethod<Object?>('currentRoute'),
    );
    return raw == null ? null : AirPlayRoute.parse(raw);
  }

  /// Whether audio is currently going to an AirPlay device.
  Future<bool> isActive() async =>
      await _guard(
        'isAirPlayActive',
        () => _channel.invokeMethod<bool>('isAirPlayActive'),
      ) ??
      false;

  Future<void> dispose() async {
    _listening = false;
    await _routeChanged.close();
  }
}

// ---------------------------------------------------------------------------
// Live Activities / Dynamic Island
// ---------------------------------------------------------------------------

/// The playback snapshot rendered in the Dynamic Island and on the lock
/// screen.
@immutable
class LiveActivityState {
  final String title;
  final String artist;
  final String album;
  final bool isPlaying;
  final Duration position;
  final Duration duration;

  const LiveActivityState({
    required this.title,
    required this.artist,
    this.album = '',
    required this.isPlaying,
    required this.position,
    required this.duration,
  });

  Map<String, Object?> toArguments(DateTime now) => <String, Object?>{
    'title': title,
    'artist': artist,
    'album': album,
    'isPlaying': isPlaying,
    'positionMs': position.inMilliseconds,
    'durationMs': duration.inMilliseconds,
    // The widget derives a self-advancing progress bar from this timestamp,
    // so it keeps moving between the system's rate-limited updates.
    'updatedAt': now.millisecondsSinceEpoch,
  };

  /// Whether an update is worth sending.
  ///
  /// ActivityKit throttles updates, so pushing on every position tick gets
  /// silently dropped *and* burns budget. Only metadata/state changes and
  /// large seeks are worth a round-trip; ordinary progress is interpolated
  /// by the widget itself.
  bool differsMeaningfullyFrom(LiveActivityState? other) {
    if (other == null) return true;
    if (title != other.title ||
        artist != other.artist ||
        album != other.album ||
        isPlaying != other.isPlaying ||
        duration != other.duration) {
      return true;
    }
    return (position - other.position).abs() > const Duration(seconds: 5);
  }
}

/// Starts, updates and ends the Live Activity.
class LiveActivityService {
  static const MethodChannel _channel = MethodChannel(
    'com.zarz.spotiflac/live_activity',
  );

  LiveActivityState? _lastPushed;
  bool _active = false;

  /// Whether an activity is currently running.
  bool get isActive => _active;

  /// Whether the device supports (and the user has enabled) Live Activities.
  Future<bool> isSupported() async =>
      await _guard(
        'isSupported',
        () => _channel.invokeMethod<bool>('isSupported'),
      ) ??
      false;

  /// Starts an activity, replacing any existing one.
  Future<bool> start(LiveActivityState state, {DateTime? now}) async {
    final started =
        await _guard(
          'liveActivity.start',
          () => _channel.invokeMethod<bool>(
            'start',
            state.toArguments(now ?? DateTime.now()),
          ),
        ) ??
        false;
    _active = started;
    _lastPushed = started ? state : null;
    return started;
  }

  /// Updates the activity, skipping pushes the widget can interpolate.
  ///
  /// Returns true when an update was actually sent.
  Future<bool> update(LiveActivityState state, {DateTime? now}) async {
    if (!_active) return false;
    if (!state.differsMeaningfullyFrom(_lastPushed)) return false;

    final updated =
        await _guard(
          'liveActivity.update',
          () => _channel.invokeMethod<bool>(
            'update',
            state.toArguments(now ?? DateTime.now()),
          ),
        ) ??
        false;
    if (updated) _lastPushed = state;
    return updated;
  }

  /// Ends the activity. Safe to call when none is running.
  Future<void> end() async {
    if (!_active) return;
    _active = false;
    _lastPushed = null;
    await _guard('liveActivity.end', () => _channel.invokeMethod<bool>('end'));
  }
}

// ---------------------------------------------------------------------------
// Siri
// ---------------------------------------------------------------------------

/// What Siri was asked to play.
enum SiriRequestKind {
  track,
  album,
  artist,
  playlist,
  podcast,
  radio,
  resume;

  static SiriRequestKind parse(Object? raw) {
    final name = raw?.toString();
    for (final value in SiriRequestKind.values) {
      if (value.name == name) return value;
    }
    return SiriRequestKind.track;
  }
}

/// A resolved "Hey Siri, play …" request.
@immutable
class SiriPlayRequest {
  final SiriRequestKind kind;
  final String title;
  final String artist;
  final String album;
  final String identifier;
  final bool shuffle;

  const SiriPlayRequest({
    required this.kind,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.identifier = '',
    this.shuffle = false,
  });

  /// The free-text query to search for, best-effort assembled from whatever
  /// Siri managed to parse.
  String get searchQuery =>
      <String>[
        title,
        artist,
        album,
      ].where((part) => part.trim().isNotEmpty).join(' ').trim();

  static SiriPlayRequest parse(Object? raw) {
    final map = raw is Map ? raw : const <Object?, Object?>{};
    return SiriPlayRequest(
      kind: SiriRequestKind.parse(map['kind']),
      title: map['title']?.toString() ?? '',
      artist: map['artist']?.toString() ?? '',
      album: map['album']?.toString() ?? '',
      identifier: map['identifier']?.toString() ?? '',
      shuffle: map['shuffle'] == true,
    );
  }
}

/// Receives Siri media intents.
///
/// The handler returns whether the request was *accepted* (not whether audio
/// already started): Siri only allows a few seconds, and waiting for the
/// streaming ladder to resolve would time out the intent.
class SiriService {
  static const MethodChannel _channel = MethodChannel(
    'com.zarz.spotiflac/siri',
  );

  bool _listening = false;

  /// Registers the handler invoked when Siri asks to play something.
  void register(Future<bool> Function(SiriPlayRequest request) onPlay) {
    if (!isAppleHost) return;
    _listening = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'play') return null;
      try {
        return await onPlay(SiriPlayRequest.parse(call.arguments));
      } catch (error, stack) {
        _log.e('Siri play request failed', error, stack);
        return false;
      }
    });
  }

  /// Whether a handler is installed.
  bool get isRegistered => _listening;

  void dispose() {
    if (!_listening) return;
    _listening = false;
    if (isAppleHost) {
      _channel.setMethodCallHandler(null);
    }
  }
}
