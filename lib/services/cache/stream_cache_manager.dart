/// Persistent stream-cache manager (Phase 1).
///
/// Spotify-style streaming: bytes that have already been heard are reused
/// offline, integrity-checked on every hit, and a partial fetch can resume
/// from the last written offset. The existing ecosystem
/// `StreamingCacheManager` still owns the *in-flight capture* path; this
/// manager owns the *durable ledger* the playback ladder consults first.
///
/// Injected I/O (integrity + delete) keeps the unit tests hermetic.
library;

import 'package:spotiflac_android/core/data/sha256.dart';
import 'package:spotiflac_android/services/cache/cache_eviction_service.dart';
import 'package:spotiflac_android/services/cache/cached_track.dart';
import 'package:spotiflac_android/services/cache/cached_track_repository.dart';

/// Outcome of an integrity check.
enum CacheIntegrity { valid, missing, mismatch, partial }

/// Bytes the manager needs to resume a partial fetch.
class PartialCacheState {
  const PartialCacheState({
    required this.record,
    required this.resumeOffset,
  });

  final CachedTrackRecord record;

  /// Byte offset to send as `Range: bytes={offset}-`.
  final int resumeOffset;
}

/// File-system port so tests never touch disk.
abstract interface class StreamCacheIo {
  Future<bool> exists(String path);

  Future<List<int>?> readAll(String path);

  Future<void> delete(String path);
}

/// In-memory IO used by tests.
class MemoryStreamCacheIo implements StreamCacheIo {
  MemoryStreamCacheIo({Map<String, List<int>>? files})
      : files = files ?? <String, List<int>>{};

  final Map<String, List<int>> files;

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<List<int>?> readAll(String path) async {
    final bytes = files[path];
    return bytes == null ? null : List<int>.from(bytes);
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
  }
}

/// Durable stream cache: lookup, commit, resume, integrity, eviction.
class StreamCacheManager {
  StreamCacheManager({
    required CachedTrackRepository repository,
    required StreamCacheIo io,
    StreamCacheBudget? budget,
    CacheEvictionService eviction = const CacheEvictionService(),
    DateTime Function()? clock,
    Set<String>? pinnedKeys,
  })  : _repository = repository,
        _io = io,
        budget = budget ?? StreamCacheBudget.bytes(StreamCacheBudget.defaultBytes),
        _eviction = eviction,
        _clock = clock ?? DateTime.now,
        _pinnedKeys = pinnedKeys ?? <String>{};

  final CachedTrackRepository _repository;
  final StreamCacheIo _io;
  final CacheEvictionService _eviction;
  final DateTime Function() _clock;
  final Set<String> _pinnedKeys;

  /// Live budget (1 GiB–100 GiB). Mutating it does not evict until
  /// [runCleanup] runs.
  StreamCacheBudget budget;

  bool _cleanupRunning = false;

  /// Cache-first lookup used by the playback ladder. Touches [lastPlayed]
  /// on a hit so LRU stays honest. Returns null when nothing playable.
  Future<CachedTrackRecord?> lookupPlayable(String trackId) async {
    if (trackId.isEmpty) return null;
    final now = _clock().toUtc();
    final candidates = await _repository.playableFor(trackId, now: now);
    for (final record in candidates) {
      final integrity = await verify(record);
      if (integrity != CacheIntegrity.valid) {
        await _drop(record);
        continue;
      }
      await _repository.touch(
        record.trackId,
        record.providerId,
        at: now,
      );
      return record.copyWith(lastPlayed: now);
    }
    return null;
  }

  /// Commits a finished fetch. [bytes] are digested; a mismatch against
  /// [expectedChecksum] (when supplied) refuses the commit.
  Future<CachedTrackRecord?> commit({
    required String trackId,
    required String providerId,
    required String localPath,
    required List<int> bytes,
    String? expectedChecksum,
    String sourceUrl = '',
    DateTime? expiry,
  }) async {
    if (trackId.isEmpty || bytes.isEmpty) return null;
    final digest = sha256Hex(bytes);
    if (expectedChecksum != null &&
        expectedChecksum.isNotEmpty &&
        expectedChecksum != digest) {
      return null;
    }
    final now = _clock().toUtc();
    final record = CachedTrackRecord(
      trackId: trackId,
      providerId: providerId,
      localPath: localPath,
      checksum: digest,
      lastPlayed: now,
      size: bytes.length,
      expiry: expiry,
      complete: true,
      bytesWritten: bytes.length,
      sourceUrl: sourceUrl,
      createdAt: now,
    );
    await _repository.upsert(record);
    return record;
  }

  /// Records a partial fetch so a later session can resume it.
  Future<CachedTrackRecord> savePartial({
    required String trackId,
    required String providerId,
    required String localPath,
    required int bytesWritten,
    required String sourceUrl,
    int? totalSize,
  }) async {
    final now = _clock().toUtc();
    final record = CachedTrackRecord(
      trackId: trackId,
      providerId: providerId,
      localPath: localPath,
      checksum: '',
      lastPlayed: now,
      size: totalSize ?? 0,
      complete: false,
      bytesWritten: bytesWritten < 0 ? 0 : bytesWritten,
      sourceUrl: sourceUrl,
      createdAt: now,
    );
    await _repository.upsert(record);
    return record;
  }

  /// Resume state for a partial fetch of [trackId]/[providerId], or null.
  Future<PartialCacheState?> resumeState({
    required String trackId,
    required String providerId,
  }) async {
    final record = await _repository.find(
      trackId: trackId,
      providerId: providerId,
    );
    if (record == null || !record.isPartial) return null;
    if (!await _io.exists(record.localPath)) {
      await _repository.delete(trackId, providerId);
      return null;
    }
    return PartialCacheState(
      record: record,
      resumeOffset: record.bytesWritten,
    );
  }

  /// Re-reads the artifact and compares it to the stored checksum.
  Future<CacheIntegrity> verify(CachedTrackRecord record) async {
    if (!record.complete) return CacheIntegrity.partial;
    if (record.checksum.isEmpty) return CacheIntegrity.mismatch;
    if (!await _io.exists(record.localPath)) return CacheIntegrity.missing;
    final bytes = await _io.readAll(record.localPath);
    if (bytes == null || bytes.isEmpty) return CacheIntegrity.missing;
    final digest = sha256Hex(bytes);
    if (digest != record.checksum) return CacheIntegrity.mismatch;
    if (record.size > 0 && bytes.length != record.size) {
      return CacheIntegrity.mismatch;
    }
    return CacheIntegrity.valid;
  }

  /// Pins a track so LRU will not evict it.
  void pin(String cacheKey) => _pinnedKeys.add(cacheKey);

  void unpin(String cacheKey) => _pinnedKeys.remove(cacheKey);

  Set<String> get pinnedKeys => Set<String>.unmodifiable(_pinnedKeys);

  /// Background cleanup: expire + LRU down to [budget]. Idempotent under
  /// concurrent callers (the second call is a no-op).
  Future<CacheEvictionPlan> runCleanup() async {
    if (_cleanupRunning) {
      return const CacheEvictionPlan(
        evict: <CacheEvictionCandidate>[],
        projectedBytes: 0,
        freedBytes: 0,
      );
    }
    _cleanupRunning = true;
    try {
      final entries = await _repository.all();
      final plan = _eviction.plan(
        entries: entries,
        budget: budget,
        now: _clock().toUtc(),
        pinnedKeys: _pinnedKeys,
      );
      for (final candidate in plan.evict) {
        await _drop(candidate.record);
      }
      return plan;
    } finally {
      _cleanupRunning = false;
    }
  }

  Future<int> totalBytes() => _repository.totalBytes();

  Future<void> _drop(CachedTrackRecord record) async {
    await _io.delete(record.localPath);
    await _repository.delete(record.trackId, record.providerId);
  }
}
