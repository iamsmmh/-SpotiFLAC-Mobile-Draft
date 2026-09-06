/// Cache cleanup planning + execution (Feature Group 7).
///
/// [CacheCleanupPlanner] is the pure decision core (LRU with pinned
/// protection and stale-partial sweeps) — unit-tested without I/O.
/// [CacheCleanupWorker] executes a plan against the repository and the
/// filesystem, mirroring `CacheCleanPlanner`/`CacheAutoCleaner` from the
/// cover cache.
library;

import 'package:spotimusic/ecosystem/cache/cache_models.dart';
import 'package:spotimusic/ecosystem/cache/cache_repository.dart';

/// Outcome of one cleanup run.
class CacheCleanupPlan {
  const CacheCleanupPlan({
    required this.evict,
    required this.sweepPartials,
    required this.projectedBytes,
  });

  /// Complete entries to evict, oldest-accessed first.
  final List<CacheEntry> evict;

  /// Incomplete entries whose fetch died (temp artifacts + rows).
  final List<CacheEntry> sweepPartials;

  /// Cache size after applying the plan.
  final int projectedBytes;

  int get freedBytes {
    var freed = 0;
    for (final entry in sweepPartials) {
      freed += entry.bytes;
    }
    for (final entry in evict) {
      freed += entry.bytes;
    }
    return freed;
  }
}

/// Pure planner: keeps the cache under [budgetBytes] with LRU eviction.
///
/// Policy:
///   1. always sweep incomplete fetches older than [stalePartialAge]
///      (their staged temp files cannot resume);
///   2. pinned entries are never evicted;
///   3. otherwise evict least-recently-accessed complete entries until the
///      projection fits the budget (nothing is evicted when already under).
class CacheCleanupPlanner {
  const CacheCleanupPlanner({
    this.budgetBytes = 2 * 1024 * 1024 * 1024,
    this.stalePartialAge = const Duration(hours: 12),
  });

  final int budgetBytes;
  final Duration stalePartialAge;

  CacheCleanupPlan plan(
    List<CacheEntry> entries, {
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final cutoff = at.subtract(stalePartialAge);

    final sweep = <CacheEntry>[];
    var projected = 0;
    final candidates = <CacheEntry>[];
    for (final entry in entries) {
      if (!entry.complete) {
        if (entry.createdAt.isBefore(cutoff)) {
          sweep.add(entry);
        } else {
          projected += entry.bytes;
        }
        continue;
      }
      projected += entry.bytes;
      if (!entry.pinned) candidates.add(entry);
    }

    candidates.sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));

    final evict = <CacheEntry>[];
    var index = 0;
    while (projected > budgetBytes && index < candidates.length) {
      final victim = candidates[index];
      evict.add(victim);
      projected -= victim.bytes;
      index += 1;
    }

    return CacheCleanupPlan(
      evict: evict,
      sweepPartials: sweep,
      projectedBytes: projected,
    );
  }
}

/// Deletes cache files. Abstracted so tests never touch a real disk.
typedef CacheFileDeleter = Future<void> Function(String fileName);

/// Executes plans: rows first (repository stays authoritative), then files
/// best-effort — a file that refuses deletion becomes an orphan swept by
/// the next run because the row is gone.
class CacheCleanupWorker {
  const CacheCleanupWorker({required this.repository, required this.deleter});

  final CacheRepository repository;
  final CacheFileDeleter deleter;

  Future<CacheCleanupPlan> run({CacheCleanupPlanner? planner}) async {
    final effective = planner ?? const CacheCleanupPlanner();
    final entries = await repository.all();
    final plan = effective.plan(entries);
    for (final entry in plan.evict) {
      await repository.delete(entry.cacheKey);
      await _deleteQuietly(entry.fileName);
    }
    for (final entry in plan.sweepPartials) {
      await repository.delete(entry.cacheKey);
      await _deleteQuietly(entry.fileName);
      await _deleteQuietly('${entry.fileName}.part');
    }
    return plan;
  }

  Future<void> _deleteQuietly(String fileName) async {
    if (fileName.isEmpty) return;
    try {
      await deleter(fileName);
    } catch (_) {
      // Filesystem cleanup is best-effort by design.
    }
  }
}
