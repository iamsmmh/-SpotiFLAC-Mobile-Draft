import 'dart:io';

import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';

/// Temporary-file suffix for every staged artifact in the pipeline.
const String kStagingTempSuffix = '.tmp';

/// Atomic file mechanics behind `file`-scheme storage: `.tmp` staging,
/// rename-based commit, best-effort rollback, and stale-temp sweeping.
///
/// Kept free of the domain ports so it is reusable by the SAF adapter (which
/// stages bytes locally before publishing to the granted tree).
class AtomicFileOps {
  const AtomicFileOps();

  /// Isolated staging target for [finalPath]. Same directory as the
  /// destination so the commit rename stays on one filesystem (rename across
  /// filesystems isn't atomic).
  String tempPathFor(String finalPath) => '$finalPath$kStagingTempSuffix';

  /// Promotes [tempPath] to [finalPath] atomically.
  ///
  /// POSIX rename replaces an existing destination in the same filesystem.
  /// On platforms/adapters where it refuses an existing destination (Windows
  /// style), the fallback removes the destination and retries once.
  Future<void> commitAtomic(String tempPath, String finalPath) async {
    final temp = File(tempPath);
    if (!await temp.exists()) {
      throw FileSystemException('Staged temp file is missing', tempPath);
    }
    final length = await temp.length();
    if (length <= 0) {
      throw const FileSystemException('Staged temp file is empty');
    }
    final parent = Directory(_parentPath(finalPath));
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    try {
      await temp.rename(finalPath);
    } on FileSystemException {
      final destination = File(finalPath);
      if (await destination.exists()) {
        await destination.delete();
      }
      await temp.rename(finalPath);
    }
  }

  /// Best-effort purge of a staged temp artifact. Idempotent, never throws.
  Future<void> rollback(String tempPath) async {
    try {
      final temp = File(tempPath);
      if (await temp.exists()) {
        await temp.delete();
      }
    } catch (_) {
      // Rollback must not mask the original failure.
    }
  }

  static String _parentPath(String path) {
    final slash = path.lastIndexOf('/');
    if (slash <= 0) return '.';
    return path.substring(0, slash);
  }
}

/// Deletes orphaned `*.tmp` artifacts (left behind by process kills) older
/// than [olderThan]. Returns the number of deleted files. Traversal errors
/// (permissions, vanished directories) are skipped, not reported: sweeping is
/// janitorial work that must never break the queue.
class TempFileJanitor {
  const TempFileJanitor();

  Future<int> purgeStaleTemps(
    Directory root, {
    required Duration olderThan,
    DateTime? now,
  }) async {
    final reference = now ?? DateTime.now();
    final cutoff = reference.subtract(olderThan);
    var removed = 0;
    if (!await root.exists()) return 0;
    await for (final entity in root.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      if (!entity.path.endsWith(kStagingTempSuffix)) continue;
      try {
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entity.delete();
          removed++;
        }
      } catch (_) {
        // Skip unreadable entries; the next sweep tries again.
      }
    }
    return removed;
  }
}

/// `file`-scheme [StorageRepository] over the app/container filesystem,
/// backed by [AtomicFileOps]. Also the storage used in unit tests and by
/// non-SAF download flows.
class LocalFileStorageRepository implements StorageRepository {
  LocalFileStorageRepository({required this.stagingRoot})
    : _ops = const AtomicFileOps(),
      _janitor = const TempFileJanitor();

  /// Directory root swept by [purgeStaleTempFiles] (typically the download
  /// output folder; staging happens in-place beside each destination).
  final String stagingRoot;

  final AtomicFileOps _ops;
  final TempFileJanitor _janitor;

  @override
  String get scheme => 'file';

  @override
  Future<StorageTarget> stage(String finalPath) async {
    final tempPath = _ops.tempPathFor(finalPath);
    final parent = Directory(AtomicFileOps._parentPath(finalPath));
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    // A leftover temp from a previous attempt must not contaminate this run.
    await _ops.rollback(tempPath);
    return StorageTarget(finalPath: finalPath, tempPath: tempPath);
  }

  @override
  Future<bool> exists(String path) => File(path).exists();

  @override
  Future<void> delete(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Idempotent delete contract.
    }
  }

  @override
  Future<void> commit(StorageTarget target) {
    return _ops.commitAtomic(target.tempPath, target.finalPath);
  }

  @override
  Future<void> rollback(StorageTarget target) {
    return _ops.rollback(target.tempPath);
  }

  @override
  Future<int> purgeStaleTempFiles({required Duration olderThan}) {
    return _janitor.purgeStaleTemps(
      Directory(stagingRoot),
      olderThan: olderThan,
    );
  }
}
