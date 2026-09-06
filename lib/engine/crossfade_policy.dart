import 'dart:math' as math;

import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/gapless_policy.dart';

/// User-facing crossfade configuration.
///
/// [seconds] is the nominal overlap between the end of one track and the
/// start of the next (0 disables crossfading). [smart] lets the policy shorten
/// or skip the fade where a hard overlap would sound wrong: album-continuous
/// neighbours, lossless pairs that can be spliced gaplessly instead, and very
/// short tracks.
class CrossfadeSettings {
  static const int minSeconds = 1;
  static const int maxSeconds = 12;

  final int seconds;
  final bool smart;

  const CrossfadeSettings({required this.seconds, this.smart = true});

  const CrossfadeSettings.off() : seconds = 0, smart = true;

  bool get enabled => seconds > 0;

  Duration get nominal => Duration(seconds: seconds.clamp(0, maxSeconds));

  @override
  bool operator ==(Object other) =>
      other is CrossfadeSettings &&
      other.seconds == seconds &&
      other.smart == smart;

  @override
  int get hashCode => Object.hash(seconds, smart);

  @override
  String toString() => 'CrossfadeSettings(seconds: $seconds, smart: $smart)';
}

/// Outcome of planning one transition.
class CrossfadeDecision {
  /// Overlap to use, or null when this transition should not crossfade.
  final Duration? fade;
  final String reason;

  const CrossfadeDecision({required this.fade, required this.reason});

  const CrossfadeDecision.none(this.reason) : fade = null;

  bool get shouldCrossfade => fade != null && fade! > Duration.zero;

  /// Whether the fade should start now, given the live [position] and the
  /// total [duration] of the outgoing track.
  bool shouldStartAt(Duration position, Duration duration) {
    final fade = this.fade;
    if (fade == null || fade <= Duration.zero) return false;
    if (duration <= Duration.zero) return false;
    final remaining = duration - position;
    return remaining <= fade;
  }

  @override
  String toString() => 'CrossfadeDecision(fade: $fade, reason: $reason)';
}

/// Instantaneous gains for the two overlapping players at a given point of
/// the fade (both in 0..1, before track normalisation is applied).
class CrossfadeGains {
  final double outgoing;
  final double incoming;

  const CrossfadeGains({required this.outgoing, required this.incoming});
}

/// Plans crossfades between consecutive queue items.
///
/// Pure and synchronous so the audio service can evaluate it on every
/// position tick and so the rules are unit-testable without a device.
class CrossfadePolicy {
  const CrossfadePolicy();

  /// Tracks shorter than this never crossfade: there is no room for a fade
  /// without eating a meaningful share of the audio.
  static const Duration minTrackDuration = Duration(seconds: 10);

  /// Smart mode raises the bar so interludes / skits are left intact.
  static const Duration smartMinTrackDuration = Duration(seconds: 30);

  /// Equal-power curve: the perceived loudness stays flat through the
  /// overlap (a linear ramp dips audibly in the middle).
  static CrossfadeGains equalPowerGains(double progress) {
    final t = progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0);
    final angle = t * math.pi / 2;
    return CrossfadeGains(
      outgoing: math.cos(angle),
      incoming: math.sin(angle),
    );
  }

  CrossfadeDecision decide({
    required CrossfadeSettings settings,
    required Duration? trackDuration,
    required AudioCharacteristics current,
    required AudioCharacteristics next,
    required bool sameTransport,
    required bool gaplessEnabled,
    bool sameAlbum = false,
    bool sequentialNeighbours = false,
    bool repeatOne = false,
  }) {
    if (!settings.enabled) {
      return const CrossfadeDecision.none('crossfade disabled');
    }
    if (repeatOne) {
      return const CrossfadeDecision.none('repeat-one replays the same item');
    }
    final duration = trackDuration;
    if (duration == null || duration <= Duration.zero) {
      return const CrossfadeDecision.none('track duration unknown');
    }
    final minDuration = settings.smart
        ? smartMinTrackDuration
        : minTrackDuration;
    if (duration < minDuration) {
      return const CrossfadeDecision.none('track too short');
    }

    if (settings.smart) {
      if (sameAlbum && sequentialNeighbours) {
        return const CrossfadeDecision.none(
          'album continuity: consecutive tracks of the same album',
        );
      }
      final gapless = const GaplessPolicy().decide(
        enabled: gaplessEnabled,
        current: current,
        next: next,
        sameTransport: sameTransport,
      );
      if (gapless.canSkipSourceTeardown) {
        return const CrossfadeDecision.none(
          'lossless pair: gapless splice preferred',
        );
      }
    }

    final nominal = settings.nominal;
    // Never let the overlap consume more than a third of the outgoing track
    // (an eighth in smart mode, which is tuned for mixed playlists).
    final cap = Duration(
      milliseconds: duration.inMilliseconds ~/ (settings.smart ? 8 : 3),
    );
    var fade = nominal < cap ? nominal : cap;
    const floor = Duration(seconds: CrossfadeSettings.minSeconds);
    if (fade < floor) fade = floor;
    if (fade > duration) fade = duration;
    return CrossfadeDecision(
      fade: fade,
      reason: fade == nominal
          ? 'nominal overlap'
          : 'overlap shortened for track length',
    );
  }
}
