/// Search suggestions + recents + trending (Phase 8).
library;

import 'package:spotiflac_android/services/search/typo_corrector.dart';
import 'package:spotiflac_android/utils/fuzzy_match.dart';

/// Where a suggestion came from.
enum SuggestionSource { recent, trending, library, correction }

/// One suggestion chip / dropdown row.
class SearchSuggestion {
  const SearchSuggestion({
    required this.text,
    required this.source,
    required this.score,
  });

  final String text;
  final SuggestionSource source;
  final double score;
}

/// Fuses recents, trending and fuzzy library hits, with typo correction.
class SearchSuggestionEngine {
  const SearchSuggestionEngine({
    this.corrector = const TypoCorrector(),
    this.limit = 8,
  });

  final TypoCorrector corrector;
  final int limit;

  List<SearchSuggestion> suggest({
    required String query,
    List<String> recent = const <String>[],
    List<String> trending = const <String>[],
    List<String> library = const <String>[],
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      final chips = <SearchSuggestion>[
        for (final item in recent.take(limit))
          SearchSuggestion(
            text: item,
            source: SuggestionSource.recent,
            score: 1,
          ),
      ];
      if (chips.length < limit) {
        for (final item in trending) {
          if (chips.length >= limit) break;
          chips.add(
            SearchSuggestion(
              text: item,
              source: SuggestionSource.trending,
              score: 0.8,
            ),
          );
        }
      }
      return List<SearchSuggestion>.unmodifiable(chips);
    }

    final dictionary = <String>{...recent, ...trending, ...library};
    final corrections = corrector.suggestions(trimmed, dictionary, limit: 3);
    final hits = <SearchSuggestion>[];
    final seen = <String>{};

    void add(String text, SuggestionSource source, double score) {
      final key = normalizeFuzzyText(text);
      if (key.isEmpty || !seen.add(key)) return;
      hits.add(SearchSuggestion(text: text, source: source, score: score));
    }

    for (final correction in corrections) {
      add(correction.token, SuggestionSource.correction, correction.score);
    }
    for (final item in recent) {
      final score = fuzzyScore(trimmed, item);
      if (score >= kFuzzyMatchThreshold) {
        add(item, SuggestionSource.recent, score + 0.05);
      }
    }
    for (final item in trending) {
      final score = fuzzyScore(trimmed, item);
      if (score >= kFuzzyMatchThreshold) {
        add(item, SuggestionSource.trending, score);
      }
    }
    for (final item in library) {
      final score = fuzzyScore(trimmed, item);
      if (score >= kFuzzyMatchThreshold) {
        add(item, SuggestionSource.library, score);
      }
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    if (hits.length > limit) {
      return List<SearchSuggestion>.unmodifiable(hits.sublist(0, limit));
    }
    return List<SearchSuggestion>.unmodifiable(hits);
  }
}
