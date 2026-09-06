import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/cache/cache_cleanup_worker.dart';
import 'package:spotiflac_android/ecosystem/cache/cache_index.dart';
import 'package:spotiflac_android/ecosystem/cache/cache_models.dart';

CacheEntry entry(
  String key, {
  String trackKey = 'tk',
  int bytes = 1000,
  bool complete = true,
  bool pinned = false,
  DateTime? lastAccessed,
  DateTime? created,
}) => CacheEntry(
  cacheKey: key,
  trackKey: trackKey,
  title: 'T',
  artist: 'A',
  fileName: '$key.flac',
  audioFormat: CachedAudioFormat.flac,
  bytes: bytes,
  durationMs: 180000,
  createdAt: created ?? DateTime(2026, 1, 1),
  lastAccessedAt: lastAccessed ?? DateTime(2026, 1, 1),
  complete: complete,
  pinned: pinned,
  sha256: 'deadbeef',
);

void main() {
  group('CachedAudioFormat sniffing', () {
    test('recognizes the four cache-supported formats', () {
      expect(
        CachedAudioFormat.sniff(<int>[0x66, 0x4C, 0x61, 0x43, 0, 0, 0, 0]),
        CachedAudioFormat.flac,
      );
      expect(
        CachedAudioFormat.sniff(<int>[0x49, 0x44, 0x33, 0x04]),
        CachedAudioFormat.mp3,
      );
      expect(
        CachedAudioFormat.sniff(<int>[0xFF, 0xF1, 0x50, 0x80]),
        CachedAudioFormat.aac,
      );
      expect(
        CachedAudioFormat.sniff(<int>[
          0x4F, 0x67, 0x67, 0x53, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
          0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x4F, 0x70, 0x75, 0x73,
          0x48, 0x65, 0x61, 0x64, 1,
        ]),
        CachedAudioFormat.opus,
      );
    });

    test('codec labels map loosely', () {
      expect(
        CachedAudioFormat.fromCodecLabel('mp4a.40.2'),
        CachedAudioFormat.aac,
      );
      expect(CachedAudioFormat.fromCodecLabel('FLAC'), CachedAudioFormat.flac);
      expect(CachedAudioFormat.fromCodecLabel(''), CachedAudioFormat.unknown);
    });
  });

  group('CacheEntry codec', () {
    test('row round trip keeps every field', () {
      final original = entry('k1', bytes: 4242, trackKey: 'tk9')
          .copyWith(sha256: 'abc', accessCount: 3);
      final restored = CacheEntry.fromRow(original.toRow());
      expect(restored.cacheKey, 'k1');
      expect(restored.trackKey, 'tk9');
      expect(restored.bytes, 4242);
      expect(restored.accessCount, 3);
      expect(restored.audioFormat, CachedAudioFormat.flac);
      expect(restored.isPlayable, isTrue);
    });
  });

  group('CacheIndex', () {
    test('prefers the freshest complete entry per track', () {
      final old = entry('a', lastAccessed: DateTime(2026, 1, 1));
      final fresh = entry('b', lastAccessed: DateTime(2026, 2, 1));
      final partial = entry('c', complete: false);
      final index = CacheIndex(<CacheEntry>[old, fresh, partial]);
      expect(index.length, 3);
      expect(index.totalBytes, 3000);
      expect(index.playableForTrack('tk')!.cacheKey, 'b');
      expect(index.allForTrack('tk'), hasLength(3));
    });

    test('incomplete entries are never playable', () {
      final index = CacheIndex(<CacheEntry>[entry('x', complete: false)]);
      expect(index.playableForTrack('tk'), isNull);
    });
  });

  group('CacheCleanupPlanner', () {
    test('evicts least-recently-accessed until the budget fits', () {
      final planner = CacheCleanupPlanner(budgetBytes: 2000);
      final plan = planner.plan(
        <CacheEntry>[
          entry('lru', lastAccessed: DateTime(2026, 1, 1), bytes: 1000),
          entry('middle', lastAccessed: DateTime(2026, 2, 1), bytes: 1000),
          entry('recent', lastAccessed: DateTime(2026, 3, 1), bytes: 1000),
        ],
        now: DateTime(2026, 4, 1),
      );
      expect(plan.evict.map((e) => e.cacheKey), <String>['lru']);
      expect(plan.projectedBytes, 2000);
      expect(plan.freedBytes, 1000);
    });

    test('pinned entries are protected', () {
      final planner = CacheCleanupPlanner(budgetBytes: 500);
      final plan = planner.plan(
        <CacheEntry>[
          entry('pinned', pinned: true, lastAccessed: DateTime(2026, 1, 1)),
          entry('evictable', lastAccessed: DateTime(2026, 2, 1)),
        ],
        now: DateTime(2026, 4, 1),
      );
      expect(plan.evict.map((e) => e.cacheKey), <String>['evictable']);
      // Pinned bytes remain "over budget" — honesty over force.
      expect(plan.projectedBytes, 1000);
    });

    test('stale partials are swept, fresh ones kept', () {
      final planner = CacheCleanupPlanner(
        budgetBytes: 100000,
        stalePartialAge: const Duration(hours: 12),
      );
      final plan = planner.plan(
        <CacheEntry>[
          entry('stale', complete: false, created: DateTime(2026, 1, 1)),
          entry('fresh', complete: false, created: DateTime(2026, 1, 1, 13)),
        ],
        now: DateTime(2026, 1, 2),
      );
      expect(plan.sweepPartials.map((e) => e.cacheKey), <String>['stale']);
      expect(plan.projectedBytes, 1000);
    });

    test('nothing is evicted under budget', () {
      final planner = CacheCleanupPlanner(budgetBytes: 5000);
      final plan = planner.plan(<CacheEntry>[entry('a'), entry('b')]);
      expect(plan.evict, isEmpty);
      expect(plan.projectedBytes, 2000);
    });
  });
}
