import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/gapless_policy.dart';

void main() {
  const policy = GaplessPolicy();

  const flac16 = AudioCharacteristics(
    codec: 'FLAC',
    sampleRateHz: 44100,
    bitDepth: 16,
    channels: 2,
    lossless: true,
  );
  const flac16Other = AudioCharacteristics(
    codec: 'FLAC',
    sampleRateHz: 44100,
    bitDepth: 16,
    channels: 2,
    lossless: true,
  );
  const flac24 = AudioCharacteristics(
    codec: 'FLAC',
    sampleRateHz: 96000,
    bitDepth: 24,
    channels: 2,
    lossless: true,
  );
  const mp3 = AudioCharacteristics(codec: 'MP3', bitrateKbps: 320);

  test('identical lossless sources splice seamlessly', () {
    final decision = policy.decide(
      enabled: true,
      current: flac16,
      next: flac16Other,
      sameTransport: true,
    );
    expect(decision.kind, GaplessTransitionKind.seamless);
    expect(decision.canSkipSourceTeardown, isTrue);
  });

  test('mismatched stream parameters prebuffer instead of splicing', () {
    final decision = policy.decide(
      enabled: true,
      current: flac16,
      next: flac24,
      sameTransport: true,
    );
    expect(decision.kind, GaplessTransitionKind.prebuffer);
    expect(decision.canSkipSourceTeardown, isFalse);
    expect(decision.shouldPrebuffer, isTrue);
  });

  test('lossy codecs never splice', () {
    final decision = policy.decide(
      enabled: true,
      current: mp3,
      next: mp3,
      sameTransport: true,
    );
    expect(decision.kind, GaplessTransitionKind.prebuffer);
  });

  test('a local ↔ stream transition prebuffers', () {
    final decision = policy.decide(
      enabled: true,
      current: flac16,
      next: flac16Other,
      sameTransport: false,
    );
    expect(decision.kind, GaplessTransitionKind.prebuffer);
    expect(decision.reason, contains('transport'));
  });

  test('disabled always returns disabled', () {
    final decision = policy.decide(
      enabled: false,
      current: flac16,
      next: flac16Other,
      sameTransport: true,
    );
    expect(decision.kind, GaplessTransitionKind.disabled);
  });

  test('sameStreamParameters compares sample rate, depth and channels', () {
    expect(GaplessPolicy.sameStreamParameters(flac16, flac16Other), isTrue);
    expect(GaplessPolicy.sameStreamParameters(flac16, flac24), isFalse);
  });
}
