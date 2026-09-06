import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/unified_search.dart';
import 'package:spotiflac_android/models/track.dart';

Track _track(String id, String name) => Track(
  id: id,
  name: name,
  artistName: 'Artist',
  albumName: 'Album',
  duration: 200,
  isrc: id == 'with-isrc' ? 'FR34N1800001' : null,
);

void main() {
  group('SearchAggregator', () {
    test('dedupes by ISRC and prefers local copies', () {
      final aggregated = const SearchAggregator().aggregate(
        <List<UnifiedSearchItem>>[
          <UnifiedSearchItem>[
            UnifiedSearchItem(
              kind: UnifiedSearchSourceKind.extension,
              sourceId: 'ext',
              title: 'Remote copy',
              subtitle: 'Artist',
              track: _track('with-isrc', 'Remote copy'),
            ),
          ],
          <UnifiedSearchItem>[
            UnifiedSearchItem(
              kind: UnifiedSearchSourceKind.localLibrary,
              sourceId: 'lib',
              title: 'Local copy',
              subtitle: 'Artist',
              track: _track('with-isrc', 'Local copy'),
              playableLocally: true,
            ),
          ],
        ],
      );
      expect(aggregated, hasLength(1));
      expect(aggregated.single.playableLocally, isTrue);
      expect(aggregated.single.title, 'Local copy');
    });

    test('same title+subtitle without ISRC merges too', () {
      final aggregated = const SearchAggregator().aggregate(
        <List<UnifiedSearchItem>>[
          <UnifiedSearchItem>[
            UnifiedSearchItem(
              kind: UnifiedSearchSourceKind.server,
              sourceId: 's1',
              title: 'Same Song',
              subtitle: 'Same Artist',
              sourceScore: 0.9,
            ),
          ],
          <UnifiedSearchItem>[
            UnifiedSearchItem(
              kind: UnifiedSearchSourceKind.downloads,
              sourceId: 'dl',
              title: 'same song',
              subtitle: 'same artist',
              sourceScore: 0.4,
            ),
          ],
        ],
      );
      expect(aggregated, hasLength(1));
      // Higher-authority kind wins the representation.
      expect(aggregated.single.kind, UnifiedSearchSourceKind.downloads);
    });

    test('distinct tracks stay distinct', () {
      final aggregated = const SearchAggregator().aggregate(
        <List<UnifiedSearchItem>>[
          <UnifiedSearchItem>[
            const UnifiedSearchItem(
              kind: UnifiedSearchSourceKind.podcast,
              sourceId: 'p',
              title: 'Episode 12',
              subtitle: 'Show',
            ),
          ],
        ],
      );
      expect(aggregated, hasLength(1));
    });
  });

  group('SearchRankingService', () {
    const ranking = SearchRankingService();

    test('exact text matches outrank weak matches from heavier sources',
        () {
      final ranked = ranking.rank(
        <UnifiedSearchItem>[
          const UnifiedSearchItem(
            kind: UnifiedSearchSourceKind.podcast,
            sourceId: 'p',
            title: 'Abbey Road',
            subtitle: '',
            sourceScore: 1.0,
          ),
          const UnifiedSearchItem(
            kind: UnifiedSearchSourceKind.localLibrary,
            sourceId: 'l',
            title: 'Abbey Road Remaster',
            subtitle: '',
            sourceScore: 0.3,
          ),
        ],
        'Abbey Road',
      );
      expect(ranked.first.item.title, 'Abbey Road');
    });

    test('limit is honored', () {
      final items = <UnifiedSearchItem>[
        for (var i = 0; i < 100; i++)
          UnifiedSearchItem(
            kind: UnifiedSearchSourceKind.extension,
            sourceId: 'e',
            title: 'Track $i',
            subtitle: 'Artist',
            track: _track('t$i', 'Track $i'),
          ),
      ];
      expect(ranking.rank(items, 'Track').length, 40);
    });
  });

  group('UnifiedSearchEngine', () {
    test('fans out, ranks and reports sources', () async {
      final engine = UnifiedSearchEngine(
        sources: <UnifiedSearchSource>[
          UnifiedSearchSource(
            id: 'local',
            kind: UnifiedSearchSourceKind.localLibrary,
            search: (query) async => <UnifiedSearchItem>[
              UnifiedSearchItem(
                kind: UnifiedSearchSourceKind.localLibrary,
                sourceId: 'local',
                title: query,
                subtitle: 'Artist',
                track: _track('l1', query),
                sourceScore: 1,
                playableLocally: true,
              ),
            ],
          ),
          UnifiedSearchSource(
            id: 'server',
            kind: UnifiedSearchSourceKind.server,
            search: (query) async => throw Exception('server down'),
          ),
        ],
      );
      final outcome = await engine.search('Alpha');
      expect(outcome.results, isNotEmpty);
      expect(outcome.respondedSourceIds, contains('local'));
      expect(outcome.failedSourceIds, contains('server'));
      expect(outcome.results.first.item.sourceId, 'local');
    });

    test('per-source timeouts degrade to empty, not errors', () async {
      final engine = UnifiedSearchEngine(
        sources: <UnifiedSearchSource>[
          UnifiedSearchSource(
            id: 'slow',
            kind: UnifiedSearchSourceKind.server,
            search: (query) async {
              await Future<void>.delayed(const Duration(seconds: 30));
              return const <UnifiedSearchItem>[];
            },
          ),
        ],
      );
      final outcome = await engine.search(
        'x',
        perSourceTimeout: const Duration(milliseconds: 20),
      );
      expect(outcome.results, isEmpty);
      expect(outcome.failedSourceIds, contains('slow'));
    });

    test('empty query short-circuits', () async {
      final engine = UnifiedSearchEngine(
        sources: <UnifiedSearchSource>[
          UnifiedSearchSource(
            id: 'x',
            kind: UnifiedSearchSourceKind.extension,
            search: (query) async => throw StateError('must not be called'),
          ),
        ],
      );
      final outcome = await engine.search('   ');
      expect(outcome.results, isEmpty);
      expect(outcome.respondedSourceIds, isEmpty);
    });

    test('register/unregister keeps one source per id', () {
      final engine = UnifiedSearchEngine();
      engine.register(
        UnifiedSearchSource(
          id: 'a',
          kind: UnifiedSearchSourceKind.extension,
          search: (query) async => const <UnifiedSearchItem>[],
        ),
      );
      engine.register(
        UnifiedSearchSource(
          id: 'a',
          kind: UnifiedSearchSourceKind.extension,
          search: (query) async => const <UnifiedSearchItem>[],
        ),
      );
      expect(engine.sources, hasLength(1));
      engine.unregister('a');
      expect(engine.sources, isEmpty);
    });
  });
}
