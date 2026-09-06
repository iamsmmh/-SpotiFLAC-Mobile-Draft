import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/audio/crossfade_manager.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';

void main() {
  const flac = AudioCharacteristics(
    codec: 'FLAC',
    sampleRateHz: 44100,
    bitDepth: 16,
    channels: 2,
    lossless: true,
  );
  const mp3 = AudioCharacteristics(codec: 'MP3', bitrateKbps: 320);

  group('CrossfadeManager configuration', () {
    test('clamps to 0 or 1–12 seconds', () {
      expect(CrossfadeManager.clampSeconds(0), 0);
      expect(CrossfadeManager.clampSeconds(-3), 0);
      expect(CrossfadeManager.clampSeconds(1), 1);
      expect(CrossfadeManager.clampSeconds(7), 7);
      expect(CrossfadeManager.clampSeconds(12), 12);
      expect(CrossfadeManager.clampSeconds(30), 12);
    });

    test('configure stores values and reports changes', () {
      final manager = CrossfadeManager();
      expect(
        manager.configure(seconds: 6, smart: true),
        isTrue,
      );
      expect(manager.enabled, isTrue);
      expect(manager.seconds, 6);
      expect(
        manager.configure(seconds: 6, smart: true),
        isFalse,
      );
      manager.configure(seconds: 0);
      expect(manager.enabled, isFalse);
    });

    test('settings round-trip into CrossfadeSettings', () {
      final manager = CrossfadeManager()..configure(seconds: 9);
      expect(manager.settings.seconds, 9);
      expect(manager.settings.enabled, isTrue);
    });
  });

  group('CrossfadeManager.decide', () {
    test('skips album-continuous neighbours in smart mode', () {
      final manager = CrossfadeManager()
        ..configure(seconds: 6, smart: true);
      final decision = manager.decide(
        trackDuration: const Duration(minutes: 3),
        current: mp3,
        next: mp3,
        sameTransport: true,
        gaplessEnabled: true,
        sameAlbum: true,
        sequentialNeighbours: true,
      );
      expect(decision.shouldCrossfade, isFalse);
    });

    test('fades mixed-codec transitions at the nominal overlap', () {
      final manager = CrossfadeManager()
        ..configure(seconds: 4, smart: true);
      final decision = manager.decide(
        trackDuration: const Duration(minutes: 3),
        current: flac,
        next: mp3,
        sameTransport: true,
        gaplessEnabled: true,
        sameAlbum: false,
      );
      expect(decision.shouldCrossfade, isTrue);
      expect(decision.fade, const Duration(seconds: 4));
    });
  });

  group('Fade curves', () {
    test('equal-power is flat in perceived power', () {
      final gains = CrossfadeManager.gainsFor(
        FadeCurveKind.equalPower,
        0.5,
      );
      final power = gains.outgoing * gains.outgoing +
          gains.incoming * gains.incoming;
      expect(power, closeTo(1.0, 1e-9));
    });

    test('linear crosses at half amplitude', () {
      final gains = CrossfadeManager.gainsFor(FadeCurveKind.linear, 0.5);
      expect(gains.outgoing, closeTo(0.5, 1e-9));
      expect(gains.incoming, closeTo(0.5, 1e-9));
    });

    test('S-curve starts and ends slowly', () {
      final early = CrossfadeManager.gainsFor(FadeCurveKind.smoothSCurve, 0.1);
      final late = CrossfadeManager.gainsFor(FadeCurveKind.smoothSCurve, 0.9);
      expect(early.incoming, lessThan(0.1));
      expect(late.outgoing, lessThan(0.1));
    });

    test('progress clamping keeps gains in range', () {
      final over = CrossfadeManager.gainsFor(FadeCurveKind.linear, 1.7);
      final under = CrossfadeManager.gainsFor(
        FadeCurveKind.linear,
        -0.7,
      );
      expect(over.outgoing, 0.0);
      expect(over.incoming, 1.0);
      expect(under.outgoing, 1.0);
      expect(under.incoming, 0.0);
    });

    test('auto curve picks the S-curve for very short fades', () {
      final manager = CrossfadeManager()
        ..configure(seconds: 1, curve: FadeCurveKind.equalPower, autoCurve: true);
      expect(
        manager.curveFor(const Duration(milliseconds: 900)),
        FadeCurveKind.smoothSCurve,
      );
      expect(
        manager.curveFor(const Duration(seconds: 5)),
        FadeCurveKind.equalPower,
      );
      // Explicit curve: auto off honours the user's choice.
      manager.configure(
        seconds: 1,
        curve: FadeCurveKind.linear,
        autoCurve: false,
      );
      expect(
        manager.curveFor(const Duration(milliseconds: 900)),
        FadeCurveKind.linear,
      );
    });

    test('gains(fade, progress) uses the auto-selected curve', () {
      final manager = CrossfadeManager()
        ..configure(seconds: 1, autoCurve: true);
      final gains = manager.gains(const Duration(milliseconds: 800), 0.0);
      expect(gains.outgoing, 1.0);
      expect(gains.incoming, 0.0);
    });
  });

  group('FadeCurveKind', () {
    test('parses names leniently', () {
      expect(FadeCurveKind.fromName('linear'), FadeCurveKind.linear);
      expect(FadeCurveKind.fromName('bogus'), FadeCurveKind.equalPower);
    });
  });
}
