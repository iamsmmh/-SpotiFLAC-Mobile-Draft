/// Fuzzy text matching for local (on-device) search ranking.
///
/// Pure Dart: no Flutter, no I/O. Used by the search suggestion engine to rank
/// history entries and library items against a partial query. The scorer is a
/// subsequence matcher with arity for the three signals users actually notice:
///
///   * contiguity  — matched runs score higher than scattered hits
///   * word start  — hits on word boundaries (space/`-`/`(`/`[`) score higher
///   * coverage    — matching a larger fraction of the candidate scores higher
///
/// Scores are normalized to `0.0..1.0`; `0` means "no match". Prefix matches
/// are floored at [kPrefixFloor] so typing the beginning of a title always
/// surfaces it above incidental subsequence hits.
library;

/// Minimum score a candidate must reach to be considered a fuzzy hit at all.
const double kFuzzyMatchThreshold = 0.25;

/// Floor granted to case-insensitive prefix matches (after normalization).
const double kPrefixFloor = 0.6;

/// Normalizes [value] for matching: lowercase, trimmed, and with a small set
/// of Latin diacritics folded to their base letters so `beyoncé` matches
/// `beyonce`. Full Unicode decomposition would need a dependency; this covers
/// the ranges that appear in real catalogs (Latin-1 + Latin Extended-A).
String normalizeFuzzyText(String value) {
  final buffer = StringBuffer();
  for (final codeUnit in value.toLowerCase().trim().codeUnits) {
    buffer.write(_folded[codeUnit] ?? String.fromCharCode(codeUnit));
  }
  return buffer.toString();
}

const Map<int, String> _folded = <int, String>{
  0x00E0: 'a', 0x00E1: 'a', 0x00E2: 'a', 0x00E3: 'a', 0x00E4: 'a', 0x00E5: 'a',
  0x0101: 'a', 0x0103: 'a', 0x0105: 'a',
  0x00E7: 'c', 0x0107: 'c', 0x0109: 'c', 0x010B: 'c', 0x010D: 'c',
  0x010F: 'd', 0x0111: 'd',
  0x00E8: 'e', 0x00E9: 'e', 0x00EA: 'e', 0x00EB: 'e',
  0x0113: 'e', 0x0115: 'e', 0x0117: 'e', 0x0119: 'e', 0x011B: 'e',
  0x011D: 'g', 0x011F: 'g', 0x0121: 'g', 0x0123: 'g',
  0x0125: 'h', 0x0127: 'h',
  0x00EC: 'i', 0x00ED: 'i', 0x00EE: 'i', 0x00EF: 'i',
  0x0129: 'i', 0x012B: 'i', 0x012D: 'i', 0x012F: 'i', 0x0131: 'i',
  0x0135: 'j',
  0x0137: 'k', 0x0138: 'k',
  0x013A: 'l', 0x013C: 'l', 0x013E: 'l', 0x0140: 'l', 0x0142: 'l',
  0x00F1: 'n', 0x0144: 'n', 0x0146: 'n', 0x0148: 'n',
  0x00F2: 'o', 0x00F3: 'o', 0x00F4: 'o', 0x00F5: 'o', 0x00F6: 'o', 0x00F8: 'o',
  0x014D: 'o', 0x014F: 'o', 0x0151: 'o',
  0x0155: 'r', 0x0157: 'r', 0x0159: 'r',
  0x015B: 's', 0x015D: 's', 0x015F: 's', 0x0161: 's',
  0x0163: 't', 0x0165: 't', 0x0167: 't',
  0x00F9: 'u', 0x00FA: 'u', 0x00FB: 'u', 0x00FC: 'u',
  0x0169: 'u', 0x016B: 'u', 0x016D: 'u', 0x016F: 'u', 0x0171: 'u', 0x0173: 'u',
  0x0175: 'w',
  0x00FD: 'y', 0x00FF: 'y', 0x0177: 'y',
  0x017A: 'z', 0x017C: 'z', 0x017E: 'z',
  0x00DF: 'ss',
  0x00E6: 'ae', 0x0153: 'oe',
};

/// Scores [candidate] against [query].
///
/// Both sides are normalized with [normalizeFuzzyText]. Returns `0.0` when the
/// query is not a subsequence of the candidate; otherwise a value in
/// `(0, 1]` where higher means "more relevant".
double fuzzyScore(String query, String candidate) {
  final q = normalizeFuzzyText(query);
  final c = normalizeFuzzyText(candidate);
  if (q.isEmpty || c.isEmpty) return 0.0;
  if (q.length > c.length) return 0.0;

  // Exact and prefix fast paths.
  if (c == q) return 1.0;
  if (c.startsWith(q)) {
    // Longer candidates with the same prefix are slightly less relevant.
    final coverage = q.length / c.length;
    return kPrefixFloor + (1 - kPrefixFloor) * coverage;
  }

  // Contiguous substring fast path: the whole query appearing anywhere in
  // the candidate ('light' inside 'Daylight') is the next-strongest signal
  // after a prefix, so it gets the same floor scaled by coverage instead
  // of the subsequence walk (which would rank it below scattered hits).
  if (c.contains(q)) {
    return (kPrefixFloor + (1 - kPrefixFloor) * (q.length / c.length))
        .clamp(0.0, 1.0);
  }

  // Subsequence walk with contiguity + word-boundary bonuses.
  var qi = 0;
  var runLength = 0;
  var runScore = 0.0;
  var firstIndex = -1;
  var lastIndex = -1;
  for (var ci = 0; ci < c.length && qi < q.length; ci++) {
    if (c.codeUnitAt(ci) != q.codeUnitAt(qi)) {
      runLength = 0;
      continue;
    }
    runLength++;
    if (firstIndex < 0) firstIndex = ci;
    lastIndex = ci;

    var charScore = 1.0;
    if (runLength > 1) {
      charScore += 0.5; // contiguous run bonus
    }
    if (_isWordBoundary(c, ci)) {
      charScore += 0.75; // word-start bonus
    }
    runScore += charScore;
    qi++;
  }
  if (qi < q.length) return 0.0; // not a subsequence

  final coverage = q.length / c.length;
  final compactness =
      q.length / (lastIndex - firstIndex + 1); // spread penalty
  final raw = (runScore / (q.length * 2.25)) // 2.25 = max per-char score
      .clamp(0.0, 1.0);
  final score = raw * 0.5 + coverage * 0.25 + compactness * 0.25;
  return score.clamp(0.0, 1.0);
}

bool _isWordBoundary(String candidate, int index) {
  if (index == 0) return true;
  final previous = candidate.codeUnitAt(index - 1);
  const boundaries = <int>[
    0x20, // space
    0x2D, // -
    0x5F, // _
    0x28, // (
    0x5B, // [
    0x2E, // .
    0x2F, // /
    0x27, // '
  ];
  return boundaries.contains(previous);
}

/// One hit from [fuzzyRank]: the matched [item] and its [score].
class FuzzyHit<T> {
  const FuzzyHit({required this.item, required this.score});

  final T item;
  final double score;

  @override
  String toString() =>
      'FuzzyHit(${score.toStringAsFixed(3)}, $item)';
}

/// Ranks [items] against [query] (best first), dropping anything below
/// [kFuzzyMatchThreshold]. [textOf] extracts the primary match target;
/// [secondaryTextOf] (optional) supplies a second field (e.g. artist name)
/// whose best score contributes at half weight.
List<FuzzyHit<T>> fuzzyRank<T>(
  String query,
  Iterable<T> items, {
  required String Function(T item) textOf,
  String Function(T item)? secondaryTextOf,
  int limit = 20,
}) {
  if (normalizeFuzzyText(query).isEmpty || limit <= 0) {
    return <FuzzyHit<T>>[];
  }
  final hits = <FuzzyHit<T>>[];
  for (final item in items) {
    final primary = fuzzyScore(query, textOf(item));
    final secondary = secondaryTextOf == null
        ? 0.0
        : fuzzyScore(query, secondaryTextOf(item)) * 0.5;
    final score = primary > secondary ? primary : secondary;
    if (score >= kFuzzyMatchThreshold) {
      hits.add(FuzzyHit<T>(item: item, score: score));
    }
  }
  hits.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return textOf(a.item).toLowerCase().compareTo(textOf(b.item).toLowerCase());
  });
  if (hits.length > limit) {
    return hits.sublist(0, limit);
  }
  return hits;
}
