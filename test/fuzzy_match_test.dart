import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/fuzzy_match.dart';

void main() {
  group('normalizeFuzzyText', () {
    test('lowercases, trims and folds diacritics', () {
      expect(normalizeFuzzyText('  Beyoncé '), 'beyonce');
      expect(normalizeFuzzyText('Sigur Rós'), 'sigur ros');
      expect(normalizeFuzzyText('Motörhead'), 'motorhead');
      expect(normalizeFuzzyText('ß'), 'ss');
    });

    test('preserves non-latin scripts untouched', () {
      expect(normalizeFuzzyText('米津玄師'), '米津玄師');
    });
  });

  group('fuzzyScore', () {
    test('exact match scores 1.0', () {
      expect(fuzzyScore('Blinding Lights', 'blinding lights'), 1.0);
    });

    test('prefix match reaches at least the prefix floor', () {
      final score = fuzzyScore('blind', 'Blinding Lights');
      expect(score, greaterThanOrEqualTo(kPrefixFloor));
      expect(score, lessThan(1.0));
    });

    test('longer prefix-candidates score slightly lower', () {
      final shortCandidate = fuzzyScore('blind', 'Blind');
      final longCandidate = fuzzyScore('blind', 'Blinding Lights (Remix)');
      expect(shortCandidate, greaterThan(longCandidate));
    });

    test('subsequence matches score above zero', () {
      expect(fuzzyScore('bdl', 'Black Diamond Lady'), greaterThan(0));
    });

    test('word-boundary hits beat non-boundary hits at equal span', () {
      // Same coverage and compactness: only the word-start bonus separates
      // 'a |b' (b starts a word) from 'axb' (b is mid-word).
      final boundary = fuzzyScore('ab', 'a b');
      final midWord = fuzzyScore('ab', 'axb');
      expect(boundary, greaterThan(0));
      expect(boundary, greaterThan(midWord));
    });

    test('non-subsequence returns zero', () {
      expect(fuzzyScore('xyz', 'Blinding Lights'), 0.0);
    });

    test('empty query or candidate returns zero', () {
      expect(fuzzyScore('', 'song'), 0.0);
      expect(fuzzyScore('song', ''), 0.0);
      expect(fuzzyScore('   ', 'song'), 0.0);
    });

    test('query longer than candidate returns zero', () {
      expect(fuzzyScore('blinding lights deluxe edition', 'Blinding'), 0.0);
    });

    test('diacritics are transparent for matching', () {
      expect(fuzzyScore('beyonce', 'Beyoncé'), 1.0);
      expect(fuzzyScore('ros', 'Sigur Rós'), greaterThanOrEqualTo(kPrefixFloor));
    });
  });

  group('fuzzyRank', () {
    final songs = <String>[
      'Blinding Lights',
      'Save Your Tears',
      'Blue Lines',
      'Lights Out',
      'Daylight',
    ];

    test('orders best match first and applies threshold', () {
      final hits = fuzzyRank('light', songs, textOf: (item) => item);
      expect(hits, isNotEmpty);
      // Prefix candidates ('Daylight' → 0.85, 'Lights Out' → 0.80) outrank
      // the subsequence hit ('Blinding Lights' → ~0.40); non-matches drop.
      expect(hits.first.item, 'Daylight');
      expect(
        hits.map((hit) => hit.item),
        containsAll(<String>['Daylight', 'Lights Out', 'Blinding Lights']),
      );
      expect(
        hits.any((hit) => hit.item == 'Blue Lines'),
        isFalse,
        reason: "'light' is not a subsequence of 'blue lines'",
      );
      for (final hit in hits) {
        expect(hit.score, greaterThanOrEqualTo(kFuzzyMatchThreshold));
      }
    });

    test('secondary field contributes at half weight', () {
      final tracks = <(String, String)>[
        ('Song A', 'The Weeknd'),
        ('Weekend Vibes', 'Another Artist'),
      ];
      final hits = fuzzyRank(
        'weeknd',
        tracks,
        textOf: (item) => item.$1,
        secondaryTextOf: (item) => item.$2,
      );
      expect(hits, isNotEmpty);
      // The title match "Weekend Vibes" should outrank the artist-only hit.
      expect(hits.first.item.$1, 'Weekend Vibes');
      expect(hits.any((hit) => hit.item.$2 == 'The Weeknd'), isTrue);
    });

    test('respects the limit', () {
      final many = List<String>.generate(50, (i) => 'track $i light');
      final hits = fuzzyRank('light', many, textOf: (item) => item, limit: 5);
      expect(hits.length, 5);
    });

    test('empty query yields no hits', () {
      expect(fuzzyRank('', songs, textOf: (item) => item), isEmpty);
    });
  });
}
