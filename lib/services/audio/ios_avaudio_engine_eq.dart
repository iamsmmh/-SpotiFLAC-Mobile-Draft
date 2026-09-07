/// iOS AVAudioEngine EQ policy (Phase 15).
///
/// Consumes [AudioEffectsSettings.toPlatformMap] and projects it onto a
/// parametric + bass/treble payload the native `IosAvAudioEngineEqualizer`
/// understands. Does **not** replace the existing Android DynamicsProcessing
/// pipeline or the AVPlayer path — iOS applies this only when the optional
/// AVAudioEngine graph is attached.
library;

import 'package:spotiflac_android/engine/audio_effects.dart';

/// One parametric peaking filter.
class IosParametricBand {
  const IosParametricBand({
    required this.frequencyHz,
    required this.gainDb,
    this.bandwidthOctaves = 0.5,
  });

  final int frequencyHz;
  final double gainDb;
  final double bandwidthOctaves;

  Map<String, Object?> toJson() => <String, Object?>{
        'frequency_hz': frequencyHz,
        'gain_db': gainDb,
        'bandwidth_octaves': bandwidthOctaves,
      };
}

/// Payload handed to the iOS AVAudioEngine equalizer.
class IosAvAudioEngineEqPayload {
  const IosAvAudioEngineEqPayload({
    required this.enabled,
    required this.bands,
    required this.bassDb,
    required this.trebleDb,
    this.presetName,
  });

  final bool enabled;
  final List<IosParametricBand> bands;
  final double bassDb;
  final double trebleDb;
  final String? presetName;

  Map<String, Object?> toJson() => <String, Object?>{
        'enabled': enabled,
        'bands': <Map<String, Object?>>[
          for (final band in bands) band.toJson(),
        ],
        'bass_db': bassDb,
        'treble_db': trebleDb,
        if (presetName != null) 'preset_name': presetName,
      };
}

/// Maps the existing DSP settings onto the iOS parametric graph.
class IosAvAudioEngineEqPolicy {
  const IosAvAudioEngineEqPolicy();

  /// Frequencies treated as "bass" / "treble" shelves.
  static const int bassFrequencyHz = 80;
  static const int trebleFrequencyHz = 10000;

  IosAvAudioEngineEqPayload fromSettings(AudioEffectsSettings settings) {
    return fromPlatformMap(settings.toPlatformMap());
  }

  IosAvAudioEngineEqPayload fromPlatformMap(Map<String, dynamic> map) {
    final Object? enabledRaw = map['enabled'];
    final freqs = <int>[];
    final Object? rawFreqs = map['band_frequencies_hz'];
    if (rawFreqs is List<Object?>) {
      for (final value in rawFreqs) {
        if (value is num) freqs.add(value.toInt());
      }
    } else if (rawFreqs is List<int>) {
      freqs.addAll(rawFreqs);
    }
    final gains = <double>[];
    final Object? rawGains = map['band_gains_db'];
    if (rawGains is List<Object?>) {
      for (final value in rawGains) {
        if (value is num) gains.add(value.toDouble());
      }
    } else if (rawGains is List<double>) {
      gains.addAll(rawGains);
    }
    final bands = <IosParametricBand>[];
    final count =
        freqs.length < gains.length ? freqs.length : gains.length;
    for (var i = 0; i < count; i++) {
      bands.add(
        IosParametricBand(frequencyHz: freqs[i], gainDb: gains[i]),
      );
    }
    final Object? bassBoost = map['bass_boost'];
    final bass = bassBoost is num ? bassBoost.toDouble() * 8 : 0.0;
    final Object? presetRaw = map['preset_name'];
    return IosAvAudioEngineEqPayload(
      enabled: enabledRaw == true,
      bands: List<IosParametricBand>.unmodifiable(bands),
      bassDb: bass,
      trebleDb: _gainNear(bands, trebleFrequencyHz),
      presetName: presetRaw?.toString(),
    );
  }

  static double _gainNear(List<IosParametricBand> bands, int hz) {
    IosParametricBand? best;
    var bestDelta = 1 << 30;
    for (final band in bands) {
      final delta = (band.frequencyHz - hz).abs();
      if (delta < bestDelta) {
        bestDelta = delta;
        best = band;
      }
    }
    return best?.gainDb ?? 0;
  }
}
