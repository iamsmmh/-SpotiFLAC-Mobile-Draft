import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/recommendation_scorer.dart';

/// Phase 2: weighted recommendation scoring.
///
/// Everything here is pure Dart (`lib/engine/discovery/` imports only `dart:`
/// libraries), so the suite needs no plugin, no database and no clock — `now`
/// is always passed in.
void main() {
  final now = DateTime.utc(2026, 9, 6, 12);

  DiscoveryTrack track(
    String id, {
    List<String> genres = const <String>[],
    List<String> tags = const <String>[],
    String? localPath,
  }) {
    return DiscoveryTrack(
      key: 'isrc:$id',
      title: id,
      artist: 'Artist $id',
      artistKey: 'e:artist-$id',
      genres: genres,
      tags: tags,
      localPath: localPath,
      durationMs: 210000,
    );
  }

  TrackSignals signals(
    String key, {
    required int plays,
    int skips = 0,
    required DateTime lastPlayedAt,
    bool isFavorite = false,
  }) {
    return TrackSignals(
      trackKey: key,
      playCount: plays,
      skipCount: skips,
      completedCount: plays - skips,
      completionSum: (plays - skips).toDouble(),
      firstPlayedAt: lastPlayedAt.subtract(const Duration(days: 30)),
      lastPlayedAt: lastPlayedAt,
      isFavorite: isFavorite,
    );
  }

  group('discovery math', () {
    test('clamp01 and clampScore never leak NaN or out-of-range values', () {
      expect(clamp01(double.nan), 0);
      expect(clamp01(1.4), 1);
      expect(clamp01(-0.2), 0);
      expect(clampScore(double.nan), 0);
      expect(clampScore(140), 100);
      expect(clampScore(-3), 0);
    });

    test('timeDecay halves exactly once per half-life', () {
      const halfLife = Duration(days: 21);
      expect(timeDecay(now, now, halfLife: halfLife), 1);
      expect(
        timeDecay(now.subtract(halfLife), now, halfLife: halfLife),
        closeTo(0.5, 1e-9),
      );
      expect(
        timeDecay(now.subtract(halfLife * 2), now, halfLife: halfLife),
        closeTo(0.25, 1e-9),
      );
      // A future-dated event must not blow the score up past 1.
      expect(
        timeDecay(now.add(const Duration(days: 40)), now, halfLife: halfLife),
        1,
      );
      // A degenerate half-life must return 0, never Infinity.
      expect(timeDecay(now.subtract(const Duration(days: 1)), now, halfLife: Duration.zero), 0);
    });

    test('logScaledCount is monotonic and reaches 1 at the reference', () {
      expect(logScaledCount(0, reference: 24), 0);
      expect(logScaledCount(24, reference: 24), closeTo(1, 1e-9));
      expect(
        logScaledCount(3, reference: 24),
        lessThan(logScaledCount(30, reference: 24)),
      );
      // Above the reference it saturates instead of exceeding 1.
      expect(logScaledCount(240, reference: 24), 1);
      expect(logScaledCount(5, reference: 0), 0);
    });

    test('cosine, jaccard and peakNormalise behave on the edge cases', () {
      expect(cosineSimilarity(<String, double>{}, <String, double>{'a': 1}), 0);
      expect(cosineSimilarity(<String, double>{'a': 1}, <String, double>{'a': 3}), 1);
      expect(cosineSimilarity(<String, double>{'a': 1}, <String, double>{'b': 1}), 0);
      expect(jaccardSimilarity(<String>{'a', 'b'}, <String>{'b', 'c'}), closeTo(1 / 3, 1e-9));
      expect(jaccardSimilarity(<String>{}, <String>{'a'}), 0);

      final normalised = peakNormalise(<String, double>{'a': 4, 'b': 1});
      expect(normalised['a'], closeTo(1, 1e-9));
      expect(normalised['b'], closeTo(0.25, 1e-9));
      expect(peakNormalise(<String, double>{}), isEmpty);
      // All-zero input must not produce NaNs.
      expect(peakNormalise(<String, double>{'a': 0})['a'], 0);
    });

    test('day, week and Monday anchors are UTC and ISO-8601', () {
      expect(dayKey(DateTime.utc(2026, 9, 6, 23, 59)), '2026-09-06');
      // 2026-09-06 is a Sunday, so it belongs to the week that started
      // Monday 2026-08-31 — ISO week 36.
      expect(startOfWeek(DateTime.utc(2026, 9, 6)), DateTime.utc(2026, 8, 31));
      expect(isoWeekKey(DateTime.utc(2026, 9, 6)), '2026-W36');
      expect(isoWeekKey(DateTime.utc(2026, 8, 31)), '2026-W36');
      expect(isoWeekKey(DateTime.utc(2026, 9, 7)), '2026-W37');
      expect(utcDayOrdinal(DateTime.utc(2026, 9, 6, 1)), utcDayOrdinal(DateTime.utc(2026, 9, 6, 23)));
    });

    test('meanOf and medianOf return 0 for empty input', () {
      expect(meanOf(<double>[]), 0);
      expect(medianOf(<int>[]), 0);
      expect(meanOf(<double>[1, 2, 3]), 2);
      expect(medianOf(<int>[3, 1, 2]), 2);
      expect(medianOf(<int>[1, 2, 3, 4]), 2.5);
    });

    test('seededShuffle is a deterministic permutation', () {
      final source = List<int>.generate(20, (i) => i);
      final a = seededShuffle(source, 12345);
      final b = seededShuffle(source, 12345);
      expect(a, orderedEquals(b));
      expect(a.toSet(), source.toSet());
      expect(a.length, source.length);
      // A different seed must produce a different order for a list this size.
      expect(seededShuffle(source, 54321), isNot(orderedEquals(a)));
    });
  });

  group('RecommendationWeights', () {
    test('the three shipped presets are normalised', () {
      for (final weights in <RecommendationWeights>[
        const RecommendationWeights.standard(),
        const RecommendationWeights.replay(),
        const RecommendationWeights.discovery(),
      ]) {
        expect(weights.isNormalised, isTrue);
        expect(weights.sum, closeTo(1, 0.001));
      }
    });

    test('replay favours frequency, discovery favours similarity', () {
      const replay = RecommendationWeights.replay();
      const discovery = RecommendationWeights.discovery();
      expect(replay.frequency, greaterThan(replay.similarity));
      expect(discovery.similarity, greaterThan(discovery.frequency));
    });

    test('ratio() normalises and survives degenerate input', () {
      final weights = RecommendationWeights.ratio(
        recency: 25,
        frequency: 25,
        favorite: 25,
        similarity: 25,
      );
      expect(weights.recency, closeTo(0.25, 1e-9));
      expect(weights.isNormalised, isTrue);

      // All-zero falls back to the shipped balance rather than scoring 0.
      final fallback = RecommendationWeights.ratio(
        recency: 0,
        frequency: 0,
        favorite: 0,
        similarity: 0,
      );
      expect(fallback.recency, const RecommendationWeights.standard().recency);

      // Negatives are clamped, never producing a negative weight.
      final clamped = RecommendationWeights.ratio(
        recency: -10,
        frequency: 0,
        favorite: 0,
        similarity: 10,
      );
      expect(clamped.recency, 0);
      expect(clamped.similarity, closeTo(1, 1e-9));
    });
  });

  group('RecommendationScorer', () {
    const scorer = RecommendationScorer();

    test('scores stay inside the 0..100 contract', () {
      final scored = scorer.scoreAll(
        <ScoringInput>[
          ScoringInput(
            track: track('max'),
            signals: signals('isrc:max', plays: 500, lastPlayedAt: now, isFavorite: true),
            genreSimilarity: 1,
            artistSimilarity: 1,
            albumSimilarity: 1,
            tagSimilarity: 1,
            coListenSimilarity: 1,
            playlistSimilarity: 1,
            isFavoriteArtist: true,
            isFavoriteAlbum: true,
            novelty: 1,
            offlinePlayable: true,
          ),
          ScoringInput(track: track('zero')),
        ],
        now: now,
      );
      for (final entry in scored) {
        expect(entry.score, greaterThanOrEqualTo(0));
        expect(entry.score, lessThanOrEqualTo(100));
      }
      expect(scored.first.score, 100, reason: 'the best possible input saturates');
      expect(scored.last.score, 0, reason: 'no signal at all scores nothing');
    });

    test('novelty and offline-playable are additive bonuses', () {
      final plain = scorer.score(ScoringInput(track: track('a')), now: now);
      final novel = scorer.score(
        ScoringInput(track: track('a'), novelty: 1),
        now: now,
      );
      final offline = scorer.score(
        ScoringInput(track: track('a'), offlinePlayable: true),
        now: now,
      );
      expect(novel.score - plain.score, closeTo(6, 1e-9));
      expect(offline.score - plain.score, closeTo(3, 1e-9));
    });

    test('a frequently skipped track is penalised', () {
      final loved = scorer.score(
        ScoringInput(
          track: track('loved'),
          signals: signals('isrc:loved', plays: 10, lastPlayedAt: now),
        ),
        now: now,
      );
      final skipped = scorer.score(
        ScoringInput(
          track: track('loved'),
          signals: signals(
            'isrc:loved',
            plays: 10,
            skips: 10,
            lastPlayedAt: now,
          ),
        ),
        now: now,
      );
      expect(loved.score, greaterThan(skipped.score));
    });

    test('recency lifts an otherwise identical candidate', () {
      final recent = scorer.score(
        ScoringInput(
          track: track('a'),
          signals: signals('isrc:a', plays: 10, lastPlayedAt: now),
        ),
        now: now,
      );
      final stale = scorer.score(
        ScoringInput(
          track: track('a'),
          signals: signals(
            'isrc:a',
            plays: 10,
            lastPlayedAt: now.subtract(const Duration(days: 300)),
          ),
        ),
        now: now,
      );
      expect(recent.score, greaterThan(stale.score));
    });

    test('similarity dominates for a never-played candidate', () {
      final unrelated = scorer.score(ScoringInput(track: track('a')), now: now);
      final related = scorer.score(
        ScoringInput(
          track: track('a'),
          genreSimilarity: 1,
          artistSimilarity: 1,
          tagSimilarity: 1,
          coListenSimilarity: 1,
          playlistSimilarity: 1,
        ),
        now: now,
      );
      expect(related.score, greaterThan(unrelated.score));
      expect(related.breakdown.similarity, greaterThan(0));
    });

    test('scoreAll sorts descending and breaks ties on title', () {
      final scored = scorer.scoreAll(
        <ScoringInput>[
          ScoringInput(track: track('zebra')),
          ScoringInput(track: track('apple')),
          ScoringInput(track: track('mango')),
        ],
        now: now,
      );
      // No signal at all, so all three tie on score and sort alphabetically.
      expect(scored.map((entry) => entry.track.title).toList(), <String>[
        'apple',
        'mango',
        'zebra',
      ]);
      expect(scored.length, 3);
    });

    test('limit truncates the ranking', () {
      final scored = scorer.scoreAll(
        <ScoringInput>[
          for (var i = 0; i < 12; i++)
            ScoringInput(track: track('t${i.toString().padLeft(2, '0')}')),
        ],
        now: now,
        limit: 5,
      );
      expect(scored.length, 5);
    });

    test('the breakdown exposes each weighted axis and a reason', () {
      final breakdown = scorer.breakdownFor(
        ScoringInput(
          track: track('a', genres: const <String>['jazz']),
          signals: signals('isrc:a', plays: 8, lastPlayedAt: now, isFavorite: true),
          genreSimilarity: 0.8,
        ),
        now: now,
      );
      expect(breakdown.recency, greaterThan(0));
      expect(breakdown.frequency, greaterThan(0));
      expect(breakdown.favorite, greaterThan(0));
      expect(breakdown.total, closeTo(
        breakdown.recency +
            breakdown.frequency +
            breakdown.favorite +
            breakdown.similarity,
        1e-9,
      ));
      expect(breakdown.reasons, isNotEmpty);
    });

    test('the discovery preset ranks an unheard similar track first', () {
      const discovery = RecommendationScorer(
        weights: RecommendationWeights.discovery(),
        noveltyBoost: 10,
      );
      final ranked = discovery.scoreAll(
        <ScoringInput>[
          ScoringInput(
            track: track('played-to-death'),
            signals: signals('isrc:played-to-death', plays: 60, lastPlayedAt: now),
          ),
          ScoringInput(
            track: track('hidden-gem'),
            genreSimilarity: 1,
            artistSimilarity: 1,
            novelty: 1,
          ),
        ],
        now: now,
      );
      expect(ranked.first.track.title, 'hidden-gem');
    });
  });

  group('DiscoveryTrack identity', () {
    test('isOfflinePlayable follows the local path only', () {
      expect(track('a').isOfflinePlayable, isFalse);
      expect(track('a', localPath: '/storage/music/a.flac').isOfflinePlayable, isTrue);
      expect(track('a', localPath: '').isOfflinePlayable, isFalse);
    });

    test('taxonomy is genres then tags', () {
      expect(
        track('a', genres: const <String>['jazz'], tags: const <String>['mellow']).taxonomy,
        <String>['jazz', 'mellow'],
      );
    });

    test('durationSeconds converts the millisecond field', () {
      expect(track('a').durationSeconds, 210);
    });
  });
}
