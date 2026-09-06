import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/audio_effects.dart';

void main() {
  group('normalizeBandGains', () {
    test('always yields ten finite, clamped gains', () {
      expect(normalizeBandGains(null), List<double>.filled(10, 0));
      expect(normalizeBandGains([1, 2]), [1, 2, 0, 0, 0, 0, 0, 0, 0, 0]);
      final clamped = normalizeBandGains([99, -99, double.nan, 'x', 3.5]);
      expect(clamped.sublist(0, 5), [12, -12, 0, 0, 3.5]);
      expect(clamped.length, 10);
      expect(normalizeBandGains(List<int>.filled(14, 4)).length, 10);
    });
  });

  group('EqualizerPreset', () {
    test('built-ins start with Flat and are all flagged built-in', () {
      expect(EqualizerPreset.builtIns.first.name, EqualizerPreset.flatName);
      expect(
        EqualizerPreset.builtIns.first.gainsDb.every((g) => g == 0),
        isTrue,
      );
      expect(EqualizerPreset.builtIns.every((p) => p.builtIn), isTrue);
      final names = EqualizerPreset.builtIns.map((p) => p.name.toLowerCase());
      expect(names.toSet().length, EqualizerPreset.builtIns.length);
    });

    test('JSON round-trip and rejection of unusable entries', () {
      final preset = EqualizerPreset(
        name: 'Mine',
        gainsDb: const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
      );
      final restored = EqualizerPreset.fromJson(preset.toJson());
      expect(restored, preset);
      expect(EqualizerPreset.fromJson({'gains_db': [1]}), isNull);
      expect(EqualizerPreset.fromJson({'name': '   '}), isNull);
      expect(EqualizerPreset.fromJson('junk'), isNull);
      expect(EqualizerPreset.fromJson({'name': 'x' * 41}), isNull);
    });
  });

  group('AudioEffectsSettings', () {
    test('defaults are neutral and disabled', () {
      final settings = AudioEffectsSettings();
      expect(settings.enabled, isFalse);
      expect(settings.isEqualizerFlat, isTrue);
      expect(settings.hasActiveStage, isFalse);
      expect(settings.presetName, EqualizerPreset.flatName);
    });

    test('band edits drop the preset name; presets restore it', () {
      final settings = AudioEffectsSettings().withBandGain(3, 6);
      expect(settings.bandGainsDb[3], 6);
      expect(settings.presetName, isNull);
      expect(settings.hasActiveStage, isTrue);
      final rock = EqualizerPreset.builtIns.firstWhere(
        (p) => p.name == 'Rock',
      );
      final withPreset = settings.withPreset(rock);
      expect(withPreset.presetName, 'Rock');
      expect(withPreset.bandGainsDb, rock.gainsDb);
      // Out-of-range band is ignored.
      expect(settings.withBandGain(42, 1), settings);
    });

    test('constructor clamps every stage', () {
      final settings = AudioEffectsSettings(
        bassBoost: 4,
        virtualizer: -1,
        enhancerGainDb: 40,
        compressorThresholdDb: -100,
        compressorRatio: 0.1,
        limiterThresholdDb: 5,
      );
      expect(settings.bassBoost, 1);
      expect(settings.virtualizer, 0);
      expect(settings.enhancerGainDb, 12);
      expect(settings.compressorThresholdDb, -40);
      expect(settings.compressorRatio, 1);
      expect(settings.limiterThresholdDb, 0);
    });

    test('JSON round-trip, including a manual (null) preset name', () {
      final original = AudioEffectsSettings(
        enabled: true,
        bandGainsDb: const [1, -1, 2, -2, 3, -3, 4, -4, 5, -5],
        presetName: null,
        bassBoost: 0.4,
        virtualizer: 0.2,
        enhancerGainDb: 3,
        compressorEnabled: true,
        compressorThresholdDb: -20,
        compressorRatio: 4,
        limiterEnabled: true,
        limiterThresholdDb: -0.5,
      );
      final restored = AudioEffectsSettings.fromJson(original.toJson());
      expect(restored, original);
      expect(restored.presetName, isNull);
    });

    test('tolerates missing/corrupt keys', () {
      final restored = AudioEffectsSettings.fromJson(const {
        'enabled': 'yes',
        'band_gains_db': 'nope',
        'bass_boost': 'high',
      });
      expect(restored.enabled, isFalse);
      expect(restored.isEqualizerFlat, isTrue);
      expect(restored.bassBoost, 0);
    });

    test('platform map carries the band frequencies and every stage', () {
      final map = AudioEffectsSettings(enabled: true).toPlatformMap();
      expect(map['band_frequencies_hz'], equalizerBandFrequencies);
      expect((map['band_gains_db'] as List).length, 10);
      expect(map.containsKey('limiter_threshold_db'), isTrue);
    });
  });

  group('EqualizerPresetCodec', () {
    test('encode/decode round-trip keeps order and de-duplicates names', () {
      final presets = [
        EqualizerPreset(name: 'A', gainsDb: const [1, 0, 0, 0, 0, 0, 0, 0]),
        EqualizerPreset(name: 'B', gainsDb: const [0, 2, 0, 0, 0, 0, 0, 0]),
        EqualizerPreset(name: 'a', gainsDb: const [0, 0, 3, 0, 0, 0, 0, 0]),
      ];
      final text = EqualizerPresetCodec.encode(presets);
      final decoded = EqualizerPresetCodec.decode(text);
      expect(decoded.map((p) => p.name), ['A', 'B']);
      expect(decoded.first.gainsDb[0], 1);
    });

    test('accepts a bare list or a single preset, rejects junk', () {
      expect(
        EqualizerPresetCodec.decode('[{"name":"X","gains":[5]}]').single.name,
        'X',
      );
      expect(
        EqualizerPresetCodec.decode('{"name":"Y","gains_db":[]}').single.name,
        'Y',
      );
      expect(EqualizerPresetCodec.decode('not json'), isEmpty);
      expect(
        EqualizerPresetCodec.decode('{"type":"other","presets":[]}'),
        isEmpty,
      );
      expect(EqualizerPresetCodec.decode('42'), isEmpty);
    });

    test('caps the number of imported presets', () {
      final many = [
        for (var i = 0; i < EqualizerPresetCodec.maxPresets + 20; i++)
          {'name': 'p$i', 'gains_db': const [0]},
      ];
      final text = EqualizerPresetCodec.encode(
        many.map((m) => EqualizerPreset.fromJson(m)!),
      );
      expect(
        EqualizerPresetCodec.decode(text).length,
        EqualizerPresetCodec.maxPresets,
      );
    });
  });

  group('AudioEffectsCapabilities', () {
    test('parses flags and reports any', () {
      final caps = AudioEffectsCapabilities.fromMap(const {
        'equalizer': true,
        'compressor': false,
        'engine': 'test',
      });
      expect(caps.equalizer, isTrue);
      expect(caps.compressor, isFalse);
      expect(caps.any, isTrue);
      expect(caps.engine, 'test');
      expect(AudioEffectsCapabilities.none.any, isFalse);
    });
  });
}
