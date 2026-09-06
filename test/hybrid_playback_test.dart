import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/streaming/hybrid_playback.dart';

HybridPlaybackFacts facts({
  bool hasLocalFile = false,
  bool hasVerifiedCache = false,
  bool streamResolved = false,
  bool cachePermitted = false,
  bool cacheEnabled = false,
  bool offline = false,
}) => HybridPlaybackFacts(
  hasLocalFile: hasLocalFile,
  hasVerifiedCache: hasVerifiedCache,
  streamResolved: streamResolved,
  cachePermitted: cachePermitted,
  cacheEnabled: cacheEnabled,
  offline: offline,
);

void main() {
  const planner = HybridPlaybackPlanner();

  test('local file always wins', () {
    final plan = planner.plan(facts(
      hasLocalFile: true,
      hasVerifiedCache: true,
      streamResolved: true,
    ));
    expect(plan.action, HybridPlaybackAction.playLocal);
    expect(plan.backgroundFetch, isFalse);
  });

  test('verified cache beats streaming', () {
    final plan = planner.plan(facts(
      hasVerifiedCache: true,
      streamResolved: true,
      cacheEnabled: true,
    ));
    expect(plan.action, HybridPlaybackAction.playCache);
    expect(plan.backgroundFetch, isFalse);
  });

  test('offline without any copy is unavailable', () {
    final plan = planner.plan(facts(offline: true));
    expect(plan.action, HybridPlaybackAction.unavailable);
    expect(plan.startsPlayback, isFalse);
  });

  test('stream + cache when terms and settings allow', () {
    final plan = planner.plan(facts(
      streamResolved: true,
      cachePermitted: true,
      cacheEnabled: true,
    ));
    expect(plan.action, HybridPlaybackAction.playStreamAndCache);
    expect(plan.backgroundFetch, isTrue);
    expect(plan.swapWhenVerified, isTrue);
  });

  test('stream only when the source forbids caching', () {
    final plan = planner.plan(facts(
      streamResolved: true,
      cachePermitted: false,
      cacheEnabled: true,
    ));
    expect(plan.action, HybridPlaybackAction.playStreamAndCache);
    expect(plan.backgroundFetch, isFalse);
    expect(plan.reason, contains('source terms'));
  });

  test('stream only when the user disabled caching', () {
    final plan = planner.plan(facts(
      streamResolved: true,
      cachePermitted: true,
      cacheEnabled: false,
    ));
    expect(plan.backgroundFetch, isFalse);
    expect(plan.reason, contains('user setting'));
  });

  test('no stream falls back to download & play', () {
    final plan = planner.plan(facts());
    expect(plan.action, HybridPlaybackAction.downloadAndPlay);
  });

  test('offline mode never reaches the stream branch', () {
    final plan = planner.plan(facts(offline: true, streamResolved: true));
    expect(plan.action, HybridPlaybackAction.unavailable);
  });
}
