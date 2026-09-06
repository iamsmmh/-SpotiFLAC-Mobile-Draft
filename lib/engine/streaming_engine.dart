library;
import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/utils/string_utils.dart';

/// The streaming engine: source discovery, ranking, health scoring, failover,
/// URL-expiration handling, retry/backoff, preflight validation, and
/// next-track preloading.
///
/// The engine is deliberately transport-agnostic. It produces
/// [StreamDescriptor]s and decides what to do next; the Riverpod layer
/// (streaming_engine_provider.dart) performs the actual HTTP/preflight work and
/// feeds playback into the existing audio_service player.

/// What a source is. [StreamSourceKind] drives both the ranking policy and the
/// terms-of-use checks — protected commercial streams are never promoted to
/// permanent downloads.
enum StreamSourceKind {
  /// A local or downloaded file (never re-downloaded; played directly).
  localFile,

  /// A direct progressive audio URL (e.g. provider preview URLs).
  httpStream,

  /// An authorized provider stream handed over by an extension adapter.
  extensionStream,

  /// A licensed/pre-authorized stream that requires credentials. Kept in the
  /// model so the UI can show "authorized" instead of silently downgrading.
  authorizedStream;
}

/// One candidate source for one logical track.
class StreamDescriptor {
  /// Sentinel used by [copyWith] to distinguish "not provided" from an
  /// explicit null (which clears the field).
  static const Object _unset = Object();

  final String id;
  final String providerId;
  final StreamSourceKind kind;
  final String uri;

  /// Resolved output quality of this source.
  final AudioQualityLevel quality;

  /// Measured/declared characteristics (codec, bitrate, ...).
  final AudioCharacteristics characteristics;

  /// Absolute expiry; null when the source does not expire.
  final DateTime? expiresAt;

  /// When this descriptor's URL was issued, used by the refresh policy.
  final DateTime? validFrom;

  /// Network latency observed during the last preflight (ms).
  final int? latencyMs;

  /// Whether the provider requires the user to have authorized it.
  final bool requiresAuthorization;

  /// Whether the provider's terms permit caching this stream for offline use.
  final bool cachePermitted;

  /// User-configured/provider priority (lower wins).
  final int priority;

  const StreamDescriptor({
    required this.id,
    required this.providerId,
    required this.kind,
    required this.uri,
    this.quality = AudioQualityLevel.auto,
    this.characteristics = const AudioCharacteristics(),
    this.expiresAt,
    this.validFrom,
    this.latencyMs,
    this.requiresAuthorization = false,
    this.cachePermitted = false,
    this.priority = 0,
  });

  bool get isLocal => kind == StreamSourceKind.localFile;

  bool get isRemote => kind != StreamSourceKind.localFile;

  bool get isExpired => _isExpired(DateTime.now());

  bool _isExpired(DateTime now) {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return !now.isBefore(expiry);
  }

  StreamDescriptor copyWith({
    String? uri,
    AudioQualityLevel? quality,
    AudioCharacteristics? characteristics,
    Object? expiresAt = _unset,
    Object? validFrom = _unset,
    Object? latencyMs = _unset,
    int? priority,
  }) => StreamDescriptor(
    id: id,
    providerId: providerId,
    kind: kind,
    uri: uri ?? this.uri,
    quality: quality ?? this.quality,
    characteristics: characteristics ?? this.characteristics,
    // Sentinel-based fields so nullable values can be explicitly cleared
    // (e.g. a refreshed URL must drop the previous expiry/validFrom/latency
    // instead of silently inheriting stale values).
    expiresAt: identical(expiresAt, _unset) ? this.expiresAt : expiresAt as DateTime?,
    validFrom: identical(validFrom, _unset) ? this.validFrom : validFrom as DateTime?,
    latencyMs: identical(latencyMs, _unset) ? this.latencyMs : latencyMs as int?,
    requiresAuthorization: requiresAuthorization,
    cachePermitted: cachePermitted,
    priority: priority ?? this.priority,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'provider': providerId,
    'kind': kind.name,
    'uri': uri,
    'quality': quality.name,
    'characteristics': characteristics.toJson(),
    if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
    if (validFrom != null) 'valid_from': validFrom!.toUtc().toIso8601String(),
    if (latencyMs != null) 'latency_ms': latencyMs,
    'requires_authorization': requiresAuthorization,
    'cache_permitted': cachePermitted,
    'priority': priority,
  };

  factory StreamDescriptor.fromJson(Map<String, dynamic> json) {
    final kind = StreamSourceKind.values.firstWhere(
      (value) => value.name == json['kind'],
      orElse: () => StreamSourceKind.httpStream,
    );
    return StreamDescriptor(
      id: json['id']?.toString() ?? json['uri']?.toString() ?? '',
      providerId: json['provider']?.toString() ?? 'unknown',
      kind: kind,
      uri: json['uri']?.toString() ?? '',
      quality: AudioQualityLevel.fromLabel(json['quality']),
      characteristics: json['characteristics'] is Map<String, dynamic>
          ? AudioCharacteristics.fromJson(
              json['characteristics'] as Map<String, dynamic>,
            )
          : const AudioCharacteristics(),
      expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
      validFrom: DateTime.tryParse(json['valid_from']?.toString() ?? ''),
      latencyMs: (json['latency_ms'] as num?)?.toInt(),
      requiresAuthorization: json['requires_authorization'] == true,
      cachePermitted: json['cache_permitted'] == true,
      priority: (json['priority'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Live health of one streaming provider, fed by preflight results and
/// playback outcomes.
class ProviderHealth {
  final String providerId;
  final String? version;
  final bool online;
  final int successCount;
  final int failureCount;
  final int consecutiveFailures;
  final int? lastLatencyMs;
  final DateTime? lastCheckedAt;
  final DateTime? lastFailedAt;
  final DateTime? backoffUntil;

  const ProviderHealth({
    required this.providerId,
    this.version,
    this.online = true,
    this.successCount = 0,
    this.failureCount = 0,
    this.consecutiveFailures = 0,
    this.lastLatencyMs,
    this.lastCheckedAt,
    this.lastFailedAt,
    this.backoffUntil,
  });

  factory ProviderHealth.initial(String providerId, {String? version}) =>
      ProviderHealth(providerId: providerId, version: version);

  double get successRate {
    final total = successCount + failureCount;
    if (total == 0) return 1.0;
    return successCount / total;
  }

  /// Whether the provider should currently be attempted at all.
  bool get isAvailable {
    if (!online) return false;
    final backoff = backoffUntil;
    if (backoff != null && DateTime.now().isBefore(backoff)) return false;
    return true;
  }

  /// Composite health in 0..1 used by source ranking.
  double get score {
    if (!online) return 0.0;
    if (DateTime.now().isBefore(backoffUntil ?? DateTime.fromMillisecondsSinceEpoch(0))) {
      return 0.0;
    }
    final reliability = successRate;
    final recency = _recencyScore(lastCheckedAt);
    // A provider that has never been measured is not penalized: like the
    // other no-data dimensions it scores neutral (1.0), so a fresh provider
    // ranks alongside perfectly-reliable ones until real measurements exist.
    final latency = lastLatencyMs == null
        ? 1.0
        : (1 - (lastLatencyMs! / 2000)).clamp(0.0, 1.0);
    return ((reliability * 0.55) + (recency * 0.20) + (latency * 0.25))
        .clamp(0.0, 1.0);
  }

  static double _recencyScore(DateTime? checkedAt) {
    if (checkedAt == null) return 1.0;
    final ageHours = DateTime.now().difference(checkedAt).inMinutes / 60;
    return (1 - (ageHours / 24)).clamp(0.0, 1.0);
  }

  ProviderHealth recordSuccess({int? latencyMs, String? version}) =>
      ProviderHealth(
        providerId: providerId,
        version: version ?? this.version,
        online: true,
        successCount: successCount + 1,
        failureCount: failureCount,
        consecutiveFailures: 0,
        lastLatencyMs: latencyMs ?? lastLatencyMs,
        lastCheckedAt: DateTime.now(),
        lastFailedAt: null,
        backoffUntil: null,
      );

  ProviderHealth recordFailure({int? latencyMs, String? version}) {
    const maxBackoff = Duration(minutes: 15);
    final failures = consecutiveFailures + 1;
    final backoffSeconds = math.min(maxBackoff.inSeconds, 2 << math.min(failures - 1, 8));
    return ProviderHealth(
      providerId: providerId,
      version: version ?? this.version,
      // Only permanently disable after 5 consecutive failures. `failures`
      // already includes this call, so the 5th failure is the one that
      // flips the provider offline (previously the pre-increment value was
      // compared, delaying the switch by one failure).
      online: failures < 5,
      successCount: successCount,
      failureCount: failureCount + 1,
      consecutiveFailures: failures,
      lastLatencyMs: latencyMs ?? lastLatencyMs,
      lastCheckedAt: DateTime.now(),
      lastFailedAt: DateTime.now(),
      backoffUntil: DateTime.now().add(Duration(seconds: backoffSeconds)),
    );
  }

  ProviderHealth markOffline({String? reason}) => recordFailure();

  /// A fresh, un-touched health row (used after a provider is re-enabled).
  ProviderHealth reset() => ProviderHealth.initial(providerId, version: version);

  Map<String, dynamic> toJson() => {
    'provider': providerId,
    if (version != null) 'version': version,
    'online': online,
    'success_count': successCount,
    'failure_count': failureCount,
    'consecutive_failures': consecutiveFailures,
    if (lastLatencyMs != null) 'last_latency_ms': lastLatencyMs,
    if (lastCheckedAt != null)
      'last_checked': lastCheckedAt!.toUtc().toIso8601String(),
    if (backoffUntil != null)
      'backoff_until': backoffUntil!.toUtc().toIso8601String(),
  };
}

/// Registry of provider health rows with bounded memory.
class ProviderHealthRegistry {
  final LinkedHashMap<String, ProviderHealth> _health = LinkedHashMap();
  static const int _maxEntries = 64;

  ProviderHealth healthOf(String providerId, {String? version}) =>
      _health[providerId] ?? ProviderHealth.initial(providerId, version: version);

  bool get hasAnyFailure =>
      _health.values.any((h) => h.failureCount > 0 || !h.isAvailable);

  void patch(String providerId, ProviderHealth health) {
    _health[providerId] = health;
    while (_health.length > _maxEntries) {
      _health.remove(_health.keys.first);
    }
  }

  void recordSuccess(String providerId, {int? latencyMs, String? version}) {
    patch(
      providerId,
      healthOf(providerId, version: version)
          .recordSuccess(latencyMs: latencyMs, version: version),
    );
  }

  void recordFailure(String providerId, {int? latencyMs, String? version}) {
    patch(
      providerId,
      healthOf(providerId, version: version)
          .recordFailure(latencyMs: latencyMs, version: version),
    );
  }

  void markOffline(String providerId, {String? version}) {
    patch(
      providerId,
      healthOf(providerId, version: version).markOffline(),
    );
  }

  void reset(String providerId, {String? version}) {
    patch(
      providerId,
      healthOf(providerId, version: version).reset(),
    );
  }

  List<ProviderHealth> snapshot() =>
      List.unmodifiable(_health.values.toList(growable: false));

  Map<String, dynamic> toJson() => {
    'providers': _health.values.map((h) => h.toJson()).toList(growable: false),
  };
}

/// Ranks candidate sources for one track.
///
/// Scoring weights (aligned with the "Source Intelligence Engine"):
///   45% provider health/reliability
///   25% quality fit for the requested profile
///   20% latency
///   10% user/provider priority
///
/// Expired, offline, backoff-pending and unauthorized-but-required sources are
/// filtered before scoring; they remain available as [retrySet] for a later
/// refresh pass, never as an immediate choice.
class StreamSourceResolver {
  final ProviderHealthRegistry health;

  const StreamSourceResolver({required this.health});

  static const double _weightsHealth = 0.45;
  static const double _weightsQuality = 0.25;
  static const double _weightsLatency = 0.20;
  static const double _weightsPriority = 0.10;

  List<StreamDescriptor> candidates(
    List<StreamDescriptor> sources, {
    AudioQualityLevel requested = AudioQualityLevel.auto,
    DateTime? now,
  }) {
    final effectiveNow = now ?? DateTime.now();
    final filtered = sources.where((source) {
      if (source.uri.trim().isEmpty) return false;
      if (source.kind == StreamSourceKind.authorizedStream &&
          source.requiresAuthorization) {
        // Authorization is checked by the adapter layer; if the descriptor
        // still requires it here, it is not usable right now.
        return false;
      }
      final providerHealth = health.healthOf(source.providerId);
      if (!providerHealth.isAvailable) return false;
      final expiry = source.expiresAt;
      if (expiry != null && !effectiveNow.isBefore(expiry)) return false;
      return true;
    }).toList(growable: false);

    return filtered..sort((a, b) => _compare(a, b, requested));
  }

  int _compare(StreamDescriptor a, StreamDescriptor b, AudioQualityLevel requested) {
    final scoreA = _score(a, requested);
    final scoreB = _score(b, requested);
    final byScore = scoreB.compareTo(scoreA);
    if (byScore != 0) return byScore;
    // Deterministic tiebreak on provider + id so ranking never flaps between
    // equal sources on successive calls.
    final byProvider = a.providerId.compareTo(b.providerId);
    if (byProvider != 0) return byProvider;
    return a.id.compareTo(b.id);
  }

  double _score(StreamDescriptor source, AudioQualityLevel requested) {
    final providerHealth = health.healthOf(source.providerId);
    final healthScore = providerHealth.score;

    final qualityScore = requested == AudioQualityLevel.auto
        ? _qualityFit(source.quality)
        : _qualityFitFor(source.quality, requested);

    final latencyScore = source.latencyMs == null
        ? 0.5
        : (1 - (source.latencyMs! / 3000)).clamp(0.0, 1.0);

    final priorityScore = (1 - (source.priority / 16)).clamp(0.0, 1.0);

    return (healthScore * _weightsHealth) +
        (qualityScore * _weightsQuality) +
        (latencyScore * _weightsLatency) +
        (priorityScore * _weightsPriority);
  }

  /// Neutral quality score when no explicit level was requested: lossless is
  /// always ranked first, unknown/auto last.
  static double _qualityFit(AudioQualityLevel quality) => switch (quality) {
    AudioQualityLevel.hires => 1.00,
    AudioQualityLevel.lossless => 0.92,
    AudioQualityLevel.high => 0.78,
    AudioQualityLevel.normal => 0.60,
    AudioQualityLevel.low => 0.40,
    AudioQualityLevel.auto => 0.20,
  };

  static double _qualityFitFor(AudioQualityLevel quality, AudioQualityLevel requested) {
    if (quality == requested) return 1.0;
    // Lossless satisfies any lower request; a lower source can never satisfy
    // a higher request.
    if (quality.rank >= requested.rank) {
      return 0.85 - ((quality.rank - requested.rank) * 0.08);
    }
    return 0.30 + (quality.rank * 0.06);
  }
}

/// Exponential backoff with full jitter (AWS-style), deterministic under an
/// injected [math.Random] so tests can assert the sequence.
class BackoffScheduler {
  final math.Random _random;
  final Duration base;
  final Duration max;
  final double jitter;

  const BackoffScheduler({
    this.base = const Duration(milliseconds: 750),
    this.max = const Duration(seconds: 30),
    this.jitter = 0.5,
    math.Random? random,
  }) : _random = random ?? const _SecureRandom();

  Duration next(int attempt) {
    final exponent = math.min(attempt, 8);
    final capMs = math.min(max.inMilliseconds, base.inMilliseconds * (1 << exponent));
    final low = (capMs * (1 - jitter)).round();
    final high = capMs;
    final span = math.max(1, high - low);
    final value = low + _random.nextInt(span + 1);
    // `clamp` on int returns num; stay in int space with explicit bounds.
    final bounded = math.max(1, math.min(value, max.inMilliseconds));
    return Duration(milliseconds: bounded);
  }
}

/// Stateless PRNG suitable for tests (system randomness is injected elsewhere
/// where a seeded sequence matters).
class _SecureRandom implements math.Random {
  const _SecureRandom();

  @override
  int nextInt(int max) => math.Random().nextInt(max);

  @override
  bool nextBool() => math.Random().nextBool();

  @override
  double nextDouble() => math.Random().nextDouble();
}

/// Failure taxonomy with retryability, so the UI can say "stream expired —
/// refreshing" vs "no source available for this track".
enum StreamFailureKind {
  timeout('Timed out', true),
  network('Network error', true),
  urlExpired('Stream URL expired', true),
  forbidden('Source not authorized', false),
  unsupported('Unsupported source', false),
  noSource('No source available', false),
  cancelled('Cancelled', false);

  const StreamFailureKind(this.label, this.retryable);

  final String label;
  final bool retryable;
}

class StreamFailure implements Exception {
  final StreamFailureKind kind;
  final int attempt;
  final String? message;
  final String providerId;

  const StreamFailure({
    required this.kind,
    required this.providerId,
    this.attempt = 1,
    this.message,
  });

  bool get retryable => kind.retryable;

  @override
  String toString() =>
      'StreamFailure(${kind.label}, provider=$providerId, attempt=$attempt'
      '${message == null ? '' : ', $message'})';
}

/// Validates a stream URL before playback. Implemented with `package:http` in
/// the provider layer; the pure engine only defines the contract + result.
abstract class StreamPreflightValidator {
  Future<StreamPreflightResult> validate(StreamDescriptor source);
}

class StreamPreflightResult {
  final bool ok;
  final int? latencyMs;
  final String? contentType;
  final int? contentLengthBytes;
  final String? error;
  final DateTime expiresAt;

  const StreamPreflightResult({
    required this.ok,
    this.latencyMs,
    this.contentType,
    this.contentLengthBytes,
    this.error,
    required this.expiresAt,
  });

  factory StreamPreflightResult.success({
    int? latencyMs,
    String? contentType,
    int? contentLengthBytes,
  }) => StreamPreflightResult(
    ok: true,
    latencyMs: latencyMs,
    contentType: contentType,
    contentLengthBytes: contentLengthBytes,
    expiresAt: DateTime.now().add(const Duration(minutes: 30)),
  );

  factory StreamPreflightResult.failure(String error) =>
      StreamPreflightResult(
        ok: false,
        error: error,
        expiresAt: DateTime.now(),
      );
}

/// One bandwidth observation used by adaptive quality / diagnostics.
///
/// Samples are derived from preflight metadata (content length + measured
/// latency) and from provider-reported transfer rates. The engine never
/// downloads a full stream to measure bandwidth — it keeps estimates bounded
/// and only for sources that already expose a content length.
class BandwidthSample {
  final DateTime at;
  final int? bytes;
  final int? latencyMs;
  final int? bytesPerSecond;
  final String providerId;

  const BandwidthSample({
    required this.at,
    this.bytes,
    this.latencyMs,
    this.bytesPerSecond,
    this.providerId = 'unknown',
  });

  /// Estimate from a preflight result: a single-byte probe gives us a useful
  /// latency reading, while content-length lets us estimate the effective
  /// throughput for the full asset.
  factory BandwidthSample.fromPreflight({
    required int? latencyMs,
    required int? contentLengthBytes,
    String providerId = 'unknown',
  }) {
    final bytes = contentLengthBytes;
    final latency = latencyMs;
    int? bps;
    if (bytes != null && bytes > 0 && latency != null && latency > 0) {
      bps = ((bytes / (latency / 1000)).round()).clamp(0, 1 << 40);
    }
    return BandwidthSample(
      at: DateTime.now(),
      bytes: bytes,
      latencyMs: latency,
      bytesPerSecond: bps,
      providerId: providerId,
    );
  }

  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    if (bytes != null) 'bytes': bytes,
    if (latencyMs != null) 'latency_ms': latencyMs,
    if (bytesPerSecond != null) 'bytes_per_second': bytesPerSecond,
    'provider': providerId,
  };
}

/// Rolling bandwidth monitor exposed through [StreamingDiagnostics].
///
/// Keeps the most recent samples (bounded) plus a smoothed estimate so the
/// Diagnostics Center and adaptive-quality logic can answer "how fast is the
/// current link without a full-file download?".
class BandwidthMonitor {
  final List<BandwidthSample> _samples = [];
  static const int _maxSamples = 12;

  List<BandwidthSample> get samples => List.unmodifiable(_samples.reversed);

  int? get latestBytesPerSecond =>
      _samples.isEmpty ? null : _samples.last.bytesPerSecond;

  /// Median of the last samples (robust against one noisy sample).
  int? get smoothedBytesPerSecond {
    final values = _samples
        .map((s) => s.bytesPerSecond)
        .whereType<int>()
        .where((v) => v > 0)
        .toList(growable: false);
    if (values.isEmpty) return null;
    values.sort();
    return values[values.length ~/ 2];
  }

  void record(BandwidthSample? sample) {
    if (sample == null) return;
    _samples.add(sample);
    if (_samples.length > _maxSamples) {
      _samples.removeAt(0);
    }
  }

  void recordPreflight({
    required int? latencyMs,
    required int? contentLengthBytes,
    String providerId = 'unknown',
  }) =>
      record(
        BandwidthSample.fromPreflight(
          latencyMs: latencyMs,
          contentLengthBytes: contentLengthBytes,
          providerId: providerId,
        ),
      );

  Map<String, dynamic> toJson() => {
    'samples': _samples.reversed.map((s) => s.toJson()).toList(growable: false),
  };
}

/// URL-expiration handling policy.
class StreamUrlRefreshPolicy {
  final Duration refreshLeadTime;
  final double ttlFraction;

  const StreamUrlRefreshPolicy({
    this.refreshLeadTime = const Duration(minutes: 5),
    this.ttlFraction = 0.2,
  });

  /// Whether [source]'s URL should be refreshed before the next play attempt.
  bool shouldRefresh(StreamDescriptor source, {DateTime? now}) {
    if (source.kind != StreamSourceKind.authorizedStream &&
        source.kind != StreamSourceKind.extensionStream) {
      return false;
    }
    final expiry = source.expiresAt;
    if (expiry == null) return false;
    final effectiveNow = now ?? DateTime.now();
    if (effectiveNow.isAfter(expiry.subtract(refreshLeadTime))) return true;
    // Refresh once the descriptor has lived past the ttl fraction of its
    // lifetime to keep URLs fresh for long queues.
    final validFrom = source.validFrom ?? DateTime.fromMillisecondsSinceEpoch(0);
    final ttl = expiry.difference(validFrom);
    if (ttl <= const Duration(seconds: 1)) return false;
    return effectiveNow.isAfter(validFrom.add(ttl * ttlFraction));
  }
}

/// Lifecycle of one stream attempt, observable by the diagnostics UI.
enum StreamPhase {
  idle,
  resolving,
  preflighting,
  streaming,
  refreshingUrl,
  fallingBack,
  waitingRetry,
  succeeded,
  failed,
  cancelled,
}

class StreamSessionState {
  final StreamPhase phase;
  final int attempt;
  final StreamDescriptor? active;
  final StreamFailure? lastFailure;
  final DateTime changedAt;
  final AudioQualityLevel quality;

  StreamSessionState({
    this.phase = StreamPhase.idle,
    this.attempt = 0,
    this.active,
    this.lastFailure,
    DateTime? changedAt,
    this.quality = AudioQualityLevel.auto,
  }) : changedAt = changedAt ?? DateTime.fromMillisecondsSinceEpoch(0);

  StreamSessionState copyWith({
    StreamPhase? phase,
    int? attempt,
    StreamDescriptor? active,
    StreamFailure? lastFailure,
    DateTime? changedAt,
    AudioQualityLevel? quality,
    bool clearFailure = false,
  }) => StreamSessionState(
    phase: phase ?? this.phase,
    attempt: attempt ?? this.attempt,
    active: active ?? this.active,
    lastFailure: clearFailure ? null : (lastFailure ?? this.lastFailure),
    changedAt: changedAt ?? DateTime.now(),
    quality: quality ?? this.quality,
  );

  Map<String, dynamic> toJson() => {
    'phase': phase.name,
    'attempt': attempt,
    if (active != null) 'active': active!.toJson(),
    if (lastFailure != null) 'last_failure': lastFailure!.toString(),
    'quality': quality.name,
    'changed_at': changedAt.toUtc().toIso8601String(),
  };
}

/// Bounded, ordered event log for the Diagnostics Center.
class EngineEventLog {
  final List<EngineEvent> _events = [];
  static const int _maxEvents = 64;

  List<EngineEvent> get events => List.unmodifiable(_events.reversed);

  void add(EngineEvent event) {
    _events.add(event);
    if (_events.length > _maxEvents) _events.removeAt(0);
  }

  void clear() => _events.clear();

  Map<String, dynamic> toJson() => {
    'events': _events.reversed.map((e) => e.toJson()).toList(growable: false),
  };
}

enum EngineEventSeverity { info, warning, error }

class EngineEvent {
  final DateTime at;
  final EngineEventSeverity severity;
  final String category;
  final String message;

  const EngineEvent({
    required this.at,
    required this.severity,
    required this.category,
    required this.message,
  });

  factory EngineEvent.info(String category, String message) => EngineEvent(
    at: DateTime.now(),
    severity: EngineEventSeverity.info,
    category: category,
    message: message,
  );

  factory EngineEvent.warning(String category, String message) => EngineEvent(
    at: DateTime.now(),
    severity: EngineEventSeverity.warning,
    category: category,
    message: message,
  );

  factory EngineEvent.error(String category, String message) => EngineEvent(
    at: DateTime.now(),
    severity: EngineEventSeverity.error,
    category: category,
    message: message,
  );

  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'severity': severity.name,
    'category': category,
    'message': message,
  };
}

/// One recorded stream attempt used by the Streaming Integrity screen.
///
/// Unlike the general [EngineEventLog] (a short diagnostic message stream),
/// integrity records are keyed and counted per source URL so the UI can answer
/// "why did this source fail?" without hunting through log text.
class StreamIntegrityRecord {
  final DateTime at;
  final String providerId;
  final String uri;
  final StreamIntegrityOutcome outcome;
  final String? category;
  final String message;

  const StreamIntegrityRecord({
    required this.at,
    required this.providerId,
    required this.uri,
    required this.outcome,
    this.category,
    required this.message,
  });

  factory StreamIntegrityRecord.success({
    required String providerId,
    required String uri,
    String? category,
    String message = '',
  }) => StreamIntegrityRecord(
    at: DateTime.now(),
    providerId: providerId,
    uri: uri,
    outcome: StreamIntegrityOutcome.success,
    category: category,
    message: message,
  );

  factory StreamIntegrityRecord.failure({
    required String providerId,
    required String uri,
    required String category,
    String message = '',
  }) => StreamIntegrityRecord(
    at: DateTime.now(),
    providerId: providerId,
    uri: uri,
    outcome: StreamIntegrityOutcome.failure,
    category: category,
    message: message,
  );

  factory StreamIntegrityRecord.fallback({
    required String providerId,
    required String uri,
    String? category,
    String message = '',
  }) => StreamIntegrityRecord(
    at: DateTime.now(),
    providerId: providerId,
    uri: uri,
    outcome: StreamIntegrityOutcome.fallback,
    category: category,
    message: message,
  );

  Map<String, dynamic> toJson() => {
    'at': at.toUtc().toIso8601String(),
    'provider': providerId,
    'uri': uri,
    'outcome': outcome.name,
    if (category != null) 'category': category,
    'message': message,
  };
}

enum StreamIntegrityOutcome { success, failure, fallback }

/// Bounded log of [StreamIntegrityRecord]s (newest first).
class StreamIntegrityLog {
  final List<StreamIntegrityRecord> _records = [];
  static const int _maxRecords = 128;

  List<StreamIntegrityRecord> get records => List.unmodifiable(_records.reversed);

  void add(StreamIntegrityRecord record) {
    _records.add(record);
    if (_records.length > _maxRecords) {
      _records.removeAt(0);
    }
  }

  int countOutcome(StreamIntegrityOutcome outcome) =>
      _records.where((r) => r.outcome == outcome).length;

  void clear() => _records.clear();

  Map<String, dynamic> toJson() => {
    'records': _records.reversed.map((r) => r.toJson()).toList(growable: false),
  };
}

/// A planned preload: which next track, which source, and its current state.
class PreloadJob {
  final String trackId;
  final StreamDescriptor source;
  PreloadJobState state;
  int attempt;

  PreloadJob({
    required this.trackId,
    required this.source,
    this.state = PreloadJobState.pending,
    this.attempt = 0,
  });

  Map<String, dynamic> toJson() => {
    'track_id': trackId,
    'source': source.toJson(),
    'state': state.name,
    'attempt': attempt,
  };
}

enum PreloadJobState { pending, preflighting, ready, failed, skipped }

/// Preloads the next N tracks' stream URLs so the next-track switch is instant.
///
/// Validation is a lightweight HEAD/GET-range check via the injected
/// [StreamPreflightValidator]; it never decodes audio. Jobs are keyed by track
/// id so repeated calls cannot duplicate work, and terminal jobs are pruned so
/// the registry stays bounded for long queues.
class StreamPreloader {
  final StreamPreflightValidator validator;
  final Map<String, PreloadJob> _jobs = {};
  final Map<String, bool> _ready = {};
  final EngineEventLog log;

  /// Upper bound on tracked jobs; the oldest terminal jobs are pruned beyond
  /// this so a long-lived queue cannot grow the registry without limit.
  static const int _maxJobs = 128;

  StreamPreloader({
    required this.validator,
    required this.log,
    StreamDescriptor Function(String trackId)? sourceResolver,
  }) : _sourceResolver = sourceResolver;

  final StreamDescriptor Function(String trackId)? _sourceResolver;

  PreloadJob? jobFor(String trackId) => _jobs[trackId];

  bool isReady(String trackId) => _ready[trackId] == true;

  /// Number of tracked jobs (diagnostics / tests). Bounded by [_maxJobs].
  int get jobCount => _jobs.length;

  /// Plans preloads for [trackIds] in queue order. [resolver] can be omitted
  /// when the controller registered a resolver at construction time.
  Future<void> plan(
    List<String> trackIds, {
    StreamDescriptor Function(String trackId)? resolver,
    int window = 2,
    Set<String>? skipIds,
  }) async {
    final resolve = resolver ?? _sourceResolver;
    if (resolve == null) return;
    _pruneTerminalJobs();
    for (final trackId in trackIds.take(window)) {
      if (skipIds?.contains(trackId) ?? false) continue;
      if (_jobs.containsKey(trackId)) continue;
      final source = resolve(trackId);
      if (source.kind == StreamSourceKind.localFile) continue;
      final job = PreloadJob(trackId: trackId, source: source);
      _jobs[trackId] = job;
      unawaited(_run(job));
    }
  }

  /// Drops jobs that reached a terminal state (ready/failed/skipped), keeping
  /// the registry bounded for arbitrarily long queues. Pending and in-flight
  /// jobs are preserved so a repeated plan call cannot duplicate work.
  void _pruneTerminalJobs() {
    if (_jobs.length <= _maxJobs) return;
    final terminal = _jobs.entries
        .where(
          (entry) =>
              entry.value.state == PreloadJobState.ready ||
              entry.value.state == PreloadJobState.failed ||
              entry.value.state == PreloadJobState.skipped,
        )
        .toList(growable: false);
    for (final entry in terminal) {
      if (_jobs.length <= _maxJobs) break;
      _jobs.remove(entry.key);
      _ready.remove(entry.key);
    }
    // Defensive bound: even if every job is in flight, never exceed the cap by
    // more than the window that can be pending at once.
    while (_jobs.length > _maxJobs + 8) {
      final oldest = _jobs.keys.first;
      _jobs.remove(oldest);
      _ready.remove(oldest);
    }
  }

  Future<void> _run(PreloadJob job) async {
    job.state = PreloadJobState.preflighting;
    try {
      final result = await validator.validate(job.source);
      if (!result.ok) {
        job.state = PreloadJobState.failed;
        log.add(
          EngineEvent.warning(
            'preload',
            'Preload failed for ${job.trackId}: ${result.error}',
          ),
        );
        return;
      }
      job.state = PreloadJobState.ready;
      _ready[job.trackId] = true;
      if (_ready.length > 32) {
        _ready.remove(_ready.keys.first);
      }
    } catch (e) {
      job.state = PreloadJobState.failed;
      log.add(
        EngineEvent.warning('preload', 'Preload error for ${job.trackId}: $e'),
      );
    }
  }

  void invalidate(String trackId) {
    _jobs[trackId]?.state = PreloadJobState.pending;
    _ready[trackId] = false;
  }

  void clear() {
    _jobs.clear();
    _ready.clear();
  }
}

/// Immutable snapshot handed to the Diagnostics Center.
class StreamingDiagnostics {
  final ProviderHealthRegistry health;
  final EngineEventLog log;
  final StreamSessionState session;
  final BandwidthMonitor bandwidth;
  final StreamIntegrityLog integrity;

  const StreamingDiagnostics({
    required this.health,
    required this.log,
    required this.session,
    required this.bandwidth,
    required this.integrity,
  });

  int get failures =>
      health.snapshot().fold(0, (sum, h) => sum + h.failureCount);

  int get successes =>
      health.snapshot().fold(0, (sum, h) => sum + h.successCount);

  int get integrityFailures =>
      integrity.countOutcome(StreamIntegrityOutcome.failure);

  int get integritySuccesses =>
      integrity.countOutcome(StreamIntegrityOutcome.success);

  /// Smoothed effective throughput estimate in bytes/sec, if available.
  int? get effectiveBandwidthBytesPerSecond => bandwidth.smoothedBytesPerSecond;

  /// Human-readable throughput label (e.g. "1.2 Mbps").
  String? get effectiveBandwidthLabel =>
      formatBandwidth(effectiveBandwidthBytesPerSecond);

  Map<String, dynamic> toJson() => {
    'health': health.toJson(),
    'events': log.toJson(),
    'session': session.toJson(),
    'bandwidth': bandwidth.toJson(),
    'integrity': integrity.toJson(),
  };

  /// Human-readable one-line summary for status chips.
  String get summaryLine {
    final providers = health.snapshot();
    if (providers.isEmpty) return 'No streaming providers registered';
    final online = providers.where((h) => h.isAvailable).length;
    final base =
        '$online/${providers.length} providers available · '
        '$successes ok · $failures failed';
    final bw = effectiveBandwidthLabel;
    final integrityText = integrityFailures == 0
        ? ''
        : ' · $integrityFailures integrity failures';
    return bw == null ? '$base$integrityText' : '$base · ~$bw$integrityText';
  }
}

/// Formats a bytes/sec rate into a compact human label.
String formatBandwidth(int? bytesPerSecond) {
  if (bytesPerSecond == null || bytesPerSecond <= 0) return '';
  final kbps = bytesPerSecond * 8 / 1000; // network bits, decimal units
  if (kbps >= 1000) return '${(kbps / 1000).toStringAsFixed(1)} Mbps';
  if (kbps >= 1) return '${kbps.round()} kbps';
  return '${bytesPerSecond.round()} B/s';
}

/// The engine session controller: owns the state machine for one playback
/// attempt and the policy knobs. Pure Dart (no platform channels), so all
/// failure/backoff behavior is unit-testable.
class StreamingSessionController {
  final StreamSourceResolver resolver;
  final BackoffScheduler backoff;
  final StreamUrlRefreshPolicy refreshPolicy;
  final EngineEventLog log;
  final ProviderHealthRegistry health;

  StreamSessionState _state = StreamSessionState();

  StreamingSessionController({
    required this.resolver,
    required this.health,
    required this.log,
    BackoffScheduler? backoff,
    StreamUrlRefreshPolicy? refreshPolicy,
  }) : backoff = backoff ?? const BackoffScheduler(),
       refreshPolicy = refreshPolicy ?? const StreamUrlRefreshPolicy();

  StreamSessionState get state => _state;

  void _transition(StreamSessionState next) {
    _state = next;
  }

  /// Resolves [sources] to the best usable source, skipping a known-bad
  /// provider, and returns the attempt index that was started.
  StreamResolutionOutcome resolve(
    List<StreamDescriptor> sources, {
    AudioQualityLevel requested = AudioQualityLevel.auto,
    DateTime? now,
  }) {
    final candidates = resolver.candidates(sources, requested: requested, now: now);
    if (candidates.isEmpty) {
      final failure = StreamFailure(
        kind: StreamFailureKind.noSource,
        providerId: sources.isEmpty ? 'none' : sources.first.providerId,
        message: 'no candidates remained after health/expiry filtering',
      );
      _transition(
        _state.copyWith(phase: StreamPhase.failed, lastFailure: failure, clearFailure: false),
      );
      log.add(EngineEvent.error('stream', failure.toString()));
      return StreamResolutionOutcome(
        resolved: null,
        alternatives: const [],
        failure: failure,
      );
    }

    final selected = candidates.first;
    final shouldRefresh = refreshPolicy.shouldRefresh(selected, now: now);
    if (shouldRefresh) {
      // The caller is expected to refresh the source URL and resolve again
      // (see [StreamResolutionOutcome.needsUrlRefresh]); stay in the
      // refreshingUrl phase until a refreshed source is handed back.
      _transition(
        _state.copyWith(
          phase: StreamPhase.refreshingUrl,
          active: selected,
          quality: selected.quality,
        ),
      );
      log.add(
        EngineEvent.info(
          'stream',
          '${selected.providerId} URL needs refresh '
          '(expires ${selected.expiresAt?.toIso8601String() ?? 'unknown'})',
        ),
      );
      return StreamResolutionOutcome(
        resolved: selected,
        alternatives: candidates.skip(1).toList(growable: false),
        needsUrlRefresh: true,
      );
    }
    _transition(
      _state.copyWith(
        phase: StreamPhase.preflighting,
        active: selected,
        quality: selected.quality,
      ),
    );
    return StreamResolutionOutcome(
      resolved: selected,
      alternatives: candidates.skip(1).toList(growable: false),
    );
  }

  /// Moves a [StreamPhase.refreshingUrl] session back to preflighting when the
  /// caller decides to proceed with the current source (e.g. URL refresh is
  /// disabled, or re-resolving produced no fresher candidate). No-op for any
  /// other phase.
  void proceedWithoutRefresh(StreamDescriptor source) {
    if (_state.phase != StreamPhase.refreshingUrl) return;
    _transition(
      _state.copyWith(
        phase: StreamPhase.preflighting,
        active: source,
        quality: source.quality,
      ),
    );
  }

  /// Records a failed playback/preflight attempt and returns the next
  /// candidate (or null when the chain is exhausted).
  StreamDescriptor? onFailure(
    StreamFailure failure,
    StreamDescriptor failedSource,
    List<StreamDescriptor> alternatives,
  ) {
    health.recordFailure(
      failedSource.providerId,
      latencyMs: failedSource.latencyMs,
    );
    log.add(EngineEvent.error('stream', failure.toString()));

    final next = alternatives
        .where((source) => health.healthOf(source.providerId).isAvailable)
        .where((source) => !source.isExpired)
        .toList(growable: false);

    if (next.isEmpty) {
      _transition(
        _state.copyWith(phase: StreamPhase.failed, lastFailure: failure),
      );
      return null;
    }

    _transition(
      _state.copyWith(
        phase: StreamPhase.fallingBack,
        attempt: _state.attempt + 1,
        active: next.first,
        lastFailure: failure,
      ),
    );
    log.add(
      EngineEvent.info(
        'stream',
        'Falling back to ${next.first.providerId} '
        'for ${next.first.uri == failedSource.uri ? 'same source' : 'alternate source'}',
      ),
    );
    return next.first;
  }

  /// Returns the delay before retrying the *same* source, or null when the
  /// retry budget is exhausted.
  Duration? retryDelay(StreamFailure failure, int maxAttempts) {
    if (!failure.retryable) return null;
    if (_state.attempt + 1 >= maxAttempts) return null;
    final delay = backoff.next(_state.attempt + 1);
    _transition(
      _state.copyWith(
        phase: StreamPhase.waitingRetry,
        attempt: _state.attempt + 1,
        lastFailure: failure,
      ),
    );
    return delay;
  }

  void markSuccess(StreamDescriptor source, {int? latencyMs}) {
    health.recordSuccess(source.providerId, latencyMs: latencyMs);
    _transition(
      _state.copyWith(
        phase: StreamPhase.streaming,
        active: source,
        quality: source.quality,
        clearFailure: true,
      ),
    );
    log.add(
      EngineEvent.info(
        'stream',
        'Streaming from ${source.providerId} (${source.quality.label})',
      ),
    );
  }

  void cancel() {
    _transition(_state.copyWith(phase: StreamPhase.cancelled));
    log.add(EngineEvent.info('stream', 'Streaming cancelled'));
  }

  void reset() {
    _transition(StreamSessionState());
  }
}

class StreamResolutionOutcome {
  final StreamDescriptor? resolved;
  final List<StreamDescriptor> alternatives;
  final StreamFailure? failure;

  /// Whether the selected source's URL is near/at expiry and should be
  /// re-fetched from the provider before playback. When true, the session
  /// stays in [StreamPhase.refreshingUrl] until the caller resolves again
  /// with a refreshed source.
  final bool needsUrlRefresh;

  const StreamResolutionOutcome({
    required this.resolved,
    required this.alternatives,
    this.failure,
    this.needsUrlRefresh = false,
  });

  bool get failed => resolved == null;

  String? get failureReason => failure?.message;
}

/// Convenience helpers shared by the engine providers.
extension StreamDescriptorText on StreamDescriptor {
  /// Short human label: "Provider · 320kbps".
  String get displayLabel {
    final qualityLabel = characteristics.compactLabel.isNotEmpty
        ? characteristics.compactLabel
        : quality.label;
    return '$providerId · $qualityLabel';
  }

  String get safeUriLabel {
    final uriText = normalizeOptionalString(uri) ?? '';
    if (uriText.isEmpty) return '';
    if (uriText.length <= 72) return uriText;
    return '${uriText.substring(0, 44)}…${uriText.substring(uriText.length - 20)}';
  }
}

// ---------------------------------------------------------------------------
// Adaptive bitrate selection
// ---------------------------------------------------------------------------

/// One playable encoding of the same logical stream, as exposed by a provider
/// that offers a bitrate ladder (YouTube's audio-only renditions, Tidal's
/// `audioquality` tiers, …).
class StreamVariant {
  final String uri;
  final int bitrateKbps;
  final String? codec;
  final String? container;
  final DateTime? expiresAt;

  const StreamVariant({
    required this.uri,
    required this.bitrateKbps,
    this.codec,
    this.container,
    this.expiresAt,
  });

  /// Bytes/second this variant needs to stream in real time.
  int get bytesPerSecond => (bitrateKbps * 1000) ~/ 8;

  @override
  String toString() =>
      'StreamVariant(${bitrateKbps}kbps, ${codec ?? 'unknown'}, $uri)';
}

/// How aggressively the ladder is allowed to move.
enum AdaptiveBitrateMode {
  /// Always take the highest rung the link can sustain.
  qualityFirst,

  /// Leave headroom for jitter: never spend more than ~75% of the measured
  /// link on audio.
  balanced,

  /// Prefer rungs well below the measured link (mobile data / roaming).
  dataSaver,
}

/// Result of one ladder decision, carrying the reasoning so the diagnostics
/// UI can explain a downgrade instead of silently changing quality.
class AdaptiveBitrateDecision {
  final StreamVariant? variant;
  final int? targetKbps;
  final int? measuredBytesPerSecond;
  final String reason;

  const AdaptiveBitrateDecision({
    this.variant,
    this.targetKbps,
    this.measuredBytesPerSecond,
    this.reason = '',
  });

  @override
  String toString() =>
      'AdaptiveBitrateDecision(${targetKbps ?? 0}kbps, reason: $reason)';
}

/// Picks a rung of a bitrate ladder that the current link can actually
/// sustain, bounded by the requested [AudioQualityLevel] and the network
/// profile.
///
/// The selector is pure: the ladder comes from the provider, the throughput
/// estimate from [BandwidthMonitor], and both are optional — with no
/// measurement the selector degrades to "highest rung that fits the requested
/// quality", which is exactly the pre-adaptive behaviour.
class AdaptiveBitrateSelector {
  const AdaptiveBitrateSelector({
    this.mode = AdaptiveBitrateMode.balanced,
    this.minKbps = 48,
    this.maxKbps = 9216,
  });

  final AdaptiveBitrateMode mode;

  /// Floor for playback: below this, audio is not worth playing.
  final int minKbps;

  /// Ceiling (Hi-Res 24/192 FLAC ≈ 9216 kbps).
  final int maxKbps;

  /// Fraction of the measured throughput a rung may consume.
  double get _usableFraction {
    switch (mode) {
      case AdaptiveBitrateMode.qualityFirst:
        return 0.95;
      case AdaptiveBitrateMode.balanced:
        return 0.75;
      case AdaptiveBitrateMode.dataSaver:
        return 0.5;
    }
  }

  /// Upper bound derived from the requested quality (unbounded for `auto`).
  int? _qualityCeiling(AudioQualityLevel requested) {
    switch (requested) {
      case AudioQualityLevel.auto:
        return null;
      case AudioQualityLevel.low:
      case AudioQualityLevel.normal:
      case AudioQualityLevel.high:
      case AudioQualityLevel.lossless:
      case AudioQualityLevel.hires:
        return requested.referenceBitrateKbps;
    }
  }

  /// Selects the best sustainable rung from [variants].
  ///
  /// [variants] may be unsorted and may contain duplicates; the highest
  /// bitrate that fits wins. Returns an empty decision (null variant) only
  /// when the ladder is empty.
  AdaptiveBitrateDecision select(
    List<StreamVariant> variants, {
    int? measuredBytesPerSecond,
    AudioQualityLevel requested = AudioQualityLevel.auto,
    NetworkProfile profile = NetworkProfile.wifi,
    DateTime? now,
  }) {
    final usable = <StreamVariant>[];
    final effectiveNow = now ?? DateTime.now();
    for (final variant in variants) {
      final expiry = variant.expiresAt;
      if (expiry != null && !effectiveNow.isBefore(expiry)) continue;
      usable.add(variant);
    }
    if (usable.isEmpty) {
      return const AdaptiveBitrateDecision(
        reason: 'no usable variant in the ladder',
      );
    }
    usable.sort((a, b) => b.bitrateKbps.compareTo(a.bitrateKbps));

    final qualityCeiling = _qualityCeiling(requested);
    var ceiling = maxKbps;
    if (qualityCeiling != null && qualityCeiling > 0) {
      ceiling = math.min(ceiling, qualityCeiling);
    }
    if (profile == NetworkProfile.roaming) {
      // Roaming is metered per megabyte regardless of the measured link.
      ceiling = math.min(ceiling, 256);
    }

    final measured = measuredBytesPerSecond;
    final budget = measured == null || measured <= 0
        ? null
        : (measured * _usableFraction).round();

    var reason = 'no bandwidth measurement; highest rung within quality cap';
    for (final variant in usable) {
      if (variant.bitrateKbps > ceiling) continue;
      if (budget != null && variant.bytesPerSecond > budget) continue;
      if (variant.bitrateKbps < minKbps) {
        // Only tolerate an ultra-low rung when nothing else exists.
        continue;
      }
      reason = budget == null
          ? 'highest rung within ${ceiling}kbps cap'
          : '${variant.bitrateKbps}kbps fits ${(budget * 8 / 1000).round()}kbps budget'
              ' (${(_usableFraction * 100).round()}% of link)';
      return AdaptiveBitrateDecision(
        variant: variant,
        targetKbps: variant.bitrateKbps,
        measuredBytesPerSecond: measured,
        reason: reason,
      );
    }

    // Nothing fits: fall back to the lowest rung so playback still starts
    // (a stuttering low-bitrate stream beats silence on a saturated link).
    final lowest = usable.last;
    final fallbackCeiling = math.min(lowest.bitrateKbps, ceiling);
    return AdaptiveBitrateDecision(
      variant: lowest,
      targetKbps: fallbackCeiling,
      measuredBytesPerSecond: measured,
      reason: budget == null
          ? 'lowest rung (${lowest.bitrateKbps}kbps)'
          : 'link too slow for any rung ≥ ${minKbps}kbps; using lowest '
              '(${lowest.bitrateKbps}kbps)',
    );
  }

  /// Recommended rung for the next attempt after a stall, i.e. one step below
  /// [currentKbps]. Returns null when already at the bottom of the ladder.
  int? stepDown(int currentKbps, List<StreamVariant> variants) {
    final sorted = variants
        .map((v) => v.bitrateKbps)
        .where((kbps) => kbps < currentKbps)
        .toList(growable: false);
    if (sorted.isEmpty) return null;
    sorted.sort((a, b) => b.compareTo(a));
    final candidate = sorted.first;
    return candidate < minKbps ? null : candidate;
  }
}

// ---------------------------------------------------------------------------
// Buffering / expiry / failure recovery
// ---------------------------------------------------------------------------

/// What the player should do next when a stream misbehaves.
enum StreamRecoveryAction {
  /// Keep going: the condition is transient and within budget.
  wait,

  /// Re-run preflight on the *same* URL (cheapest check).
  revalidate,

  /// Ask the provider for a fresh URL (the current one is stale/expired).
  reResolve,

  /// Abandon this source and move to the next ranked candidate.
  failover,

  /// Nothing more can be done for this track.
  abort,
}

/// Snapshot of the runtime conditions a recovery decision is made from.
class StreamRecoveryContext {
  /// How long the player has been unable to advance (buffering/stalled).
  final Duration stallDuration;

  /// Whether the transport reported buffering rather than an error.
  final bool buffering;

  /// Time left before the current signed URL expires, when known.
  final Duration? untilExpiry;

  /// Recoveries already attempted for this play session.
  final int attempts;

  /// Consecutive failures recorded for the current provider.
  final int providerFailures;

  const StreamRecoveryContext({
    this.stallDuration = Duration.zero,
    this.buffering = false,
    this.untilExpiry,
    this.attempts = 0,
    this.providerFailures = 0,
  });
}

/// Turns runtime symptoms into one concrete [StreamRecoveryAction].
///
/// The policy is intentionally conservative: recovery is *bounded*
/// ([maxAttempts], [recoveryWindow]) so a permanently broken source cannot
/// trap the player in an endless re-resolve loop, and it always prefers the
/// cheapest action that can plausibly fix the symptom (revalidate → re-resolve
/// → failover → abort).
class StreamRecoveryPolicy {
  const StreamRecoveryPolicy({
    this.stallTimeout = const Duration(seconds: 8),
    this.expiryLeadTime = const Duration(minutes: 2),
    this.maxAttempts = 3,
    this.recoveryWindow = const Duration(minutes: 5),
    this.expiryRecoveries = 2,
  });

  /// How long a buffering/stalled state is tolerated before recovery starts.
  final Duration stallTimeout;

  /// Refresh a signed URL this long before it actually expires.
  final Duration expiryLeadTime;

  /// Hard cap on recovery attempts per play session.
  final int maxAttempts;

  /// Attempts older than this no longer count against [maxAttempts], so a
  /// long track that recovered once early can still recover later.
  final Duration recoveryWindow;

  /// Separate, smaller budget for proactive expiry refreshes (those are
  /// expected and must not consume the failure budget).
  final int expiryRecoveries;

  /// Decision for a stalled/buffering stream.
  StreamRecoveryAction forStall(StreamRecoveryContext context) {
    if (context.attempts >= maxAttempts) return StreamRecoveryAction.abort;
    if (!context.buffering) return StreamRecoveryAction.wait;
    if (context.stallDuration < stallTimeout) return StreamRecoveryAction.wait;
    // A healthy URL that suddenly stops delivering is usually a CDN/connection
    // hiccup: refresh it. Repeated stalls mean the source itself is bad.
    return context.attempts == 0
        ? StreamRecoveryAction.reResolve
        : StreamRecoveryAction.failover;
  }

  /// Decision for a playback error (decode failure, HTTP 403/404, …).
  StreamRecoveryAction forError(StreamRecoveryContext context) {
    if (context.attempts >= maxAttempts) return StreamRecoveryAction.abort;
    final expiry = context.untilExpiry;
    if (expiry != null && expiry <= Duration.zero) {
      return StreamRecoveryAction.reResolve;
    }
    // A provider that failed repeatedly is not worth another URL from the
    // same source: move down the ranked candidate list immediately.
    return context.providerFailures >= 2
        ? StreamRecoveryAction.failover
        : StreamRecoveryAction.reResolve;
  }

  /// Proactive decision taken *before* playback breaks: the signed URL is
  /// about to expire, so mint a fresh one while audio still plays.
  StreamRecoveryAction forExpiry(
    StreamRecoveryContext context, {
    int previousExpiryRefreshes = 0,
  }) {
    final expiry = context.untilExpiry;
    if (expiry == null) return StreamRecoveryAction.wait;
    if (previousExpiryRefreshes >= expiryRecoveries) {
      return StreamRecoveryAction.wait;
    }
    if (expiry <= expiryLeadTime) return StreamRecoveryAction.reResolve;
    return StreamRecoveryAction.wait;
  }

  /// Absolute time at which the current URL should be refreshed, or null when
  /// it never expires / the refresh budget is spent.
  DateTime? nextRefreshAt(
    DateTime? expiresAt, {
    int previousExpiryRefreshes = 0,
    DateTime? now,
  }) {
    if (expiresAt == null) return null;
    if (previousExpiryRefreshes >= expiryRecoveries) return null;
    final candidate = expiresAt.subtract(expiryLeadTime);
    final effectiveNow = now ?? DateTime.now();
    return candidate.isBefore(effectiveNow) ? effectiveNow : candidate;
  }
}

/// Tracks how many recoveries a single play session has performed inside the
/// policy's sliding window, so the budget resets on long tracks.
class StreamRecoveryBudget {
  StreamRecoveryBudget({required this.policy, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final StreamRecoveryPolicy policy;
  final DateTime Function() _clock;
  final List<DateTime> _attempts = <DateTime>[];
  int _expiryRefreshes = 0;

  int get attempts => _prune();
  int get expiryRefreshes => _expiryRefreshes;

  int _prune() {
    final now = _clock();
    _attempts.removeWhere(
      (at) => now.difference(at) > policy.recoveryWindow,
    );
    return _attempts.length;
  }

  StreamRecoveryContext context({
    Duration stallDuration = Duration.zero,
    bool buffering = false,
    Duration? untilExpiry,
    int providerFailures = 0,
  }) => StreamRecoveryContext(
    stallDuration: stallDuration,
    buffering: buffering,
    untilExpiry: untilExpiry,
    attempts: attempts,
    providerFailures: providerFailures,
  );

  /// Records one recovery attempt and returns the updated count.
  int record() {
    final count = _prune();
    _attempts.add(_clock());
    return count + 1;
  }

  /// Records a proactive URL refresh (does not consume the failure budget).
  int recordExpiryRefresh() => ++_expiryRefreshes;

  /// Called when the source changes (failover) or the user skips: the new
  /// source gets a fresh recovery budget.
  void reset() {
    _attempts.clear();
    _expiryRefreshes = 0;
  }
}
