/// Observability facade (Phase 17).
///
/// Wraps [CrashReporter] without adding a [CrashCategory] value (exhaustive
/// switches on the existing enum must keep compiling). Sync / cache events
/// are tagged `CrashCategory.app` plus a `surface` extra.
library;

import 'package:spotiflac_android/core/monitoring/crash_reporter.dart';
import 'package:spotiflac_android/services/observability/secret_redactor.dart';

/// Surfaces the reporter can tag without a new enum value.
enum ObservabilitySurface {
  app,
  playback,
  download,
  cache,
  sync,
  search,
  lan,
}

/// Thin wrapper: redacts, then forwards. No-ops when the reporter is disabled.
class ObservabilityService {
  ObservabilityService({
    CrashReporter? reporter,
    this.redactor = const SecretRedactor(),
  }) : _reporter = reporter ?? CrashReporter.instance;

  final CrashReporter _reporter;
  final SecretRedactor redactor;

  bool get isEnabled => _reporter.isEnabled;

  void breadcrumb(
    String message, {
    ObservabilitySurface surface = ObservabilitySurface.app,
    Map<String, Object?>? data,
  }) {
    _reporter.addBreadcrumb(
      message,
      category: CrashCategory.app,
      data: redactor.redactMap(<String, Object?>{
        'surface': surface.name,
        ...?data,
      }),
    );
  }

  Future<bool> captureError(
    Object error,
    StackTrace? stackTrace, {
    ObservabilitySurface surface = ObservabilitySurface.app,
    Map<String, Object?>? context,
  }) {
    return _reporter.captureError(
      error,
      stackTrace,
      category: CrashCategory.app,
      context: redactor.redactMap(<String, Object?>{
        'surface': surface.name,
        ...?context,
      }),
    );
  }

  Future<bool> captureMessage(
    String message, {
    ObservabilitySurface surface = ObservabilitySurface.app,
    Map<String, Object?>? context,
  }) {
    return _reporter.captureMessage(
      message,
      category: CrashCategory.app,
      context: redactor.redactMap(<String, Object?>{
        'surface': surface.name,
        ...?context,
      }),
    );
  }
}
