import 'dart:io';
import 'dart:math' as math;

import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('CacheAutoCleaner');

/// A cache entry considered by the auto-cleaner.
class CacheEntry {
  final String path;

  /// Size in bytes.
  final int sizeBytes;

  /// Last-modified timestamp used for least-recently-used ordering.
  final DateTime lastModified;

  const CacheEntry({
    required this.path,
    required this.sizeBytes,
    required this.lastModified,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'size_bytes': sizeBytes,
    'last_modified_ms': lastModified.millisecondsSinceEpoch,
  };
}

/// Result of an auto-clean pass.
class CacheCleanResult {
  final int deletedFiles;
  final int freedBytes;

  const CacheCleanResult({required this.deletedFiles, required this.freedBytes});

  const CacheCleanResult.none() : deletedFiles = 0, freedBytes = 0;

  bool get didAnything => deletedFiles > 0 || freedBytes > 0;
}

/// File suffixes that mark an interrupted or stale streaming artifact.
///
/// A "broken stream" is a partially-written spool/temp file (or a stale
/// ephemeral download) left behind when a stream or metadata probe was
/// cancelled mid-flight. These are safe to remove because the audio itself is
/// never kept in these locations — downloaded music lives in the managed
/// download directory, never in the app cache or temp directory.
const Set<String> kBrokenStreamSuffixes = {
  '.part',
  '.partial',
  '.tmp',
  '.temp',
  '.spool',
  '.crdownload',
  '.download',
  '.opdownload',
};

/// Pure planning for the offline storage policy.
///
/// All threshold/LRU/broken-stream decisions live here so they can be unit
/// tested without touching the file system; [CacheAutoCleaner] adds the I/O.
class CacheCleanPlanner {
  CacheCleanPlanner._();

  /// Selects the least-recently-used files that must be deleted to bring
  /// [entries]' total size under [maxBytes]. Returns entries ordered
  /// oldest-first (the recommended deletion order).
  static List<CacheEntry> planPrune(
    List<CacheEntry> entries, {
    required int maxBytes,
  }) {
    if (maxBytes <= 0) return const [];
    var total = entries.fold<int>(0, (sum, e) => sum + math.max(0, e.sizeBytes));
    if (total <= maxBytes) return const [];

    final byOldest = [...entries]
      ..sort((a, b) => a.lastModified.compareTo(b.lastModified));

    final toDelete = <CacheEntry>[];
    for (final entry in byOldest) {
      if (total <= maxBytes) break;
      toDelete.add(entry);
      total -= math.max(0, entry.sizeBytes);
    }
    return toDelete;
  }

  /// Whether [path]'s base name looks like a broken/partial stream artifact.
  static bool isBrokenStreamArtifact(String path) {
    final lower = path.toLowerCase();
    return kBrokenStreamSuffixes.any(lower.endsWith);
  }

  /// Which entries are considered stale and removable regardless of the size
  /// threshold — broken-stream artifacts of any age, plus anything else older
  /// than [staleAfter] (default 24h).
  static List<CacheEntry> planStaleCleanup(
    List<CacheEntry> entries, {
    Duration staleAfter = const Duration(hours: 24),
  }) {
    final now = DateTime.now();
    return entries
        .where(
          (e) =>
              isBrokenStreamArtifact(e.path) ||
              now.difference(e.lastModified) > staleAfter,
        )
        .toList(growable: false);
  }
}

/// Applies the offline storage policies to the app's ephemeral cache and temp
/// directories: enforce a maximum cache size (LRU) and auto-remove broken
/// streams. Downloaded music is never touched.
class CacheAutoCleaner {
  const CacheAutoCleaner();

  /// Recursively lists [directory] as [CacheEntry]s, never following links.
  Future<List<CacheEntry>> listEntries(Directory directory) async {
    if (!await directory.exists()) return const [];
    final entries = <CacheEntry>[];
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          entries.add(
            CacheEntry(
              path: entity.path,
              sizeBytes: stat.size,
              lastModified: stat.modified,
            ),
          );
        } catch (_) {
          // File vanished mid-scan.
        }
      }
    } catch (e) {
      _log.w('Failed to list cache directory ${directory.path}: $e');
    }
    return entries;
  }

  /// Deletes the given files (chunked), returning how much was reclaimed.
  Future<CacheCleanResult> delete(List<CacheEntry> entries) async {
    if (entries.isEmpty) return const CacheCleanResult.none();
    var freed = 0;
    var deleted = 0;

    const chunkSize = 24;
    for (var i = 0; i < entries.length; i += chunkSize) {
      final end = math.min(i + chunkSize, entries.length);
      final chunk = entries.sublist(i, end);
      final results = await Future.wait(
        chunk.map((entry) async {
          try {
            final file = File(entry.path);
            if (await file.exists()) {
              await file.delete();
              return entry.sizeBytes;
            }
          } catch (e) {
            _log.d('best-effort step failed: $e');
          }
          return 0;
        }),
      );
      for (final bytes in results) {
        if (bytes > 0) {
          deleted++;
          freed += bytes;
        }
      }
    }
    return CacheCleanResult(deletedFiles: deleted, freedBytes: freed);
  }

  /// Total size of the entries.
  static int totalBytes(List<CacheEntry> entries) =>
      entries.fold<int>(0, (sum, e) => sum + math.max(0, e.sizeBytes));

  /// Enforces [maxBytes] across [directories], pruning LRU-first.
  ///
  /// Returns the combined cleanup result. Directories are treated as one
  /// logical pool so the threshold spans both the app cache and temp dir.
  Future<CacheCleanResult> enforceLimit(
    List<Directory> directories, {
    required int maxBytes,
  }) async {
    if (maxBytes <= 0) return const CacheCleanResult.none();

    final all = <CacheEntry>[];
    for (final dir in directories) {
      all.addAll(await listEntries(dir));
    }
    final toDelete = CacheCleanPlanner.planPrune(all, maxBytes: maxBytes);
    return delete(toDelete);
  }

  /// Removes broken-stream artifacts and stale ephemeral files from
  /// [directories].
  Future<CacheCleanResult> cleanBrokenStreams(
    List<Directory> directories, {
    Duration staleAfter = const Duration(hours: 24),
  }) async {
    final all = <CacheEntry>[];
    for (final dir in directories) {
      all.addAll(await listEntries(dir));
    }
    final toDelete = CacheCleanPlanner.planStaleCleanup(
      all,
      staleAfter: staleAfter,
    );
    return delete(toDelete);
  }

  /// Computes the current total cache footprint for the summary UI.
  Future<int> currentBytes(List<Directory> directories) async {
    var total = 0;
    for (final dir in directories) {
      total += totalBytes(await listEntries(dir));
    }
    return total;
  }
}
