import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/favorites/favorites.dart';

FavoriteEntry _entry(
  String key,
  FavoriteKind kind,
  String title, {
  String subtitle = '',
  DateTime? addedAt,
}) {
  return FavoriteEntry(
    key: key,
    kind: kind,
    title: title,
    subtitle: subtitle,
    addedAt: addedAt ?? DateTime.utc(2026, 1, 1),
  );
}

void main() {
  const catalog = FavoritesCatalog();

  final entries = <FavoriteEntry>[
    _entry('isrc:A', FavoriteKind.track, 'Alpha', subtitle: 'Zed',
        addedAt: DateTime.utc(2026, 1, 1)),
    _entry('isrc:B', FavoriteKind.track, 'Beta', subtitle: 'Ada',
        addedAt: DateTime.utc(2026, 3, 1)),
    _entry('qobuz:album1', FavoriteKind.album, 'Cosmos', subtitle: 'Ada',
        addedAt: DateTime.utc(2026, 2, 1)),
    _entry('qobuz:artist1', FavoriteKind.artist, 'Ada',
        addedAt: DateTime.utc(2026, 4, 1)),
    _entry('playlist:1', FavoriteKind.playlist, 'Road trip',
        addedAt: DateTime.utc(2026, 5, 1)),
  ];

  group('FavoritesCatalog', () {
    test('index is ordered newest first and exposes O(1) lookups', () {
      final index = catalog.build(entries);
      expect(index.length, 5);
      expect(index.entries.first.key, 'playlist:1');
      expect(index.contains('isrc:A'), isTrue);
      expect(index.contains('isrc:missing'), isFalse);
      expect(index.countOf(FavoriteKind.track), 2);
      expect(index.countOf(FavoriteKind.artist), 1);
    });

    test('filtering by kind returns only that kind', () {
      final index = catalog.build(entries);
      final tracks = catalog.query(
        index,
        kinds: <FavoriteKind>{FavoriteKind.track},
      );
      expect(tracks.map((e) => e.key), <String>['isrc:B', 'isrc:A']);
    });

    test('search matches on title and subtitle tokens', () {
      final index = catalog.build(entries);
      expect(
        catalog.query(index, search: 'cosmos').map((e) => e.key),
        <String>['qobuz:album1'],
      );
      expect(catalog.query(index, search: 'ada').length, 3);
      expect(catalog.query(index, search: 'nope'), isEmpty);
    });

    test('sorting supports recency, title, artist and play counts', () {
      final index = catalog.build(entries);

      final byRecency = catalog.query(
        index,
        sort: FavoriteSortOrder.recentlyAdded,
      );
      expect(byRecency.first.key, 'playlist:1');

      final byOldest = catalog.query(
        index,
        sort: FavoriteSortOrder.oldestAdded,
      );
      expect(byOldest.first.key, 'isrc:A');

      final byTitle = catalog.query(index, sort: FavoriteSortOrder.title);
      expect(byTitle.first.title.toLowerCase(), 'ada');

      final byArtist = catalog.query(index, sort: FavoriteSortOrder.artist);
      expect(byArtist.first.subtitle.toLowerCase(), 'ada');

      final byPlays = catalog.query(
        index,
        sort: FavoriteSortOrder.mostPlayed,
        playCounts: const <String, int>{'isrc:A': 9},
      );
      expect(byPlays.first.key, 'isrc:A');
    });

    test('entries round trip through JSON', () {
      final entry = _entry('isrc:A', FavoriteKind.track, 'Alpha',
          subtitle: 'Zed');
      final parsed = FavoriteEntry.tryParse(entry.toJson());
      expect(parsed, isNotNull);
      expect(parsed!.key, entry.key);
      expect(parsed.kind, FavoriteKind.track);
      expect(parsed.title, 'Alpha');
    });

    test('empty catalog produces an empty index', () {
      final index = catalog.build(const <FavoriteEntry>[]);
      expect(index.length, 0);
      expect(catalog.query(index), isEmpty);
    });
  });
}
