import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/adaptive_buffer.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';

void main() {
  const planner = AdaptiveBufferPlanner();

  test('offline disables buffering', () {
    final decision = planner.plan(
      profile: NetworkProfile.offline,
      policy: const StreamBufferPolicy(),
    );
    expect(decision.headBytes, 0);
    expect(decision.prebufferNextTrack, isFalse);
  });

  test('poor network opens a deeper low-bandwidth window', () {
    final poor = planner.plan(
      profile: NetworkProfile.poor,
      policy: const StreamBufferPolicy(),
      bitrateKbps: 128,
      lowBandwidthBufferSeconds: 30,
      prebufferHeadBytes: 512 * 1024,
    );
    final wifi = planner.plan(
      profile: NetworkProfile.wifi,
      policy: const StreamBufferPolicy(),
      bitrateKbps: 128,
      prebufferHeadBytes: 512 * 1024,
    );
    expect(poor.headBytes, greaterThan(wifi.headBytes));
  });

  test('head bytes respect the configured cap', () {
    final decision = planner.plan(
      profile: NetworkProfile.wifi,
      policy: const StreamBufferPolicy(),
      bitrateKbps: 1411,
      prebufferHeadBytes: 64 * 1024,
    );
    expect(decision.headBytes, lessThanOrEqualTo(64 * 1024));
    expect(decision.headBytes, greaterThanOrEqualTo(16 * 1024));
  });

  test('bitrate-derived throughput when there is no live sample', () {
    final decision = planner.plan(
      profile: NetworkProfile.wifi,
      policy: const StreamBufferPolicy(targetSeconds: Duration(seconds: 20)),
      bitrateKbps: 320,
      prebufferHeadBytes: 1 << 20,
    );
    // 320 kbps → 40000 B/s × 20 s = 800000 bytes.
    expect(decision.headBytes, 800000);
  });

  test('live throughput overrides the bitrate estimate', () {
    final decision = planner.plan(
      profile: NetworkProfile.wifi,
      policy: const StreamBufferPolicy(targetSeconds: Duration(seconds: 20)),
      bitrateKbps: 320,
      measuredBytesPerSecond: 100000,
      prebufferHeadBytes: 4 << 20,
    );
    expect(decision.headBytes, 100000 * 20);
  });

  test('preload disabled preflights but does not prebuffer', () {
    final decision = planner.plan(
      profile: NetworkProfile.wifi,
      policy: const StreamBufferPolicy(),
      bitrateKbps: 320,
      preloadEnabled: false,
    );
    expect(decision.prebufferNextTrack, isFalse);
  });
}
