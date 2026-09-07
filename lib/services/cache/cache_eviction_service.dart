/// LRU eviction + background cleanup for the persistent stream cache (Phase 1).
///
/// Pure decisions over [CachedTrackRecord]s: pinned / incomplete entries are
/// protected, expired rows are swept first, then least-recently-played
/// complete copies until the budget fits. The manager applies the plan.
library;

import 'package:spotiflac_android/services/cache/cached_track.dart';

/// One planned deletion.
class CacheEvictionCandidate {
  const CacheEvictionCandidate({
    required this.record,
    required this.reason,
  });

  final CachedTrackRecord record;
  final String reason;
}

/// Outcome of one eviction pass.
class CacheEvictionPlan {
  const CacheEvictionPlan({
    required this.evict,
    required this.projectedBytes,
    required this.freedBytes,
  });

  final List<CacheEvictionCandidate> evict;
  final int projectedBytes;
  final int freedBytes;

  bool get isEmpty => evict.isEmpty;

  List<CachedTrackRecord> get records => <CachedTrackRecord>[
        for (final candidate in evict) candidate.record,
      ];
}

/// Builds LRU eviction plans under a [StreamCacheBudget].
class CacheEvictionService {
  const CacheEvictionService({
    this.headroomBytes = 64 * 1024 * 1024,
    this.stalePartialAge = const Duration(hours: 6),
  });

  /// Bytes kept free under the budget so a fetch in flight still fits.
  final int headroomBytes;

  /// Incomplete fetches older than this are swept as orphans.
  final Duration stalePartialAge;

  /// Keys that must never be evicted (user-pinned offline albums, etc.).
  CacheEvictionPlan plan({
    required List<CachedTrackRecord> entries,
    required StreamCacheBudget budget,
    DateTime? now,
    Set<String> pinnedKeys = const <String>{},
  }) {
    final stamp = now ?? DateTime.now().toUtc();
    final evict = <CacheEvictionCandidate>[];
    var projected = 0;
    for (final entry in entries) {
      projected += entry.complete ? entry.size : entry.bytesWritten;
    }

    // 1. Expired complete copies.
    for (final entry in entries) {
      if (!entry.complete) continue;
      if (pinnedKeys.contains(entry.cacheKey)) continue;
      if (entry.isExpired(stamp)) {
        evict.add(
          CacheEvictionCandidate(record: entry, reason: 'expired'),
        );
        projected -= entry.size;
      }
    }

    // 2. Stale partials (resume windows that never finished).
    final partialCutoff = stamp.subtract(stalePartialAge);
    for (final entry in entries) {
      if (entry.complete) continue;
      if (pinnedKeys.contains(entry.cacheKey)) continue;
      final created = entry.createdAt ?? entry.lastPlayed;
      if (created.isBefore(partialCutoff)) {
        evict.add(
          CacheEvictionCandidate(record: entry, reason: 'stale partial'),
        );
        projected -= entry.bytesWritten;
      }
    }

    // 3. LRU complete copies until the budget + headroom fits.
    final floor = budget.maxBytes > headroomBytes
        ? budget.maxBytes - headroomBytes
        : 0;
    if (projected > budget.maxBytes) {
      final already = <String>{
        for (final candidate in evict) candidate.record.cacheKey,
      };
      final lru = entries.where((entry) {
        if (!entry.complete) return false;
        if (pinnedKeys.contains(entry.cacheKey)) return false;
        return !already.contains(entry.cacheKey);
      }).toList()
        ..sort((a, b) => a.lastPlayed.compareTo(b.lastPlayed));
      for (final entry in lru) {
        if (projected <= floor) break;
        evict.add(
          CacheEvictionCandidate(record: entry, reason: 'lru'),
        );
        projected -= entry.size;
      }
    }

    var freed = 0;
    for (final candidate in evict) {
      final record = candidate.record;
      freed += record.complete ? record.size : record.bytesWritten;
    }
    return CacheEvictionPlan(
      evict: List<CacheEvictionCandidate>.unmodifiable(evict),
      projectedBytes: projected < 0 ? 0 : projected,
      freedBytes: freed,
    );
  }
}
