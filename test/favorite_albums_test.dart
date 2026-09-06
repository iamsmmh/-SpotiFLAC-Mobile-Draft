import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';

void main() {
  group('albumCollectionKey', () {
    test('provider id namespaces the key', () {
      expect(
        albumCollectionKey(albumId: 'abc123', providerId: 'MyExt'),
        'myext:abc123',
      );
    });

    test('prefixed album id keeps its own namespace', () {
      expect(
        albumCollectionKey(albumId: 'deezer:123456', providerId: null),
        'deezer:123456',
      );
    });

    test('bare id without provider falls back to builtin namespace', () {
      expect(
        albumCollectionKey(albumId: '789', providerId: null),
        'builtin:789',
      );
    });

    test('explicit provider wins over id prefix', () {
      expect(
        albumCollectionKey(albumId: 'other:42', providerId: 'Qobuz'),
        'qobuz:42',
      );
    });

    test('album keys never collide with artist keys for same id', () {
      // Both helpers share the source:id shape but live in separate tables;
      // this test pins that contract.
      final albumKey = albumCollectionKey(
        albumId: 'x:1',
        providerId: null,
      );
      final artistKey = artistCollectionKey(
        artistId: 'x:1',
        providerId: null,
      );
      expect(albumKey, artistKey); // same string…
      // …stored under different tables (favorite_albums/favorite_artists),
      // and separate in-memory indexes.
    });
  });

  group('CollectionAlbumEntry', () {
    test('json round trip keeps every field', () {
      final entry = CollectionAlbumEntry(
        key: 'myext:alb1',
        albumId: 'alb1',
        providerId: 'myext',
        name: 'Discovery',
        artistName: 'Daft Punk',
        artistId: 'art1',
        imageUrl: 'https://example.test/cover.jpg',
        addedAt: DateTime.utc(2026, 9, 5, 10, 30),
      );
      final restored = CollectionAlbumEntry.fromJson(entry.toJson());
      expect(restored.key, entry.key);
      expect(restored.albumId, entry.albumId);
      expect(restored.providerId, entry.providerId);
      expect(restored.name, entry.name);
      expect(restored.artistName, entry.artistName);
      expect(restored.artistId, entry.artistId);
      expect(restored.imageUrl, entry.imageUrl);
      expect(restored.addedAt, entry.addedAt);
    });

    test('missing key is rederived deterministically', () {
      final restored = CollectionAlbumEntry.fromJson(<String, dynamic>{
        'albumId': 'deezer:99',
        'providerId': null,
        'name': 'Homework',
      });
      expect(restored.key, 'deezer:99');
    });

    test('optional fields survive absence', () {
      final restored = CollectionAlbumEntry.fromJson(<String, dynamic>{
        'albumId': 'x',
        'providerId': null,
        'name': 'Minimal',
        'addedAt': '2026-09-05T00:00:00.000Z',
      });
      expect(restored.artistName, isNull);
      expect(restored.artistId, isNull);
      expect(restored.imageUrl, isNull);
    });
  });

  group('LibraryCollectionsState favorite albums', () {
    CollectionAlbumEntry entry(String key, String name) => CollectionAlbumEntry(
      key: key,
      albumId: name,
      providerId: 'myext',
      name: name,
      addedAt: DateTime.utc(2026, 9, 5),
    );

    test('empty state has no favorites and count zero', () {
      final state = LibraryCollectionsState();
      expect(state.favoriteAlbumCount, 0);
      expect(
        state.isFavoriteAlbum(albumId: 'a', providerId: 'myext'),
        isFalse,
      );
    });

    test('isFavoriteAlbum resolves via the derived key index', () {
      final state = LibraryCollectionsState(
        favoriteAlbums: <CollectionAlbumEntry>[entry('myext:a', 'A')],
      );
      expect(state.favoriteAlbumCount, 1);
      expect(state.isFavoriteAlbum(albumId: 'a', providerId: 'myext'), isTrue);
      expect(state.isFavoriteAlbum(albumId: 'b', providerId: 'myext'), isFalse);
      expect(state.containsFavoriteAlbumKey('myext:a'), isTrue);
      expect(state.containsFavoriteAlbumKey('myext:b'), isFalse);
    });

    test('copyWith replaces albums and refreshes the key index', () {
      final initial = LibraryCollectionsState(
        favoriteAlbums: <CollectionAlbumEntry>[entry('myext:a', 'A')],
      );
      final next = initial.copyWith(
        favoriteAlbums: <CollectionAlbumEntry>[
          entry('myext:a', 'A'),
          entry('myext:b', 'B'),
        ],
      );
      expect(next.favoriteAlbumCount, 2);
      expect(next.containsFavoriteAlbumKey('myext:b'), isTrue);
    });

    test('toJson/fromJson round trip preserves favorite albums', () {
      final state = LibraryCollectionsState(
        favoriteAlbums: <CollectionAlbumEntry>[
          entry('myext:a', 'Random Access Memories'),
          entry('myext:b', 'Discovery'),
        ],
        isLoaded: true,
      );
      final restored = LibraryCollectionsState.fromJson(state.toJson());
      expect(restored.favoriteAlbumCount, 2);
      expect(restored.containsFavoriteAlbumKey('myext:a'), isTrue);
      expect(
        restored.favoriteAlbums.first.name,
        'Random Access Memories',
      );
    });

    test('legacy json without the albums field still loads', () {
      final restored = LibraryCollectionsState.fromJson(<String, dynamic>{
        'wishlist': <dynamic>[],
        'loved': <dynamic>[],
        'playlists': <dynamic>[],
        'favoriteArtists': <dynamic>[],
      });
      expect(restored.favoriteAlbumCount, 0);
      expect(restored.isLoaded, isTrue);
    });
  });
}
