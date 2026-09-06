/// Crossfade manager (premium audio engine, Phase 1).
///
/// Wraps the existing [CrossfadePolicy] (1–12 s, smart skipping) and adds the
/// pieces the policy leaves to the caller:
///
///   * **Fade curves** — equal-power (the audible default), linear, and an
///     S-curve; [FadeCurveKind.auto] picks per transition (short overlaps get
///     the S-curve so the hand-off stays smooth, long ones equal-power).
///   * **Clamped configuration** — the slider range is enforced in one place
///     ([CrossfadeManager.clampSeconds], 1–12 while enabled, 0 = off).
///   * **Planning with album context** — mirrors the gapless album runs so
///     album-continuous neighbours are not faded.
library;

import 'dart:math' as math;

import 'package:spotiflac_android/engine/crossfade_policy.dart';
import 'package:spotiflac_android/engine/gapless_policy.dart';

/// Fade curve family.
enum FadeCurveKind {
  /// Equal-power (cos/sin): perceived loudness stays flat. The default.
  equalPower('Equal power'),

  /// Linear ramps: simple, slightly dips in the middle.
  linear('Linear'),

  /// S-curve: slow start/end, fast middle; nicest for very short fades.
  smoothSCurve('Smooth');

  const FadeCurveKind(this.label);

  final String label;

  static FadeCurveKind fromName(Object? name) {
    final text = name?.toString().trim().toLowerCase() ?? '';
    for (final kind in FadeCurveKind.values) {
      if (kind.name == text) return kind;
    }
    return FadeCurveKind.equalPower;
  }
}

/// Instantaneous gains for the two overlapping players (0..1).
class FadeGains {
  final double outgoing;
  final double incoming;

  const FadeGains({required this.outgoing, required this.incoming});
}

/// The manager.
class CrossfadeManager {
  /// The configured overlap in seconds. 0 = crossfading disabled; 1–12 while
  /// enabled (enforced by [configure] and [clampSeconds]).
  int seconds = 0;

  /// Smart mode: skip the overlap for album-continuous neighbours, splicable
  /// lossless pairs and very short tracks.
  bool smart = true;

  /// Explicit curve, or [FadeCurveKind.equalPower] + auto-selection.
  FadeCurveKind curve = FadeCurveKind.equalPower;

  /// True when [curve] should be picked per transition instead of used
  /// verbatim.
  bool autoCurve = true;

  final CrossfadePolicy _policy = const CrossfadePolicy();

  CrossfadeSettings get settings => CrossfadeSettings(seconds: seconds, smart: smart);

  bool get enabled => seconds > 0;

  /// Installs a configuration. Returns true when it changed.
  bool configure({
    required int seconds,
    bool smart = true,
    FadeCurveKind curve = FadeCurveKind.equalPower,
    bool autoCurve = true,
  }) {
    final next = clampSeconds(seconds);
    final changed = this.seconds != next ||
        this.smart != smart ||
        this.curve != curve ||
        this.autoCurve != autoCurve;
    this.seconds = next;
    this.smart = smart;
    this.curve = curve;
    this.autoCurve = autoCurve;
    return changed;
  }

  /// The single source of truth for the user-facing range: 0 (off) or 1–12 s.
  static int clampSeconds(int seconds) {
    if (seconds <= 0) return 0;
    return seconds.clamp(CrossfadeSettings.minSeconds, CrossfadeSettings.maxSeconds);
  }

  /// Evaluates one transition through the existing policy. [sameAlbum]
  /// should come from [albumRuns]-style context (see `GaplessManager`).
  CrossfadeDecision decide({
    required Duration? trackDuration,
    required AudioCharacteristics current,
    required AudioCharacteristics next,
    required bool sameTransport,
    required bool gaplessEnabled,
    bool sameAlbum = false,
    bool sequentialNeighbours = false,
    bool repeatOne = false,
  }) {
    return _policy.decide(
      settings: settings,
      trackDuration: trackDuration,
      current: current,
      next: next,
      sameTransport: sameTransport,
      gaplessEnabled: gaplessEnabled,
      sameAlbum: sameAlbum,
      sequentialNeighbours: sequentialNeighbours,
      repeatOne: repeatOne,
    );
  }

  /// Picks the curve for one fade. Auto mode: very short fades use the
  /// S-curve (its slow ends hide the seam), everything else equal-power.
  FadeCurveKind curveFor(Duration fade) {
    if (!autoCurve) return curve;
    if (fade <= const Duration(milliseconds: 1200)) {
      return FadeCurveKind.smoothSCurve;
    }
    return FadeCurveKind.equalPower;
  }

  /// Gains at [progress] (0..1) for [kind].
  static FadeGains gainsFor(FadeCurveKind kind, double progress) {
    final t = progress.isNaN ? 0.0 : progress.clamp(0.0, 1.0);
    switch (kind) {
      case FadeCurveKind.equalPower:
        final gains = CrossfadePolicy.equalPowerGains(t);
        return FadeGains(outgoing: gains.outgoing, incoming: gains.incoming);
      case FadeCurveKind.linear:
        return FadeGains(outgoing: 1.0 - t, incoming: t);
      case FadeCurveKind.smoothSCurve:
        final s = t * t * (3.0 - 2.0 * t); // smoothstep
        return FadeGains(outgoing: math.cos(s * math.pi / 2), incoming: math.sin(s * math.pi / 2));
    }
  }

  /// Gains at [progress] using the curve this manager would pick for [fade].
  FadeGains gains(Duration fade, double progress) =>
      gainsFor(curveFor(fade), progress);
}
