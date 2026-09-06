library;
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/streaming_engine.dart';

/// Smart Play: the single decision path the player uses when the user hits
/// Play.
///
/// The source-priority ladder is the core architectural contract of the
/// upgraded app:
///
///   Downloaded?      → local playback (instant, offline-safe)
///   Streaming ok?    → stream (progressive, no storage cost)
///   Downloadable?    → download, then play (provider available)
///   Otherwise        → unavailable (clear reason, no silent failure)
///
/// Every branch also carries the *reasons* for the decision so the UI can show
/// "Playing from local — offline" or "Streaming Deezer FLAC" instead of an
/// opaque spinner. The flow stays pure and testable; the Riverpod layer wires
/// real sources into it.

/// User-selected playback mode. `smart` follows the ladder automatically;
/// the others lock it to one branch (used by "Play as" menus and by the
/// network-policy fallback).
enum PlaybackModePreference {
  smart('Smart Play'),
  stream('Stream only'),
  download('Download only'),
  downloadAndPlay('Download & Play'),
  localOnly('Local only');

  const PlaybackModePreference(this.label);

  final String label;
}

/// Everything the decision engine needs to know about one play request.
class SmartPlayInput {
  final String trackId;
  final String title;
  final String artist;
  final String album;
  final String? isrc;
  final int durationSeconds;

  /// Absolute path of an already-downloaded/local copy (null when absent).
  final String? localPath;

  /// Ranked streaming candidates (already health-filtered, not yet selected).
  final List<StreamDescriptor> streamCandidates;

  /// Whether the download subsystem can produce this track on demand.
  final bool downloadAvailable;

  /// Whether streaming is globally enabled and this source set is the user's
  /// permitted providers.
  final bool streamingEnabled;

  final NetworkProfile networkProfile;
  final PlaybackModePreference modePreference;
  final AudioQualityLevel requestQuality;

  /// Local-first: prefer the file even when its measured quality is below the
  /// requested streaming quality.
  final bool localFirst;

  const SmartPlayInput({
    required this.trackId,
    required this.title,
    required this.artist,
    this.album = '',
    this.isrc,
    this.durationSeconds = 0,
    this.localPath,
    this.streamCandidates = const [],
    this.downloadAvailable = false,
    this.streamingEnabled = true,
    this.networkProfile = NetworkProfile.wifi,
    this.modePreference = PlaybackModePreference.smart,
    this.requestQuality = AudioQualityLevel.auto,
    this.localFirst = true,
  });
}

enum SmartPlayMode {
  local('Local'),
  stream('Stream'),
  download('Download'),
  downloadAndPlay('Download & Play'),
  unavailable('Unavailable');

  const SmartPlayMode(this.label);

  final String label;

  bool get isPlayable => this == SmartPlayMode.local || this == SmartPlayMode.stream;
}

/// One line of the decision trace (shown in the diagnostics UI and logged).
class SmartPlayStep {
  final String check;
  final bool passed;
  final String detail;

  const SmartPlayStep({
    required this.check,
    required this.passed,
    required this.detail,
  });

  Map<String, dynamic> toJson() => {
    'check': check,
    'passed': passed,
    'detail': detail,
  };
}

class SmartPlayDecision {
  final SmartPlayMode mode;
  final StreamDescriptor? source;
  final List<SmartPlayStep> steps;
  final NetworkProfile networkProfile;
  final AudioQualityLevel requestedQuality;
  final AudioQualityLevel actualQuality;

  /// Human-readable explanation of why playback cannot start right now.
  /// Populated for [SmartPlayMode.unavailable] decisions so the UI can show
  /// *why* instead of failing silently; null for playable decisions.
  final String? reason;

  const SmartPlayDecision({
    required this.mode,
    this.source,
    required this.steps,
    required this.networkProfile,
    required this.requestedQuality,
    required this.actualQuality,
    this.reason,
  });

  factory SmartPlayDecision.unavailable(
    SmartPlayInput input,
    List<SmartPlayStep> steps,
    String reason,
  ) => SmartPlayDecision(
    mode: SmartPlayMode.unavailable,
    steps: steps,
    networkProfile: input.networkProfile,
    requestedQuality: input.requestQuality,
    actualQuality: input.requestQuality,
    reason: reason,
  );

  bool get canPlayNow => mode.isPlayable;

  /// Same decision with the actually-selected source (used after preflight
  /// confirms it).
  SmartPlayDecision copyWithSource(StreamDescriptor source) =>
      SmartPlayDecision(
        mode: mode,
        source: source,
        steps: steps,
        networkProfile: networkProfile,
        requestedQuality: requestedQuality,
        actualQuality: source.quality,
        reason: reason,
      );

  /// One-line human description, e.g. "Stream · Deezer FLAC".
  String get summary {
    switch (mode) {
      case SmartPlayMode.local:
        return 'Local playback';
      case SmartPlayMode.stream:
        final sourceText = source == null ? '' : ' ${source!.providerId}';
        final qualityText = actualQuality == AudioQualityLevel.auto
            ? ''
            : ' ${actualQuality.label}';
        return 'Stream$sourceText$qualityText';
      case SmartPlayMode.download:
        return 'Download (play after completion)';
      case SmartPlayMode.downloadAndPlay:
        return 'Download & Play';
      case SmartPlayMode.unavailable:
        return reason == null
            ? 'Unavailable'
            : 'Unavailable — $reason';
    }
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    if (source != null) 'source': source!.toJson(),
    'steps': steps.map((s) => s.toJson()).toList(growable: false),
    'network': networkProfile.name,
    'requested_quality': requestedQuality.name,
    'actual_quality': actualQuality.name,
    if (reason != null) 'reason': reason,
  };
}

/// Pure decision engine. Inject everything; assert nothing against the
/// platform.
class SmartPlayEngine {
  const SmartPlayEngine();

  SmartPlayDecision decide(SmartPlayInput input) {
    final steps = <SmartPlayStep>[];

    final offline = input.networkProfile == NetworkProfile.offline;

    // Mode lock overrides the ladder, but never overrides offline safety:
    // downloading on a dead link is a guaranteed failure the user didn't ask
    // for (the ladder would have told us it's unavailable).
    switch (input.modePreference) {
      case PlaybackModePreference.localOnly:
        steps.add(_step('local_only_mode', input.localPath != null,
            'Local-only mode: ${input.localPath ?? 'no local file'}'));
        if (input.localPath != null) {
          return _local(input, steps);
        }
        return SmartPlayDecision.unavailable(
          input,
          steps,
          'Local-only mode and no local file found',
        );

      case PlaybackModePreference.stream:
        if (offline) {
          steps.add(_step('offline', false, 'Offline — cannot stream'));
          return _fallbackToLocalOrUnavailable(input, steps);
        }
        steps.add(_step('stream_mode', input.streamCandidates.isNotEmpty,
            'Stream-only mode: ${input.streamCandidates.length} candidates'));
        if (input.streamCandidates.isNotEmpty) {
          return _stream(input, steps);
        }
        return SmartPlayDecision.unavailable(
          input,
          steps,
          'Stream-only mode and no source available',
        );

      case PlaybackModePreference.download:
        if (offline) {
          steps.add(_step('offline', false, 'Offline — cannot download'));
          return _fallbackToLocalOrUnavailable(input, steps);
        }
        steps.add(_step('download_available', input.downloadAvailable,
            'Download-only mode'));
        if (input.downloadAvailable) {
          return SmartPlayDecision(
            mode: SmartPlayMode.download,
            steps: steps,
            networkProfile: input.networkProfile,
            requestedQuality: input.requestQuality,
            actualQuality: input.requestQuality,
          );
        }
        return SmartPlayDecision.unavailable(
          input,
          steps,
          'Download-only mode and track not available for download',
        );

      case PlaybackModePreference.downloadAndPlay:
        if (offline) {
          steps.add(_step('offline', false, 'Offline — cannot download'));
          return _fallbackToLocalOrUnavailable(input, steps);
        }
        steps.add(_step('download_available', input.downloadAvailable,
            'Download & Play mode'));
        if (input.downloadAvailable) {
          return SmartPlayDecision(
            mode: SmartPlayMode.downloadAndPlay,
            steps: steps,
            networkProfile: input.networkProfile,
            requestedQuality: input.requestQuality,
            actualQuality: input.requestQuality,
          );
        }
        return SmartPlayDecision.unavailable(
          input,
          steps,
          'Download not available for this track',
        );

      case PlaybackModePreference.smart:
        break;
    }

    // ---- Smart ladder ----------------------------------------------------
    final hasLocal =
        input.localPath != null && input.localPath!.trim().isNotEmpty;
    steps.add(_step('downloaded', hasLocal, hasLocal ? 'File found' : 'No local file'));

    if (hasLocal && input.localFirst) {
      return _local(input, steps);
    }

    final canStream = !offline &&
        input.streamingEnabled &&
        input.streamCandidates.isNotEmpty;
    steps.add(_step(
      'streaming_available',
      canStream,
      canStream
          ? '${input.streamCandidates.length} candidate(s)'
          : offline
          ? 'Offline'
          : input.streamingEnabled
          ? 'No streaming source'
          : 'Streaming disabled',
    ));

    if (hasLocal) {
      // Local file exists but local-first is off; prefer stream when the
      // source is meaningfully better, otherwise stay local.
      if (canStream && _streamOutranksLocal(input)) {
        return _stream(input, steps);
      }
      return _local(input, steps);
    }

    if (canStream) {
      return _stream(input, steps);
    }

    final canDownload = !offline &&
        input.downloadAvailable &&
        input.modePreference != PlaybackModePreference.localOnly;
    steps.add(_step('download_available', canDownload,
        canDownload ? 'Download queue available' : 'No download source'));

    if (canDownload) {
      return SmartPlayDecision(
        mode: SmartPlayMode.downloadAndPlay,
        steps: steps,
        networkProfile: input.networkProfile,
        requestedQuality: input.requestQuality,
        actualQuality: input.requestQuality,
      );
    }

    return SmartPlayDecision.unavailable(
      input,
      steps,
      offline
          ? 'Offline and no local copy'
          : 'No local file, no streaming source, and no download source',
    );
  }

  SmartPlayDecision _local(SmartPlayInput input, List<SmartPlayStep> steps) {
    steps.add(
      _step('local_chosen', true, 'Playing from local storage'),
    );
    return SmartPlayDecision(
      mode: SmartPlayMode.local,
      steps: steps,
      networkProfile: input.networkProfile,
      requestedQuality: input.requestQuality,
      actualQuality: input.requestQuality,
    );
  }

  SmartPlayDecision _stream(
    SmartPlayInput input,
    List<SmartPlayStep> steps,
  ) {
    final resolver = _rankStreams(input);
    final selected = resolver.$1;
    final actualQuality = resolver.$2;
    steps.add(
      _step(
        'stream_chosen',
        true,
        '${selected.providerId} · ${actualQuality.label}',
      ),
    );
    return SmartPlayDecision(
      mode: SmartPlayMode.stream,
      source: selected,
      steps: steps,
      networkProfile: input.networkProfile,
      requestedQuality: input.requestQuality,
      actualQuality: actualQuality,
    );
  }

  SmartPlayDecision _fallbackToLocalOrUnavailable(
    SmartPlayInput input,
    List<SmartPlayStep> steps,
  ) {
    if (input.localPath != null && input.localPath!.trim().isNotEmpty) {
      steps.add(
        _step('local_fallback', true, 'Falling back to the local copy'),
      );
      return _local(input, steps);
    }
    return SmartPlayDecision.unavailable(input, steps, 'No local copy available');
  }

  /// Prefers the highest-rank candidate that satisfies the requested quality
  /// band — the resolution is policy-driven, not "first URL wins".
  (StreamDescriptor, AudioQualityLevel) _rankStreams(SmartPlayInput input) {
    final sorted = [...input.streamCandidates]
      ..sort((a, b) => b.quality.rank.compareTo(a.quality.rank));
    StreamDescriptor selected = sorted.first;
    if (input.requestQuality != AudioQualityLevel.auto) {
      // Pick the closest source that meets the requested level; if none does,
      // pick the highest available (the adaptive layer downgrades visibly).
      final meeting = sorted.where(
        (s) => s.quality.rank >= input.requestQuality.rank,
      );
      if (meeting.isNotEmpty) selected = meeting.first;
    } else {
      selected = sorted.first;
    }
    final level = input.requestQuality != AudioQualityLevel.auto &&
            selected.quality.rank < input.requestQuality.rank
        ? selected.quality
        : selected.quality == AudioQualityLevel.auto
        ? input.requestQuality
        : selected.quality;
    return (selected, level);
  }

  bool _streamOutranksLocal(SmartPlayInput input) {
    final requested = input.requestQuality;
    if (requested == AudioQualityLevel.auto) return false;
    final best = input.streamCandidates
        .map((s) => s.quality.rank)
        .fold(0, (a, b) => a > b ? a : b);
    return best > requested.rank;
  }

  static SmartPlayStep _step(String check, bool passed, String detail) =>
      SmartPlayStep(check: check, passed: passed, detail: detail);
}
