/// Pure domain entities for the Stage 2 core engine.
///
/// Nothing in this file imports Flutter, platform channels, or lib/services:
/// entities are plain values that every layer can share, construct in tests,
/// and serialize if needed.
library;

import 'package:spotiflac_android/core/domain/core_errors.dart';

// ---------------------------------------------------------------------------
// Track identity
// ---------------------------------------------------------------------------

/// Minimal, provider-agnostic track identity used by the core engine.
///
/// The presentation layer maps the rich `Track` model into this record at the
/// boundary so the core never depends on the UI-facing model graph.
class TrackRef {
  const TrackRef({
    required this.id,
    required this.name,
    required this.artistName,
    this.albumName = '',
    this.albumArtistName,
    this.durationMs,
    this.isrc,
    this.coverUrl,
    this.trackNumber,
    this.discNumber,
    this.releaseDate,
  });

  final String id;
  final String name;
  final String artistName;
  final String albumName;
  final String? albumArtistName;
  final int? durationMs;
  final String? isrc;
  final String? coverUrl;
  final int? trackNumber;
  final int? discNumber;
  final String? releaseDate;

  TrackRef copyWith({
    String? id,
    String? name,
    String? artistName,
    String? albumName,
    Object? albumArtistName = _unset,
    Object? durationMs = _unset,
    Object? isrc = _unset,
    Object? coverUrl = _unset,
    Object? trackNumber = _unset,
    Object? discNumber = _unset,
    Object? releaseDate = _unset,
  }) {
    return TrackRef(
      id: id ?? this.id,
      name: name ?? this.name,
      artistName: artistName ?? this.artistName,
      albumName: albumName ?? this.albumName,
      albumArtistName: identical(albumArtistName, _unset)
          ? this.albumArtistName
          : albumArtistName as String?,
      durationMs: identical(durationMs, _unset)
          ? this.durationMs
          : durationMs as int?,
      isrc: identical(isrc, _unset) ? this.isrc : isrc as String?,
      coverUrl: identical(coverUrl, _unset) ? this.coverUrl : coverUrl as String?,
      trackNumber: identical(trackNumber, _unset)
          ? this.trackNumber
          : trackNumber as int?,
      discNumber: identical(discNumber, _unset)
          ? this.discNumber
          : discNumber as int?,
      releaseDate: identical(releaseDate, _unset)
          ? this.releaseDate
          : releaseDate as String?,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TrackRef &&
        other.id == id &&
        other.name == name &&
        other.artistName == artistName &&
        other.albumName == albumName &&
        other.albumArtistName == albumArtistName &&
        other.durationMs == durationMs &&
        other.isrc == isrc &&
        other.coverUrl == coverUrl &&
        other.trackNumber == trackNumber &&
        other.discNumber == discNumber &&
        other.releaseDate == releaseDate;
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    artistName,
    albumName,
    albumArtistName,
    durationMs,
    isrc,
    coverUrl,
    trackNumber,
    discNumber,
    releaseDate,
  );

  @override
  String toString() => 'TrackRef($id, "$name" by $artistName)';
}

// ---------------------------------------------------------------------------
// Queue entities
// ---------------------------------------------------------------------------

/// Scheduling lane of a queue job. Lower [rank] runs first.
///
/// `immediate` covers user-triggered interactive downloads that must pre-empt
/// batch work; `low` is for background syncing that should yield to anything
/// else.
enum JobPriority {
  immediate(0),
  high(1),
  normal(2),
  low(3);

  const JobPriority(this.rank);

  final int rank;

  static int compare(JobPriority a, JobPriority b) => a.rank.compareTo(b.rank);
}

/// Lifecycle of a [QueueJob] inside the engine.
///
/// `held` means intentionally parked (user pause or engine gate): the job
/// still belongs to the queue but consumes no worker slot.
enum JobLifecycle {
  pending,
  held,
  running,
  completed,
  failed,
  cancelled;

  bool get isTerminal =>
      this == JobLifecycle.completed ||
      this == JobLifecycle.failed ||
      this == JobLifecycle.cancelled;

  bool get isActive =>
      this == JobLifecycle.pending ||
      this == JobLifecycle.held ||
      this == JobLifecycle.running;
}

/// Immutable description of work to schedule.
class DownloadJobSpec {
  const DownloadJobSpec({
    required this.track,
    required this.finalPath,
    this.jobId,
    this.priority = JobPriority.normal,
    this.expectedSha256Hex,
    this.expectedSizeBytes,
    this.options = const <String, Object?>{},
  });

  /// What should be downloaded.
  final TrackRef track;

  /// Final destination the staged artifact commits to (filesystem path or a
  /// storage-scheme specific target understood by the StorageRepository).
  final String finalPath;

  /// Caller-chosen stable id; the engine assigns one when null.
  final String? jobId;

  /// Scheduling lane.
  final JobPriority priority;

  /// Optional SHA-256 (hex, lower or upper case) the finalized artifact must
  /// match before commit. Verified during the transactional finalize.
  final String? expectedSha256Hex;

  /// Optional exact byte size the finalized artifact must match.
  final int? expectedSizeBytes;

  /// Backend-specific passthrough (quality, service hints, SAF subtree, …).
  /// Keys are owned by the composing DownloadBackend; the engine never reads
  /// them.
  final Map<String, Object?> options;

  DownloadJobSpec copyWith({
    TrackRef? track,
    String? finalPath,
    Object? jobId = _unset,
    JobPriority? priority,
    Object? expectedSha256Hex = _unset,
    Object? expectedSizeBytes = _unset,
    Map<String, Object?>? options,
  }) {
    return DownloadJobSpec(
      track: track ?? this.track,
      finalPath: finalPath ?? this.finalPath,
      jobId: identical(jobId, _unset) ? this.jobId : jobId as String?,
      priority: priority ?? this.priority,
      expectedSha256Hex: identical(expectedSha256Hex, _unset)
          ? this.expectedSha256Hex
          : expectedSha256Hex as String?,
      expectedSizeBytes: identical(expectedSizeBytes, _unset)
          ? this.expectedSizeBytes
          : expectedSizeBytes as int?,
      options: options ?? this.options,
    );
  }
}

/// Engine-side view of one scheduled job. Immutable; every transition emits a
/// new copy alongside its [QueueEvent].
class QueueJob {
  const QueueJob({
    required this.id,
    required this.sequence,
    required this.spec,
    required this.lifecycle,
    this.attempt = 0,
    this.progress = 0,
    this.error,
  });

  final String id;

  /// Monotonic insertion order; FIFO tie-breaker within one priority lane.
  final int sequence;

  final DownloadJobSpec spec;
  final JobLifecycle lifecycle;

  /// 1-based execution attempt counter (increments on every start, including
  /// resume-after-pause and engine retries).
  final int attempt;

  /// 0..1, reported by the executing backend.
  final double progress;

  /// Terminal error (failed/cancelled) when any.
  final CoreError? error;

  TrackRef get track => spec.track;
  JobPriority get priority => spec.priority;
  bool get isTerminal => lifecycle.isTerminal;

  QueueJob copyWith({
    int? sequence,
    DownloadJobSpec? spec,
    JobLifecycle? lifecycle,
    int? attempt,
    double? progress,
    Object? error = _unset,
  }) {
    return QueueJob(
      id: id,
      sequence: sequence ?? this.sequence,
      spec: spec ?? this.spec,
      lifecycle: lifecycle ?? this.lifecycle,
      attempt: attempt ?? this.attempt,
      progress: progress ?? this.progress,
      error: identical(error, _unset) ? this.error : error as CoreError?,
    );
  }

  @override
  String toString() =>
      'QueueJob($id, ${lifecycle.name}, attempt=$attempt, '
      'progress=${progress.toStringAsFixed(3)})';
}

/// Outcome of one job execution as reported by the worker runner.
class QueueJobResult {
  const QueueJobResult._({
    required this.success,
    this.outputPath,
    this.error,
    this.byteSize,
  });

  const QueueJobResult.success({String? outputPath, int? byteSize})
    : this._(success: true, outputPath: outputPath, byteSize: byteSize);

  const QueueJobResult.failure(CoreError error)
    : this._(success: false, error: error);

  final bool success;
  final String? outputPath;
  final CoreError? error;
  final int? byteSize;
}

// ---------------------------------------------------------------------------
// Queue events (sealed: exhaustive handling in the UI and tests)
// ---------------------------------------------------------------------------

/// Base class for every queue-engine event. Events are the engine's only
/// output channel: presentation consumes them and never pokes engine
/// internals.
sealed class QueueEvent {
  const QueueEvent();
}

class QueueJobEnqueued extends QueueEvent {
  const QueueJobEnqueued(this.job);
  final QueueJob job;
}

class QueueJobStarted extends QueueEvent {
  const QueueJobStarted(this.job);
  final QueueJob job;
}

class QueueJobProgress extends QueueEvent {
  const QueueJobProgress(this.jobId, this.progress);
  final String jobId;
  final double progress;
}

/// A running or pending job was parked (user pause or engine-gate pause) and
/// will resume from the queue, not from scratch logic outside the engine.
class QueueJobHeld extends QueueEvent {
  const QueueJobHeld(this.job, {required this.byUser});
  final QueueJob job;
  final bool byUser;
}

class QueueJobResumed extends QueueEvent {
  const QueueJobResumed(this.job);
  final QueueJob job;
}

class QueueJobReordered extends QueueEvent {
  const QueueJobReordered(this.job);
  final QueueJob job;
}

class QueueJobRetryScheduled extends QueueEvent {
  const QueueJobRetryScheduled(this.job, {required this.delay});
  final QueueJob job;
  final Duration delay;
}

class QueueJobCompleted extends QueueEvent {
  const QueueJobCompleted(this.job, this.result);
  final QueueJob job;
  final QueueJobResult result;
}

class QueueJobFailed extends QueueEvent {
  const QueueJobFailed(this.job, this.error);
  final QueueJob job;
  final CoreError error;
}

class QueueJobCancelled extends QueueEvent {
  const QueueJobCancelled(this.job, this.reason);
  final QueueJob job;
  final String reason;
}

/// Emitted when no pending/running work remains. Held (user-paused) jobs do
/// not block this event because they consume no resources.
class QueueEmptied extends QueueEvent {
  const QueueEmptied();
}

// ---------------------------------------------------------------------------
// Storage entities
// ---------------------------------------------------------------------------

/// Location pair for transactional staging: bytes land in [tempPath] and are
/// atomically promoted to [finalPath] only after integrity checks pass.
class StorageTarget {
  const StorageTarget({
    required this.finalPath,
    required this.tempPath,
    this.scheme = 'file',
  });

  final String finalPath;
  final String tempPath;

  /// Storage backend discriminator: `file`, `saf`, or `bookmark` (iOS).
  final String scheme;

  @override
  String toString() => 'StorageTarget($scheme, $tempPath → $finalPath)';
}

/// Result of a metadata-sanity probe on a staged artifact.
class SanityReport {
  const SanityReport._({
    required this.ok,
    required this.kind,
    required this.sizeBytes,
    this.reason,
  });

  const SanityReport.ok({required String kind, required int sizeBytes})
    : this._(ok: true, kind: kind, sizeBytes: sizeBytes);

  const SanityReport.failure({required int sizeBytes, required String reason})
    : this._(ok: false, kind: 'unknown', sizeBytes: sizeBytes, reason: reason);

  final bool ok;

  /// Detected container kind (`flac`, `mp3`, `ogg`, …) or `unknown`.
  final String kind;
  final int sizeBytes;
  final String? reason;
}

// ---------------------------------------------------------------------------
// Extension engine entities
// ---------------------------------------------------------------------------

enum ExtensionRequestKind { downloadUrl, search, trackMetadata }

/// One request routed to a dynamic provider driver.
class ExtensionRequest {
  const ExtensionRequest({
    required this.kind,
    required this.track,
    this.quality,
    this.parameters = const <String, Object?>{},
  });

  final ExtensionRequestKind kind;
  final TrackRef track;
  final String? quality;
  final Map<String, Object?> parameters;
}

/// Decoded payload returned by a provider driver. Kept as raw map here;
/// typed decoding helpers live in the data layer (`ExtensionPayloadDecoder`).
class ExtensionPayload {
  const ExtensionPayload(this.data);

  final Map<String, Object?> data;

  Object? operator [](String key) => data[key];

  @override
  String toString() => 'ExtensionPayload(${data.keys.join(', ')})';
}

/// Record of one failed provider attempt, kept for diagnostics and ordering.
class ProviderAttemptFailure {
  const ProviderAttemptFailure({
    required this.providerId,
    required this.attempt,
    required this.error,
  });

  final String providerId;
  final int attempt;
  final CoreError error;

  @override
  String toString() =>
      'ProviderAttemptFailure($providerId#$attempt, ${error.category.name})';
}

/// Successful resolution, including which provider won and what failed
/// before it (priority switching audit trail).
class ExtensionResolution {
  const ExtensionResolution({
    required this.providerId,
    required this.payload,
    this.priorFailures = const <ProviderAttemptFailure>[],
  });

  final String providerId;
  final ExtensionPayload payload;
  final List<ProviderAttemptFailure> priorFailures;
}

/// Health snapshot of one provider inside the engine.
class ExtensionProviderHealth {
  const ExtensionProviderHealth({
    required this.providerId,
    this.consecutiveFailures = 0,
    this.totalSuccesses = 0,
    this.lastError,
  });

  final String providerId;
  final int consecutiveFailures;
  final int totalSuccesses;
  final CoreError? lastError;

  ExtensionProviderHealth copyWith({
    int? consecutiveFailures,
    int? totalSuccesses,
    Object? lastError = _unset,
  }) {
    return ExtensionProviderHealth(
      providerId: providerId,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      totalSuccesses: totalSuccesses ?? this.totalSuccesses,
      lastError: identical(lastError, _unset)
          ? this.lastError
          : lastError as CoreError?,
    );
  }
}

// ---------------------------------------------------------------------------
// Metadata pipeline entities
// ---------------------------------------------------------------------------

/// Normalized metadata envelope passed through the pipeline stages
/// (enrich → transform → embed).
class MetadataEnvelope {
  const MetadataEnvelope({
    required this.title,
    required this.artist,
    this.album,
    this.albumArtist,
    this.trackNumber,
    this.discNumber,
    this.isrc,
    this.coverUrl,
    this.releaseDate,
    this.extras = const <String, Object?>{},
  });

  final String title;
  final String artist;
  final String? album;
  final String? albumArtist;
  final int? trackNumber;
  final int? discNumber;
  final String? isrc;
  final String? coverUrl;
  final String? releaseDate;
  final Map<String, Object?> extras;

  MetadataEnvelope copyWith({
    String? title,
    String? artist,
    Object? album = _unset,
    Object? albumArtist = _unset,
    Object? trackNumber = _unset,
    Object? discNumber = _unset,
    Object? isrc = _unset,
    Object? coverUrl = _unset,
    Object? releaseDate = _unset,
    Map<String, Object?>? extras,
  }) {
    return MetadataEnvelope(
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: identical(album, _unset) ? this.album : album as String?,
      albumArtist: identical(albumArtist, _unset)
          ? this.albumArtist
          : albumArtist as String?,
      trackNumber: identical(trackNumber, _unset)
          ? this.trackNumber
          : trackNumber as int?,
      discNumber: identical(discNumber, _unset)
          ? this.discNumber
          : discNumber as int?,
      isrc: identical(isrc, _unset) ? this.isrc : isrc as String?,
      coverUrl: identical(coverUrl, _unset) ? this.coverUrl : coverUrl as String?,
      releaseDate: identical(releaseDate, _unset)
          ? this.releaseDate
          : releaseDate as String?,
      extras: extras ?? this.extras,
    );
  }
}

// ---------------------------------------------------------------------------
// Transcode entities
// ---------------------------------------------------------------------------

enum TranscodeTargetFormat { flac, mp3, opus, m4a, ogg }

class TranscodeRequest {
  const TranscodeRequest({
    required this.inputPath,
    required this.targetFormat,
    this.outputPath,
    this.bitrateKbps,
    this.deleteSourceOnSuccess = false,
  });

  final String inputPath;
  final TranscodeTargetFormat targetFormat;

  /// Destination; null lets the transcoder derive it from [inputPath].
  final String? outputPath;
  final int? bitrateKbps;
  final bool deleteSourceOnSuccess;
}

class TranscodeOutcome {
  const TranscodeOutcome({required this.success, this.outputPath, this.error});

  final bool success;
  final String? outputPath;
  final CoreError? error;
}

const Object _unset = Object();
