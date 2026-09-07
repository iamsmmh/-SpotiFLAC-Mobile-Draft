/// Playback source ladder (Phase 1) — Spotify-style fallback.
///
/// Before the audio engine requests network playback it walks, in order:
///
///   1. local library (downloaded / imported file)
///   2. verified stream cache
///   3. provider stream (full track)
///   4. preview stream (30 s fallback)
///
/// Pure policy: the Riverpod layer supplies the facts; this file never
/// touches I/O. Complements [HybridPlaybackPlanner] without replacing it —
/// the hybrid planner owns cache-while-listening; this ladder owns the
/// *source selection* that happens first.
library;

/// Facts resolved before planning one play request.
class PlaybackSourceFacts {
  const PlaybackSourceFacts({
    required this.hasLocalFile,
    required this.hasVerifiedCache,
    required this.hasProviderStream,
    required this.hasPreviewStream,
    required this.offline,
  });

  final bool hasLocalFile;
  final bool hasVerifiedCache;
  final bool hasProviderStream;
  final bool hasPreviewStream;
  final bool offline;
}

/// What the runtime should play.
enum PlaybackSourceKind {
  localLibrary,
  streamCache,
  providerStream,
  previewStream,
  unavailable,
}

/// One planned source, with the reason the UI / diagnostics can show.
class PlaybackSourcePlan {
  const PlaybackSourcePlan({
    required this.kind,
    required this.reason,
  });

  final PlaybackSourceKind kind;
  final String reason;

  bool get isPlayable => kind != PlaybackSourceKind.unavailable;

  bool get isOfflineSafe =>
      kind == PlaybackSourceKind.localLibrary ||
      kind == PlaybackSourceKind.streamCache;
}

/// Pure ladder. Deterministic, side-effect free, exhaustively tested.
class PlaybackSourceLadder {
  const PlaybackSourceLadder();

  PlaybackSourcePlan resolve(PlaybackSourceFacts facts) {
    if (facts.hasLocalFile) {
      return const PlaybackSourcePlan(
        kind: PlaybackSourceKind.localLibrary,
        reason: 'Local library file present',
      );
    }
    if (facts.hasVerifiedCache) {
      return const PlaybackSourcePlan(
        kind: PlaybackSourceKind.streamCache,
        reason: 'Verified stream cache hit',
      );
    }
    if (facts.offline) {
      return const PlaybackSourcePlan(
        kind: PlaybackSourceKind.unavailable,
        reason: 'Offline and no local or cached copy',
      );
    }
    if (facts.hasProviderStream) {
      return const PlaybackSourcePlan(
        kind: PlaybackSourceKind.providerStream,
        reason: 'Provider stream available',
      );
    }
    if (facts.hasPreviewStream) {
      return const PlaybackSourcePlan(
        kind: PlaybackSourceKind.previewStream,
        reason: 'Falling back to preview stream',
      );
    }
    return const PlaybackSourcePlan(
      kind: PlaybackSourceKind.unavailable,
      reason: 'No local file, cache, provider stream, or preview',
    );
  }
}
