import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/crossfade_policy.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart';

const _flac = AudioCharacteristics(
  codec: 'FLAC',
  sampleRateHz: 44100,
  bitDepth: 16,
  lossless: true,
);
const _mp3 = AudioCharacteristics(codec: 'MP3', bitrateKbps: 320);
const _aac = AudioCharacteristics(codec: 'AAC', bitrateKbps: 256);

CrossfadeDecision _decide({
  CrossfadeSettings settings = const CrossfadeSettings(seconds: 6),
  Duration? duration = const Duration(minutes: 4),
  AudioCharacteristics current = _mp3,
  AudioCharacteristics next = _aac,
  bool sameTransport = true,
  bool gaplessEnabled = true,
  bool sameAlbum = false,
  bool sequentialNeighbours = false,
  bool repeatOne = false,
}) {
  return const CrossfadePolicy().decide(
    settings: settings,
    trackDuration: duration,
    current: current,
    next: next,
    sameTransport: sameTransport,
    gaplessEnabled: gaplessEnabled,
    sameAlbum: sameAlbum,
    sequentialNeighbours: sequentialNeighbours,
    repeatOne: repeatOne,
  );
}

void main() {
  group('CrossfadeSettings', () {
    test('zero seconds disables crossfade', () {
      expect(const CrossfadeSettings.off().enabled, isFalse);
      expect(const CrossfadeSettings(seconds: 0).enabled, isFalse);
      expect(const CrossfadeSettings(seconds: 3).enabled, isTrue);
      expect(const CrossfadeSettings(seconds: 3).nominal.inSeconds, 3);
    });

    test('value equality (the handler caches plans per settings)', () {
      expect(
        const CrossfadeSettings(seconds: 4, smart: true),
        const CrossfadeSettings(seconds: 4, smart: true),
      );
      expect(
        const CrossfadeSettings(seconds: 4, smart: true),
        isNot(const CrossfadeSettings(seconds: 4, smart: false)),
      );
    });
  });

  group('CrossfadePolicy.decide', () {
    test('disabled settings never crossfade', () {
      final decision = _decide(settings: const CrossfadeSettings.off());
      expect(decision.shouldCrossfade, isFalse);
      expect(decision.fade, isNull);
    });

    test('repeat-one never crossfades', () {
      expect(_decide(repeatOne: true).shouldCrossfade, isFalse);
    });

    test('unknown or zero duration never crossfades', () {
      expect(_decide(duration: null).shouldCrossfade, isFalse);
      expect(_decide(duration: Duration.zero).shouldCrossfade, isFalse);
    });

    test('nominal overlap for a normal mixed-codec transition', () {
      final decision = _decide();
      expect(decision.shouldCrossfade, isTrue);
      expect(decision.fade, const Duration(seconds: 6));
    });

    test('12 second maximum is honoured, longer values are clamped', () {
      final decision = _decide(
        settings: const CrossfadeSettings(seconds: 30, smart: false),
        duration: const Duration(minutes: 10),
      );
      expect(decision.fade, const Duration(seconds: 12));
    });

    test('smart mode skips consecutive tracks of the same album', () {
      final decision = _decide(sameAlbum: true, sequentialNeighbours: true);
      expect(decision.shouldCrossfade, isFalse);
      expect(decision.reason, contains('album'));
    });

    test('same album but shuffled (not neighbours) still crossfades', () {
      final decision = _decide(sameAlbum: true, sequentialNeighbours: false);
      expect(decision.shouldCrossfade, isTrue);
    });

    test('smart mode prefers the gapless splice for a lossless pair', () {
      final decision = _decide(current: _flac, next: _flac);
      expect(decision.shouldCrossfade, isFalse);
      expect(decision.reason, contains('gapless'));
    });

    test('lossless pair crossfades when gapless is disabled', () {
      final decision = _decide(
        current: _flac,
        next: _flac,
        gaplessEnabled: false,
      );
      expect(decision.shouldCrossfade, isTrue);
    });

    test('non-smart mode crossfades a lossless pair regardless', () {
      final decision = _decide(
        settings: const CrossfadeSettings(seconds: 6, smart: false),
        current: _flac,
        next: _flac,
      );
      expect(decision.shouldCrossfade, isTrue);
    });

    test('short tracks are left intact', () {
      expect(
        _decide(duration: const Duration(seconds: 25)).shouldCrossfade,
        isFalse,
      );
      // Non-smart threshold is lower.
      expect(
        _decide(
          settings: const CrossfadeSettings(seconds: 6, smart: false),
          duration: const Duration(seconds: 25),
        ).shouldCrossfade,
        isTrue,
      );
      expect(
        _decide(
          settings: const CrossfadeSettings(seconds: 6, smart: false),
          duration: const Duration(seconds: 8),
        ).shouldCrossfade,
        isFalse,
      );
    });

    test('overlap is shortened for short tracks and never below 1s', () {
      // Smart: at most an eighth of the track → 40s / 8 = 5s.
      final smart = _decide(
        settings: const CrossfadeSettings(seconds: 12),
        duration: const Duration(seconds: 40),
      );
      expect(smart.fade, const Duration(seconds: 5));
      expect(smart.reason, contains('shortened'));

      // Non-smart: at most a third → 12s / 3 = 4s.
      final plain = _decide(
        settings: const CrossfadeSettings(seconds: 12, smart: false),
        duration: const Duration(seconds: 12),
      );
      expect(plain.fade, const Duration(seconds: 4));

      final floor = _decide(
        settings: const CrossfadeSettings(seconds: 12, smart: false),
        duration: const Duration(seconds: 10),
      );
      expect(floor.fade! >= const Duration(seconds: 1), isTrue);
    });
  });

  group('CrossfadeDecision.shouldStartAt', () {
    test('fires once the remaining time is within the fade', () {
      const decision = CrossfadeDecision(
        fade: Duration(seconds: 5),
        reason: 'test',
      );
      const duration = Duration(minutes: 3);
      expect(decision.shouldStartAt(const Duration(seconds: 10), duration),
          isFalse);
      expect(
        decision.shouldStartAt(duration - const Duration(seconds: 6), duration),
        isFalse,
      );
      expect(
        decision.shouldStartAt(duration - const Duration(seconds: 5), duration),
        isTrue,
      );
      expect(
        decision.shouldStartAt(duration - const Duration(seconds: 1), duration),
        isTrue,
      );
    });

    test('never fires without a fade or duration', () {
      const none = CrossfadeDecision.none('off');
      expect(
        none.shouldStartAt(
          const Duration(seconds: 100),
          const Duration(seconds: 101),
        ),
        isFalse,
      );
      const decision = CrossfadeDecision(
        fade: Duration(seconds: 5),
        reason: 'test',
      );
      expect(decision.shouldStartAt(const Duration(seconds: 1), Duration.zero),
          isFalse);
    });
  });

  group('CrossfadePolicy.equalPowerGains', () {
    test('starts fully on the outgoing track and ends on the incoming one', () {
      final start = CrossfadePolicy.equalPowerGains(0);
      expect(start.outgoing, closeTo(1, 1e-9));
      expect(start.incoming, closeTo(0, 1e-9));
      final end = CrossfadePolicy.equalPowerGains(1);
      expect(end.outgoing, closeTo(0, 1e-9));
      expect(end.incoming, closeTo(1, 1e-9));
    });

    test('keeps constant power through the fade', () {
      for (var i = 0; i <= 10; i++) {
        final g = CrossfadePolicy.equalPowerGains(i / 10);
        expect(g.outgoing * g.outgoing + g.incoming * g.incoming,
            closeTo(1, 1e-9));
      }
    });

    test('clamps out-of-range progress', () {
      expect(CrossfadePolicy.equalPowerGains(-1).outgoing, closeTo(1, 1e-9));
      expect(CrossfadePolicy.equalPowerGains(2).incoming, closeTo(1, 1e-9));
      expect(CrossfadePolicy.equalPowerGains(double.nan).outgoing,
          closeTo(1, 1e-9));
    });
  });

  group('EngineSettings crossfade persistence', () {
    test('defaults to off with smart mode on', () {
      const settings = EngineSettings();
      expect(settings.crossfadeSeconds, 0);
      expect(settings.crossfadeSmart, isTrue);
      expect(settings.crossfade.enabled, isFalse);
    });

    test('round-trips through JSON and clamps stored values', () {
      const original = EngineSettings(
        crossfadeSeconds: 8,
        crossfadeSmart: false,
      );
      final restored = EngineSettings.fromJson(original.toJson());
      expect(restored.crossfadeSeconds, 8);
      expect(restored.crossfadeSmart, isFalse);
      expect(
        restored.crossfade,
        const CrossfadeSettings(seconds: 8, smart: false),
      );

      final clamped = EngineSettings.fromJson(const {'crossfade_seconds': 99});
      expect(clamped.crossfadeSeconds, CrossfadeSettings.maxSeconds);
    });

    test('older stored settings without the keys stay crossfade-free', () {
      final restored = EngineSettings.fromJson(const {'gapless_enabled': true});
      expect(restored.crossfadeSeconds, 0);
      expect(restored.crossfadeSmart, isTrue);
    });
  });
}
