/// Crash & failure monitoring (Phase 10) — dependency-free, wire-compatible
/// with the Sentry envelope store endpoint.
///
/// Design constraints that shaped this module:
///
///   * **Zero new package dependencies.** The app already ships `package:http`;
///     the Sentry envelope protocol (v7) is a documented, stable JSON-over-POST
///     contract, so a compact client avoids adding a full SDK (and its native
///     layers, build complexity and API-surface churn) to a mobile release.
///     Swapping in `sentry_flutter` later is a drop-in: the DSN, event
///     taxonomy (category tags, breadcrumbs, fingerprints) and redaction rules
///     here map 1:1 onto Sentry's model.
///   * **Disabled by default, opt-in by DSN.** No DSN configured → every entry
///     point is a no-op (no timers, no I/O, no battery). The DSN is *never*
///     hardcoded: it arrives via `--dart-define=SPOTIFLAC_SENTRY_DSN` or the
///     remote-config payload (Phase 11: no secrets in source).
///   * **Reporting must never break the app.** Every public method catches its
///     own failures; a reporter that throws while reporting would be its own
///     worst bug. Auth failures (401/403) auto-disable the client instead of
///     retrying forever; other 4xx responses drop the event; only
///     429/5xx/network errors retry, with bounded exponential backoff.
///   * **Bounded battery/CPU cost.** Breadcrumbs and the send queue are ring
///     buffers; events are rate-limited per sliding window; sends are
///     serialized; each attempt has a hard timeout.
///   * **Privacy.** Context maps are recursively redacted (token / secret /
///     password / authorization / cookie / api-key / credential keys) and
///     every string is length-capped before it can enter a payload.
///
/// Pure Dart on purpose (no `dart:io`, no Flutter imports): the module is
/// fully unit-testable and reusable from any layer.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// Severity for reported events.
enum CrashSeverity { debug, info, warning, error, fatal }

/// Failure taxonomy tags — the `category` dimension dashboards filter on.
enum CrashCategory {
  playback('playback'),
  streaming('streaming'),
  download('download'),
  provider('provider'),
  extension('extension'),
  library('library'),
  native('native'),
  ui('ui'),
  app('app');

  const CrashCategory(this.tag);
  final String tag;
}

/// One breadcrumb in the trail attached to the next reported event.
class CrashBreadcrumb {
  CrashBreadcrumb({
    required this.message,
    this.category = CrashCategory.app,
    this.level = CrashSeverity.info,
    Map<String, Object?> data = const <String, Object?>{},
    DateTime? at,
  }) : data = Map<String, Object?>.unmodifiable(data),
       at = at ?? DateTime.now();

  final String message;
  final CrashCategory category;
  final CrashSeverity level;
  final Map<String, Object?> data;
  final DateTime at;
}

/// Parsed Sentry DSN: `https://<publicKey>[:<secret>]@<host>[:<port>]/<projectId>`.
class CrashReportDsn {
  CrashReportDsn._({
    required this.publicKey,
    required this.host,
    required this.projectId,
    required this.envelopeUrl,
  });

  /// Throws [FormatException] for anything that is not a usable DSN; callers
  /// treat that as "crash reporting stays disabled".
  factory CrashReportDsn.parse(String raw) {
    final trimmed = raw.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      throw const FormatException(
        'DSN must be an absolute http(s) URL with a host',
      );
    }
    final publicKey = uri.userInfo.split(':').first;
    if (publicKey.isEmpty) {
      throw const FormatException('DSN has no public key');
    }
    final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segments.isEmpty) {
      throw const FormatException('DSN has no project id');
    }
    final projectId = segments.last;

    // Only append the port when it is not the scheme default.
    final defaultPort = uri.scheme == 'https' ? 443 : 80;
    final portSuffix = uri.port != defaultPort ? ':${uri.port}' : '';
    final envelopeUrl =
        '${uri.scheme}://${uri.host}$portSuffix/api/$projectId/envelope/';
    return CrashReportDsn._(
      publicKey: publicKey,
      host: uri.host,
      projectId: projectId,
      envelopeUrl: envelopeUrl,
    );
  }

  final String publicKey;
  final String host;
  final String projectId;
  final String envelopeUrl;
}

enum _SendOutcome { delivered, transient, retryExhausted, permanent, disabled }

class _PendingEvent {
  _PendingEvent({required this.eventId, required this.envelopeBody});

  final String eventId;
  final String envelopeBody;
}

/// Dependency-free crash reporter speaking the Sentry envelope protocol.
///
/// Obtain the app instance via [CrashReporter.instance]; tests construct their
/// own with injectable transport pieces. All public methods are safe to call
/// from any async context and never throw.
class CrashReporter {
  /// Shared app instance. Inert until [configure] is called with a DSN.
  static final CrashReporter instance = CrashReporter._();

  /// Redirects through the public constructor so the injected-transport
  /// fields are definitely assigned exactly once (defaults for the app).
  CrashReporter._() : this();

  CrashReporter({
    http.Client? httpClient,
    DateTime Function()? now,
    Future<void> Function(Duration)? delay,
    Random? random,
    int maxQueueLength = 30,
    int maxBreadcrumbs = 100,
    int rateLimitEvents = 20,
    Duration rateLimitWindow = const Duration(minutes: 10),
    Duration requestTimeout = const Duration(seconds: 10),
    int maxSendAttempts = 3,
  }) : _configuredClient = httpClient,
       _now = now ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed,
       _random = random ?? Random.secure(),
       _maxQueueLength = maxQueueLength,
       _maxBreadcrumbs = maxBreadcrumbs,
       _rateLimitEvents = rateLimitEvents,
       _rateLimitWindow = rateLimitWindow,
       _requestTimeout = requestTimeout,
       _maxSendAttempts = maxSendAttempts;

  // Injected transport pieces.
  http.Client? _configuredClient;
  http.Client? _lazyClient;
  final DateTime Function() _now;
  final Future<void> Function(Duration) _delay;
  final Random _random;

  // Bounds.
  final int _maxQueueLength;
  final int _maxBreadcrumbs;
  final int _rateLimitEvents;
  final Duration _rateLimitWindow;
  final Duration _requestTimeout;
  final int _maxSendAttempts;

  // Configuration (set by configure()).
  CrashReportDsn? _dsn;
  String _clientName = 'spotiflac-mobile';
  String? _release;
  String? _environment;

  // Live state.
  final List<CrashBreadcrumb> _breadcrumbs = <CrashBreadcrumb>[];
  final List<DateTime> _eventTimes = <DateTime>[];
  final Queue<_PendingEvent> _queue = Queue<_PendingEvent>();
  bool _draining = false;
  int _droppedByQueueLimit = 0;
  int _droppedByRateLimit = 0;
  int _droppedPermanent = 0;
  int _delivered = 0;
  String? _lastDeliveryError;

  http.Client get _client => _configuredClient ?? (_lazyClient ??= http.Client());

  /// Whether events are actually delivered. False until a DSN is configured.
  bool get isEnabled => _dsn != null;

  /// Last transport-level failure (diagnostics; never reported by itself).
  String? get lastDeliveryError => _lastDeliveryError;

  /// Counters for logs/diagnostics.
  Map<String, int> get stats => <String, int>{
    'delivered': _delivered,
    'queued': _queue.length,
    'dropped_queue_limit': _droppedByQueueLimit,
    'dropped_rate_limit': _droppedByRateLimit,
    'dropped_permanent': _droppedPermanent,
  };

  /// Configures delivery and returns the parsed DSN (for caller logging).
  /// Throws [FormatException] only for a malformed DSN; the bootstrap treats
  /// that as "stay disabled" and logs it.
  CrashReportDsn configure({
    required String dsn,
    String clientName = 'spotiflac-mobile',
    String? release,
    String? environment,
    http.Client? httpClient,
  }) {
    final parsed = CrashReportDsn.parse(dsn);
    _dsn = parsed;
    _clientName = clientName;
    _release = release;
    _environment = environment;
    if (httpClient != null) {
      _lazyClient?.close();
      _lazyClient = null;
      _configuredClient = httpClient;
    }
    return parsed;
  }

  /// Disables and clears everything (used on opt-out and in tests).
  void reset() {
    _dsn = null;
    _release = null;
    _environment = null;
    _lazyClient?.close();
    _lazyClient = null;
    _breadcrumbs.clear();
    _eventTimes.clear();
    _queue.clear();
    _draining = false;
    _droppedByQueueLimit = 0;
    _droppedByRateLimit = 0;
    _droppedPermanent = 0;
    _delivered = 0;
    _lastDeliveryError = null;
  }

  /// Adds a breadcrumb to the ring buffer. No-op when disabled.
  void addBreadcrumb(
    String message, {
    CrashCategory category = CrashCategory.app,
    CrashSeverity level = CrashSeverity.info,
    Map<String, Object?>? data,
  }) {
    if (_dsn == null) return;
    _breadcrumbs.add(
      CrashBreadcrumb(
        message: _truncate(message, 1024),
        category: category,
        level: level,
        data: _redactMap(data ?? const <String, Object?>{}),
      ),
    );
    while (_breadcrumbs.length > _maxBreadcrumbs) {
      _breadcrumbs.removeAt(0);
    }
  }

  /// Reports [error] with its [stackTrace]. Returns true when the event was
  /// accepted for delivery (rate limits may refuse it). Never throws.
  Future<bool> captureError(
    Object error,
    StackTrace? stackTrace, {
    CrashCategory category = CrashCategory.app,
    CrashSeverity severity = CrashSeverity.error,
    Map<String, Object?>? context,
    List<String>? fingerprint,
  }) {
    return _capture(
      category: category,
      severity: severity,
      context: context,
      fingerprint: fingerprint,
      buildEventBody: () => <String, Object?>{
        'exception': <String, Object?>{
          'values': <Object?>[
            <String, Object?>{
              'type': error.runtimeType.toString(),
              'value': _truncate(error.toString(), 8192),
              'stacktrace': _stacktraceFrames(stackTrace),
              'mechanism': <String, Object?>{
                'type': _clientName,
                'handled': false,
              },
            },
          ],
        },
      },
    );
  }

  /// Reports a plain message (no exception attached). Never throws.
  Future<bool> captureMessage(
    String message, {
    CrashCategory category = CrashCategory.app,
    CrashSeverity severity = CrashSeverity.warning,
    Map<String, Object?>? context,
    List<String>? fingerprint,
  }) {
    return _capture(
      category: category,
      severity: severity,
      context: context,
      fingerprint: fingerprint,
      buildEventBody: () => <String, Object?>{'message': _truncate(message, 8192)},
    );
  }

  Future<bool> _capture({
    required CrashCategory category,
    required CrashSeverity severity,
    required Map<String, Object?>? context,
    required List<String>? fingerprint,
    required Map<String, Object?> Function() buildEventBody,
  }) async {
    if (_dsn == null) return false;

    // Sliding-window rate limit protects the user's battery and data plan.
    final now = _now();
    _eventTimes.removeWhere((t) => now.difference(t) > _rateLimitWindow);
    if (_eventTimes.length >= _rateLimitEvents) {
      _droppedByRateLimit++;
      return false;
    }
    _eventTimes.add(now);

    final eventId = _randomEventId();
    final event = <String, Object?>{
      'event_id': eventId,
      'timestamp': now.toUtc().toIso8601String(),
      'platform': 'dart',
      'level': severity.name,
      'logger': category.tag,
      'tags': <String, String>{'category': category.tag},
      if (_release != null) 'release': _release,
      if (_environment != null) 'environment': _environment,
      if (fingerprint != null && fingerprint.isNotEmpty)
        'fingerprint': fingerprint.take(8).toList(growable: false),
      'breadcrumbs': <String, Object?>{
        'values': _breadcrumbs
            .map(
              (b) => <String, Object?>{
                'timestamp': b.at.toUtc().toIso8601String(),
                'message': b.message,
                'category': b.category.tag,
                'level': b.level.name,
                if (b.data.isNotEmpty) 'data': b.data,
              },
            )
            .toList(growable: false),
      },
      if (context != null && context.isNotEmpty) 'extra': _redactValue(context),
      ...buildEventBody(),
    };

    final envelope = <String>[
      jsonEncode(<String, String>{'event_id': eventId}),
      jsonEncode(<String, String>{
        'type': 'event',
        'content_type': 'application/json',
      }),
      jsonEncode(event),
    ].join('\n');

    // Bounded queue: a burst must not accumulate unbounded memory.
    while (_queue.length >= _maxQueueLength) {
      _queue.removeFirst();
      _droppedByQueueLimit++;
    }
    _queue.addLast(_PendingEvent(eventId: eventId, envelopeBody: envelope));
    unawaited(_drain());
    return true;
  }

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty && _dsn != null) {
        final job = _queue.first;
        final outcome = await _sendWithRetry(job);
        switch (outcome) {
          case _SendOutcome.delivered:
            _delivered++;
            // Remove *this* job, not "whatever is first now": the queue cap
            // may have dropped the original head while the send was in
            // flight, and removing the wrong entry would lose an event.
            _queue.remove(job);
          case _SendOutcome.disabled:
            // Repeated auth failures switched the client off; drop the
            // unsendable event and stop draining.
            _queue.remove(job);
            _droppedPermanent++;
            return;
          case _SendOutcome.retryExhausted:
          case _SendOutcome.permanent:
          case _SendOutcome.transient:
            // transient is unreachable here (retry is handled inside
            // _sendWithRetry), but the switch stays exhaustive by design.
            _queue.remove(job);
            _droppedPermanent++;
        }
      }
    } catch (e) {
      // The reporter must never raise into caller code. Drop whatever is
      // stuck; the app keeps working without crash reports.
      _lastDeliveryError = e.toString();
      _droppedPermanent += _queue.length;
      _queue.clear();
    } finally {
      _draining = false;
    }
  }

  /// Retries transient failures (429 / 5xx / network) with bounded backoff:
  /// 500 ms then 4 s. Anything else is terminal for the event.
  Future<_SendOutcome> _sendWithRetry(_PendingEvent job) async {
    for (var attempt = 1; attempt <= _maxSendAttempts; attempt++) {
      final result = await _sendOnce(job);
      if (result != _SendOutcome.transient) {
        return result;
      }
      if (attempt < _maxSendAttempts) {
        await _delay(Duration(milliseconds: attempt == 1 ? 500 : 4000));
      }
    }
    return _SendOutcome.retryExhausted;
  }

  Future<_SendOutcome> _sendOnce(_PendingEvent job) async {
    final dsn = _dsn;
    if (dsn == null) return _SendOutcome.disabled;
    try {
      final response = await _client
          .post(
            Uri.parse(dsn.envelopeUrl),
            headers: <String, String>{
              'Content-Type': 'application/x-sentry-envelope',
              'X-Sentry-Auth':
                  'Sentry sentry_version=7, '
                  'sentry_client=$_clientName/1.0, '
                  'sentry_key=${dsn.publicKey}',
            },
            body: job.envelopeBody,
          )
          .timeout(_requestTimeout);

      if (response.statusCode == 429 || response.statusCode >= 500) {
        return _SendOutcome.transient;
      }
      if (response.statusCode == 401 || response.statusCode == 403) {
        // Bad DSN or revoked key: retrying is pointless — disable globally.
        _dsn = null;
        return _SendOutcome.disabled;
      }
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return _SendOutcome.delivered;
      }
      // Other 4xx: the event itself is unacceptable (size/schema); drop it.
      return _SendOutcome.permanent;
    } catch (e) {
      _lastDeliveryError = e.toString();
      return _SendOutcome.transient;
    }
  }

  /// Best-effort wait for the queue to empty (bounded by [timeout]).
  Future<void> flush({Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = _now().add(timeout);
    while (_queue.isNotEmpty && _dsn != null) {
      if (!_now().isBefore(deadline)) return;
      await _delay(const Duration(milliseconds: 50));
    }
  }

  // ---------------------------------------------------------------- helpers

  String _randomEventId() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Map<String, Object?> _stacktraceFrames(StackTrace? stackTrace) {
    if (stackTrace == null) return <String, Object?>{'frames': <Object?>[]};
    final frames = <Object?>[];
    final framePattern = RegExp(
      r'^#\d+\s+(.+?)\s+\((.+?):(\d+)(?::(\d+))?\)?$',
    );
    for (final line in stackTrace.toString().split('\n')) {
      final match = framePattern.firstMatch(line.trim());
      if (match == null) continue;
      frames.add(<String, Object?>{
        'function': _truncate(match.group(1) ?? '?', 256),
        'filename': _truncate(match.group(2) ?? '?', 512),
        'lineno': int.tryParse(match.group(3) ?? '') ?? 0,
        if (match.group(4) != null) 'colno': int.tryParse(match.group(4)!),
      });
      if (frames.length >= 50) break;
    }
    return <String, Object?>{'frames': frames};
  }

  static final RegExp _sensitiveKey = RegExp(
    r'(token|secret|password|passwd|authorization|auth|cookie|api[-_]?key|credential|session)',
    caseSensitive: false,
  );

  Map<String, Object?> _redactMap(Map<String, Object?> input) {
    final out = <String, Object?>{};
    input.forEach((key, value) {
      out[key] = _sensitiveKey.hasMatch(key) ? '[redacted]' : _redactValue(value);
    });
    return out;
  }

  Object? _redactValue(Object? value) {
    if (value is Map) {
      return _redactMap(Map<String, Object?>.from(value));
    }
    if (value is List) {
      return value.take(64).map(_redactValue).toList(growable: false);
    }
    if (value is String) {
      return _truncate(value, 4096);
    }
    if (value is num || value is bool || value == null) {
      return value;
    }
    return _truncate(value.toString(), 4096);
  }

  static String _truncate(String input, int maxLength) {
    if (input.length <= maxLength) return input;
    final head = maxLength - 32;
    return '${input.substring(0, head < 0 ? 0 : head)}…'
        '[truncated ${input.length} chars]';
  }
}
