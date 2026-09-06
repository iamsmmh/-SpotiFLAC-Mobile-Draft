import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:spotimusic/engine/advanced_audio.dart';

void main() {
  group('BiquadCoefficients (RBJ cookbook)', () {
    test('peaking filter boosts around its centre', () {
      const band = ParametricBand(
        type: ParametricFilterType.peaking,
        frequencyHz: 1000,
        gainDb: 6,
        q: 1,
      );
      final coefficients = BiquadCoefficients.forBand(band, 48000);
      final atCentre = _db(coefficients.magnitudeAt(1000, 48000));
      final farAway = _db(coefficients.magnitudeAt(10000, 48000));
      expect(atCentre, closeTo(6, 0.6));
      expect(farAway.abs(), lessThan(1.5));
    });

    test('low shelf lifts the bass and leaves the treble alone', () {
      const band = ParametricBand(
        type: ParametricFilterType.lowShelf,
        frequencyHz: 120,
        gainDb: 4,
        q: 0.7,
      );
      final coefficients = BiquadCoefficients.forBand(band, 48000);
      expect(_db(coefficients.magnitudeAt(30, 48000)), closeTo(4, 0.6));
      expect(_db(coefficients.magnitudeAt(8000, 48000)).abs(), lessThan(1.0));
    });

    test('high shelf lifts the treble', () {
      const band = ParametricBand(
        type: ParametricFilterType.highShelf,
        frequencyHz: 8000,
        gainDb: 3,
        q: 0.7,
      );
      final coefficients = BiquadCoefficients.forBand(band, 48000);
      expect(_db(coefficients.magnitudeAt(16000, 48000)), closeTo(3, 0.6));
      expect(_db(coefficients.magnitudeAt(200, 48000)).abs(), lessThan(1.0));
    });

    test('cuts attenuate their stop band', () {
      const lowCut = ParametricBand(
        type: ParametricFilterType.lowCut,
        frequencyHz: 80,
        gainDb: 0,
        q: 0.7,
      );
      final coefficients = BiquadCoefficients.forBand(lowCut, 48000);
      expect(coefficients.magnitudeAt(20, 48000), lessThan(0.5));
      expect(
        (coefficients.magnitudeAt(2000, 48000) - 1).abs(),
        lessThan(0.2),
      );
    });
  });

  group('ParametricEqualizer cascade', () {
    test('sums the gains of stacked bands', () {
      // Two peaking bands at the same centre each contribute their full
      // gain there, so the cascade must sum to ~6 dB at 100 Hz. (A shelf
      // at 90 Hz would only add ~1.2 dB at 100 Hz — shelves reach full
      // gain below their corner, not at it.)
      const eq = ParametricEqualizer(
        bands: <ParametricBand>[
          ParametricBand(
            type: ParametricFilterType.peaking,
            frequencyHz: 100,
            gainDb: 3,
          ),
          ParametricBand(
            type: ParametricFilterType.peaking,
            frequencyHz: 100,
            gainDb: 3,
          ),
        ],
      );
      final gain = eq.gainDbAt(100);
      expect(gain, closeTo(6, 0.8));
      expect(eq.isFlat, isFalse);
    });

    test('flat when no bands', () {
      expect(const ParametricEqualizer().isFlat, isTrue);
    });
  });

  group('AdvancedAudioChain', () {
    test('disabled chains flatten to zeros', () {
      const chain = AdvancedAudioChain(
        enabled: false,
        bassBoost: BassBoostSettings(enabled: true, amount: 1),
      );
      final gains = chain.flattenToBandGains(<double>[31, 1000, 16000]);
      expect(gains, everyElement(0));
    });

    test('bass boost flattens onto the low bands only', () {
      const chain = AdvancedAudioChain(
        enabled: true,
        bassBoost: BassBoostSettings(enabled: true, amount: 1),
      );
      final gains = chain.flattenToBandGains(<double>[31, 62, 1000, 8000]);
      expect(gains[0], greaterThan(5));
      expect(gains[1], greaterThan(4));
      expect(gains[2].abs(), lessThan(1.5));
      expect(gains[3].abs(), lessThan(1.5));
    });

    test('vocal boost lifts presence and cuts mud', () {
      const chain = AdvancedAudioChain(
        enabled: true,
        vocalBoost: VocalBoostSettings(enabled: true, amount: 1),
      );
      final gains = chain.flattenToBandGains(<double>[250, 2800]);
      expect(gains[0], lessThan(-1));
      expect(gains[1], greaterThan(3));
    });

    test('headphone profiles change the curve', () {
      const vShaped = AdvancedAudioChain(
        enabled: true,
        headphoneProfile: HeadphoneProfile.vShaped,
      );
      const flat = AdvancedAudioChain(enabled: true);
      final vGains = vShaped.flattenToBandGains(<double>[60, 1000, 12000]);
      final fGains = flat.flattenToBandGains(<double>[60, 1000, 12000]);
      expect(vGains[0] - fGains[0], greaterThan(2));
      expect(vGains[1] - fGains[1], lessThan(0));
      expect(vGains[2] - fGains[2], greaterThan(1));
    });

    test('JSON round trip preserves every stage', () {
      const chain = AdvancedAudioChain(
        enabled: true,
        bassBoost: BassBoostSettings(enabled: true, amount: 0.7),
        vocalBoost: VocalBoostSettings(enabled: true, amount: 0.3),
        headphoneProfile: HeadphoneProfile.warm,
        crossfeed: CrossfeedSettings(enabled: true, level: 0.4, cutoffHz: 650),
        convolver: ConvolverSettings(enabled: true, impulseName: 'hall.wav'),
        loudness: LoudnessNormalizationSettings(targetLufs: -16),
      );
      final restored = AdvancedAudioChain.fromJson(
        jsonDecode(jsonEncode(chain.toJson())) as Map<String, dynamic>,
      );
      expect(restored.enabled, isTrue);
      expect(restored.bassBoost.amount, closeTo(0.7, 1e-9));
      expect(restored.vocalBoost.enabled, isTrue);
      expect(restored.headphoneProfile, HeadphoneProfile.warm);
      expect(restored.crossfeed.cutoffHz, 650);
      expect(restored.convolver.impulseName, 'hall.wav');
      expect(restored.loudness.targetLufs, -16);
    });
  });

  group('LoudnessNormalizationSettings', () {
    test('offsets replaygain toward the target and clamps', () {
      const settings = LoudnessNormalizationSettings(
        targetLufs: -16,
        preampDbMax: 6,
      );
      // -18 reference → -16 target needs +2 dB more gain.
      expect(settings.gainDbFor(0), closeTo(-2, 1e-9));
      // Quiet masters clamp to the pre-amp ceiling.
      expect(settings.gainDbFor(12), 6);
      // Loud masters attenuate hard.
      expect(settings.gainDbFor(-14), -16);
    });
  });

  group('ImpulseResponse', () {
    test('parses a minimal 16-bit stereo WAV', () {
      final wav = _buildWav(
        channels: 2,
        sampleRate: 48000,
        bits: 16,
        samples: <int>[
          0, 0, // silence
          16384, -16384, // peak
          0, 0,
        ],
      );
      final ir = ImpulseResponse.parseWav('test.wav', wav);
      expect(ir, isNotNull);
      expect(ir!.channels, 2);
      expect(ir.sampleRateHz, 48000);
      expect(ir.frames, 3);
      expect(ir.samples[2], closeTo(0.5, 1e-6));
    });

    test('trims leading and trailing silence', () {
      final wav = _buildWav(
        channels: 1,
        sampleRate: 48000,
        bits: 16,
        samples: <int>[
          0, 0, 0, 0, 8000, 0, 0, 0, 0, 0,
        ],
      );
      final ir = ImpulseResponse.parseWav('t.wav', wav)!.trimmed();
      expect(ir.frames, 1);
    });

    test('rejects non-RIFF payloads', () {
      expect(ImpulseResponse.parseWav('x', <int>[1, 2, 3]), isNull);
    });
  });

  group('DspPreset', () {
    test('built-ins exist and parse from JSON', () {
      expect(builtInDspPresets.length, greaterThanOrEqualTo(4));
      final preset = builtInDspPresets.first;
      final restored = DspPreset.fromJson(
        jsonDecode(jsonEncode(preset.toJson())) as Map<String, dynamic>,
      );
      expect(restored!.name, preset.name);
      expect(restored.chain.enabled, preset.chain.enabled);
    });

    test('rejects rows without names', () {
      expect(DspPreset.fromJson(<String, String>{'name': ''}), isNull);
      expect(DspPreset.fromJson('junk'), isNull);
    });
  });
}

double _db(double magnitude) =>
    magnitude <= 0 ? -99 : 20 * math.log(magnitude) / math.ln10;

List<int> _buildWav({
  required int channels,
  required int sampleRate,
  required int bits,
  required List<int> samples,
}) {
  final data = <int>[];
  if (bits == 16) {
    for (final value in samples) {
      final signed = value >= 0x8000 ? value - 0x10000 : value;
      data
        ..add(signed & 0xFF)
        ..add((signed >> 8) & 0xFF);
    }
  }
  final header = <int>[
    0x52, 0x49, 0x46, 0x46, // RIFF
    36 + data.length, 0, 0, 0, // size
    0x57, 0x41, 0x56, 0x45, // WAVE
    0x66, 0x6D, 0x74, 0x20, // 'fmt '
    16, 0, 0, 0, // chunk size
    1, 0, // PCM
    channels, 0,
    sampleRate, 0, 0, 0,
    sampleRate * channels * (bits ~/ 8), 0, 0, 0,
    channels * (bits ~/ 8), 0,
    bits, 0,
    0x64, 0x61, 0x74, 0x61, // 'data'
    data.length, 0, 0, 0,
  ];
  return <int>[...header, ...data];
}
