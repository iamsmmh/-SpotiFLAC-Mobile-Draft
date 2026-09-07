/// Cached-track metadata repository (Phase 1).
///
/// The audio engine talks to this port, never to SQLite directly. Production
/// binds [MemoryCachedTrackRepository] at tests and a thin sqflite adapter
/// at runtime; both share the same contract so playback, eviction and resume
/// stay hermetic.
library;

import 'package:spotiflac_android/services/cache/cached_track.dart';

/// Persistence port for [CachedTrackRecord]s.
abstract interface class CachedTrackRepository {
  Future<CachedTrackRecord?> find({
    required String trackId,
    String? providerId,
  });

  /// Every complete, non-expired playable copy of [trackId], newest first.
  Future<List<CachedTrackRecord>> playableFor(String trackId, {DateTime? now});

  Future<void> upsert(CachedTrackRecord record);

  Future<void> touch(String trackId, String providerId, {DateTime? at});

  Future<void> delete(String trackId, String providerId);

  Future<List<CachedTrackRecord>> all({bool completeOnly = false});

  Future<int> totalBytes({bool completeOnly = false});

  Future<void> clear();
}

/// In-memory implementation used by unit tests and as the cold-start default
/// until the SQLite adapter is opened. Thread-hostile on purpose: the cache
/// manager serializes writes.
class MemoryCachedTrackRepository implements CachedTrackRepository {
  MemoryCachedTrackRepository({DateTime Function()? clock})
      : _clock = clock ?? DateTime.now;

  final DateTime Function() _clock;
  final Map<String, CachedTrackRecord> _rows = <String, CachedTrackRecord>{};

  static String _key(String trackId, String providerId) =>
      '$trackId|$providerId';

  @override
  Future<CachedTrackRecord?> find({
    required String trackId,
    String? providerId,
  }) async {
    if (providerId != null && providerId.isNotEmpty) {
      return _rows[_key(trackId, providerId)];
    }
    CachedTrackRecord? best;
    for (final record in _rows.values) {
      if (record.trackId != trackId) continue;
      if (best == null || record.lastPlayed.isAfter(best.lastPlayed)) {
        best = record;
      }
    }
    return best;
  }

  @override
  Future<List<CachedTrackRecord>> playableFor(
    String trackId, {
    DateTime? now,
  }) async {
    final stamp = now ?? _clock();
    final matches = <CachedTrackRecord>[
      for (final record in _rows.values)
        if (record.trackId == trackId &&
            record.isPlayable &&
            !record.isExpired(stamp))
          record,
    ]..sort((a, b) => b.lastPlayed.compareTo(a.lastPlayed));
    return List<CachedTrackRecord>.unmodifiable(matches);
  }

  @override
  Future<void> upsert(CachedTrackRecord record) async {
    _rows[record.cacheKey] = record;
  }

  @override
  Future<void> touch(
    String trackId,
    String providerId, {
    DateTime? at,
  }) async {
    final existing = _rows[_key(trackId, providerId)];
    if (existing == null) return;
    _rows[_key(trackId, providerId)] = existing.copyWith(
      lastPlayed: (at ?? _clock()).toUtc(),
    );
  }

  @override
  Future<void> delete(String trackId, String providerId) async {
    _rows.remove(_key(trackId, providerId));
  }

  @override
  Future<List<CachedTrackRecord>> all({bool completeOnly = false}) async {
    final values = _rows.values
        .where((record) => !completeOnly || record.complete)
        .toList(growable: false);
    return List<CachedTrackRecord>.unmodifiable(values);
  }

  @override
  Future<int> totalBytes({bool completeOnly = false}) async {
    var sum = 0;
    for (final record in _rows.values) {
      if (completeOnly && !record.complete) continue;
      sum += record.complete ? record.size : record.bytesWritten;
    }
    return sum;
  }

  @override
  Future<void> clear() async => _rows.clear();
}
