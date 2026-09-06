/// Loudness normalization manager (premium audio engine, Phase 1).
///
/// Gives every track — streamed or local — a consistent perceived volume:
///
///   * Built on the ReplayGain tag path the player already feeds
///     (`engine/replay_gain.dart` + the Go metadata reader), plus the
///     target-LUFS policy from `engine/advanced_audio.dart`.
///   * [LoudnessTarget] presets cover the ReplayGain 2.0 reference (-18 LUFS),
///     the loudness-war streaming target (-14 LUFS) and the EBU R128
///     broadcast target (-23 LUFS), plus a custom value.
///   * [NormalizationPlan] is the pure decision (gain, volume, whether
///     clipping protection fired) — the player only applies `volume`.
///
/// Pure Dart: no Flutter, no I/O.
library;

import 'package:spotiflac_android/audio/replaygain_processor.dart';
import 'package:spotiflac_android/engine/advanced_audio.dart';

/// Named target loudness presets.
enum LoudnessTarget {
  /// ReplayGain 2.0 reference — the honest, dynamic-range-preserving default.
  replayGain18(-18.0, 'ReplayGain 2.0 (-18 LUFS)'),

  /// What most streaming services normalize to; masters sound uniformly loud.
  streaming14(-14.0, 'Streaming (-14 LUFS)'),

  /// EBU R128 broadcast target — maximum headroom.
  broadcast23(-23.0, 'Broadcast (-23 LUFS)');

  const LoudnessTarget(this.targetLufs, this.label);

  final double targetLufs;
  final String label;

  static LoudnessTarget fromLufs(double lufs) {
    for (final target in LoudnessTarget.values) {
      if (target.targetLufs == lufs) return target;
    }
    return LoudnessTarget.replayGain18;
  }
}

/// Which side produced the tags for a track — recorded in the plan so the UI
/// can explain where normalization data came from.
enum LoudnessSource { none, localTags, streamDescriptor, manualOverride }

/// The complete normalization decision for one track.
class NormalizationPlan {
  /// Volume multiplier (0.0 .. 1.0) to apply to the player.
  final double volume;

  /// Effective gain in dB after re-targeting + pre-amp (null = no gain).
  final double? gainDb;

  final LoudnessSource source;

  /// True when clipping protection reduced the volume below the gain alone.
  final bool clippingProtected;

  const NormalizationPlan({
    required this.volume,
    required this.source,
    this.gainDb,
    this.clippingProtected = false,
  });

  static const NormalizationPlan unity = NormalizationPlan(
    volume: 1.0,
    source: LoudnessSource.none,
  );

  bool get applied => volume != 1.0 || (gainDb != null && gainDb != 0.0);
}

/// The manager. Holds the target-loudness settings, exposes pure planning,
/// and delegates gain selection (mode/smart/overrides) to
/// [ReplayGainProcessor] so the two features compose instead of fighting.
class NormalizationManager {
  LoudnessNormalizationSettings _settings =
      const LoudnessNormalizationSettings(enabled: false);

  /// Extra headroom for quiet masters (kept in one place with the target).
  double preAmpDb = 0.0;

  LoudnessNormalizationSettings get settings => _settings;

  LoudnessTarget get target =>
      LoudnessTarget.fromLufs(_settings.targetLufs);

  bool get enabled => _settings.enabled;

  /// Installs the loudness settings (mutates a copy so the clamps in
  /// [LoudnessNormalizationSettings.copyWith] always apply).
  void configure({
    required bool enabled,
    double targetLufs = -18.0,
    double preampDbMax = 6.0,
  }) {
    _settings = LoudnessNormalizationSettings(
      enabled: enabled,
      targetLufs: targetLufs,
      preampDbMax: preampDbMax,
    );
  }

  void setPreAmpDb(double db) => preAmpDb = db.clamp(-6.0, 6.0).toDouble();

  /// Plans normalization for a track played in [context] with [tags].
  ///
  /// The loudness re-targeting itself runs inside
  /// [ReplayGainProcessor.resolve]; this method wraps the result in a
  /// [NormalizationPlan] and adds the source attribution.
  NormalizationPlan planFor({
    required ReplayGainProcessor processor,
    required GainContext context,
    GainTagSet tags = GainTagSet.empty,
    LoudnessSource source = LoudnessSource.localTags,
  }) {
    if (!enabled) return NormalizationPlan.unity;
    final resolved = processor.resolve(context: context, tags: tags);
    if (!resolved.applied) return NormalizationPlan.unity;
    return NormalizationPlan(
      volume: resolved.volume,
      gainDb: resolved.gainDb,
      source: resolved.source == GainSource.manualTrack ||
              resolved.source == GainSource.manualAlbum
          ? LoudnessSource.manualOverride
          : source,
      clippingProtected: resolved.volume < 1.0 &&
          resolved.gainDb != null &&
          resolved.gainDb! > 0.0,
    );
  }

}
