import 'package:flutter/services.dart';

import 'package:spotiflac_android/core/domain/core_errors.dart';

/// Strict payload decoding for the extension driver layer.
///
/// gomobile/JS-runtime payloads arrive as loosely typed maps; each driver
/// converts them to the typed shapes the engine and UI consume. A malformed
/// payload is a normalized [CoreErrorCategory.format] failure attributed to
/// the provider — never a raw [TypeError]/[CastError] escaping the driver.
class ExtensionPayloadDecoder {
  const ExtensionPayloadDecoder(this.data, {this.providerId});

  final Map<String, Object?> data;
  final String? providerId;

  CoreError _formatError(String key, String expectedType, Object? actual) {
    return CoreError(
      category: CoreErrorCategory.format,
      message:
          'Payload key "$key" expected $expectedType, got '
          '${actual.runtimeType}',
      providerId: providerId,
      retryable: false,
    );
  }

  /// Required string; fails on missing/empty/wrong-typed values.
  String requireString(String key) {
    final value = data[key];
    if (value is String && value.isNotEmpty) return value;
    throw _formatError(key, 'non-empty String', value);
  }

  /// Optional string (empty string normalized to null).
  String? optString(String key) {
    final value = data[key];
    if (value == null) return null;
    if (value is String) return value.isEmpty ? null : value;
    throw _formatError(key, 'String?', value);
  }

  /// Optional int, accepting JSON numbers and numeric strings.
  int? optInt(String key) {
    final value = data[key];
    if (value == null) return null;
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) return parsed;
      throw _formatError(key, 'int?', value);
    }
    throw _formatError(key, 'int?', value);
  }

  /// Optional bool, accepting `true/false` strings.
  bool? optBool(String key) {
    final value = data[key];
    if (value == null) return null;
    if (value is bool) return value;
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      if (normalized == 'true') return true;
      if (normalized == 'false') return false;
    }
    throw _formatError(key, 'bool?', value);
  }

  /// Optional nested map with string keys.
  Map<String, Object?>? optMap(String key) {
    final value = data[key];
    if (value == null) return null;
    if (value is Map) {
      return value.map(
        (Object? k, Object? v) => MapEntry(k?.toString() ?? '', v),
      );
    }
    throw _formatError(key, 'Map?', value);
  }

  /// Optional list of strings (skips non-string entries).
  List<String>? optStringList(String key) {
    final value = data[key];
    if (value == null) return null;
    if (value is List) {
      return value.whereType<String>().toList(growable: false);
    }
    throw _formatError(key, 'List?', value);
  }
}

/// Normalizes `PlatformException`-style channel failures into [CoreError].
///
/// Code mapping mirrors the native handlers in MainActivity.kt /
/// AppDelegate.swift: `permission*`/`saf*`/`EACCES` → permission,
/// `not_found`/`NOT_FOUND` → notFound, `cancel*` → cancelled, `unavailable`/
/// `timeout`/`network` → network (retryable). Unknown codes stay unknown.
CoreError normalizePlatformException(
  Object error, {
  String? providerId,
  String? contextMessage,
}) {
  if (error is CoreError) return error;
  if (error is PlatformException) {
    final code = error.code.toLowerCase();
    final Object? rawDetails = error.details;
    final detail =
        (error.message ?? (rawDetails == null ? '' : rawDetails.toString()))
            .toLowerCase();
    final haystack = '$code $detail';
    CoreErrorCategory category;
    if (haystack.contains('cancel')) {
      category = CoreErrorCategory.cancelled;
    } else if (haystack.contains('permission') ||
        haystack.contains('eacces') ||
        haystack.contains('saf_grant')) {
      category = CoreErrorCategory.permission;
    } else if (haystack.contains('not_found') || haystack.contains('404')) {
      category = CoreErrorCategory.notFound;
    } else if (haystack.contains('rate') || haystack.contains('429')) {
      category = CoreErrorCategory.rateLimited;
    } else if (haystack.contains('no space') || haystack.contains('enospc')) {
      category = CoreErrorCategory.storage;
    } else if (haystack.contains('unavailable') ||
        haystack.contains('timeout') ||
        haystack.contains('timed out') ||
        haystack.contains('network') ||
        haystack.contains('io_exception')) {
      category = CoreErrorCategory.network;
    } else {
      category = CoreErrorCategory.unknown;
    }
    return CoreError(
      category: category,
      message: contextMessage ?? error.message ?? 'Platform error (${error.code})',
      providerId: providerId,
      cause: error,
    );
  }
  return normalizeCoreError(
    error,
    providerId: providerId,
    fallbackMessage: contextMessage,
  );
}
