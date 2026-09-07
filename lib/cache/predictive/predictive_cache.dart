/// Smart Offline Cache — Predictive Prefetch (Milestone 7).
///
/// Extends the existing streaming cache with intelligent prefetching:
///
///   - **Predictive Cache**: Uses listening history to predict next tracks
///   - **Next Track Cache**: Prefetches the next queue item during playback
///   - **Playlist Cache**: Downloads entire playlists for offline listening
///   - **Recently Played Cache**: Keeps recent tracks available offline
///   - **Radio Cache**: Caches the current radio session's upcoming tracks
///
/// Cache database tables:
///   - cached_tracks: track metadata + storage path
///   - cache_access: LRU access timestamps
///   - cache_priority: prediction-based priority scores
///
/// Eviction strategy:
///   - LRU (Least Recently Used) as the baseline
///   - Priority weighting from prediction scores
///   - Storage limits enforced by background cleanup
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('PredictiveCache');

/// Priority levels for cache entries.
enum CachePriority {
  /// Will likely be played soon (next in queue, currently playing radio).
  high,

  /// Part of an active playlist or recently played.
  medium,

  /// Cached speculatively based on prediction.
  low,

  /// Not predicted to be needed — first to evict.
  background;

  int get weight {
    switch (this) {
      case CachePriority.high:
        return 4;
      case CachePriority.medium:
        return 3;
      case CachePriority.low:
        return 2;
      case CachePriority.background:
        return 1;
    }
  }
}

/// A cached track entry.
class CachedTrack {
  const CachedTrack({
    required this.trackId,
    required this.filePath,
    required this.sizeBytes,
    required this.cachedAt,
    this.lastAccessed,
    this.accessCount = 0,
    this.priority = CachePriority.medium,
    this.durationMs = 0,
    this.source = CacheSource.manual,
  });

  final String trackId;
  final String filePath;
  final int sizeBytes;
  final DateTime cachedAt;
  final DateTime? lastAccessed;
  final int accessCount;
  final CachePriority priority;
  final int durationMs;
  final CacheSource source;

  /// The effective eviction score: higher = keep longer.
  /// Combines LRU recency with priority and access frequency.
  int get evictionScore {
    final ageHours = DateTime.now().difference(cachedAt).inHours;
    final accessBonus = math.min(accessCount * 10, 100);
    final priorityBonus = priority.weight * 25;
    final recencyBonus = math.max(0, 168 - ageHours); // 7-day window
    return recencyBonus + priorityBonus + accessBonus;
  }
}

/// Where the cache entry came from.
enum CacheSource {
  manual,     // User explicitly downloaded
  predictive, // Predictive prefetch
  nextTrack,  // Next in queue
  playlist,   // Playlist prefetch
  radio,      // Radio session
  recent,     // Recently played
}

/// Configuration for the predictive cache.
class PredictiveCacheConfig {
  const PredictiveCacheConfig({
    this.maxStorageBytes = 2 * 1024 * 1024 * 1024, // 2 GB default
    this.maxTracks = 1000,
    this.predictiveEnabled = true,
    this.nextTrackPrefetch = true,
    this.playlistPrefetch = true,
    this.radioPrefetch = true,
    this.cleanupInterval = const Duration(hours: 6),
    this.minFreeSpaceBytes = 500 * 1024 * 1024, // 500 MB
  });

  final int maxStorageBytes;
  final int maxTracks;
  final bool predictiveEnabled;
  final bool nextTrackPrefetch;
  final bool playlistPrefetch;
  final bool radioPrefetch;
  final Duration cleanupInterval;
  final int minFreeSpaceBytes;
}

/// Prediction result: a track predicted to be played next.
class CachePrediction {
  const CachePrediction({
    required this.trackId,
    required this.confidence,
    required this.reason,
  });

  final String trackId;
  final double confidence;
  final String reason;
}

/// The predictive cache manager.
///
/// Coordinates between the prediction engine and the cache store:
///   1. Predicts which tracks the user will play next
///   2. Prefetches high-confidence predictions
///   3. Manages LRU eviction within storage limits
///   4. Handles background cleanup
class PredictiveCacheManager {
  PredictiveCacheManager({
    PredictiveCacheConfig config = const PredictiveCacheConfig(),
  }) : _config = config;

  final PredictiveCacheConfig _config;

  /// Current cache entries indexed by track ID.
  final Map<String, CachedTrack> _entries = {};

  /// Whether the manager is actively running.
  bool _running = false;
  Timer? _cleanupTimer;

  /// Current total cache size in bytes.
  int get totalSizeBytes =>
      _entries.values.fold<int>(0, (sum, e) => sum + e.sizeBytes);

  /// Number of cached tracks.
  int get trackCount => _entries.length;

  /// Whether a track is cached.
  bool isCached(String trackId) => _entries.containsKey(trackId);

  /// Gets a cached track entry.
  CachedTrack? getEntry(String trackId) => _entries[trackId];

  /// Records access to a cached track (LRU touch).
  void touch(String trackId) {
    final entry = _entries[trackId];
    if (entry == null) return;
    _entries[trackId] = CachedTrack(
      trackId: entry.trackId,
      filePath: entry.filePath,
      sizeBytes: entry.sizeBytes,
      cachedAt: entry.cachedAt,
      lastAccessed: DateTime.now(),
      accessCount: entry.accessCount + 1,
      priority: entry.priority,
      durationMs: entry.durationMs,
      source: entry.source,
    );
  }

  /// Adds a track to the cache.
  void addEntry(CachedTrack entry) {
    _entries[entry.trackId] = entry;
    _checkStorageLimits();
  }

  /// Removes a track from the cache.
  void removeEntry(String trackId) {
    _entries.remove(trackId);
  }

  /// Starts the background cleanup timer.
  void start() {
    if (_running) return;
    _running = true;
    _cleanupTimer = Timer.periodic(_config.cleanupInterval, (_) {
      _runCleanup();
    });
    _log.i('Predictive cache manager started');
  }

  /// Stops the manager.
  void stop() {
    _running = false;
    _cleanupTimer?.cancel();
    _cleanupTimer = null;
  }

  /// Generates predictions for the next tracks to cache.
  List<CachePrediction> predict({
    List<String>? queue,
    int currentIndex = 0,
    List<String>? recentlyPlayed,
    List<String>? favorites,
  }) {
    if (!_config.predictiveEnabled) return const [];
    final predictions = <CachePrediction>[];

    // 1. Next in queue (highest confidence).
    if (_config.nextTrackPrefetch && queue != null && queue.isNotEmpty) {
      for (var i = currentIndex + 1;
           i < math.min(currentIndex + 3, queue.length);
           i++) {
        predictions.add(CachePrediction(
          trackId: queue[i],
          confidence: 0.95 - (i - currentIndex - 1) * 0.1,
          reason: 'next_in_queue',
        ));
      }
    }

    // 2. Favorites not yet cached (medium confidence).
    if (favorites != null) {
      for (final trackId in favorites.take(5)) {
        if (!isCached(trackId)) {
          predictions.add(CachePrediction(
            trackId: trackId,
            confidence: 0.7,
            reason: 'favorite_track',
          ));
        }
      }
    }

    // 3. Recently played (low-medium confidence, for re-listen).
    if (recentlyPlayed != null) {
      for (final trackId in recentlyPlayed.take(3)) {
        if (!isCached(trackId)) {
          predictions.add(CachePrediction(
            trackId: trackId,
            confidence: 0.5,
            reason: 'recent_replay',
          ));
        }
      }
    }

    // Sort by confidence descending.
    predictions.sort((a, b) => b.confidence.compareTo(a.confidence));
    return predictions;
  }

  /// Runs the LRU eviction to stay within storage limits.
  void _runCleanup() {
    _checkStorageLimits();
    _log.d(
      'Cache cleanup: $trackCount tracks, '
      '${totalSizeBytes ~/ (1024 * 1024)} MB',
    );
  }

  void _checkStorageLimits() {
    while (_entries.length > _config.maxTracks ||
        totalSizeBytes > _config.maxStorageBytes) {
      // Evict the lowest-scoring entry.
      CachedTrack? victim;
      int lowestScore = double.maxFinite.toInt();
      for (final entry in _entries.values) {
        if (entry.source == CacheSource.manual) continue; // Never evict manual.
        if (entry.evictionScore < lowestScore) {
          lowestScore = entry.evictionScore;
          victim = entry;
        }
      }
      if (victim == null) break;
      _entries.remove(victim.trackId);
    }
  }
}
