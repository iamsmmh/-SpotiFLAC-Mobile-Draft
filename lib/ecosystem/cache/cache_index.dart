/// In-memory index over the stream cache (Feature Group 7).
///
/// Keeps a hot, immutable-snapshot view of the cache for instant lookups
/// (playback starts, search integration) without hitting SQLite. Rebuilt
/// from [CacheRepository.all] after every mutation batch — the repository
/// stays the source of truth, the index is a projection, exactly like the
/// `LocalLibraryLookupIndex` pattern in the library store.
library;

import 'package:spotiflac_android/ecosystem/cache/cache_models.dart';

class CacheIndex {
  CacheIndex(Iterable<CacheEntry> entries)
    : _byTrackKey = <String, List<CacheEntry>>{},
      _byCacheKey = <String, CacheEntry>{} {
    for (final entry in entries) {
      _byCacheKey[entry.cacheKey] = entry;
      final list = _byTrackKey.putIfAbsent(
        entry.trackKey,
        () => <CacheEntry>[],
      );
      list.add(entry);
    }
    for (final list in _byTrackKey.values) {
      list.sort((a, b) => b.lastAccessedAt.compareTo(a.lastAccessedAt));
    }
  }

  final Map<String, List<CacheEntry>> _byTrackKey;
  final Map<String, CacheEntry> _byCacheKey;

  static CacheIndex empty() => CacheIndex(const <CacheEntry>[]);

  int get length => _byCacheKey.length;

  int get totalBytes {
    var total = 0;
    for (final entry in _byCacheKey.values) {
      total += entry.bytes;
    }
    return total;
  }

  CacheEntry? byCacheKey(String cacheKey) => _byCacheKey[cacheKey];

  /// Most-recently-accessed *complete* entry for a logical track.
  CacheEntry? playableForTrack(String trackKey) {
    final entries = _byTrackKey[trackKey];
    if (entries == null || entries.isEmpty) return null;
    for (final entry in entries) {
      if (entry.isPlayable) return entry;
    }
    return null;
  }

  List<CacheEntry> allForTrack(String trackKey) =>
      List<CacheEntry>.unmodifiable(_byTrackKey[trackKey] ?? const <CacheEntry>[]);

  List<CacheEntry> get all {
    final entries = _byCacheKey.values.toList(growable: false)
      ..sort((a, b) => b.lastAccessedAt.compareTo(a.lastAccessedAt));
    return List<CacheEntry>.unmodifiable(entries);
  }
}
