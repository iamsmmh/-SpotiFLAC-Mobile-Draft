/// Standardized platform-channel contracts for file I/O across Android SAF
/// storage and the iOS document sandbox.
///
/// Stage 2 contract rule: method names, argument keys, and response shapes
/// for storage and download-lifecycle operations are defined ONCE here and
/// referenced by every data adapter — instead of string literals scattered
/// through providers. The Kotlin/Swift counterparts (MainActivity.kt /
/// AppDelegate.swift) consume the same spellings; tests lock both sides
/// together by asserting these builders against the native handler source.
library;

/// Method channel shared by the core backend bridge.
class CoreChannelNames {
  const CoreChannelNames._();

  static const String backend = 'com.zarz.spotiflac/backend';
  static const String downloadProgressEvents =
      'com.zarz.spotiflac/download_progress_stream';
}

/// Storage I/O methods (Android SAF + iOS sandbox), mirroring
/// MainActivity.kt / AppDelegate.swift handler names.
class StorageChannelMethods {
  const StorageChannelMethods._();

  // ----- Android SAF -----
  static const String pickSafTree = 'pickSafTree';
  static const String validateSafTree = 'isSafTreeAccessible';
  static const String safExists = 'safExists';
  static const String safDelete = 'safDelete';
  static const String safStat = 'safStat';
  static const String safCopyToTemp = 'safCopyToTemp';
  static const String safCreateFromPath = 'safCreateFromPath';

  // ----- iOS document sandbox (security-scoped bookmarks) -----
  static const String pickIosDirectory = 'pickIosDirectory';
  static const String createIosBookmark = 'createIosBookmarkFromPath';
  static const String startAccessingIosBookmark = 'startAccessingIosBookmark';
  static const String stopAccessingIosBookmark = 'stopAccessingIosBookmark';

  /// Methods handled natively on Android only (iOS uses the sandbox flow).
  static const List<String> androidSafOps = <String>[
    pickSafTree,
    validateSafTree,
    safExists,
    safDelete,
    safStat,
    safCopyToTemp,
    safCreateFromPath,
  ];

  static const List<String> iosSandboxOps = <String>[
    pickIosDirectory,
    createIosBookmark,
    startAccessingIosBookmark,
    stopAccessingIosBookmark,
  ];
}

/// Download lifecycle methods: transfer control + native worker offload.
class DownloadChannelMethods {
  const DownloadChannelMethods._();

  static const String cancelDownload = 'cancelDownload';
  static const String resetDownloadCancel = 'resetDownloadCancel';
  static const String clearItemProgress = 'clearItemProgress';
  static const String getAllDownloadProgress = 'getAllDownloadProgress';

  static const String startNativeDownloadWorker = 'startNativeDownloadWorker';
  static const String pauseNativeDownloadWorker = 'pauseNativeDownloadWorker';
  static const String resumeNativeDownloadWorker =
      'resumeNativeDownloadWorker';
  static const String cancelNativeDownloadWorker =
      'cancelNativeDownloadWorker';
  static const String getNativeDownloadWorkerSnapshot =
      'getNativeDownloadWorkerSnapshot';

  static const List<String> transferOps = <String>[
    cancelDownload,
    resetDownloadCancel,
    clearItemProgress,
    getAllDownloadProgress,
  ];

  static const List<String> workerLifecycleOps = <String>[
    startNativeDownloadWorker,
    pauseNativeDownloadWorker,
    resumeNativeDownloadWorker,
    cancelNativeDownloadWorker,
    getNativeDownloadWorkerSnapshot,
  ];
}

/// Typed request payload builders. Every key matches the native argument
/// reads exactly (e.g. `call.argument<String>("tree_uri")` in Kotlin).
class StorageChannelArgs {
  const StorageChannelArgs._();

  static const String uri = 'uri';
  static const String treeUri = 'tree_uri';
  static const String relativeDir = 'relative_dir';
  static const String fileName = 'file_name';
  static const String mimeType = 'mime_type';
  static const String srcPath = 'src_path';
  static const String path = 'path';
  static const String bookmark = 'bookmark';
  static const String token = 'token';

  static Map<String, Object?> safExists(String uri) => <String, Object?>{
    StorageChannelArgs.uri: uri,
  };

  static Map<String, Object?> safDelete(String uri) => safExists(uri);

  static Map<String, Object?> safStat(String uri) => safExists(uri);

  static Map<String, Object?> safCopyToTemp(String uri) => safExists(uri);

  static Map<String, Object?> validateSafTree(String treeUri) =>
      <String, Object?>{StorageChannelArgs.treeUri: treeUri};

  static Map<String, Object?> safCreateFromPath({
    required String treeUri,
    required String relativeDir,
    required String fileName,
    required String mimeType,
    required String srcPath,
  }) => <String, Object?>{
    StorageChannelArgs.treeUri: treeUri,
    StorageChannelArgs.relativeDir: relativeDir,
    StorageChannelArgs.fileName: fileName,
    StorageChannelArgs.mimeType: mimeType,
    StorageChannelArgs.srcPath: srcPath,
  };

  static Map<String, Object?> createIosBookmark(String path) =>
      <String, Object?>{StorageChannelArgs.path: path};

  static Map<String, Object?> startAccessingIosBookmark(String bookmark) =>
      <String, Object?>{StorageChannelArgs.bookmark: bookmark};

  static Map<String, Object?> stopAccessingIosBookmark(String token) =>
      <String, Object?>{StorageChannelArgs.token: token};
}

/// Download-channel argument builders (item id keyed, per legacy bridge).
class DownloadChannelArgs {
  const DownloadChannelArgs._();

  static const String itemId = 'item_id';

  static Map<String, Object?> cancelDownload(String id) =>
      <String, Object?>{itemId: id};

  static Map<String, Object?> resetDownloadCancel(String id) =>
      <String, Object?>{itemId: id};

  static Map<String, Object?> clearItemProgress(String id) =>
      <String, Object?>{itemId: id};
}

/// Decoded `safStat` response. The native side returns the stat as a JSON
/// *string* (see MainActivity.kt `"safStat"`), decoded once by the bridge
/// transport before reaching this parser.
class SafStatResult {
  const SafStatResult({
    required this.exists,
    required this.size,
    required this.modifiedMillis,
    required this.mimeType,
  });

  final bool exists;
  final int size;
  final int modifiedMillis;
  final String mimeType;

  static const String existsKey = 'exists';
  static const String sizeKey = 'size';
  static const String modifiedKey = 'modified';
  static const String mimeTypeKey = 'mime_type';

  /// Strict parse: wrong shapes throw [FormatException] so a contract drift
  /// on either side fails loudly in tests instead of corrupting queue state.
  factory SafStatResult.fromMap(Map<String, Object?> map) {
    final exists = map[existsKey];
    final size = map[sizeKey];
    final modified = map[modifiedKey];
    final mime = map[mimeTypeKey];
    if (exists is! bool || (mime != null && mime is! String)) {
      throw const FormatException('Invalid safStat payload shape');
    }
    return SafStatResult(
      exists: exists,
      size: size is num ? size.toInt() : 0,
      modifiedMillis: modified is num ? modified.toInt() : 0,
      mimeType: mime == null ? '' : mime as String,
    );
  }
}
