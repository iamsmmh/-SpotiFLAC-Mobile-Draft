/// Smart stream cache policy (Phase 2) — pure decisions, zero I/O.
///
/// The brain of the stream-cache milestone: admission (should this stream be
/// captured at all?), expiration (TTL), eviction (LRU under a byte budget)
/// and predictive warming (which upcoming queue items to pre-cache). Every
/// plan is a pure function of immutable inputs, so the whole policy is
/// unit-testable headlessly and the storage layer stays dumb.
library;

/// Minimal view of one cache entry the policy reasons about. Adapters map
/// the ecosystem `CacheEntry` (and any future store) onto this.
class CachePolicyEntry {
  final String key;
  final int bytes;
  final DateTime lastAccessedAt;
  final bool complete;

  /// Pinned entries (explicitly kept, e.g. a user-pinned offline album)
  /// never evict.
  final bool pinned;

  const CachePolicyEntry({
    required this.key,
    required this.bytes,
    required this.lastAccessedAt,
    required this.complete,
    this.pinned = false,
  });
}

/// Network context for admission + warm decisions.
class CacheNetworkState {
  final bool online;
  final bool metered;

  const CacheNetworkState({required this.online, this.metered = false});

  static const CacheNetworkState offline = CacheNetworkState(online: false);
  static const CacheNetworkState wifi = CacheNetworkState(online: true);
  static const CacheNetworkState cellular = CacheNetworkState(
    online: true,
    metered: true,
  );
}

/// Outcome of an admission check.
class CacheAdmission {
  const CacheAdmission.allow(this.reason)
    : isAllowed = true;

  const CacheAdmission.deny(this.reason)
    : isAllowed = false;

  final String reason;

  final bool isAllowed;

  @override
  String toString() =>
      'CacheAdmission(${isAllowed ? 'allow' : 'deny'}: $reason)';
}

/// Immutable policy configuration (persisted by the settings layer).
class SmartCacheConfig {
  /// Hard budget for the smart stream cache. 0 = unlimited (policy then
  /// relies on the ecosystem cleanup worker's defaults).
  final int maxBytes;

  /// Entries older than this are expired on the next maintenance pass.
  final Duration ttl;

  /// One artifact larger than this is never admitted.
  final int maxArtifactBytes;

  /// Free space kept in reserve when evicting (never evict down to zero).
  final int evictionHeadroomBytes;

  /// How many upcoming queue items predictive warming considers.
  final int warmLookahead;

  /// Whether warming may run on metered connections.
  final bool allowMeteredWarm;

  /// Whether stream capture may run on metered connections.
  final bool allowMeteredCapture;

  const SmartCacheConfig({
    this.maxBytes = 512 * 1024 * 1024,
    this.ttl = const Duration(days: 30),
    this.maxArtifactBytes = 1024 * 1024 * 1024,
    this.evictionHeadroomBytes = 32 * 1024 * 1024,
    this.warmLookahead = 2,
    this.allowMeteredWarm = false,
    this.allowMeteredCapture = false,
  });

  SmartCacheConfig copyWith({
    int? maxBytes,
    Duration? ttl,
    int? warmLookahead,
    bool? allowMeteredWarm,
    bool? allowMeteredCapture,
  }) => SmartCacheConfig(
    maxBytes: maxBytes ?? this.maxBytes,
    ttl: ttl ?? this.ttl,
    maxArtifactBytes: maxArtifactBytes,
    evictionHeadroomBytes: evictionHeadroomBytes,
    warmLookahead: warmLookahead ?? this.warmLookahead,
    allowMeteredWarm: allowMeteredWarm ?? this.allowMeteredWarm,
    allowMeteredCapture: allowMeteredCapture ?? this.allowMeteredCapture,
  );
}

/// One planned warm-up.
class WarmCandidate {
  final String trackKey;

  /// Higher priority warms first (the immediate next track beats the one
  /// after).
  final int priority;

  /// Whether a fetch for this key is already running.
  final bool alreadyWarming;

  const WarmCandidate({
    required this.trackKey,
    this.priority = 0,
    this.alreadyWarming = false,
  });
}

/// Result of a warm plan.
class WarmPlan {
  final List<String> warm;
  final List<String> skipped;

  const WarmPlan({required this.warm, required this.skipped});

  bool get isEmpty => warm.isEmpty;
}

/// Maintenance outcome.
class CacheEvictionPlan {
  final List<String> evictKeys;
  final List<String> expireKeys;
  final int freedBytes;

  const CacheEvictionPlan({
    required this.evictKeys,
    required this.expireKeys,
    required this.freedBytes,
  });

  bool get isEmpty => evictKeys.isEmpty && expireKeys.isEmpty;
}

/// The policy. All methods are pure.
class SmartCachePolicy {
  const SmartCachePolicy({this.config = const SmartCacheConfig()});

  final SmartCacheConfig config;

  /// Admission decision for capturing one stream of [bytes] (null = unknown
  /// size, e.g. before the response headers arrive — admitted when the cache
  /// is enabled and the network allows capture).
  CacheAdmission admission({
    required bool captureEnabled,
    required CacheNetworkState network,
    required int currentBytes,
    int? bytes,
  }) {
    if (!captureEnabled) {
      return const CacheAdmission.deny('stream capture disabled');
    }
    if (!network.online) {
      return const CacheAdmission.deny('offline');
    }
    if (network.metered && !config.allowMeteredCapture) {
      return const CacheAdmission.deny('metered connection');
    }
    if (bytes != null) {
      if (bytes > config.maxArtifactBytes) {
        return const CacheAdmission.deny('artifact exceeds the size cap');
      }
      if (config.maxBytes > 0 && currentBytes + bytes > config.maxBytes) {
        return const CacheAdmission.deny('byte budget exhausted');
      }
    } else if (config.maxBytes > 0 && currentBytes >= config.maxBytes) {
      return const CacheAdmission.deny('byte budget exhausted');
    }
    return const CacheAdmission.allow('budget available');
  }

  /// Entries strictly older than the TTL.
  List<String> expiredKeys(
    List<CachePolicyEntry> entries,
    DateTime now,
  ) {
    final cutoff = now.subtract(config.ttl);
    return [
      for (final entry in entries)
        if (entry.lastAccessedAt.isBefore(cutoff)) entry.key,
    ];
  }

  /// LRU eviction: least-recently-accessed complete entries first, pinned
  /// entries immune, until the projected total lands at or under
  /// `budgetBytes - headroom`. A non-positive [budgetBytes] disables
  /// eviction (unlimited mode) — expiration still applies.
  CacheEvictionPlan evictionPlan(
    List<CachePolicyEntry> entries, {
    required int currentBytes,
    required int budgetBytes,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final expired = expiredKeys(entries, clock);
    if (budgetBytes <= 0 || currentBytes <= budgetBytes) {
      return CacheEvictionPlan(
        evictKeys: const <String>[],
        expireKeys: expired,
        freedBytes: 0,
      );
    }
    final floor = budgetBytes > config.evictionHeadroomBytes
        ? budgetBytes - config.evictionHeadroomBytes
        : 0;
    final evict = <String>[];
    var projected = currentBytes;
    final candidates = entries.where((entry) {
      if (entry.pinned || !entry.complete) return false;
      return !expired.contains(entry.key);
    }).toList()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));
    for (final entry in candidates) {
      if (projected <= floor) break;
      evict.add(entry.key);
      projected -= entry.bytes;
    }
    return CacheEvictionPlan(
      evictKeys: evict,
      expireKeys: expired,
      freedBytes: currentBytes - projected,
    );
  }

  /// Predictive warming: from [candidates] (ordered as the queue plays them,
  /// excluding the current item), pick at most [config.warmLookahead] that
  /// are neither cached nor already warming, respecting the network policy
  /// and the remaining byte budget.
  WarmPlan warmPlan({
    required List<WarmCandidate> candidates,
    required Set<String> cachedKeys,
    required CacheNetworkState network,
    required int currentBytes,
    int? estimatedBytesPerItem,
  }) {
    if (!network.online) {
      return const WarmPlan(warm: <String>[], skipped: <String>[]);
    }
    if (network.metered && !config.allowMeteredWarm) {
      return const WarmPlan(warm: <String>[], skipped: <String>[]);
    }
    final warm = <String>[];
    final skipped = <String>[];
    var projected = currentBytes;
    for (final candidate in candidates) {
      if (warm.length >= config.warmLookahead) {
        skipped.add(candidate.trackKey);
        continue;
      }
      if (cachedKeys.contains(candidate.trackKey) || candidate.alreadyWarming) {
        skipped.add(candidate.trackKey);
        continue;
      }
      if (config.maxBytes > 0 &&
          estimatedBytesPerItem != null &&
          projected + estimatedBytesPerItem > config.maxBytes) {
        skipped.add(candidate.trackKey);
        continue;
      }
      warm.add(candidate.trackKey);
      if (estimatedBytesPerItem != null) projected += estimatedBytesPerItem;
    }
    return WarmPlan(warm: warm, skipped: skipped);
  }
}
