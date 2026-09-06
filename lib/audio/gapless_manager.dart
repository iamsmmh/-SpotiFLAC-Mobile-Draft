/// Gapless manager (premium audio engine, Phase 1).
///
/// Wraps the existing [GaplessPolicy] with the runtime pieces the policy
/// deliberately leaves out:
///
///   * **Album playback optimization** — consecutive items of the same album
///     are detected up front ([albumRuns]) so the player can treat a run as
///     one continuous splice instead of per-track decisions.
///   * **Queue-wide planning** — one pass over the queue produces every
///     transition decision, which the preloader and the crossfade both reuse.
///   * **Runtime telemetry** — how many transitions actually spliced vs.
///     pre-buffered, so the settings surface can report honest numbers.
library;

import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/gapless_policy.dart';

/// A maximal run of queue items that belong to the same album (same album key
/// and transport family). Runs of length >= 2 are gapless-eligible as a
/// whole: within a run, transitions plan with `sameAlbum: true`, which the
/// smart crossfade treats as "do not fade across album continuity".
class AlbumRun {
  final int startIndex;

  /// Exclusive end index.
  final int endIndex;

  const AlbumRun({required this.startIndex, required this.endIndex});

  int get length => endIndex - startIndex;

  bool contains(int index) => index >= startIndex && index < endIndex;
}

/// Minimal facts the planner needs per queue item. Kept as an interface so
/// `PlayableMedia` (which already carries everything) needs no conversion.
abstract interface class GaplessQueueItem {
  String get id;

  String get album;

  AudioCharacteristics get characteristics;

  /// Whether the item plays from the same transport family as its neighbours
  /// (local file vs. progressive stream vs. deferred stream).
  bool get isRemote;
}

/// Result of planning one transition between queue item [index] and
/// [index + 1].
class GaplessTransition {
  final int index;

  final GaplessDecision decision;

  /// True when both items sit inside one album run.
  final bool sameAlbum;

  const GaplessTransition({
    required this.index,
    required this.decision,
    required this.sameAlbum,
  });
}

/// Counters for the settings/diagnostics surface.
class GaplessStats {
  int seamless = 0;
  int prebuffered = 0;
  int skipped = 0;

  void record(GaplessDecision decision) {
    switch (decision.kind) {
      case GaplessTransitionKind.seamless:
        seamless++;
        break;
      case GaplessTransitionKind.prebuffer:
        prebuffered++;
        break;
      case GaplessTransitionKind.disabled:
        skipped++;
        break;
    }
  }

  int get total => seamless + prebuffered + skipped;
}

/// The manager.
class GaplessManager {
  bool enabled = true;

  final GaplessStats stats = GaplessStats();

  final GaplessPolicy _policy = const GaplessPolicy();

  /// Configures the master switch. Returns true when it changed.
  bool configure({required bool enabled}) {
    final changed = this.enabled != enabled;
    this.enabled = enabled;
    return changed;
  }

  /// Detects album runs over [items]. Two neighbours group when their album
  /// keys match and their transport family matches (local vs. remote) — a
  /// local→stream hop breaks continuity even inside one album.
  static List<AlbumRun> albumRuns(List<GaplessQueueItem> items) {
    final runs = <AlbumRun>[];
    var start = 0;
    for (var i = 1; i <= items.length; i++) {
      final breaks = i == items.length ||
          items[i].album != items[start].album ||
          items[i].isRemote != items[start].isRemote;
      if (breaks) {
        if (i - start >= 2) runs.add(AlbumRun(startIndex: start, endIndex: i));
        start = i;
      }
    }
    return runs;
  }

  static bool _inRun(List<AlbumRun> runs, int index) {
    for (final run in runs) {
      if (run.contains(index)) return true;
    }
    return false;
  }

  /// Plans every transition of [items] in one pass.
  List<GaplessTransition> planQueue(
    List<GaplessQueueItem> items, {
    bool repeatOne = false,
  }) {
    final runs = albumRuns(items);
    final transitions = <GaplessTransition>[];
    for (var i = 0; i + 1 < items.length; i++) {
      final current = items[i];
      final next = items[i + 1];
      final sameAlbum = _inRun(runs, i) && _inRun(runs, i + 1);
      final decision = _policy.decide(
        enabled: enabled && !repeatOne,
        current: current.characteristics,
        next: next.characteristics,
        sameTransport: current.isRemote == next.isRemote,
      );
      transitions.add(
        GaplessTransition(index: i, decision: decision, sameAlbum: sameAlbum),
      );
    }
    return transitions;
  }

  /// Decision for one live transition (the per-track path the audio service
  /// evaluates as the queue advances). Records the outcome in [stats].
  GaplessDecision decideNext({
    required GaplessQueueItem current,
    required GaplessQueueItem next,
    required bool sameAlbum,
  }) {
    final decision = _policy.decide(
      enabled: enabled,
      current: current.characteristics,
      next: next.characteristics,
      sameTransport: current.isRemote == next.isRemote,
    );
    stats.record(decision);
    return decision;
  }

  void resetStats() {
    stats.seamless = 0;
    stats.prebuffered = 0;
    stats.skipped = 0;
  }
}
