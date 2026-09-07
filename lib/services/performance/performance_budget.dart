/// Performance budgets (Phase 16).
///
/// Search <150 ms, startup <2 s, UI frame 16.6 ms (60 fps). Pure policy so
/// tests can assert the constants and a stopwatch helper can flag overruns
/// without depending on Flutter.
library;

/// Named budget the runtime / tests compare against.
class PerformanceBudget {
  const PerformanceBudget({required this.name, required this.limit});

  final String name;
  final Duration limit;

  static const PerformanceBudget search = PerformanceBudget(
    name: 'search',
    limit: Duration(milliseconds: 150),
  );

  static const PerformanceBudget startup = PerformanceBudget(
    name: 'startup',
    limit: Duration(seconds: 2),
  );

  static const PerformanceBudget frame = PerformanceBudget(
    name: 'frame',
    limit: Duration(microseconds: 16667),
  );

  bool within(Duration elapsed) => !elapsed.isNegative && elapsed <= limit;
}

/// Records one measurement against a budget.
class PerformanceSample {
  const PerformanceSample({
    required this.budget,
    required this.elapsed,
  });

  final PerformanceBudget budget;
  final Duration elapsed;

  bool get ok => budget.within(elapsed);
}

/// Stopwatch helper. [clock] is injectable for tests.
class PerformanceProbe {
  PerformanceProbe({
    required this.budget,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final PerformanceBudget budget;
  final DateTime Function() _clock;
  DateTime? _started;

  void start({DateTime? now}) {
    _started = now ?? _clock();
  }

  PerformanceSample stop({DateTime? now}) {
    final started = _started ?? (now ?? _clock());
    final elapsed = (now ?? _clock()).difference(started);
    return PerformanceSample(budget: budget, elapsed: elapsed);
  }
}

/// Caps the working set the library / playlist screens may materialize.
class LibraryWorkingSet {
  const LibraryWorkingSet({
    this.maxTracks = 100000,
    this.maxPlaylistEntries = 10000,
    this.pageSize = 200,
  });

  final int maxTracks;
  final int maxPlaylistEntries;
  final int pageSize;

  int clampTrackCount(int count) =>
      count < 0 ? 0 : (count > maxTracks ? maxTracks : count);

  int clampPlaylistEntries(int count) => count < 0
      ? 0
      : (count > maxPlaylistEntries ? maxPlaylistEntries : count);
}
