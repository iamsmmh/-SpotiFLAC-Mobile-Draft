import 'dart:io';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('PathMatchKeys');

const _androidStoragePathAliases = <String>[
  '/storage/emulated/0',
  '/storage/emulated/legacy',
  '/storage/self/primary',
  '/sdcard',
  '/mnt/sdcard',
];

/// Audio file extensions that the app commonly produces or converts between.
/// Used to generate extension-stripped match keys so that a file converted from
/// one format to another (e.g. .flac → .opus) is still recognised as the same
/// track.
const _audioExtensions = <String>[
  '.flac',
  '.m4a',
  '.mp3',
  '.opus',
  '.ogg',
  '.wav',
  '.aiff',
  '.aif',
  '.aac',
];

const _maxPathMatchKeyCacheSize = 6000;
final Map<String, Set<String>> _pathMatchKeyCache = <String, Set<String>>{};

String? _stripAudioExtension(String path) {
  final lower = path.toLowerCase();
  for (final ext in _audioExtensions) {
    if (lower.endsWith(ext)) {
      return path.substring(0, path.length - ext.length);
    }
  }
  return null;
}

/// Path aliases that refer to the same physical file.
///
/// Unlike [buildPathMatchKeys], this deliberately keeps the audio extension.
/// A converted `.flac` and `.opus` can coexist on disk and must not be treated
/// as the same physical file by destructive operations.
Set<String> buildPhysicalPathMatchKeys(String? filePath) =>
    _buildPathMatchKeys(filePath, includeExtensionless: false);

Set<String> buildPathMatchKeys(String? filePath) =>
    _buildPathMatchKeys(filePath, includeExtensionless: true);

bool physicalFilePathsMatch(String? first, String? second) {
  final firstKeys = buildPhysicalPathMatchKeys(first);
  if (firstKeys.isEmpty) return false;
  return buildPhysicalPathMatchKeys(
    second,
  ).any((key) => firstKeys.contains(key));
}

bool isPhysicalFileRetained(
  String? candidatePath,
  Iterable<String?> retainedPaths,
) => retainedPaths.any(
  (retainedPath) => physicalFilePathsMatch(candidatePath, retainedPath),
);

Set<String> _buildPathMatchKeys(
  String? filePath, {
  required bool includeExtensionless,
}) {
  final raw = filePath?.trim() ?? '';
  if (raw.isEmpty) return const {};

  final cleaned = raw.startsWith('EXISTS:') ? raw.substring(7).trim() : raw;
  if (cleaned.isEmpty) return const {};
  final cacheKey =
      '${includeExtensionless ? 'track' : 'physical'}\u0000$cleaned';
  final cached = _pathMatchKeyCache.remove(cacheKey);
  if (cached != null) {
    _pathMatchKeyCache[cacheKey] = cached;
    return cached;
  }

  final keys = <String>{};
  final visited = <String>{};

  void addNormalized(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return;
    if (!visited.add(trimmed)) return;

    keys.add(trimmed);
    keys.add(trimmed.toLowerCase());

    if (trimmed.contains('\\')) {
      final slash = trimmed.replaceAll('\\', '/');
      if (slash != trimmed) {
        addNormalized(slash);
      }
    }

    if (trimmed.contains('%')) {
      try {
        final decoded = Uri.decodeFull(trimmed);
        if (decoded != trimmed) {
          addNormalized(decoded);
        }
      } catch (e) {
        _log.w('Ignoring undecodable percent-encoding in path key: $e');
      }
    }

    Uri? parsed;
    try {
      parsed = Uri.parse(trimmed);
    } catch (e) {
      _log.w('Ignoring unparsable URI while building path keys: $e');
    }

    if (parsed != null && parsed.hasScheme) {
      final withoutQueryOrFragment = parsed.replace(
        query: null,
        fragment: null,
      );
      final uriString = withoutQueryOrFragment.toString();
      keys.add(uriString);
      keys.add(uriString.toLowerCase());

      if (parsed.scheme == 'file') {
        try {
          addNormalized(parsed.toFilePath());
        } catch (e) {
          _log.w('Failed to convert file URI to a path key: $e');
        }
      }

      for (final alias in _androidExternalStorageDocumentPaths(parsed)) {
        addNormalized(alias);
      }
    } else if (trimmed.startsWith('/')) {
      try {
        final asFileUri = Uri.file(trimmed).toString();
        keys.add(asFileUri);
        keys.add(asFileUri.toLowerCase());
      } catch (e) {
        _log.w('Failed to build file URI from path key: $e');
      }
    }

    if (Platform.isAndroid) {
      for (final alias in _androidEquivalentPaths(trimmed)) {
        if (alias != trimmed) {
          addNormalized(alias);
        }
      }
    }
  }

  addNormalized(cleaned);

  if (includeExtensionless) {
    final extensionStrippedKeys = <String>{};
    for (final key in keys) {
      final stripped = _stripAudioExtension(key);
      if (stripped != null && stripped.isNotEmpty) {
        extensionStrippedKeys.add(stripped);
      }
    }
    keys.addAll(extensionStrippedKeys);
  }

  final result = Set<String>.unmodifiable(keys);
  _pathMatchKeyCache[cacheKey] = result;
  while (_pathMatchKeyCache.length > _maxPathMatchKeyCacheSize) {
    _pathMatchKeyCache.remove(_pathMatchKeyCache.keys.first);
  }
  return result;
}

Iterable<String> _androidExternalStorageDocumentPaths(Uri uri) {
  if (uri.scheme.toLowerCase() != 'content' ||
      uri.host.toLowerCase() != 'com.android.externalstorage.documents') {
    return const [];
  }

  final segments = uri.pathSegments;
  final documentIndex = segments.lastIndexOf('document');
  final treeIndex = segments.lastIndexOf('tree');
  final idIndex = documentIndex >= 0 ? documentIndex + 1 : treeIndex + 1;
  if (idIndex <= 0 || idIndex >= segments.length) return const [];

  var documentId = segments.sublist(idIndex).join('/');
  try {
    documentId = Uri.decodeComponent(documentId);
  } catch (e) {
    _log.w('Failed to decode path segment ($documentId): $e');
  }
  final separator = documentId.indexOf(':');
  if (separator < 0 ||
      documentId.substring(0, separator).toLowerCase() != 'primary') {
    return const [];
  }

  final relativePath = documentId
      .substring(separator + 1)
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'^/+'), '');
  final suffix = relativePath.isEmpty ? '' : '/$relativePath';
  return _androidStoragePathAliases.map((prefix) => '$prefix$suffix');
}

Iterable<String> _androidEquivalentPaths(String path) {
  final normalized = path.replaceAll('\\', '/');
  final lower = normalized.toLowerCase();
  String? suffix;

  for (final prefix in _androidStoragePathAliases) {
    if (lower == prefix) {
      suffix = '';
      break;
    }
    final withSlash = '$prefix/';
    if (lower.startsWith(withSlash)) {
      suffix = normalized.substring(prefix.length);
      break;
    }
  }

  if (suffix == null) return const [];
  return _androidStoragePathAliases.map((prefix) => '$prefix$suffix');
}
