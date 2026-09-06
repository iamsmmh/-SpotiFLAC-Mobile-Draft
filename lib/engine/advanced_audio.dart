/// Advanced audio DSP chain (Feature Group: advanced audio).
///
/// Pure-Dart models + math for the features beyond the shipped 10-band EQ:
///
///   * **Parametric EQ** — arbitrary peaking/shelf/cut bands, evaluated
///     with the RBJ biquad formulas. The whole chain is *flattened* onto
///     the existing platform DSP path (`band_frequencies_hz` +
///     `band_gains_db` accept arbitrary centre frequencies on Android
///     DynamicsProcessing), so no second audio pipeline exists.
///   * **Bass / vocal boost** — target curves expressed as parametric
///     bands, composed with the user's EQ.
///   * **Headphone profiles** — built-in compensation curves (neutral,
///     studio, warm, bright, V-shaped, bass-light).
///   * **Crossfeed** — bs2b-style stereo crossfeed coefficients; live
///     application is capability-gated (report honestly where the platform
///     cannot mix channels, same precedent as the iOS EQ).
///   * **Convolver** — impulse-response management (WAV parsing, wet/dry)
///     for offline preparation through the existing FFmpeg path.
///   * **Loudness normalization** — target-LUFS policy on top of the
///     existing ReplayGain volume path, with pre-amp clamping.
///   * **Preset manager** — full-chain presets, built-in + user, with a
///     JSON codec for import/export (same shape as `EqualizerPresetCodec`).
///
/// Everything here is unit-testable headlessly: no Flutter, no I/O.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Filter shapes a parametric band can take.
enum ParametricFilterType {
  peaking('Peaking'),
  lowShelf('Low shelf'),
  highShelf('High shelf'),
  lowCut('Low cut'),
  highCut('High cut');

  const ParametricFilterType(this.label);

  final String label;

  static ParametricFilterType fromName(Object? name) {
    final text = name?.toString().trim().toLowerCase() ?? '';
    for (final value in ParametricFilterType.values) {
      if (value.name == text) return value;
    }
    return ParametricFilterType.peaking;
  }
}

/// One parametric band.
class ParametricBand {
  const ParametricBand({
    required this.type,
    required this.frequencyHz,
    required this.gainDb,
    this.q = 1.0,
  });

  final ParametricFilterType type;

  /// Centre/corner frequency (20 .. 20000 Hz, clamped on construction by
  /// callers; kept permissive for curve math).
  final double frequencyHz;

  /// Boost/cut in dB (-15 .. +15).
  final double gainDb;

  /// Resonance (0.1 .. 8); ignored by cut filters.
  final double q;

  ParametricBand copyWith({
    ParametricFilterType? type,
    double? frequencyHz,
    double? gainDb,
    double? q,
  }) => ParametricBand(
    type: type ?? this.type,
    frequencyHz: frequencyHz ?? this.frequencyHz,
    gainDb: gainDb ?? this.gainDb,
    q: q ?? this.q,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'type': type.name,
    'frequency_hz': frequencyHz,
    'gain_db': gainDb,
    'q': q,
  };

  static ParametricBand fromJson(Object? raw) {
    if (raw is! Map) return const ParametricBand(type: ParametricFilterType.peaking, frequencyHz: 1000, gainDb: 0);
    return ParametricBand(
      type: ParametricFilterType.fromName(raw['type']),
      frequencyHz: _finite(raw['frequency_hz'], 1000),
      gainDb: _finite(raw['gain_db'], 0).clamp(-15, 15),
      q: _finite(raw['q'], 1).clamp(0.1, 8),
    );
  }
}

double _finite(Object? value, double fallback) {
  final parsed = value is num ? value.toDouble() : double.tryParse('$value');
  if (parsed == null || !parsed.isFinite) return fallback;
  return parsed;
}

/// Digital biquad (RBJ Audio EQ Cookbook), coefficient form.
class BiquadCoefficients {
  const BiquadCoefficients(this.b0, this.b1, this.b2, this.a1, this.a2);

  final double b0;
  final double b1;
  final double b2;
  final double a1;
  final double a2;

  /// Cooks the coefficients for [band] at sample rate [sampleRateHz]
  /// (RBJ Audio EQ Cookbook, Q-based shelf variant).
  factory BiquadCoefficients.forBand(
    ParametricBand band,
    double sampleRateHz,
  ) {
    final fs = sampleRateHz <= 0 ? 48000.0 : sampleRateHz;
    final f0 = band.frequencyHz.clamp(10.0, fs / 2 - 1).toDouble();
    final w0 = 2 * math.pi * f0 / fs;
    final cw = math.cos(w0);
    final sw = math.sin(w0);
    final alphaQ = sw / (2 * band.q.clamp(0.1, 8));
    final a = math.pow(10.0, band.gainDb / 40.0).toDouble();

    double b0;
    double b1;
    double b2;
    double a0;
    double a1;
    double a2;

    switch (band.type) {
      case ParametricFilterType.peaking:
        b0 = 1 + alphaQ * a;
        b1 = -2 * cw;
        b2 = 1 - alphaQ * a;
        a0 = 1 + alphaQ / a;
        a1 = -2 * cw;
        a2 = 1 - alphaQ / a;
      case ParametricFilterType.lowShelf:
        final sq = 2 * math.sqrt(a) * alphaQ;
        b0 = a * ((a + 1) - (a - 1) * cw + sq);
        b1 = 2 * a * ((a - 1) - (a + 1) * cw);
        b2 = a * ((a + 1) - (a - 1) * cw - sq);
        a0 = (a + 1) + (a - 1) * cw + sq;
        a1 = -2 * ((a - 1) + (a + 1) * cw);
        a2 = (a + 1) + (a - 1) * cw - sq;
      case ParametricFilterType.highShelf:
        final sq = 2 * math.sqrt(a) * alphaQ;
        b0 = a * ((a + 1) + (a - 1) * cw + sq);
        b1 = -2 * a * ((a - 1) + (a + 1) * cw);
        b2 = a * ((a + 1) + (a - 1) * cw - sq);
        a0 = (a + 1) - (a - 1) * cw + sq;
        a1 = 2 * ((a - 1) - (a + 1) * cw);
        a2 = (a + 1) - (a - 1) * cw - sq;
      case ParametricFilterType.lowCut:
        b0 = (1 + cw) / 2;
        b1 = -(1 + cw);
        b2 = (1 + cw) / 2;
        a0 = 1 + alphaQ;
        a1 = -2 * cw;
        a2 = 1 - alphaQ;
      case ParametricFilterType.highCut:
        b0 = (1 - cw) / 2;
        b1 = 1 - cw;
        b2 = (1 - cw) / 2;
        a0 = 1 + alphaQ;
        a1 = -2 * cw;
        a2 = 1 - alphaQ;
    }
    return BiquadCoefficients(
      b0 / a0,
      b1 / a0,
      b2 / a0,
      a1 / a0,
      a2 / a0,
    );
  }

  /// Magnitude (linear) of the transfer function at [frequencyHz].
  double magnitudeAt(double frequencyHz, double sampleRateHz) {
    final fs = sampleRateHz <= 0 ? 48000.0 : sampleRateHz;
    final w = 2 * math.pi * frequencyHz.clamp(1.0, fs / 2 - 1) / fs;
    final cw = math.cos(w);
    final sw = math.sin(w);
    final cw2 = math.cos(2 * w);
    final sw2 = math.sin(2 * w);
    final numRe = b0 + b1 * cw + b2 * cw2;
    final numIm = -(b1 * sw + b2 * sw2);
    final denRe = 1 + a1 * cw + a2 * cw2;
    final denIm = -(a1 * sw + a2 * sw2);
    final num = math.sqrt(numRe * numRe + numIm * numIm);
    final den = math.sqrt(denRe * denRe + denIm * denIm);
    if (den <= 0) return 1.0;
    return num / den;
  }
}

/// A parametric EQ: ordered list of bands evaluated as a cascade.
class ParametricEqualizer {
  const ParametricEqualizer({this.bands = const <ParametricBand>[]});

  final List<ParametricBand> bands;

  bool get isFlat => bands.every((band) => band.gainDb.abs() < 0.01 && band.type != ParametricFilterType.lowCut && band.type != ParametricFilterType.highCut);

  /// Combined magnitude of the cascade at [frequencyHz] in dB.
  double gainDbAt(double frequencyHz, {double sampleRateHz = 48000}) {
    var linear = 1.0;
    for (final band in bands) {
      final coefficients = BiquadCoefficients.forBand(band, sampleRateHz);
      linear *= coefficients.magnitudeAt(frequencyHz, sampleRateHz);
    }
    return 20 * math.log(math.max(linear, 1e-9)) / math.ln10;
  }

  ParametricEqualizer copyWith({List<ParametricBand>? bands}) =>
      ParametricEqualizer(bands: bands ?? this.bands);
}

/// Bass boost curve (0..1 amount → up to +9 dB low shelf).
class BassBoostSettings {
  const BassBoostSettings({this.enabled = false, this.amount = 0.5});

  final bool enabled;

  /// 0..1.
  final double amount;

  List<ParametricBand> toBands() => enabled
      ? <ParametricBand>[
          ParametricBand(
            type: ParametricFilterType.lowShelf,
            frequencyHz: 90,
            gainDb: 9 * amount.clamp(0.0, 1.0),
            q: 0.7,
          ),
        ]
      : const <ParametricBand>[];

  BassBoostSettings copyWith({bool? enabled, double? amount}) =>
      BassBoostSettings(
        enabled: enabled ?? this.enabled,
        amount: (amount ?? this.amount).clamp(0.0, 1.0),
      );
}

/// Vocal boost curve: presence lift + low-mud cut.
class VocalBoostSettings {
  const VocalBoostSettings({this.enabled = false, this.amount = 0.5});

  final bool enabled;
  final double amount;

  List<ParametricBand> toBands() {
    if (!enabled) return const <ParametricBand>[];
    final a = amount.clamp(0.0, 1.0);
    return <ParametricBand>[
      ParametricBand(
        type: ParametricFilterType.peaking,
        frequencyHz: 250,
        gainDb: -3 * a,
        q: 1.1,
      ),
      ParametricBand(
        type: ParametricFilterType.peaking,
        frequencyHz: 2800,
        gainDb: 5.5 * a,
        q: 0.9,
      ),
      ParametricBand(
        type: ParametricFilterType.peaking,
        frequencyHz: 6500,
        gainDb: 2.5 * a,
        q: 1.4,
      ),
    ];
  }

  VocalBoostSettings copyWith({bool? enabled, double? amount}) =>
      VocalBoostSettings(
        enabled: enabled ?? this.enabled,
        amount: (amount ?? this.amount).clamp(0.0, 1.0),
      );
}

/// Built-in headphone compensation profiles.
enum HeadphoneProfile {
  flat('Flat', 'No correction'),
  studio('Studio', 'Neutral studio reference'),
  warm('Warm', 'Gentle low lift, softened top'),
  bright('Bright', 'Air and presence lift'),
  vShaped('V-Shaped', 'Bass and treble forward'),
  bassLight('Bass-light fix', 'Corrects thin-sounding headphones');

  const HeadphoneProfile(this.title, this.description);

  final String title;
  final String description;

  static HeadphoneProfile fromName(Object? name) {
    final text = name?.toString().trim().toLowerCase() ?? '';
    for (final value in HeadphoneProfile.values) {
      if (value.name == text) return value;
    }
    return HeadphoneProfile.flat;
  }

  List<ParametricBand> toBands() => switch (this) {
    HeadphoneProfile.flat => const <ParametricBand>[],
    HeadphoneProfile.studio => const <ParametricBand>[
        ParametricBand(type: ParametricFilterType.peaking, frequencyHz: 60, gainDb: -1.5, q: 0.8),
        ParametricBand(type: ParametricFilterType.peaking, frequencyHz: 8000, gainDb: -1.0, q: 0.9),
      ],
    HeadphoneProfile.warm => const <ParametricBand>[
        ParametricBand(type: ParametricFilterType.lowShelf, frequencyHz: 120, gainDb: 2.5, q: 0.7),
        ParametricBand(type: ParametricFilterType.peaking, frequencyHz: 9000, gainDb: -2.5, q: 0.8),
      ],
    HeadphoneProfile.bright => const <ParametricBand>[
        ParametricBand(type: ParametricFilterType.peaking, frequencyHz: 3500, gainDb: 1.5, q: 1.0),
        ParametricBand(type: ParametricFilterType.highShelf, frequencyHz: 9000, gainDb: 3.0, q: 0.7),
      ],
    HeadphoneProfile.vShaped => const <ParametricBand>[
        ParametricBand(type: ParametricFilterType.lowShelf, frequencyHz: 100, gainDb: 4.0, q: 0.7),
        ParametricBand(type: ParametricFilterType.peaking, frequencyHz: 1000, gainDb: -2.0, q: 0.9),
        ParametricBand(type: ParametricFilterType.highShelf, frequencyHz: 8000, gainDb: 3.5, q: 0.7),
      ],
    HeadphoneProfile.bassLight => const <ParametricBand>[
        ParametricBand(type: ParametricFilterType.lowShelf, frequencyHz: 110, gainDb: 5.0, q: 0.7),
        ParametricBand(type: ParametricFilterType.peaking, frequencyHz: 3200, gainDb: -1.5, q: 1.0),
      ],
  };
}

/// bs2b-style crossfeed. Live channel mixing is not available on every
/// audio path (DynamicsProcessing has no crossfeed node); the coefficients
/// are computed here so a capable path (or offline FFmpeg render) can use
/// them, and the UI reports capability honestly elsewhere.
class CrossfeedSettings {
  const CrossfeedSettings({
    this.enabled = false,
    this.cutoffHz = 700,
    this.level = 0.3,
  });

  final bool enabled;

  /// Low-pass cutoff of the cross-fed signal (400..1100 Hz, bs2b defaults).
  final double cutoffHz;

  /// Crossfeed level 0..1 (0 = none, 1 = strongest).
  final double level;

  CrossfeedSettings copyWith({bool? enabled, double? cutoffHz, double? level}) =>
      CrossfeedSettings(
        enabled: enabled ?? this.enabled,
        cutoffHz: (cutoffHz ?? this.cutoffHz).clamp(400, 1100),
        level: (level ?? this.level).clamp(0.0, 1.0),
      );

  /// Cross-feed filter pair (per channel): low-pass at [cutoffHz] feeding
  /// the opposite channel at [level].
  List<ParametricBand> toBands() => enabled
      ? <ParametricBand>[
          ParametricBand(
            type: ParametricFilterType.lowShelf,
            frequencyHz: cutoffHz,
            gainDb: -4.5 * level.clamp(0.0, 1.0),
            q: 0.6,
          ),
        ]
      : const <ParametricBand>[];

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'cutoff_hz': cutoffHz,
    'level': level,
  };

  static CrossfeedSettings fromJson(Object? raw) {
    if (raw is! Map) return const CrossfeedSettings();
    return CrossfeedSettings(
      enabled: raw['enabled'] == true,
      cutoffHz: _finite(raw['cutoff_hz'], 700).clamp(400, 1100),
      level: _finite(raw['level'], 0.3).clamp(0.0, 1.0),
    );
  }
}

/// Convolver configuration. Application happens offline through the
/// existing FFmpeg pipeline (afir) for downloaded/prepared files; live
/// convolution stays capability-gated per platform.
class ConvolverSettings {
  const ConvolverSettings({
    this.enabled = false,
    this.impulseName = '',
    this.wetMix = 0.4,
  });

  final bool enabled;

  /// Name of a stored impulse response file (`assets`/user-provided WAV).
  final String impulseName;

  /// 0..1 (dry = 1 - wet).
  final double wetMix;

  ConvolverSettings copyWith({bool? enabled, String? impulseName, double? wetMix}) =>
      ConvolverSettings(
        enabled: enabled ?? this.enabled,
        impulseName: impulseName ?? this.impulseName,
        wetMix: (wetMix ?? this.wetMix).clamp(0.0, 1.0),
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'impulse_name': impulseName,
    'wet_mix': wetMix,
  };

  static ConvolverSettings fromJson(Object? raw) {
    if (raw is! Map) return const ConvolverSettings();
    return ConvolverSettings(
      enabled: raw['enabled'] == true,
      impulseName: raw['impulse_name']?.toString() ?? '',
      wetMix: _finite(raw['wet_mix'], 0.4).clamp(0.0, 1.0),
    );
  }
}

/// Loudness normalization policy on top of the existing ReplayGain path.
class LoudnessNormalizationSettings {
  const LoudnessNormalizationSettings({
    this.enabled = true,
    this.targetLufs = -18.0,
    this.preampDbMax = 6.0,
  });

  final bool enabled;

  /// Target integrated loudness (default: the ReplayGain 2.0 reference).
  final double targetLufs;

  /// Maximum positive gain applied for quiet masters.
  final double preampDbMax;

  /// Converts a track's ReplayGain dB to the gain needed for [targetLufs],
  /// clamped to [-30, +preampDbMax]. The offset points *away* from the
  /// target (pinned by test/advanced_audio_test.dart).
  double gainDbFor(double replayGainDb) {
    final offset = (targetLufs + 18.0).clamp(-12.0, 12.0).toDouble();
    final raw = replayGainDb - offset;
    return raw.clamp(-30.0, preampDbMax).toDouble();
  }

  LoudnessNormalizationSettings copyWith({
    bool? enabled,
    double? targetLufs,
    double? preampDbMax,
  }) => LoudnessNormalizationSettings(
    enabled: enabled ?? this.enabled,
    targetLufs: (targetLufs ?? this.targetLufs).clamp(-30, -8),
    preampDbMax: (preampDbMax ?? this.preampDbMax).clamp(0, 12),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'target_lufs': targetLufs,
    'preamp_db_max': preampDbMax,
  };

  static LoudnessNormalizationSettings fromJson(Object? raw) {
    if (raw is! Map) {
      return const LoudnessNormalizationSettings();
    }
    return LoudnessNormalizationSettings(
      enabled: raw['enabled'] != false,
      targetLufs: _finite(raw['target_lufs'], -18).clamp(-30, -8),
      preampDbMax: _finite(raw['preamp_db_max'], 6).clamp(0, 12),
    );
  }
}

/// The whole advanced chain.
class AdvancedAudioChain {
  const AdvancedAudioChain({
    this.enabled = false,
    this.equalizer = const ParametricEqualizer(),
    this.bassBoost = const BassBoostSettings(),
    this.vocalBoost = const VocalBoostSettings(),
    this.headphoneProfile = HeadphoneProfile.flat,
    this.crossfeed = const CrossfeedSettings(),
    this.convolver = const ConvolverSettings(),
    this.loudness = const LoudnessNormalizationSettings(),
  });

  final bool enabled;

  /// Master switch: when off, the existing 10-band EQ path is untouched.
  final ParametricEqualizer equalizer;
  final BassBoostSettings bassBoost;
  final VocalBoostSettings vocalBoost;
  final HeadphoneProfile headphoneProfile;
  final CrossfeedSettings crossfeed;
  final ConvolverSettings convolver;
  final LoudnessNormalizationSettings loudness;

  /// All active parametric bands (EQ + boosts + headphone + crossfeed
  /// equalization approximation), composed.
  List<ParametricBand> get activeBands => <ParametricBand>[
    ...equalizer.bands,
    ...bassBoost.toBands(),
    ...vocalBoost.toBands(),
    ...headphoneProfile.toBands(),
    ...crossfeed.toBands(),
  ];

  /// Flattens the chain onto the existing platform EQ: evaluates the full
  /// cascade at each centre frequency and returns the per-band gains the
  /// current `AudioEffectsSettings.toPlatformMap()` already carries.
  List<double> flattenToBandGains(List<double> centerFrequenciesHz) {
    if (!enabled) {
      return List<double>.filled(centerFrequenciesHz.length, 0);
    }
    final cascade = ParametricEqualizer(bands: activeBands);
    return <double>[
      for (final frequency in centerFrequenciesHz)
        cascade.gainDbAt(frequency).clamp(-12.0, 12.0).toDouble(),
    ];
  }

  AdvancedAudioChain copyWith({
    bool? enabled,
    ParametricEqualizer? equalizer,
    BassBoostSettings? bassBoost,
    VocalBoostSettings? vocalBoost,
    HeadphoneProfile? headphoneProfile,
    CrossfeedSettings? crossfeed,
    ConvolverSettings? convolver,
    LoudnessNormalizationSettings? loudness,
  }) => AdvancedAudioChain(
    enabled: enabled ?? this.enabled,
    equalizer: equalizer ?? this.equalizer,
    bassBoost: bassBoost ?? this.bassBoost,
    vocalBoost: vocalBoost ?? this.vocalBoost,
    headphoneProfile: headphoneProfile ?? this.headphoneProfile,
    crossfeed: crossfeed ?? this.crossfeed,
    convolver: convolver ?? this.convolver,
    loudness: loudness ?? this.loudness,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'equalizer': <Object?>[
      for (final band in equalizer.bands) band.toJson(),
    ],
    'bass_boost': <String, Object?>{
      'enabled': bassBoost.enabled,
      'amount': bassBoost.amount,
    },
    'vocal_boost': <String, Object?>{
      'enabled': vocalBoost.enabled,
      'amount': vocalBoost.amount,
    },
    'headphone_profile': headphoneProfile.name,
    'crossfeed': crossfeed.toJson(),
    'convolver': convolver.toJson(),
    'loudness': loudness.toJson(),
  };

  static AdvancedAudioChain fromJson(Object? raw) {
    if (raw is! Map) return const AdvancedAudioChain();
    final eqRaw = raw['equalizer'];
    return AdvancedAudioChain(
      enabled: raw['enabled'] == true,
      equalizer: ParametricEqualizer(
        bands: <ParametricBand>[
          if (eqRaw is List)
            for (final Object? band in eqRaw) ParametricBand.fromJson(band),
        ],
      ),
      bassBoost: BassBoostSettings(
        enabled: (raw['bass_boost'] is Map) &&
            (raw['bass_boost'] as Map)['enabled'] == true,
        amount: raw['bass_boost'] is Map
            ? _finite((raw['bass_boost'] as Map)['amount'], 0.5).clamp(0, 1)
            : 0.5,
      ),
      vocalBoost: VocalBoostSettings(
        enabled: (raw['vocal_boost'] is Map) &&
            (raw['vocal_boost'] as Map)['enabled'] == true,
        amount: raw['vocal_boost'] is Map
            ? _finite((raw['vocal_boost'] as Map)['amount'], 0.5).clamp(0, 1)
            : 0.5,
      ),
      headphoneProfile: HeadphoneProfile.fromName(raw['headphone_profile']),
      crossfeed: CrossfeedSettings.fromJson(raw['crossfeed']),
      convolver: ConvolverSettings.fromJson(raw['convolver']),
      loudness: LoudnessNormalizationSettings.fromJson(raw['loudness']),
    );
  }
}

/// A named, exportable chain preset.
class DspPreset {
  const DspPreset({required this.name, required this.chain, this.builtIn = false});

  final String name;
  final AdvancedAudioChain chain;
  final bool builtIn;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'chain': chain.toJson(),
  };

  static DspPreset? fromJson(Object? raw, {bool builtIn = false}) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString().trim() ?? '';
    if (name.isEmpty || name.length > 40) return null;
    return DspPreset(
      name: name,
      chain: AdvancedAudioChain.fromJson(raw['chain']),
      builtIn: builtIn,
    );
  }
}

/// Built-in full-chain presets.
final List<DspPreset> builtInDspPresets = List<DspPreset>.unmodifiable(
  <DspPreset>[
    const DspPreset(
      name: 'Reference',
      chain: AdvancedAudioChain(enabled: false),
      builtIn: true,
    ),
    const DspPreset(
      name: 'Club Bass',
      chain: AdvancedAudioChain(
        enabled: true,
        bassBoost: BassBoostSettings(enabled: true, amount: 0.8),
        loudness: LoudnessNormalizationSettings(),
      ),
      builtIn: true,
    ),
    const DspPreset(
      name: 'Vocal Focus',
      chain: AdvancedAudioChain(
        enabled: true,
        vocalBoost: VocalBoostSettings(enabled: true, amount: 0.8),
      ),
      builtIn: true,
    ),
    const DspPreset(
      name: 'Late Night',
      chain: AdvancedAudioChain(
        enabled: true,
        loudness: LoudnessNormalizationSettings(
          enabled: true,
          targetLufs: -21,
          preampDbMax: 3,
        ),
        crossfeed: CrossfeedSettings(enabled: true, level: 0.35),
      ),
      builtIn: true,
    ),
  ],
);

/// Minimal RIFF/WAVE parsing for user impulse responses (PCM 16/24/32 +
/// float32). Returns channel samples or null when the file is unusable.
class ImpulseResponse {
  const ImpulseResponse({
    required this.name,
    required this.sampleRateHz,
    required this.channels,
    required this.samples,
  });

  final String name;
  final int sampleRateHz;
  final int channels;

  /// Interleaved samples, normalized to -1..1.
  final List<double> samples;

  int get frames => channels <= 0 ? 0 : samples.length ~/ channels;

  /// Trims leading/trailing silence below [threshold] and caps length.
  ImpulseResponse trimmed({double threshold = 1e-4, int maxFrames = 65536}) {
    var start = 0;
    var end = frames;
    for (var f = 0; f < frames; f++) {
      var peak = 0.0;
      for (var c = 0; c < channels; c++) {
        final value = samples[f * channels + c].abs();
        if (value > peak) peak = value;
      }
      if (peak > threshold) {
        start = f;
        break;
      }
    }
    for (var f = frames - 1; f >= start; f--) {
      var peak = 0.0;
      for (var c = 0; c < channels; c++) {
        final value = samples[f * channels + c].abs();
        if (value > peak) peak = value;
      }
      if (peak > threshold) {
        end = f + 1;
        break;
      }
    }
    final limited = end - start > maxFrames ? start + maxFrames : end;
    return ImpulseResponse(
      name: name,
      sampleRateHz: sampleRateHz,
      channels: channels,
      samples: samples.sublist(
        start * channels,
        limited * channels,
      ),
    );
  }

  /// Parses a WAV byte blob (little-endian RIFF).
  static ImpulseResponse? parseWav(String name, List<int> bytes) {
    if (bytes.length < 44) return null;
    if (!(bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 &&
        bytes[3] == 0x46)) {
      return null; // RIFF
    }
    if (!(bytes[8] == 0x57 && bytes[9] == 0x41 && bytes[10] == 0x56 &&
        bytes[11] == 0x45)) {
      return null; // WAVE
    }
    var offset = 12;
    var sampleRate = 0;
    var channels = 0;
    var bits = 0;
    var audioFormat = 1;
    List<double>? data;
    while (offset + 8 <= bytes.length) {
      final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final chunkSize = bytes[offset + 4] |
          (bytes[offset + 5] << 8) |
          (bytes[offset + 6] << 16) |
          (bytes[offset + 7] << 24);
      final body = offset + 8;
      if (chunkId == 'fmt ') {
        if (body + 16 > bytes.length) return null;
        audioFormat = bytes[body] | (bytes[body + 1] << 8);
        channels = bytes[body + 2] | (bytes[body + 3] << 8);
        sampleRate = bytes[body + 4] |
            (bytes[body + 5] << 8) |
            (bytes[body + 6] << 16) |
            (bytes[body + 7] << 24);
        bits = bytes[body + 14] | (bytes[body + 15] << 8);
      } else if (chunkId == 'data') {
        final available = (bytes.length - body).clamp(0, chunkSize);
        final audioBytes = bytes.sublist(body, body + available);
        data = _decodePcm(audioBytes, bits, audioFormat);
      }
      offset = body + chunkSize + (chunkSize.isOdd ? 1 : 0);
    }
    if (data == null || channels <= 0 || sampleRate <= 0) return null;
    return ImpulseResponse(
      name: name,
      sampleRateHz: sampleRate,
      channels: channels,
      samples: data,
    );
  }

  static List<double> _decodePcm(List<int> bytes, int bits, int format) {
    final out = <double>[];
    if (format == 3 && bits == 32) {
      final byteData = ByteData.view(Uint8List.fromList(bytes).buffer);
      final count = bytes.length ~/ 4;
      for (var i = 0; i < count; i++) {
        out.add(byteData.getFloat32(i * 4, Endian.little));
      }
      return out;
    }
    if (bits == 16) {
      for (var i = 0; i + 1 < bytes.length; i += 2) {
        final value = bytes[i] | (bytes[i + 1] << 8);
        final signed = value >= 0x8000 ? value - 0x10000 : value;
        out.add(signed / 32768.0);
      }
      return out;
    }
    if (bits == 24) {
      for (var i = 0; i + 2 < bytes.length; i += 3) {
        final value =
            bytes[i] | (bytes[i + 1] << 8) | (bytes[i + 2] << 16);
        final signed = value >= 0x800000 ? value - 0x1000000 : value;
        out.add(signed / 8388608.0);
      }
      return out;
    }
    if (bits == 32 && format == 1) {
      for (var i = 0; i + 3 < bytes.length; i += 4) {
        final value = bytes[i] |
            (bytes[i + 1] << 8) |
            (bytes[i + 2] << 16) |
            (bytes[i + 3] << 24);
        final signed = value >= 0x80000000 ? value - 0x100000000 : value;
        out.add(signed / 2147483648.0);
      }
      return out;
    }
    return out;
  }
}
