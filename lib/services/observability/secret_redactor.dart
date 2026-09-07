/// Secret redaction (Phase 17).
///
/// Mirrors the CrashReporter key filter so breadcrumbs / logs never leak
/// tokens, cookies or passwords. Pure and recursive.
library;

/// Redacts maps/lists before they enter a payload.
class SecretRedactor {
  const SecretRedactor();

  static final RegExp sensitiveKey = RegExp(
    r'(token|secret|password|passwd|authorization|auth|cookie|api[-_]?key|credential|session|pin|dsn)',
    caseSensitive: false,
  );

  Map<String, Object?> redactMap(Map<String, Object?> input) {
    final out = <String, Object?>{};
    input.forEach((key, value) {
      out[key] = sensitiveKey.hasMatch(key) ? '[redacted]' : redactValue(value);
    });
    return out;
  }

  Object? redactValue(Object? value) {
    if (value is Map<String, Object?>) {
      return redactMap(value);
    }
    if (value is Map<Object?, Object?>) {
      return redactMap(Map<String, Object?>.from(value));
    }
    if (value is List<Object?>) {
      return value.take(64).map(redactValue).toList(growable: false);
    }
    if (value is String) {
      return value.length > 4096
          ? '${value.substring(0, 4064)}…[truncated ${value.length} chars]'
          : value;
    }
    if (value is num || value is bool || value == null) {
      return value;
    }
    return value.toString();
  }
}
