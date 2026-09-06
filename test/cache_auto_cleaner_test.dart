import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/cache_auto_cleaner.dart';

void main() {
  CacheEntry entry(String path, int size, DateTime modified) => CacheEntry(
    path: path,
    sizeBytes: size,
    lastModified: modified,
  );

  group('CacheCleanPlanner.planPrune', () {
    test('returns nothing when already under the limit', () {
      final entries = [
        entry('/c/a.bin', 100, DateTime(2026, 1, 1)),
        entry('/c/b.bin', 200, DateTime(2026, 1, 2)),
      ];
      expect(
        CacheCleanPlanner.planPrune(entries, maxBytes: 500),
        isEmpty,
      );
    });

    test('prunes least-recently-used files first, oldest first', () {
      final entries = [
        entry('/c/new.bin', 400, DateTime(2026, 1, 3)),
        entry('/c/old.bin', 300, DateTime(2026, 1, 1)),
        entry('/c/mid.bin', 500, DateTime(2026, 1, 2)),
      ];
      final plan = CacheCleanPlanner.planPrune(entries, maxBytes: 500);
      // total = 1200; need to free 700 → oldest (300) then mid (500).
      expect(plan.map((e) => e.path).toList(), ['/c/old.bin', '/c/mid.bin']);
    });

    test('zero or negative limit means no pruning', () {
      final entries = [entry('/c/a.bin', 100, DateTime(2026))];
      expect(CacheCleanPlanner.planPrune(entries, maxBytes: 0), isEmpty);
      expect(CacheCleanPlanner.planPrune(entries, maxBytes: -1), isEmpty);
    });

    test('does not mutate the input list', () {
      final entries = [entry('/c/a.bin', 100, DateTime(2026))];
      final before = entries.length;
      CacheCleanPlanner.planPrune(entries, maxBytes: 50);
      expect(entries.length, before);
    });
  });

  group('CacheCleanPlanner broken-stream detection', () {
    test('flags partial/stale stream artifacts by extension', () {
      expect(CacheCleanPlanner.isBrokenStreamArtifact('/t/foo.part'), isTrue);
      expect(CacheCleanPlanner.isBrokenStreamArtifact('/t/foo.tmp'), isTrue);
      expect(CacheCleanPlanner.isBrokenStreamArtifact('/t/foo.crdownload'), isTrue);
      expect(CacheCleanPlanner.isBrokenStreamArtifact('/t/FOO.PART'), isTrue);
      expect(CacheCleanPlanner.isBrokenStreamArtifact('/t/foo.mp3'), isFalse);
      expect(CacheCleanPlanner.isBrokenStreamArtifact('/t/foo.flac'), isFalse);
    });

    test('stale cleanup removes broken artifacts of any age and old files', () {
      final now = DateTime.now();
      final entries = [
        entry('/t/fresh.part', 10, now), // broken → always removed
        entry('/t/old.bin', 20, now.subtract(const Duration(days: 3))),
        entry('/t/fresh.bin', 30, now.subtract(const Duration(hours: 1))),
      ];
      final plan = CacheCleanPlanner.planStaleCleanup(entries);
      expect(plan.map((e) => e.path).toSet(), {'/t/fresh.part', '/t/old.bin'});
    });
  });

  test('CacheAutoCleaner.totalBytes sums non-negative sizes', () {
    expect(CacheAutoCleaner.totalBytes(const []), 0);
    expect(
      CacheAutoCleaner.totalBytes([
        entry('/a', 100, DateTime(2026)),
        entry('/b', 50, DateTime(2026)),
        entry('/c', -10, DateTime(2026)),
      ]),
      150,
    );
  });
}
