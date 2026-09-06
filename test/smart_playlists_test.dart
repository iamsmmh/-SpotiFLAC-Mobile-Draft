import 'package:flutter_test/flutter_test.dart';
import 'package:spotimusic/ecosystem/ecosystem_kv.dart';
import 'package:spotimusic/ecosystem/favorites/favorites.dart';
import 'package:spotimusic/ecosystem/history/listening_history.dart';
import 'package:spotimusic/ecosystem/smart_playlists/smart_playlist_engine.dart';
import 'package:spotimusic/ecosystem/smart_playlists/smart_playlist_models.dart';
import 'package:spotimusic/ecosystem/smart_playlists/smart_playlist_store.dart';
import 'package:spotimusic/engine/recommendations.dart';
import 'package:spotimusic/models/track.dart';

TrackHistory history(
  String key,
  String title,
  String artist, {
  int plays = 3,
  int skips = 0,
  DateTime? lastPlayed,
  double completion = 0.95,
}) => TrackHistory(
  trackKey: key,
  title: title,
  artist: artist,
  album: 'Album',
  playCount: plays,
  skipCount: skips,
  totalPlayedMs: plays * 200000,
  firstPlayedAt: DateTime(2026, 1, 1),
  lastPlayedAt: lastPlayed ?? DateTime(2026, 5, 1),
  averageCompletion: completion,
);

SmartLibraryEntry libraryRow(String title, DateTime scannedAt) =>
    SmartLibraryEntry(
      track: Track(
        id: 'lib-$title',
        name: title,
        artistName: 'Artist',
        albumName: 'Album',
        duration: 200,
        source: 'local',
      ),
      scannedAt: scannedAt,
    );

void main() {
  final input = SmartPlaylistInput(
    history: <TrackHistory>[
      history('k1', 'Favourite', 'A', plays: 20, lastPlayed: DateTime(2026, 6, 1)),
      history('k2', 'Often', 'B', plays: 10, lastPlayed: DateTime(2026, 6, 15)),
      history('k3', 'Once', 'A', plays: 1, lastPlayed: DateTime(2026, 6, 3)),
      history('k4', 'Skippy', 'C', plays: 10, skips: 9,
          lastPlayed: DateTime(2026, 6, 4)),
    ],
    library: <SmartLibraryEntry>[
      libraryRow('Old file', DateTime(2026, 1, 1)),
      libraryRow('New file', DateTime(2026, 7, 1)),
      libraryRow('Newest file', DateTime(2026, 7, 2)),
    ],
    favorites: <FavoriteEntry>[
      FavoriteEntry(
        key: 'f1',
        kind: FavoriteKind.track,
        title: 'Loved song',
        subtitle: 'A',
        addedAt: DateTime(2026, 6, 10),
        track: const Track(
          id: 'f1',
          name: 'Loved song',
          artistName: 'A',
          albumName: '',
          duration: 100,
        ),
      ),
      FavoriteEntry(
        key: 'f2',
        kind: FavoriteKind.album,
        title: 'An album',
        subtitle: 'A',
        addedAt: DateTime(2026, 6, 11),
      ),
    ],
    recommendations: <RecommendationSection>[
      const RecommendationSection(
        kind: RecommendationSectionKind.discoveryMix,
        items: <RecommendedItem>[
          RecommendedItem(
            kind: RecommendedItemKind.track,
            id: 'r1',
            title: 'Found gem',
            subtitle: 'D',
          ),
        ],
      ),
    ],
    now: DateTime(2026, 7, 3),
    dailySeed: 99,
  );

  const engine = SmartPlaylistEngine();

  test('most played ranks by count and excludes skip-heavy tracks', () {
    final playlist = engine.generate(
      const SmartPlaylistDefinition(
        kind: SmartPlaylistKind.mostPlayed,
        minPlayCount: 2,
      ),
      input,
    );
    final titles = playlist.tracks.map((row) => row.track.name).toList();
    expect(titles.first, 'Favourite');
    expect(titles, isNot(contains('Skippy')));
    expect(titles, contains('Often'));
    expect(titles, isNot(contains('Once')));
  });

  test('recently played orders by last play and honors the window', () {
    final playlist = engine.generate(
      const SmartPlaylistDefinition(
        kind: SmartPlaylistKind.recentlyPlayed,
        daysWindow: 30,
      ),
      input,
    );
    // Window: 30 days back from 2026-07-03 → cutoff 2026-06-03.
    // 'Favourite' (Jun 1) falls out; 'Once' (Jun 3, midnight) is not
    // strictly after the cutoff; 'Skippy' (skip rate 0.9 > 0.6 with more
    // than 2 plays) is filtered. Only 'Often' (Jun 15) survives.
    final titles = playlist.tracks.map((row) => row.track.name).toList();
    expect(titles, <String>['Often']);
  });

  test('favorites only includes track-kind favorites', () {
    final playlist = engine.generate(
      const SmartPlaylistDefinition(kind: SmartPlaylistKind.favorites),
      input,
    );
    expect(playlist.tracks.single.track.name, 'Loved song');
  });

  test('recently added sorts the library by scan date', () {
    final playlist = engine.generate(
      const SmartPlaylistDefinition(kind: SmartPlaylistKind.recentlyAdded),
      input,
    );
    expect(
      playlist.tracks.map((row) => row.track.name).toList(),
      <String>['Newest file', 'New file', 'Old file'],
    );
  });

  test('discover mix projects recommendation tracks', () {
    final playlist = engine.generate(
      const SmartPlaylistDefinition(kind: SmartPlaylistKind.discoverMix),
      input,
    );
    expect(playlist.tracks.single.track.name, 'Found gem');
  });

  test('daily mix is deterministic per seed and excludes low plays', () {
    final definition = const SmartPlaylistDefinition(
      kind: SmartPlaylistKind.dailyMix,
      minPlayCount: 2,
    );
    final a = engine.generate(definition, input);
    final b = engine.generate(definition, input);
    final otherSeed = SmartPlaylistInput(
      history: input.history,
      library: input.library,
      favorites: input.favorites,
      recommendations: input.recommendations,
      now: input.now,
      dailySeed: 12345,
    );
    final c = engine.generate(definition, otherSeed);
    expect(
      a.tracks.map((row) => row.track.name).toList(),
      b.tracks.map((row) => row.track.name).toList(),
    );
    // A different seed almost certainly reshuffles (two eligible tracks
    // → 50% flip chance per draw; assert determinism only, not layout).
    expect(c.tracks, isNotEmpty);
    expect(a.tracks.length, 2);
  });

  test('generateAll respects enabled flags and limits', () {
    final playlists = engine.generateAll(
      <SmartPlaylistDefinition>[
        const SmartPlaylistDefinition(
          kind: SmartPlaylistKind.mostPlayed,
          limit: 1,
        ),
        const SmartPlaylistDefinition(
          kind: SmartPlaylistKind.favorites,
          enabled: false,
        ),
      ],
      input,
    );
    expect(playlists, hasLength(1));
    expect(playlists.single.tracks, hasLength(1));
    expect(playlists.single.definition.kind, SmartPlaylistKind.mostPlayed);
  });

  group('SmartPlaylistStore definitions', () {
    test('fresh installs get the six built-ins', () async {
      final store = SmartPlaylistStore(
        preferences: MemoryKeyValueStore(),
      );
      final definitions = await store.definitions();
      expect(definitions, hasLength(6));
      expect(
        definitions.map((d) => d.kind).toSet(),
        containsAll(SmartPlaylistKind.values),
      );
    });

    test('persisted overrides merge over new kinds', () async {
      final preferences = MemoryKeyValueStore();
      await preferences.write(
        SmartPlaylistStore.definitionsKey,
        '[{"kind":"favorites","limit":5,"enabled":false}]',
      );
      final store = SmartPlaylistStore(preferences: preferences);
      final definitions = await store.definitions();
      expect(definitions, hasLength(6));
      final favorites = definitions
          .firstWhere((d) => d.kind == SmartPlaylistKind.favorites);
      expect(favorites.limit, 5);
      expect(favorites.enabled, isFalse);
    });

    test('corrupt storage degrades to built-ins', () async {
      final preferences = MemoryKeyValueStore();
      await preferences.write(SmartPlaylistStore.definitionsKey, '{oops');
      final store = SmartPlaylistStore(preferences: preferences);
      expect(await store.definitions(), hasLength(6));
    });
  });

  group('SmartPlaylistRefreshPolicy', () {
    const policy = SmartPlaylistRefreshPolicy();

    test('null and stale states refresh', () {
      expect(policy.shouldRefresh(null), isTrue);
      expect(policy.isStale(null), isTrue);
    });

    test('fresh states do not', () {
      final state = SmartPlaylistState(
        playlistId: 'p',
        lastMaterializedAt: DateTime.now(),
        lastTrackCount: 10,
      );
      expect(policy.shouldRefresh(state), isFalse);
      expect(policy.isStale(state), isFalse);
    });
  });

  test('state row codec round trip', () {
    final state = SmartPlaylistState(
      playlistId: 'dailyMix',
      lastMaterializedAt: DateTime.utc(2026, 7, 3),
      lastTrackCount: 12,
    );
    final restored = SmartPlaylistState.fromRow(state.toRow());
    expect(restored.playlistId, 'dailyMix');
    expect(restored.lastTrackCount, 12);
    expect(restored.lastMaterializedAt, isNotNull);
  });
}
