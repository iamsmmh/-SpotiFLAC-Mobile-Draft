/// Podcast / audiobook sleep timer (Phase 9).
///
/// Pure countdown: the player supplies [onFire] (typically `PodcastPlayer.pause`).
/// No Flutter timers here so unit tests can drive [tick] with a fake clock.
library;

/// How the timer ends.
enum SleepTimerMode {
  /// Fire after a fixed duration.
  duration,

  /// Fire when the current episode / chapter ends.
  endOfEpisode,
}

/// Mutable countdown. [remaining] is zero after it fires or is cancelled.
class SleepTimer {
  SleepTimer({
    this.mode = SleepTimerMode.duration,
    Duration duration = const Duration(minutes: 15),
    this.onFire,
    DateTime Function()? clock,
  })  : _duration = duration,
        _clock = clock ?? DateTime.now;

  SleepTimerMode mode;
  Duration _duration;
  final Future<void> Function()? onFire;
  final DateTime Function() _clock;

  DateTime? _deadline;
  bool _fired = false;
  bool _cancelled = false;

  Duration get duration => _duration;

  bool get isArmed => _deadline != null && !_fired && !_cancelled;

  bool get hasFired => _fired;

  Duration remaining({DateTime? now}) {
    if (!isArmed) return Duration.zero;
    final left = _deadline!.difference(now ?? _clock());
    return left.isNegative ? Duration.zero : left;
  }

  /// Starts (or restarts) the countdown.
  void arm({SleepTimerMode? mode, Duration? duration, DateTime? now}) {
    if (mode != null) this.mode = mode;
    if (duration != null) _duration = duration;
    _fired = false;
    _cancelled = false;
    if (this.mode == SleepTimerMode.endOfEpisode) {
      _deadline = null;
      return;
    }
    _deadline = (now ?? _clock()).add(_duration);
  }

  void cancel() {
    _cancelled = true;
    _deadline = null;
  }

  /// Called from a position stream. Returns true when it just fired.
  Future<bool> tick({
    DateTime? now,
    bool episodeEnded = false,
  }) async {
    if (_cancelled || _fired) return false;
    if (mode == SleepTimerMode.endOfEpisode) {
      if (!episodeEnded) return false;
      return _fire();
    }
    final deadline = _deadline;
    if (deadline == null) return false;
    if ((now ?? _clock()).isBefore(deadline)) return false;
    return _fire();
  }

  Future<bool> _fire() async {
    _fired = true;
    _deadline = null;
    final callback = onFire;
    if (callback != null) await callback();
    return true;
  }
}
