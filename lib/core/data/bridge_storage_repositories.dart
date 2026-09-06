import 'dart:async';
import 'dart:io';

import 'package:spotiflac_android/core/data/atomic_file_ops.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';

/// Android SAF [StorageRepository].
///
/// Transaction model: bytes download into a local `.tmp` staging file (inside
/// [stagingDir], an app-private folder); commit publishes the staged bytes
/// into the granted tree via `safCreateFromPath`, mirroring the native
/// `stageSafOutput` flow in `SafDownloadHandler.kt`. Rollback purges the
/// staged file and any partially created SAF document.
class SafStorageRepository implements StorageRepository {
  SafStorageRepository({
    required this.treeUri,
    required this.stagingDir,
    this.mimeTypeFor = _defaultMimeType,
  });

  /// Persisted SAF tree document URI the user granted access to.
  final String treeUri;

  /// App-private directory for `.tmp` staging files before publication.
  final String stagingDir;

  /// MIME type lookup for the final file name (defaults by extension).
  final String Function(String fileName) mimeTypeFor;

  final AtomicFileOps _ops = const AtomicFileOps();
  final TempFileJanitor _janitor = const TempFileJanitor();

  static String _defaultMimeType(String fileName) {
    final dot = fileName.lastIndexOf('.');
    final ext = dot >= 0 ? fileName.substring(dot + 1).toLowerCase() : '';
    return switch (ext) {
      'flac' => 'audio/flac',
      'mp3' => 'audio/mpeg',
      'm4a' || 'aac' => 'audio/mp4',
      'opus' => 'audio/opus',
      'ogg' => 'audio/ogg',
      'wav' => 'audio/wav',
      'lrc' => 'text/plain',
      _ => 'application/octet-stream',
    };
  }

  /// SAF final paths carry the relative directory + file name in one string
  /// form (`subdir/Artist - Title.flac`, no leading slash).
  static ({String relativeDir, String fileName}) splitSafFinalPath(
    String finalPath,
  ) {
    final normalized = finalPath.startsWith('/')
        ? finalPath.substring(1)
        : finalPath;
    final slash = normalized.lastIndexOf('/');
    if (slash < 0) return (relativeDir: '', fileName: normalized);
    return (
      relativeDir: normalized.substring(0, slash),
      fileName: normalized.substring(slash + 1),
    );
  }

  @override
  String get scheme => 'saf';

  @override
  Future<StorageTarget> stage(String finalPath) async {
    final dir = Directory(stagingDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final safeName = finalPath.replaceAll('/', '_');
    final tempPath = '$stagingDir/$safeName$kStagingTempSuffix';
    await _ops.rollback(tempPath);
    return StorageTarget(
      finalPath: finalPath,
      tempPath: tempPath,
      scheme: scheme,
    );
  }

  @override
  Future<bool> exists(String path) async {
    final segments = splitSafFinalPath(path);
    try {
      final resolved = await PlatformBridge.resolveSafFile(
        treeUri: treeUri,
        fileName: segments.fileName,
        relativeDir: segments.relativeDir,
      );
      final Object? uri = resolved['uri'];
      return uri != null && uri.toString().isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> delete(String path) async {
    final segments = splitSafFinalPath(path);
    try {
      final resolved = await PlatformBridge.resolveSafFile(
        treeUri: treeUri,
        fileName: segments.fileName,
        relativeDir: segments.relativeDir,
      );
      final Object? uri = resolved['uri'];
      if (uri != null && uri.toString().isNotEmpty) {
        await PlatformBridge.safDelete(uri.toString());
      }
    } catch (_) {
      // Idempotent delete contract.
    }
  }

  @override
  Future<void> commit(StorageTarget target) async {
    final segments = splitSafFinalPath(target.finalPath);
    final created = await PlatformBridge.createSafFileFromPath(
      treeUri: treeUri,
      relativeDir: segments.relativeDir,
      fileName: segments.fileName,
      mimeType: mimeTypeFor(segments.fileName),
      srcPath: target.tempPath,
    );
    if (created == null || created.isEmpty) {
      throw FileSystemException(
        'Failed to publish staged file to SAF destination',
        target.finalPath,
      );
    }
    // Publication succeeded: the staged temp is consumed.
    await _ops.rollback(target.tempPath);
  }

  @override
  Future<void> rollback(StorageTarget target) async {
    await _ops.rollback(target.tempPath);
  }

  @override
  Future<int> purgeStaleTempFiles({required Duration olderThan}) {
    return _janitor.purgeStaleTemps(
      Directory(stagingDir),
      olderThan: olderThan,
    );
  }
}

/// iOS document-sandbox [StorageRepository] guarded by security-scoped
/// bookmark leases.
///
/// Every operation that touches the user-picked directory runs inside
/// `startAccessingIosBookmark`/`stopAccessingIosBookmark`; staging + commit
/// are plain filesystem mechanics (AtomicFileOps) executed under the lease.
class IosSandboxStorageRepository implements StorageRepository {
  IosSandboxStorageRepository({
    required this.bookmark,
    required this.stagingRoot,
  });

  /// Base64 security-scoped bookmark granting access to the output folder.
  final String bookmark;

  /// Absolute output directory (resolved from the bookmark by settings).
  final String stagingRoot;

  final AtomicFileOps _ops = const AtomicFileOps();
  final TempFileJanitor _janitor = const TempFileJanitor();
  int _activeLeases = 0;
  IosSecurityScopedAccess? _lease;
  Future<void> _leaseAcquisition = Future<void>.value();

  /// Concurrent jobs share one native lease; acquisition itself is serialized
  /// so two parallel jobs cannot double-acquire the bookmark.
  Future<T> _withLease<T>(Future<T> Function() action) async {
    final previous = _leaseAcquisition;
    final completer = Completer<void>();
    _leaseAcquisition = completer.future;
    await previous;
    try {
      _lease ??= await PlatformBridge.startAccessingIosBookmark(bookmark);
    } finally {
      completer.complete();
    }
    _activeLeases++;
    try {
      return await action();
    } finally {
      _activeLeases--;
      final lease = _lease;
      if (_activeLeases <= 0 && lease != null) {
        _lease = null;
        _activeLeases = 0;
        await PlatformBridge.stopAccessingIosBookmark(lease);
      }
    }
  }

  @override
  String get scheme => 'bookmark';

  @override
  Future<StorageTarget> stage(String finalPath) {
    return _withLease(() async {
      final tempPath = _ops.tempPathFor(finalPath);
      await _ops.rollback(tempPath);
      return StorageTarget(
        finalPath: finalPath,
        tempPath: tempPath,
        scheme: scheme,
      );
    });
  }

  @override
  Future<bool> exists(String path) =>
      _withLease(() => File(path).exists());

  @override
  Future<void> delete(String path) {
    return _withLease(() async {
      try {
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException {
        // Idempotent delete contract.
      }
    });
  }

  @override
  Future<void> commit(StorageTarget target) {
    return _withLease(
      () => _ops.commitAtomic(target.tempPath, target.finalPath),
    );
  }

  @override
  Future<void> rollback(StorageTarget target) {
    return _withLease(() => _ops.rollback(target.tempPath));
  }

  @override
  Future<int> purgeStaleTempFiles({required Duration olderThan}) {
    return _withLease(
      () => _janitor.purgeStaleTemps(
        Directory(stagingRoot),
        olderThan: olderThan,
      ),
    );
  }
}
