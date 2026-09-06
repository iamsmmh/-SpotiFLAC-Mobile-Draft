/// Unified search (Feature Group: search) — aggregator + ranking over
/// every search surface the app has.
///
/// Pure Dart, no I/O: sources register as async callbacks and the engine
/// fans out with a per-source budget, merges, de-duplicates by canonical
/// text identity and returns ranked results. The Riverpod layer
/// (`providers/unified_search_provider.dart`) binds real sources —
/// local library, downloads, extension providers, streaming adapters,
/// self-hosted servers, podcasts — without this file knowing any of them.
///
/// Ranking combines three signals, mirroring how the big services blend:
///   * text relevance   — the on-device fuzzy scorer (`utils/fuzzy_match`)
///   * source authority — local > downloads > servers > extension >
///                        podcasts > streaming previews (tunable weights)
///   * source score     — provider-declared relevance (position in the
///                        provider's own result list), 0..1
library;

import 'package:spotimusic/models/track.dart';
import 'package:spotimusic/utils/fuzzy_match.dart';

/// Where a result came from.
enum UnifiedSearchSourceKind {
  localLibrary('Library'),
  downloads('Downloads'),
  extension('Extension'),
  streaming('Streaming'),
  server('Server'),
  podcast('Podcast');

  const UnifiedSearchSourceKind(this.label);

  final String label;

  /// Default authority weight (higher wins ties).
  double get defaultWeight => switch (this) {
    UnifiedSearchSourceKind.localLibrary => 1.0,
    UnifiedSearchSourceKind.downloads => 0.95,
    UnifiedSearchSourceKind.server => 0.8,
    UnifiedSearchSourceKind.extension => 0.7,
    UnifiedSearchSourceKind.streaming => 0.6,
    UnifiedSearchSourceKind.podcast => 0.5,
  };
}

/// One normalized search result, independent of where it came from.
class UnifiedSearchItem {
  const UnifiedSearchItem({
    required this.kind,
    required this.sourceId,
    required this.title,
    required this.subtitle,
    this.imageUrl,
    this.track,
    this.sourceScore = 0.5,
    this.playableLocally = false,
  });

  final UnifiedSearchSourceKind kind;
  final String sourceId;
  final String title;
  final String subtitle;
  final String? imageUrl;

  /// The app [Track] currency when the result is playable through the
  /// existing queue/playback path (null for e.g. pure podcast episodes).
  final Track? track;

  /// Relevance inside the producing source (0..1, best first).
  final double sourceScore;

  /// Local file already on the device (library/download hit).
  final bool playableLocally;

  String get identityKey {
    final track = this.track;
    if (track != null) {
      final isrc = track.isrc?.trim() ?? '';
      if (isrc.length >= 8) return 'isrc:${isrc.toLowerCase()}';
    }
    return '${normalizeFuzzyText(title)}|${normalizeFuzzyText(subtitle)}';
  }
}

/// A registered search surface.
class UnifiedSearchSource {
  const UnifiedSearchSource({
    required this.id,
    required this.kind,
    required this.search,
    this.weight,
    this.perSourceLimit = 20,
  });

  final String id;
  final UnifiedSearchSourceKind kind;

  /// Never throws for "no results"; errors surface as empty results so
  /// one dead server cannot blank the whole search.
  final Future<List<UnifiedSearchItem>> Function(String query) search;

  /// Overrides the kind's default authority weight.
  final double? weight;

  final int perSourceLimit;
}

/// Ranked output row.
class UnifiedSearchResult {
  const UnifiedSearchResult({
    required this.item,
    required this.score,
    required this.textScore,
    required this.sourceWeight,
  });

  final UnifiedSearchItem item;
  final double score;
  final double textScore;
  final double sourceWeight;
}

/// Pure ranking logic, unit-tested in isolation.
class SearchRankingService {
  const SearchRankingService({this.textWeight = 0.6, this.sourceWeight = 0.4});

  final double textWeight;
  final double sourceWeight;

  double score(UnifiedSearchItem item, String query) {
    final primary = fuzzyScore(query, item.title);
    final secondary = item.subtitle.isEmpty
        ? 0.0
        : fuzzyScore(query, item.subtitle) * 0.5;
    final text = primary > secondary ? primary : secondary;
    final weight = item.sourceScore.clamp(0.0, 1.0);
    return text * textWeight + weight * sourceWeight;
  }

  List<UnifiedSearchResult> rank(
    List<UnifiedSearchItem> items,
    String query, {
    int limit = 40,
  }) {
    final ranked = <UnifiedSearchResult>[];
    for (final item in items) {
      final kindWeight = item.kind.defaultWeight;
      final score = this.score(item, query) * 0.8 + kindWeight * 0.2;
      ranked.add(
        UnifiedSearchResult(
          item: item,
          score: score,
          textScore: fuzzyScore(query, item.title),
          sourceWeight: kindWeight,
        ),
      );
    }
    ranked.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      return a.item.title.toLowerCase().compareTo(b.item.title.toLowerCase());
    });
    if (ranked.length > limit) return ranked.sublist(0, limit);
    return ranked;
  }
}

/// Merges + de-duplicates across sources. Identity: ISRC when both sides
/// carry one, otherwise normalized title+subtitle. Local copies always
/// win the dedupe (they play instantly, offline).
class SearchAggregator {
  const SearchAggregator();

  List<UnifiedSearchItem> aggregate(
    List<List<UnifiedSearchItem>> sourceResults,
  ) {
    final byIdentity = <String, UnifiedSearchItem>{};
    final order = <String>[];
    for (final results in sourceResults) {
      for (final item in results) {
        final key = item.identityKey;
        final existing = byIdentity[key];
        if (existing == null) {
          byIdentity[key] = item;
          order.add(key);
          continue;
        }
        byIdentity[key] = _merge(existing, item);
      }
    }
    return <UnifiedSearchItem>[for (final key in order) byIdentity[key]!];
  }

  UnifiedSearchItem _merge(UnifiedSearchItem a, UnifiedSearchItem b) {
    // Prefer a local representation, then higher-authority kinds, then the
    // richer track payload.
    final aLocal = a.playableLocally;
    final bLocal = b.playableLocally;
    if (aLocal != bLocal) return aLocal ? a : b;
    if (a.kind.defaultWeight != b.kind.defaultWeight) {
      return a.kind.defaultWeight > b.kind.defaultWeight ? a : b;
    }
    final aTrack = a.track;
    final bTrack = b.track;
    if ((aTrack == null) != (bTrack == null)) return aTrack != null ? a : b;
    return a.sourceScore >= b.sourceScore ? a : b;
  }
}

/// Outcome of one engine run: ranked rows + which sources answered.
class UnifiedSearchOutcome {
  const UnifiedSearchOutcome({
    required this.results,
    required this.respondedSourceIds,
    required this.failedSourceIds,
  });

  final List<UnifiedSearchResult> results;
  final Set<String> respondedSourceIds;
  final Set<String> failedSourceIds;
}

/// Orchestrates one fan-out search across all sources.
class UnifiedSearchEngine {
  UnifiedSearchEngine({
    List<UnifiedSearchSource> sources = const <UnifiedSearchSource>[],
    SearchRankingService ranking = const SearchRankingService(),
    SearchAggregator aggregator = const SearchAggregator(),
    this.timeout = const Duration(seconds: 4),
  }) : _sources = <UnifiedSearchSource>[...sources],
       _ranking = ranking,
       _aggregator = aggregator;

  final List<UnifiedSearchSource> _sources;
  final SearchRankingService _ranking;
  final SearchAggregator _aggregator;
  final Duration timeout;

  List<UnifiedSearchSource> get sources =>
      List<UnifiedSearchSource>.unmodifiable(_sources);

  void register(UnifiedSearchSource source) {
    unregister(source.id);
    _sources.add(source);
  }

  void unregister(String id) {
    _sources.removeWhere((source) => source.id == id);
  }

  /// Runs [query] against every source concurrently. Slow/failing sources
  /// degrade to empty results after [timeout]; they never fail the run.
  Future<UnifiedSearchOutcome> search(
    String query, {
    int limit = 40,
    Duration? perSourceTimeout,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return UnifiedSearchOutcome(
        results: const <UnifiedSearchResult>[],
        respondedSourceIds: const <String>{},
        failedSourceIds: const <String>{},
      );
    }
    final budget = perSourceTimeout ?? timeout;
    final responded = <String>{};
    final failed = <String>{};

    final futures = <Future<List<UnifiedSearchItem>>>[
      for (final source in _sources) _runSource(source, trimmed, budget, responded, failed),
    ];
    final collected = await Future.wait(futures);

    final merged = _aggregator.aggregate(collected);
    final ranked = _ranking.rank(merged, trimmed, limit: limit);
    return UnifiedSearchOutcome(
      results: ranked,
      respondedSourceIds: responded,
      failedSourceIds: failed,
    );
  }

  Future<List<UnifiedSearchItem>> _runSource(
    UnifiedSearchSource source,
    String query,
    Duration budget,
    Set<String> responded,
    Set<String> failed,
  ) async {
    try {
      final results = await source.search(query).timeout(budget);
      responded.add(source.id);
      if (results.length <= source.perSourceLimit) return results;
      return results.sublist(0, source.perSourceLimit);
    } catch (_) {
      failed.add(source.id);
      return const <UnifiedSearchItem>[];
    }
  }
}
