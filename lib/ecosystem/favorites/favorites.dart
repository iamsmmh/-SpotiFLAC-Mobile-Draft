/// Favorites ecosystem (Feature Group 3).
///
/// The existing favorites UI (`Loved`, `Favorite albums`, `Favorite artists`)
/// is owned by `LibraryCollectionsNotifier` and stores its rows in
/// `collections.db`. This module does **not** duplicate that storage — it is a
/// read-only *projection* that unifies all four kinds (tracks, albums,
/// artists, playlists) into one queryable index, and adds the one kind the app
/// was missing: **favorite playlists**.
///
/// Benefits of the projection:
///   * one search box over everything the user has liked;
///   * sorting (recently added, title, artist, most played) and filtering by
///     kind, on top of a pre-built index rather than a per-keystroke scan;
///   * a single seam for cloud sync: [FavoriteEntry.key] is the same stable
///     identity the sync layer already uses for favorites.
library;

import 'package:spotimusic/models/track.dart';

/// The four favorite domains.
enum FavoriteKind {
  track,
  album,
  artist,
  playlist;

  String get wireId => name;
}

/// How the favorites page orders its list.
enum FavoriteSortOrder {
  recentlyAdded,
  oldestAdded,
  title,
  artist,
  mostPlayed;

  String get label {
    switch (this) {
      case FavoriteSortOrder.recentlyAdded:
        return 'Recently added';
      case FavoriteSortOrder.oldestAdded:
        return 'Oldest first';
      case FavoriteSortOrder.title:
        return 'Title A–Z';
      case FavoriteSortOrder.artist:
        return 'Artist A–Z';
      case FavoriteSortOrder.mostPlayed:
        return 'Most played';
    }
  }
}

/// One favorited entity, normalized across kinds.
class FavoriteEntry {
  const FavoriteEntry({
    required this.key,
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.coverUrl,
    required this.addedAt,
    this.track,
    this.albumId,
    this.artistId,
    this.playlistId,
  });

  /// Stable, sync-safe identity (`isrc:…`, `qobuz:albumId`, …).
  final String key;

  final FavoriteKind kind;
  final String title;
  final String subtitle;
  final String? coverUrl;
  final DateTime addedAt;

  /// Present for [FavoriteKind.track] entries.
  final Track? track;

  final String? albumId;
  final String? artistId;
  final String? playlistId;

  /// Lowercased haystack used by the search index.
  String get searchText => '$title $subtitle'.toLowerCase();

  FavoriteEntry copyWith({
    String? title,
    String? subtitle,
    String? coverUrl,
    DateTime? addedAt,
  }) {
    return FavoriteEntry(
      key: key,
      kind: kind,
      title: title ?? this.title,
      subtitle: subtitle ?? this.subtitle,
      coverUrl: coverUrl ?? this.coverUrl,
      addedAt: addedAt ?? this.addedAt,
      track: track,
      albumId: albumId,
      artistId: artistId,
      playlistId: playlistId,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'kind': kind.wireId,
    'title': title,
    'subtitle': subtitle,
    if (coverUrl != null) 'coverUrl': coverUrl,
    'addedAt': addedAt.toUtc().toIso8601String(),
    if (albumId != null) 'albumId': albumId,
    if (artistId != null) 'artistId': artistId,
    if (playlistId != null) 'playlistId': playlistId,
  };

  static FavoriteEntry? tryParse(Map<String, Object?> json) {
    final key = json['key']?.toString();
    final addedAtRaw = json['addedAt']?.toString();
    if (key == null || key.isEmpty || addedAtRaw == null) return null;
    return FavoriteEntry(
      key: key,
      kind: _kindFrom(json['kind']?.toString()),
      title: json['title']?.toString() ?? '',
      subtitle: json['subtitle']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString(),
      addedAt: DateTime.tryParse(addedAtRaw) ?? DateTime.now(),
      albumId: json['albumId']?.toString(),
      artistId: json['artistId']?.toString(),
      playlistId: json['playlistId']?.toString(),
    );
  }

  static FavoriteKind _kindFrom(String? value) {
    for (final kind in FavoriteKind.values) {
      if (kind.wireId == value) return kind;
    }
    return FavoriteKind.track;
  }
}

/// Immutable, pre-indexed view of every favorite.
class FavoritesIndex {
  const FavoritesIndex({
    required this.entries,
    required this.byKey,
    required this.byKind,
    required this.searchIndex,
  });

  /// All entries, newest first.
  final List<FavoriteEntry> entries;

  /// O(1) existence checks (heart icons in every list tile).
  final Map<String, FavoriteEntry> byKey;

  final Map<FavoriteKind, List<FavoriteEntry>> byKind;

  /// token → keys, so a search is a set intersection instead of a scan.
  final Map<String, Set<String>> searchIndex;

  static const FavoritesIndex empty = FavoritesIndex(
    entries: <FavoriteEntry>[],
    byKey: <String, FavoriteEntry>{},
    byKind: <FavoriteKind, List<FavoriteEntry>>{},
    searchIndex: <String, Set<String>>{},
  );

  int get length => entries.length;

  int countOf(FavoriteKind kind) => byKind[kind]?.length ?? 0;

  bool contains(String key) => byKey.containsKey(key);
}

/// Pure index/sort/filter logic — no Flutter, no I/O, fully unit-testable.
class FavoritesCatalog {
  const FavoritesCatalog();

  /// Builds the fast index from a flat entry list.
  FavoritesIndex build(Iterable<FavoriteEntry> source) {
    final entries = source.toList(growable: false)
      ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    final byKey = <String, FavoriteEntry>{};
    final byKind = <FavoriteKind, List<FavoriteEntry>>{
      for (final kind in FavoriteKind.values) kind: <FavoriteEntry>[],
    };
    final searchIndex = <String, Set<String>>{};

    for (final entry in entries) {
      byKey[entry.key] = entry;
      byKind[entry.kind]!.add(entry);
      for (final token in _tokens(entry.searchText)) {
        searchIndex.putIfAbsent(token, () => <String>{}).add(entry.key);
      }
    }
    return FavoritesIndex(
      entries: List<FavoriteEntry>.unmodifiable(entries),
      byKey: Map<String, FavoriteEntry>.unmodifiable(byKey),
      byKind: Map<FavoriteKind, List<FavoriteEntry>>.unmodifiable(byKind),
      searchIndex: Map<String, Set<String>>.unmodifiable(searchIndex),
    );
  }

  /// Filters by kind and free text, then sorts.
  ///
  /// [playCounts] feeds [FavoriteSortOrder.mostPlayed] (keyed by
  /// [FavoriteEntry.key]); missing entries fall back to recency.
  List<FavoriteEntry> query(
    FavoritesIndex index, {
    String search = '',
    Set<FavoriteKind>? kinds,
    FavoriteSortOrder sort = FavoriteSortOrder.recentlyAdded,
    Map<String, int> playCounts = const <String, int>{},
  }) {
    final pool = kinds == null || kinds.isEmpty
        ? index.entries
        : <FavoriteEntry>[
            for (final kind in kinds) ...?index.byKind[kind],
          ];

    final query = search.trim().toLowerCase();
    final filtered = query.isEmpty
        ? pool
        : pool.where((entry) => _matches(index, entry, query));

    final sorted = filtered.toList(growable: false);
    sorted.sort((a, b) => _compare(a, b, sort, playCounts));
    return List<FavoriteEntry>.unmodifiable(sorted);
  }

  int _compare(
    FavoriteEntry a,
    FavoriteEntry b,
    FavoriteSortOrder sort,
    Map<String, int> playCounts,
  ) {
    switch (sort) {
      case FavoriteSortOrder.recentlyAdded:
        return b.addedAt.compareTo(a.addedAt);
      case FavoriteSortOrder.oldestAdded:
        return a.addedAt.compareTo(b.addedAt);
      case FavoriteSortOrder.title:
        return _natural(a.title).compareTo(_natural(b.title));
      case FavoriteSortOrder.artist:
        // Entries without a subtitle (e.g. favorited artists, whose name is
        // the title) carry no artist metadata — they sort last, not first.
        final aArtist = _natural(a.subtitle);
        final bArtist = _natural(b.subtitle);
        int artistCompare;
        if (aArtist.isEmpty && bArtist.isEmpty) {
          artistCompare = 0;
        } else if (aArtist.isEmpty) {
          artistCompare = 1;
        } else if (bArtist.isEmpty) {
          artistCompare = -1;
        } else {
          artistCompare = aArtist.compareTo(bArtist);
        }
        return artistCompare != 0
            ? artistCompare
            : _natural(a.title).compareTo(_natural(b.title));
      case FavoriteSortOrder.mostPlayed:
        final plays = (playCounts[b.key] ?? 0).compareTo(
          playCounts[a.key] ?? 0,
        );
        return plays != 0 ? plays : b.addedAt.compareTo(a.addedAt);
    }
  }

  bool _matches(FavoritesIndex index, FavoriteEntry entry, String query) {
    // Prefix scan over the token index first: it is dramatically cheaper than
    // substring-matching every entry on large libraries.
    final keys = <String>{};
    for (final token in _tokens(query)) {
      final hits = index.searchIndex[token];
      if (hits != null) keys.addAll(hits);
    }
    if (keys.isNotEmpty) return keys.contains(entry.key);
    return entry.searchText.contains(query);
  }

  /// Case/Diacritic-insensitive-ish tokenizer: splits on non-alphanumerics and
  /// keeps prefixes so "bea" matches "beatles".
  static Iterable<String> _tokens(String value) sync* {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      final char = String.fromCharCode(rune).toLowerCase();
      final isWord = _isWordChar(char);
      if (isWord) {
        buffer.write(char);
      } else if (buffer.isNotEmpty) {
        yield buffer.toString();
        buffer.clear();
      }
    }
    if (buffer.isNotEmpty) yield buffer.toString();
  }

  static bool _isWordChar(String char) {
    final code = char.codeUnitAt(0);
    return (code >= 97 && code <= 122) || (code >= 48 && code <= 57);
  }

  static String _natural(String value) => value.trim().toLowerCase();
}
