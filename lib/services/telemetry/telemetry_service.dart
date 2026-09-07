/// Telemetry & Observability service (Milestone 11).
///
/// Provides structured telemetry from the mobile client:
///   - Crash reporting (via existing CrashReporter)
///   - Performance monitoring (startup, frame drops)
///   - Sync diagnostics (latency, conflicts)
///   - Streaming diagnostics (provider health, buffer underruns)
///   - Playback metrics (success rate, failures)
///
/// Metrics collected:
///   - Playback success rate
///   - Stream failures (per provider)
///   - Download failures
///   - Provider availability
///   - Sync latency
///
/// The service batches events and sends them to the backend telemetry
/// endpoint. It respects user privacy settings and never reports when
/// the user has opted out.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('Telemetry');

/// Event categories for telemetry.
enum TelemetryCategory {
  crash,
  performance,
  sync,
  streaming,
  playback,
  download,
  provider,
}

/// Severity levels for telemetry events.
enum TelemetrySeverity {
  debug,
  info,
  warning,
  error,
  fatal,
}

/// A single telemetry event.
class TelemetryEvent {
  const TelemetryEvent({
    required this.type,
    required this.category,
    required this.severity,
    required this.message,
    this.stacktrace,
    this.metadata = const {},
    this.durationMs,
    this.success,
    this.providerId,
    this.timestamp,
  });

  final String type;
  final TelemetryCategory category;
  final TelemetrySeverity severity;
  final String message;
  final String? stacktrace;
  final Map<String, String> metadata;
  final int? durationMs;
  final bool? success;
  final String? providerId;
  final DateTime? timestamp;

  Map<String, Object?> toJson(String deviceId) => <String, Object?>{
        'type': type,
        'category': category.name,
        'severity': severity.name,
        'message': message,
        if (stacktrace != null) 'stacktrace': stacktrace,
        if (metadata.isNotEmpty) 'metadata': metadata,
        if (durationMs != null) 'durationMs': durationMs,
        if (success != null) 'success': success,
        if (providerId != null) 'providerId': providerId,
        'deviceId': deviceId,
        'createdAt': (timestamp ?? DateTime.now()).toUtc().toIso8601String(),
      };
}

/// Aggregated metrics summary for the dashboard.
class TelemetryMetricsSummary {
  const TelemetryMetricsSummary({
    required this.playbackSuccessRate,
    required this.streamFailures,
    required this.downloadFailures,
    required this.providerAvailability,
    required this.syncLatencyMs,
    required this.crashCount,
    required this.activeUsers,
  });

  final double playbackSuccessRate;
  final int streamFailures;
  final int downloadFailures;
  final double providerAvailability;
  final int syncLatencyMs;
  final int crashCount;
  final int activeUsers;

  static TelemetryMetricsSummary? tryFromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    return TelemetryMetricsSummary(
      playbackSuccessRate: (raw['playbackSuccessRate'] as num?)?.toDouble() ?? 0,
      streamFailures: (raw['streamFailures'] as num?)?.toInt() ?? 0,
      downloadFailures: (raw['downloadFailures'] as num?)?.toInt() ?? 0,
      providerAvailability:
          (raw['providerAvailability'] as num?)?.toDouble() ?? 0,
      syncLatencyMs: (raw['syncLatencyMs'] as num?)?.toInt() ?? 0,
      crashCount: (raw['crashCount'] as num?)?.toInt() ?? 0,
      activeUsers: (raw['activeUsers'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Configuration for the telemetry service.
class TelemetryConfig {
  const TelemetryConfig({
    this.enabled = false,
    this.batchSize = 20,
    this.flushInterval = const Duration(minutes: 5),
    this.maxBatchSize = 100,
    this.maxRetryAttempts = 3,
  });

  final bool enabled;
  final int batchSize;
  final Duration flushInterval;
  final int maxBatchSize;
  final int maxRetryAttempts;
}

/// The telemetry service.
///
/// Batches events and periodically flushes them to the backend.
class TelemetryService {
  TelemetryService({
    required String baseUrl,
    required Future<String?> Function() accessToken,
    required Future<String> Function() deviceId,
    TelemetryConfig config = const TelemetryConfig(),
    http.Client? httpClient,
  })  : _baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        _accessToken = accessToken,
        _deviceId = deviceId,
        _config = config,
        _client = httpClient ?? http.Client();

  final String _baseUrl;
  final Future<String?> Function() _accessToken;
  final Future<String> Function() _deviceId;
  final TelemetryConfig _config;
  final http.Client _client;

  final List<TelemetryEvent> _buffer = [];
  Timer? _flushTimer;
  bool _started = false;

  /// Starts periodic flushing.
  void start() {
    if (_started || !_config.enabled) return;
    _started = true;
    _flushTimer = Timer.periodic(_config.flushInterval, (_) => flush());
    _log.i('Telemetry service started');
  }

  /// Stops the service and flushes remaining events.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _flushTimer?.cancel();
    _flushTimer = null;
    await flush();
  }

  /// Records a telemetry event.
  void record(TelemetryEvent event) {
    if (!_config.enabled) return;
    _buffer.add(event);
    if (_buffer.length >= _config.batchSize) {
      unawaited(flush());
    }
  }

  /// Records a playback success/failure.
  void recordPlayback({required bool success, String? providerId}) {
    record(TelemetryEvent(
      type: 'playback_result',
      category: TelemetryCategory.playback,
      severity: success ? TelemetrySeverity.info : TelemetrySeverity.warning,
      message: success ? 'Playback succeeded' : 'Playback failed',
      success: success,
      providerId: providerId,
    ));
  }

  /// Records a streaming failure.
  void recordStreamFailure({
    required String providerId,
    required String reason,
    int? durationMs,
  }) {
    record(TelemetryEvent(
      type: 'stream_failure',
      category: TelemetryCategory.streaming,
      severity: TelemetrySeverity.error,
      message: 'Stream failed: $reason',
      providerId: providerId,
      durationMs: durationMs,
      metadata: {'reason': reason},
    ));
  }

  /// Records a download failure.
  void recordDownloadFailure({
    required String reason,
    int? durationMs,
  }) {
    record(TelemetryEvent(
      type: 'download_failure',
      category: TelemetryCategory.download,
      severity: TelemetrySeverity.warning,
      message: 'Download failed: $reason',
      durationMs: durationMs,
      metadata: {'reason': reason},
    ));
  }

  /// Records sync latency.
  void recordSyncLatency(int latencyMs) {
    record(TelemetryEvent(
      type: 'sync_latency',
      category: TelemetryCategory.sync,
      severity: TelemetrySeverity.info,
      message: 'Sync completed in ${latencyMs}ms',
      durationMs: latencyMs,
    ));
  }

  /// Records provider availability check.
  void recordProviderHealth({
    required String providerId,
    required bool available,
    int? latencyMs,
  }) {
    record(TelemetryEvent(
      type: 'provider_health',
      category: TelemetryCategory.provider,
      severity: available ? TelemetrySeverity.info : TelemetrySeverity.warning,
      message: 'Provider $providerId: ${available ? "available" : "unavailable"}',
      providerId: providerId,
      success: available,
      durationMs: latencyMs,
    ));
  }

  /// Flushes buffered events to the backend.
  Future<void> flush() async {
    if (_buffer.isEmpty || !_config.enabled) return;
    final batch = List<TelemetryEvent>.from(_buffer);
    _buffer.clear();

    final token = await _accessToken();
    if (token == null || token.isEmpty) return;
    final deviceId = await _deviceId();

    try {
      final events = batch
          .map((e) => e.toJson(deviceId))
          .toList(growable: false);
      final response = await _client.post(
        Uri.parse('$_baseUrl/v1/telemetry/events'),
        headers: <String, String>{
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(<String, Object>{'events': events}),
      );
      if (response.statusCode == 200 || response.statusCode == 202) {
        _log.d('Flushed ${events.length} telemetry events');
      } else {
        _log.w('Telemetry flush failed: ${response.statusCode}');
        // Re-buffer on failure (up to max).
        if (_buffer.length + batch.length <= _config.maxBatchSize) {
          _buffer.insertAll(0, batch);
        }
      }
    } catch (error, stack) {
      _log.e('Telemetry flush error', error, stack);
      if (_buffer.length + batch.length <= _config.maxBatchSize) {
        _buffer.insertAll(0, batch);
      }
    }
  }
}
