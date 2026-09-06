/// Smart cache manager (Phase 2) — orchestration.
///
/// Owns the two background responsibilities the playback path must never
/// block on:
///
///   * **Predictive queue warming** — [warmQueue] plans which of the upcoming
///     queue items to pre-cache ([SmartCachePolicy.warmPlan]) and starts
///     their fetches sequentially, highest priority first.
///   * **Maintenance** — [runMaintenance] expires TTL'd entries, evicts LRU
///     down to the configured budget, records the pass in the metadata
///     store, and returns a report for the settings surface.
///
/// Everything heavy is injected behind small ports, so orchestration is
/// unit-tested with in-memory fakes and the production adapter stays thin.
library;

import 'package:spotiflac_android/cache/cache_database.dart';
import 'package:spotiflac_android/cache/cache_policy.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SmartCacheManager');

/// One upcoming queue item the predictor may warm.
class WarmQueueCandidate {
  final String trackKey;
  final String url;
  final int priority;

  const WarmQueueCandidate({
    required this.trackKey,
    required this.url,
    this.priority = 0,
  });
}

/// Outcome of a warm-queue pass.
class WarmQueueReport {
  final List<String> started;
  final List<String> skipped;
  final List<String> failed;

  const WarmQueueReport({
    required this.started,
    required this.skipped,
    required this.failed,
  });

  bool get isEmpty => started.isEmpty && failed.isEmpty;
}

/// Outcome of a maintenance pass.
class CacheMaintenanceReport {
  final int expired;
  final int evicted;
  final int freedBytes;

  const CacheMaintenanceReport({
    required this.expired,
    required this.evicted,
    required this.freedBytes,
  });

  bool get isEmpty => expired == 0 && evicted == 0;
}

/// Executes the deletions a maintenance plan produced (adapter wires this to
/// the ecosystem repository + file deleter).
typedef CacheEvictionExecutor = Future<void> Function(
  Iterable<String> expiredKeys,
  Iterable<String> evictedKeys,
);

/// The manager.
class SmartCacheManager {
  SmartCacheManager({
    required StreamByteCache bytes,
    required SmartCachePolicy policy,
    required CacheMetadataStore metadata,
    DateTime Function()? clock,
  }) : _bytes = bytes,
       _policy = policy,
       _metadata = metadata,
       _clock = clock ?? () => DateTime.now().toUtc();

  final StreamByteCache _bytes;
  final SmartCachePolicy _policy;
  final CacheMetadataStore _metadata;
  final DateTime Function() _clock;

  SmartCachePolicy get policy => _policy;

  /// Guards concurrent maintenance runs (a timer and a manual trigger can
  /// race; the second call simply returns an empty report).
  bool _maintenanceRunning = false;

  /// Warms the upcoming queue.
  ///
  /// [cachedKeys] should contain every track key that already has a complete
  /// cached copy (the caller snapshots it from the cache index). Candidates
  /// are evaluated in queue order; the policy decides how many may run.
  Future<WarmQueueReport> warmQueue({
    required List<WarmQueueCandidate> candidates,
    required Set<String> cachedKeys,
    required CacheNetworkState network,
    int? estimatedBytesPerItem,
  }) async {
    final plan = _policy.warmPlan(
      candidates: <WarmCandidate>[
        for (final candidate in candidates)
          WarmCandidate(
            trackKey: candidate.trackKey,
            priority: candidate.priority,
            alreadyWarming: _bytes.isWarming(candidate.trackKey),
          ),
      ],
      cachedKeys: cachedKeys,
      network: network,
      currentBytes: await _bytes.totalBytes(),
      estimatedBytesPerItem: estimatedBytesPerItem,
    );

    final started = <String>[];
    final failed = <String>[];
    // Sequential on purpose: warm fetches share the link with playback.
    for (final trackKey in plan.warm) {
      final url = candidates
          .firstWhere(
            (candidate) => candidate.trackKey == trackKey,
          )
          .url;
      final ok = await _bytes.warm(trackKey, url);
      if (ok) {
        started.add(trackKey);
      } else {
        failed.add(trackKey);
      }
      await _metadata.upsertWarmRequest(
        WarmRequestRecord(
          trackKey: trackKey,
          url: url,
          priority: 0,
          requestedAt: _clock(),
          state: ok
              ? WarmRequestState.requested
              : WarmRequestState.failed,
        ),
      );
    }
    if (started.isNotEmpty || failed.isNotEmpty) {
      _log.i(
        'Predictive warm: ${started.length} started, ${failed.length} failed, '
        '${plan.skipped.length} skipped',
      );
    }
    return WarmQueueReport(
      started: started,
      skipped: plan.skipped,
      failed: failed,
    );
  }

  /// One maintenance pass: TTL expiration + LRU eviction to the budget.
  /// Returns an empty report when a pass is already running.
  Future<CacheMaintenanceReport> runMaintenance({
    required CacheEvictionExecutor execute,
    int? budgetBytes,
  }) async {
    if (_maintenanceRunning) {
      return const CacheMaintenanceReport(
        expired: 0,
        evicted: 0,
        freedBytes: 0,
      );
    }
    _maintenanceRunning = true;
    try {
      final entries = await _bytes.policyEntries();
      final currentBytes = entries.fold<int>(0, (sum, e) => sum + e.bytes);
      final plan = _policy.evictionPlan(
        entries,
        currentBytes: currentBytes,
        budgetBytes: budgetBytes ?? _policy.config.maxBytes,
        now: _clock(),
      );
      if (!plan.isEmpty) {
        await execute(plan.expireKeys, plan.evictKeys);
        _log.i(
          'Cache maintenance: ${plan.expireKeys.length} expired, '
          '${plan.evictKeys.length} evicted, '
          '${(plan.freedBytes / (1024 * 1024)).toStringAsFixed(1)} MB freed',
        );
      }
      await _metadata.recordMaintenance(
        CacheMaintenanceRecord(
          ranAt: _clock(),
          expired: plan.expireKeys.length,
          evicted: plan.evictKeys.length,
          freedBytes: plan.freedBytes,
        ),
      );
      return CacheMaintenanceReport(
        expired: plan.expireKeys.length,
        evicted: plan.evictKeys.length,
        freedBytes: plan.freedBytes,
      );
    } finally {
      _maintenanceRunning = false;
    }
  }

  /// Recent warm-up history (diagnostics surface).
  Future<List<WarmRequestRecord>> recentWarmRequests({int limit = 20}) =>
      _metadata.warmRequests(limit: limit);

  /// The last maintenance pass (diagnostics surface).
  Future<CacheMaintenanceRecord?> lastMaintenance() =>
      _metadata.lastMaintenance();
}
