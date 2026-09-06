import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/similarity_engine.dart';

/// Phase 6: similar artists — genre overlap, listening overlap, shared
/// playlists/tags and album overlap, blended into one explainable score.
void main() {
  final t0 = DateTime.utc(2026, 9, 6, 9);

  DiscoveryTrack track(
    String id, {
    String artistKey = '',
    String albumKey = '',
    List<String> genres = const <String>[],
    List<String> tags = const <String>[],
  }) {
    return DiscoveryTrack(
      key: 'isrc:$id',
      title: id,
      artist: 'Artist $id',
      artistKey: artistKey,
      albumKey: albumKey,
      genres: genres,
      tags: tags,
    );
  }

  ArtistVector vector(
    String key, {
    Map<String, double> genres = const <String, double>{},
    Map<String, double> tags = const <String, double>{},
    Map<String, double> albums = const <String, double>{},
    Set<String> coListenedArtists = const <String>{},
    Set<String> playlistIds = const <String>{},
  }) {
    return ArtistVector(
      key: key,
      label: key.toUpperCase(),
      genres: genres,
      tags: tags,
      albums: albums,
      coListenedArtists: coListenedArtists,
      playlistIds: playlistIds,
    );
  }

  group('SimilarityWeights', () {
    test('the shipped blend sums to one', () {
      const weights = SimilarityWeights();
      expect(
        weights.genre +
            weights.tag +
            weights.coListen +
            weights.playlist +
            weights.album,
        closeTo(1, 1e-9),
      );
      expect(weights.genre, greaterThan(weights.tag));
      expect(weights.coListen, greaterThan(weights.playlist));
    });
  });

  group('SimilarityEngine.compare', () {
    const engine = SimilarityEngine();

    test('an artist is perfectly similar to itself', () {
      final a = vector('a', genres: const <String, double>{'rock': 1});
      final result = engine.compare(a, a);
      expect(result.score, 1);
      expect(result.genreOverlap, 1);
      expect(result.isGrounded, isTrue);
      expect(result.artistKey, 'a');
    });

    test('identical genre sets score the genre weight alone', () {
      final a = vector('a', genres: const <String, double>{'rock': 1, 'grunge': 0.5});
      final b = vector('b', genres: const <String, double>{'rock': 3, 'grunge': 1.5});
      final result = engine.compare(a, b);
      // Cosine is scale-invariant, so the 3x play-count difference is ignored.
      expect(result.genreOverlap, closeTo(1, 1e-9));
      expect(result.score, closeTo(const SimilarityWeights().genre, 1e-9));
      expect(result.isGrounded, isTrue);
    });

    test('disjoint taxonomies are not grounded', () {
      final a = vector('a', genres: const <String, double>{'rock': 1});
      final b = vector('b', genres: const <String, double>{'jazz': 1});
      final result = engine.compare(a, b);
      expect(result.genreOverlap, 0);
      expect(result.score, 0);
      expect(result.isGrounded, isFalse);
    });

    test('a completely empty taxonomy never fabricates similarity', () {
      final result = engine.compare(vector('a'), vector('b'));
      expect(result.score, 0);
      expect(result.isGrounded, isFalse);
    });

    test('co-listening lifts a pair with a weaker taxonomy', () {
      final a = vector(
        'a',
        genres: const <String, double>{'rock': 1},
        coListenedArtists: const <String>{'b', 'c'},
      );
      final withCoListen = vector(
        'b',
        genres: const <String, double>{'rock': 1},
        coListenedArtists: const <String>{'a', 'c'},
      );
      final withoutCoListen = vector(
        'b',
        genres: const <String, double>{'rock': 1},
      );
      expect(
        engine.compare(a, withCoListen).score,
        greaterThan(engine.compare(a, withoutCoListen).score),
      );
      expect(engine.compare(a, withCoListen).coListenOverlap, greaterThan(0));
    });
  });

  group('SimilarityEngine.rank', () {
    const engine = SimilarityEngine();

    test('drops itself, excluded keys and ungrounded candidates', () {
      final target = vector('target', genres: const <String, double>{'rock': 1});
      final pool = <ArtistVector>[
        target,
        vector('excluded', genres: const <String, double>{'rock': 1}),
        vector('ungrounded'),
        vector('match', genres: const <String, double>{'rock': 1}),
      ];
      final ranked = engine.rank(
        target: target,
        pool: pool,
        exclude: const <String>{'excluded'},
      );
      expect(ranked.map((entry) => entry.artistKey).toList(), <String>['match']);
    });

    test('orders best first and honours the limit', () {
      final target = vector(
        'target',
        genres: const <String, double>{'rock': 1, 'punk': 1},
      );
      final pool = <ArtistVector>[
        vector('partial', genres: const <String, double>{'rock': 1}),
        vector('full', genres: const <String, double>{'rock': 1, 'punk': 1}),
      ];
      final ranked = engine.rank(target: target, pool: pool);
      expect(ranked.first.artistKey, 'full');
      expect(ranked.last.artistKey, 'partial');
      expect(engine.rank(target: target, pool: pool, limit: 1).length, 1);
    });
  });

  group('SimilarityEngine.trackSimilarity', () {
    const engine = SimilarityEngine();

    test('a track is identical to itself', () {
      final a = track('a', artistKey: 'e:x', albumKey: 'e:y');
      expect(engine.trackSimilarity(a, a), 1);
    });

    test('same artist lifts, same album lifts further', () {
      final base = track('a', artistKey: 'e:x', albumKey: 'e:y');
      final otherArtist = track('b', artistKey: 'e:z', albumKey: 'e:w');
      final sameArtist = track('b', artistKey: 'e:x', albumKey: 'e:w');
      final sameBoth = track('b', artistKey: 'e:x', albumKey: 'e:y');
      expect(engine.trackSimilarity(base, otherArtist), 0);
      expect(
        engine.trackSimilarity(base, sameArtist),
        closeTo(0.26, 1e-9),
      );
      expect(
        engine.trackSimilarity(base, sameBoth),
        closeTo(0.38, 1e-9),
      );
    });

    test('shared genres contribute through the taxonomy term', () {
      final a = track('a', genres: const <String>['jazz', 'soul']);
      final shared = track('b', genres: const <String>['jazz', 'soul']);
      final partial = track('c', genres: const <String>['jazz']);
      expect(
        engine.trackSimilarity(a, shared),
        greaterThan(engine.trackSimilarity(a, partial)),
      );
    });
  });

  group('ArtistVector.fromTracks', () {
    test('peak-normalises genres and totals plays', () {
      final v = ArtistVector.fromTracks(
        'e:artist',
        'Artist',
        <DiscoveryTrack>[
          track('a', genres: const <String>['rock']),
          track('b', genres: const <String>['rock', 'punk']),
        ],
      );
      expect(v.genres['rock'], closeTo(1, 1e-9));
      expect(v.genres['punk'], closeTo(0.5, 1e-9));
      expect(v.playCount, 2);
      expect(v.hasTaxonomy, isTrue);
    });

    test('play counts weight the taxonomy when signals are supplied', () {
      final signals = <String, TrackSignals>{
        'isrc:a': TrackSignals(
          trackKey: 'isrc:a',
          playCount: 9,
          firstPlayedAt: t0,
          lastPlayedAt: t0,
        ),
        'isrc:b': TrackSignals(
          trackKey: 'isrc:b',
          playCount: 1,
          firstPlayedAt: t0,
          lastPlayedAt: t0,
        ),
      };
      final v = ArtistVector.fromTracks(
        'e:artist',
        'Artist',
        <DiscoveryTrack>[
          track('a', genres: const <String>['rock']),
          track('b', genres: const <String>['punk']),
        ],
        signals: signals,
      );
      expect(v.genres['rock'], closeTo(1, 1e-9));
      // 9 plays vs 1, peak-normalised against the heavier genre.
      expect(v.genres['punk'], closeTo(1 / 9, 1e-9));
      expect(v.playCount, 10);
    });

    test('an artist with no genres reports no taxonomy', () {
      final v = ArtistVector.fromTracks('e:x', 'X', <DiscoveryTrack>[track('a')]);
      expect(v.hasTaxonomy, isFalse);
      expect(v.genres, isEmpty);
    });
  });

  group('co-listening graph', () {
    test('only plays inside one session become edges', () {
      final graph = buildCoListenGraph(<CoListenEvent>[
        CoListenEvent(artistKey: 'a', at: t0),
        CoListenEvent(artistKey: 'b', at: t0.add(const Duration(minutes: 5))),
        // More than 30 minutes later: a different session, so no edge.
        CoListenEvent(artistKey: 'c', at: t0.add(const Duration(hours: 2))),
      ]);
      expect(graph['a'], <String>{'b'});
      expect(graph['b'], <String>{'a'});
      expect(graph.containsKey('c'), isFalse);
    });

    test('a session with a single artist produces nothing', () {
      expect(
        buildCoListenGraph(<CoListenEvent>[
          CoListenEvent(artistKey: 'solo', at: t0),
        ]),
        isEmpty,
      );
    });

    test('the most co-listened neighbours survive the edge cap', () {
      final events = <CoListenEvent>[
        for (var i = 0; i < 6; i++) ...<CoListenEvent>[
          CoListenEvent(artistKey: 'hub', at: t0.add(Duration(minutes: i * 40))),
          CoListenEvent(
            artistKey: 'leaf$i',
            at: t0.add(Duration(minutes: i * 40 + 1)),
          ),
        ],
      ];
      final graph = buildCoListenGraph(events, maxEdgesPerArtist: 2);
      expect(graph['hub']!.length, 2);
      expect(graph['hub']!.every((key) => key.startsWith('leaf')), isTrue);
    });

    test('coListenScore normalises over the seed weights', () {
      final graph = buildCoListenGraph(<CoListenEvent>[
        CoListenEvent(artistKey: 'seed', at: t0),
        CoListenEvent(artistKey: 'hit', at: t0.add(const Duration(minutes: 2))),
      ]);
      expect(
        coListenScore('hit', <String, double>{'seed': 1}, graph),
        1,
      );
      expect(coListenScore('miss', <String, double>{'seed': 1}, graph), 0);
      expect(coListenScore('hit', <String, double>{}, graph), 0);
      expect(coListenScore('', <String, double>{'seed': 1}, graph), 0);
      // Only one of the two seeds is connected, so the score is the share of
      // seed weight that actually reaches the candidate.
      final partial = <String, double>{'seed': 1, 'other': 3};
      expect(coListenScore('hit', partial, graph), closeTo(0.25, 1e-9));
    });
  });
}
