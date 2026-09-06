import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/recommendations.dart';

RecommendationProfile _profile({
  List<ProfilePlay>? plays,
  List<ProfileAffinity>? favoriteArtists,
  List<ProfilePlay>? lovedTracks,
  int seed = 42,
}) {
  return RecommendationProfile(
    plays: plays ?? const <ProfilePlay>[],
    favoriteArtists: favoriteArtists ?? const <ProfileAffinity>[],
    lovedTracks: lovedTracks ?? const <ProfilePlay>[],
    dailySeed: seed,
  );
}

ProfilePlay _play(
  String id,
  String title,
  String artist, {
  int playCount = 1,
  int listenedMs = 0,
  DateTime? lastPlayedAt,
}) {
  return ProfilePlay(
    trackId: id,
    title: title,
    artist: artist,
    playCount: playCount,
    listenedMs: listenedMs,
    lastPlayedAt: lastPlayedAt,
  );
}

void main() {
  final base = DateTime.utc(2026, 9, 1, 12);

  group('LocalRecommendationEngine', () {
    const engine = LocalRecommendationEngine();

    test('cold profile yields no sections', () async {
      final sections = await engine.recommend(_profile());
      expect(sections, isEmpty);
    });

    test('recently played is ordered by recency', () async {
      final profile = _profile(
        plays: <ProfilePlay>[
          _play('a', 'Alpha', 'Artist A', lastPlayedAt: base),
          _play(
            'b',
            'Beta',
            'Artist B',
            lastPlayedAt: base.add(const Duration(minutes: 5)),
          ),
          _play(
            'c',
            'Gamma',
            'Artist C',
            lastPlayedAt: base.subtract(const Duration(hours: 1)),
          ),
        ],
      );
      final sections = await engine.recommend(profile);
      final recent = sections.firstWhere(
        (section) => section.kind == RecommendationSectionKind.recentlyPlayed,
      );
      expect(recent.items.map((item) => item.id).toList(), <String>[
        'b',
        'a',
        'c',
      ]);
    });

    test('frequently played is ordered by play count', () async {
      final profile = _profile(
        plays: <ProfilePlay>[
          _play('a', 'Alpha', 'Artist A', playCount: 2),
          _play('b', 'Beta', 'Artist B', playCount: 9),
          _play('c', 'Gamma', 'Artist C', playCount: 4),
        ],
      );
      final sections = await engine.recommend(profile);
      final frequent = sections.firstWhere(
        (section) => section.kind == RecommendationSectionKind.frequentlyPlayed,
      );
      expect(frequent.items.map((item) => item.id).toList(), <String>[
        'b',
        'c',
        'a',
      ]);
    });

    test('similar artists rank favorites above observed plays', () async {
      final profile = _profile(
        plays: <ProfilePlay>[
          _play('a', 'Alpha', 'Observed Artist', playCount: 50),
        ],
        favoriteArtists: const <ProfileAffinity>[
          ProfileAffinity(id: 'ext:1', name: 'Favorite Artist'),
        ],
      );
      final sections = await engine.recommend(profile);
      final artists = sections.firstWhere(
        (section) => section.kind == RecommendationSectionKind.similarArtists,
      );
      expect(artists.items.first.title, 'Favorite Artist');
      expect(artists.items.any((item) => item.title == 'Observed Artist'),
          isTrue);
    });

    test('discovery mix interleaves artists round-robin', () async {
      final plays = <ProfilePlay>[
        for (var i = 0; i < 5; i++)
          _play('a$i', 'A$i', 'Artist A', playCount: 10 - i),
        for (var i = 0; i < 5; i++)
          _play('b$i', 'B$i', 'Artist B', playCount: 10 - i),
        for (var i = 0; i < 5; i++)
          _play('c$i', 'C$i', 'Artist C', playCount: 10 - i),
      ];
      final sections = await engine.recommend(_profile(plays: plays));
      final mix = sections.firstWhere(
        (section) => section.kind == RecommendationSectionKind.discoveryMix,
      );
      expect(mix.items.length, greaterThanOrEqualTo(3));
      // No artist may occupy three consecutive slots: round-robin guarantee.
      for (var i = 0; i + 2 < mix.items.length; i++) {
        final window = mix.items.sublist(i, i + 3);
        final artists = window.map((item) => item.subtitle).toSet();
        expect(artists.length, greaterThan(1));
      }
    });

    test('discovery mix is deterministic for the same seed', () async {
      final plays = <ProfilePlay>[
        for (var i = 0; i < 4; i++) _play('a$i', 'A$i', 'Artist A'),
        for (var i = 0; i < 4; i++) _play('b$i', 'B$i', 'Artist B'),
      ];
      final firstRun =
          (await engine.recommend(_profile(plays: plays, seed: 7)))
              .firstWhere((s) => s.kind == RecommendationSectionKind.discoveryMix)
              .items;
      final secondRun =
          (await engine.recommend(_profile(plays: plays, seed: 7)))
              .firstWhere((s) => s.kind == RecommendationSectionKind.discoveryMix)
              .items;
      expect(firstRun, secondRun);
    });

    test('single-artist listener gets loved-track mix instead', () async {
      final profile = _profile(
        plays: <ProfilePlay>[_play('a', 'Alpha', 'Solo Artist', playCount: 3)],
        lovedTracks: <ProfilePlay>[
          _play('l1', 'Loved One', 'Solo Artist'),
          _play('l2', 'Loved Two', 'Another Artist'),
        ],
      );
      final sections = await engine.recommend(profile);
      final mix = sections.firstWhere(
        (section) => section.kind == RecommendationSectionKind.discoveryMix,
      );
      expect(mix.items.map((item) => item.id), containsAll(<String>['l1', 'l2']));
    });

    test('sections respect maxItemsPerSection', () async {
      final plays = <ProfilePlay>[
        for (var i = 0; i < 30; i++)
          _play('t$i', 'Track $i', 'Artist ${i % 4}', playCount: i),
      ];
      final sections = await engine.recommend(
        _profile(plays: plays),
        maxItemsPerSection: 5,
      );
      for (final section in sections) {
        expect(section.items.length, lessThanOrEqualTo(5));
      }
    });
  });

  group('RecommendationSection.withScoresNormalized', () {
    test('normalizes best score to 1.0', () {
      const section = RecommendationSection(
        kind: RecommendationSectionKind.trending,
        items: <RecommendedItem>[
          RecommendedItem(
            kind: RecommendedItemKind.track,
            id: 'a',
            title: 'A',
            score: 4,
          ),
          RecommendedItem(
            kind: RecommendedItemKind.track,
            id: 'b',
            title: 'B',
            score: 2,
          ),
        ],
      );
      final normalized = section.withScoresNormalized();
      expect(normalized.items.first.score, 1.0);
      expect(normalized.items.last.score, closeTo(0.5, 1e-9));
    });
  });

  group('RecommendationService', () {
    test('local-only service serves cold start gracefully', () async {
      final service = RecommendationService.localOnly();
      expect(service.providerIds, <String>['local']);
      final sections = await service.recommend(_profile());
      expect(sections, isEmpty);
    });

    test('first non-empty provider wins per section kind', () async {
      final remote = _StubProvider(
        id: 'remote',
        sections: const <RecommendationSection>[
          RecommendationSection(
            kind: RecommendationSectionKind.trending,
            items: <RecommendedItem>[
              RecommendedItem(
                kind: RecommendedItemKind.track,
                id: 'hot',
                title: 'Trending Song',
              ),
            ],
          ),
        ],
      );
      final service = RecommendationService(
        providers: const <RecommendationProvider>[
          LocalRecommendationEngine(),
        ],
      ).withProvider(remote);

      // Remote must register ahead of the local fallback.
      expect(service.providerIds, <String>['remote', 'local']);

      final profile = _profile(
        plays: <ProfilePlay>[
          _play('a', 'Alpha', 'Artist A', playCount: 3, lastPlayedAt: base),
        ],
      );
      final sections = await service.recommend(profile);
      expect(
        sections.any(
          (section) => section.kind == RecommendationSectionKind.trending,
        ),
        isTrue,
      );
      // Local sections still fill the remaining kinds.
      expect(
        sections.any(
          (section) => section.kind == RecommendationSectionKind.recentlyPlayed,
        ),
        isTrue,
      );
    });

    test('failing provider falls through to the local engine', () async {
      final service = RecommendationService(
        providers: <RecommendationProvider>[
          _ThrowingProvider(),
          const LocalRecommendationEngine(),
        ],
      );
      final profile = _profile(
        plays: <ProfilePlay>[
          _play('a', 'Alpha', 'Artist A', playCount: 1, lastPlayedAt: base),
        ],
      );
      final sections = await service.recommend(profile);
      expect(sections, isNotEmpty);
    });
  });
}

class _StubProvider implements RecommendationProvider {
  _StubProvider({required this.id, required this.sections});

  @override
  final String id;

  final List<RecommendationSection> sections;

  @override
  Future<List<RecommendationSection>> recommend(
    RecommendationProfile profile, {
    int maxItemsPerSection = 20,
  }) async =>
      sections;
}

class _ThrowingProvider implements RecommendationProvider {
  @override
  String get id => 'thrower';

  @override
  Future<List<RecommendationSection>> recommend(
    RecommendationProfile profile, {
    int maxItemsPerSection = 20,
  }) async {
    throw StateError('backend down');
  }
}
