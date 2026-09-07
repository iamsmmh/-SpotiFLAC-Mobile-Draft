/// Typo correction for smart search (Phase 8).
///
/// Tiny Damerau-Levenshtein against a dictionary of recent / trending /
/// library tokens. Pure Dart, bounded so a 2-character query never walks
/// the whole catalog.
library;

import 'package:spotiflac_android/utils/fuzzy_match.dart';

/// One correction candidate.
class TypoCorrection {
  const TypoCorrection({
    required this.token,
    required this.distance,
    required this.score,
  });

  final String token;
  final int distance;
  final double score;
}

/// Corrects a query against [dictionary] tokens.
class TypoCorrector {
  const TypoCorrector({this.maxDistance = 2, this.minQueryLength = 3});

  final int maxDistance;
  final int minQueryLength;

  /// Best correction, or the original query when nothing is closer.
  String correct(String query, Iterable<String> dictionary) {
    final ranked = suggestions(query, dictionary, limit: 1);
    if (ranked.isEmpty) return query.trim();
    return ranked.first.token;
  }

  List<TypoCorrection> suggestions(
    String query,
    Iterable<String> dictionary, {
    int limit = 5,
  }) {
    final q = normalizeFuzzyText(query);
    if (q.length < minQueryLength) return const <TypoCorrection>[];
    final hits = <TypoCorrection>[];
    for (final raw in dictionary) {
      final token = normalizeFuzzyText(raw);
      if (token.isEmpty) continue;
      if ((token.length - q.length).abs() > maxDistance) continue;
      final distance = damerauLevenshtein(q, token, maxDistance: maxDistance);
      if (distance < 0 || distance > maxDistance) continue;
      final score = 1.0 - (distance / (q.length + 1));
      hits.add(
        TypoCorrection(token: raw.trim(), distance: distance, score: score),
      );
    }
    hits.sort((a, b) {
      final byDistance = a.distance.compareTo(b.distance);
      if (byDistance != 0) return byDistance;
      return b.score.compareTo(a.score);
    });
    if (hits.length > limit) return hits.sublist(0, limit);
    return hits;
  }

  /// Damerau-Levenshtein with a hard cap. Returns -1 when the distance
  /// would exceed [maxDistance] (early exit).
  static int damerauLevenshtein(
    String a,
    String b, {
    int maxDistance = 2,
  }) {
    if (a == b) return 0;
    if (a.isEmpty) return b.length > maxDistance ? -1 : b.length;
    if (b.isEmpty) return a.length > maxDistance ? -1 : a.length;
    if ((a.length - b.length).abs() > maxDistance) return -1;

    final rows = a.length + 1;
    final cols = b.length + 1;
    final prev = List<int>.generate(cols, (i) => i);
    final curr = List<int>.filled(cols, 0);
    var lastLast = List<int>.filled(cols, 0);

    for (var i = 1; i < rows; i++) {
      curr[0] = i;
      var rowMin = curr[0];
      for (var j = 1; j < cols; j++) {
        final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
        var value = prev[j - 1] + cost;
        final ins = curr[j - 1] + 1;
        final del = prev[j] + 1;
        if (ins < value) value = ins;
        if (del < value) value = del;
        if (i > 1 &&
            j > 1 &&
            a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
            a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1)) {
          final trans = lastLast[j - 2] + 1;
          if (trans < value) value = trans;
        }
        curr[j] = value;
        if (value < rowMin) rowMin = value;
      }
      if (rowMin > maxDistance) return -1;
      lastLast = List<int>.from(prev);
      for (var j = 0; j < cols; j++) {
        prev[j] = curr[j];
      }
    }
    final distance = prev[b.length];
    return distance > maxDistance ? -1 : distance;
  }
}
