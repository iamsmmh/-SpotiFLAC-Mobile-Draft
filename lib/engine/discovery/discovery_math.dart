/// Shared maths for the discovery engines.
///
/// Pure Dart, no state: every function here is deterministic for a given
/// input plus an explicit `now`, which is what makes the whole suite
/// unit-testable without a clock or a database.
library;

import 'dart:math' as math;

/// Clamps [value] into `0..1`.
double clamp01(double value) => value.isNaN ? 0 : value.clamp(0.0, 1.0);

/// Clamps [value] into `0..100` — the recommendation score contract.
double clampScore(double value) =>
    value.isNaN ? 0 : value.clamp(0.0, 100.0);

/// Exponential time decay with a configurable half-life.
///
/// `1.0` for "just now", `0.5` after one half-life, `0.25` after two. Used by
/// every recency term so a single play yesterday still matters but a play from
/// a year ago is nearly forgotten.
double timeDecay(DateTime event, DateTime now, {required Duration halfLife}) {
  final halfLifeMs = halfLife.inMilliseconds.toDouble();
  if (halfLifeMs <= 0) return 0;
  final ageMs = now.difference(event).inMilliseconds.toDouble();
  if (ageMs <= 0) return 1;
  return math.exp(-0.6931471805599453 * ageMs / halfLifeMs);
}

/// Log-scaled count normalisation: `log1p(count) / log1p(reference)`, clamped.
///
/// Linear counts let a single viral track dominate a profile; the log keeps a
/// 30-play favourite clearly ahead of a 3-play one without flattening the tail.
double logScaledCount(int count, {required int reference}) {
  if (count <= 0) return 0;
  if (reference <= 0) return 0;
  final value = math.log(1 + count) / math.log(1 + reference);
  return clamp01(value);
}

/// Cosine similarity between two sparse weight vectors keyed by token.
///
/// Returns `0` when either side is empty. Self-similarity is `1`.
double cosineSimilarity(
  Map<String, double> a,
  Map<String, double> b,
) {
  if (a.isEmpty || b.isEmpty) return 0;
  // Iterate the smaller map: cosine is symmetric and this halves the work on
  // the typical (one candidate vs. a large profile) shape.
  final small = a.length <= b.length ? a : b;
  final large = identical(small, a) ? b : a;
  var dot = 0.0;
  for (final entry in small.entries) {
    final other = large[entry.key];
    if (other == null) continue;
    dot += entry.value * other;
  }
  if (dot <= 0) return 0;
  var normA = 0.0;
  for (final value in a.values) {
    normA += value * value;
  }
  var normB = 0.0;
  for (final value in b.values) {
    normB += value * value;
  }
  if (normA <= 0 || normB <= 0) return 0;
  return clamp01(dot / math.sqrt(normA * normB));
}

/// Jaccard index of two sets: `|A ∩ B| / |A ∪ B|`.
double jaccardSimilarity(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  // Always iterate the smaller set for the intersection.
  final small = a.length <= b.length ? a : b;
  final large = identical(small, a) ? b : a;
  var intersection = 0;
  for (final value in small) {
    if (large.contains(value)) intersection++;
  }
  if (intersection == 0) return 0;
  final union = a.length + b.length - intersection;
  return union <= 0 ? 0 : intersection / union;
}

/// Weighted overlap coefficient: `Σ min(wA, wB) / min(ΣwA, ΣwB)`.
///
/// Softer than cosine for short lists — a candidate that matches the user's
/// single strongest genre scores high even though the cosine denominator is
/// dominated by the profile's breadth.
double weightedOverlap(
  Map<String, double> a,
  Map<String, double> b,
) {
  if (a.isEmpty || b.isEmpty) return 0;
  final small = a.length <= b.length ? a : b;
  final large = identical(small, a) ? b : a;
  var overlap = 0.0;
  for (final entry in small.entries) {
    final other = large[entry.key];
    if (other == null) continue;
    overlap += math.min(entry.value, other);
  }
  if (overlap <= 0) return 0;
  var sumA = 0.0;
  for (final value in a.values) {
    sumA += value;
  }
  var sumB = 0.0;
  for (final value in b.values) {
    sumB += value;
  }
  final denominator = math.min(sumA, sumB);
  return denominator <= 0 ? 0 : clamp01(overlap / denominator);
}

/// L2-normalises a weight map in place-free fashion (returns a new map).
///
/// Values are scaled so the largest is `1`, which keeps cosine comparable
/// across candidates with wildly different absolute play counts.
Map<String, double> peakNormalise(Map<String, double> source) {
  if (source.isEmpty) return const <String, double>{};
  var peak = 0.0;
  for (final value in source.values) {
    if (value > peak) peak = value;
  }
  if (peak <= 0) {
    return <String, double>{for (final key in source.keys) key: 0};
  }
  return <String, double>{
    for (final entry in source.entries) entry.key: entry.value / peak,
  };
}

/// Sums [source] into [target], adding weights for shared keys.
void accumulateWeights(
  Map<String, double> target,
  Map<String, double> source, {
  double scale = 1,
}) {
  if (scale == 0) return;
  for (final entry in source.entries) {
    target[entry.key] = (target[entry.key] ?? 0) + entry.value * scale;
  }
}

/// FNV-1a hash, the same mixer `LocalRecommendationEngine` uses for its daily
/// seed so rotation is stable across engines within a day.
int fnv1a(String value, {int seed = 0x811c9dc5}) {
  var hash = seed & 0x7fffffff;
  for (final unit in value.codeUnits) {
    hash = (hash ^ unit) * 0x01000193;
    hash &= 0x7fffffff;
  }
  return hash;
}

/// Deterministic pseudo-random in `0..1` from a [seed] and a [salt].
///
/// Shuffling must be reproducible: the same day (or the same radio session)
/// has to produce the same order on every launch, otherwise a cached shelf
/// would reshuffle under the user's fingers between reads.
double seededRandom(int seed, String salt) {
  final mixed = fnv1a(salt, seed: seed);
  return (mixed % 100000) / 100000.0;
}

/// Stable shuffle of [items] driven by [seed]: same input, same output.
List<T> seededShuffle<T>(List<T> items, int seed) {
  final result = List<T>.of(items);
  for (var i = result.length - 1; i > 0; i--) {
    final r = seededRandom(seed, 'shuffle:$i:${result.length}');
    final j = (r * (i + 1)).floor().clamp(0, i);
    final tmp = result[i];
    result[i] = result[j];
    result[j] = tmp;
  }
  return result;
}

/// UTC day ordinal — the app-wide "what day is it" key.
int utcDayOrdinal(DateTime at) {
  final utc = at.toUtc();
  return DateTime.utc(
    utc.year,
    utc.month,
    utc.day,
  ).millisecondsSinceEpoch ~/ Duration.millisecondsPerDay;
}

/// `YYYY-MM-DD` in UTC. Matches `ListeningStats.dayKey`.
String dayKey(DateTime at) {
  final utc = at.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

/// ISO-8601 week key (`2026-W37`) in UTC.
///
/// Discover Weekly refreshes on Monday, so the week boundary has to be the ISO
/// one (weeks start Monday) rather than the `DateTime.weekday`-naive one.
String isoWeekKey(DateTime at) {
  final utc = DateTime.utc(at.year, at.month, at.day);
  // Thursday of the current ISO week determines the year the week belongs to.
  final thursday = utc.add(Duration(days: DateTime.thursday - utc.weekday));
  final yearStart = DateTime.utc(thursday.year);
  final week = ((thursday.difference(yearStart).inDays) / 7).floor() + 1;
  return '${thursday.year}-W${week.toString().padLeft(2, '0')}';
}

/// Monday 00:00 UTC of the week containing [at] — the Discover Weekly anchor.
DateTime startOfWeek(DateTime at) {
  final utc = DateTime.utc(at.year, at.month, at.day);
  return utc.subtract(Duration(days: utc.weekday - DateTime.monday));
}

/// Mean of a list; `0` when empty (never NaN into a score).
double meanOf(Iterable<double> values) {
  var sum = 0.0;
  var count = 0;
  for (final value in values) {
    sum += value;
    count++;
  }
  return count == 0 ? 0 : sum / count;
}

/// Median of a list; `0` when empty.
double medianOf(Iterable<int> values) {
  if (values.isEmpty) return 0;
  final sorted = values.toList()..sort();
  final middle = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[middle].toDouble();
  return (sorted[middle - 1] + sorted[middle]) / 2.0;
}
