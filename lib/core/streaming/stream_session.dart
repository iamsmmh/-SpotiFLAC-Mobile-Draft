/// Per-playback lifecycle for the native streaming engine (Feature 1).
///
/// A [StreamSession] follows one logical playback from resolution through
/// validation, playback, background caching and (for hybrid playbacks) the
/// hand-off to the local file. It is a pure state machine: clock and event
/// log are bounded, transitions are guarded, and every step is visible to
/// diagnostics. The runtime pieces (HTTP, player, cache) live behind the
/// Riverpod layer — this class only records *what happened*.
library;

import 'package:spotiflac_android/core/streaming/stream_provider.dart';

/// Lifecycle phases of one streamed playback.
enum StreamSessionPhase {
  /// Not started.
  idle,

  /// Asking providers for sources.
  resolving,

  /// Preflight-validating the chosen source.
  validating,

  /// Remote playback has started.
  playing,

  /// A background copy is being fetched while playback continues.
  caching,

  /// The verified local copy is being swapped in.
  handoff,

  /// Playback now runs from the local file (hybrid completion).
  local,

  /// Terminal failure.
  failed,

  /// Stopped by the user or queue advance.
  stopped;

  bool get isTerminal =>
      this == StreamSessionPhase.failed || this == StreamSessionPhase.stopped;

  bool get isStreaming =>
      this == StreamSessionPhase.playing || this == StreamSessionPhase.caching;
}

/// One recorded session event (bounded log).
class StreamSessionEvent {
  const StreamSessionEvent({
    required this.phase,
    required this.at,
    this.detail = '',
  });

  final StreamSessionPhase phase;
  final DateTime at;
  final String detail;

  @override
  String toString() => '${at.toUtc().toIso8601String()} ${phase.name}'
      '${detail.isEmpty ? '' : ' — $detail'}';
}

/// Plan for swapping a remote playback to its local copy (Feature 3).
class StreamHandoffPlan {
  const StreamHandoffPlan({
    required this.mediaId,
    required this.localPath,
    required this.sourceUrl,
    this.expectedSha256 = '',
    this.cipherEnabled = false,
  });

  /// Player-queue media id of the currently playing remote item.
  final String mediaId;

  /// Absolute path of the downloaded/verified file.
  final String localPath;

  /// Remote URL the local file replaces (for logs and cache bookkeeping).
  final String sourceUrl;

  /// Expected digest of [localPath]; empty when unverified.
  final String expectedSha256;

  /// Whether the local file is encrypted on disk (cache at-rest encryption).
  final bool cipherEnabled;
}

/// Callback fired when a session reaches a new phase.
typedef StreamSessionListener = void Function(
  StreamSession session,
  StreamSessionEvent event,
);

/// Bounded, clock-injected session recorder.
class StreamSession {
  StreamSession({
    required this.trackId,
    DateTime Function()? clock,
    int maxEvents = 64,
  }) : _clock = clock ?? DateTime.now,
       _events = <StreamSessionEvent>[] {
    if (maxEvents < 1) maxEvents = 1;
    _maxEvents = maxEvents;
  }

  /// Logical track identity (canonical stable id when available).
  final String trackId;
  final DateTime Function() _clock;
  final List<StreamSessionEvent> _events;
  late final int _maxEvents;

  StreamSessionPhase _phase = StreamSessionPhase.idle;
  StreamSource? _source;
  StreamHandoffPlan? _handoffPlan;
  final List<String> _retries = <String>[];
  DateTime? _startedAt;
  DateTime? _endedAt;
  final List<StreamSessionListener> _listeners = <StreamSessionListener>[];

  StreamSessionPhase get phase => _phase;
  StreamSource? get source => _source;
  StreamHandoffPlan? get handoffPlan => _handoffPlan;
  List<String> get retries => List<String>.unmodifiable(_retries);
  DateTime? get startedAt => _startedAt;
  DateTime? get endedAt => _endedAt;

  bool get isActive => !_phase.isTerminal && _phase != StreamSessionPhase.idle;

  void addListener(StreamSessionListener listener) {
    _listeners.add(listener);
  }

  void removeListener(StreamSessionListener listener) {
    _listeners.remove(listener);
  }

  void _transition(StreamSessionPhase next, {String detail = ''}) {
    if (_phase.isTerminal) return;
    _phase = next;
    if (next == StreamSessionPhase.resolving && _startedAt == null) {
      _startedAt = _clock();
    }
    if (next.isTerminal) {
      _endedAt = _clock();
    }
    final event = StreamSessionEvent(
      phase: next,
      at: _clock(),
      detail: detail,
    );
    _events.add(event);
    if (_events.length > _maxEvents) {
      _events.removeRange(0, _events.length - _maxEvents);
    }
    for (final listener in List<StreamSessionListener>.of(_listeners)) {
      listener(this, event);
    }
  }

  /// Begins (or re-begins after failure) resolution for this track.
  void beginResolving() =>
      _transition(StreamSessionPhase.resolving, detail: 'asking providers');

  /// Records the chosen source and moves to validation.
  void markValidating(StreamSource source) {
    _source = source;
    _transition(
      StreamSessionPhase.validating,
      detail: '${source.providerId} ${source.protocol.label}',
    );
  }

  /// Validation passed and remote playback started.
  void markPlaying() => _transition(
    StreamSessionPhase.playing,
    detail: _source?.url ?? '',
  );

  /// A background copy started while playback continues.
  void markCaching() => _transition(StreamSessionPhase.caching);

  /// A retry was needed (provider failover, URL refresh, …).
  void recordRetry(String reason) {
    if (_retries.length >= 32) _retries.removeAt(0);
    _retries.add(reason);
  }

  /// Planning the local swap (hybrid playback).
  void planHandoff(StreamHandoffPlan plan) {
    _handoffPlan = plan;
    _transition(StreamSessionPhase.handoff, detail: plan.localPath);
  }

  /// The swap completed; playback now runs locally.
  void completeHandoff() => _transition(StreamSessionPhase.local);

  /// Terminal failure.
  void fail(String reason) =>
      _transition(StreamSessionPhase.failed, detail: reason);

  /// User stop or queue advance.
  void stop() => _transition(StreamSessionPhase.stopped);

  /// Wall-clock duration of the session, null before it started.
  Duration? elapsed({DateTime? now}) {
    final start = _startedAt;
    if (start == null) return null;
    final end = _endedAt ?? now ?? _clock();
    return end.difference(start);
  }

  List<StreamSessionEvent> eventLog() => List<StreamSessionEvent>.unmodifiable(
    _events,
  );
}
