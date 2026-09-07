/// Unified smart search (Phase 8).
///
/// One endpoint returning tracks, albums, artists, playlists, podcasts and
/// servers. Wraps the existing [UnifiedSearchEngine] ranking with typo
/// correction and suggestion chips — it does not replace the engine.
library;

import 'package:spotiflac_android/engine/unified_search.dart';
import 'package:spotiflac_android/services/search/search_suggestions.dart';
import 'package:spotiflac_android/services/search/typo_corrector.dart';

/// Entity kinds the unified endpoint can return.
enum SmartSearchKind {
  track,
  album,
  artist,
  playlist,
  podcast,
  server,
}

/// One row in the unified response.
class SmartSearchHit {
  const SmartSearchHit({
    required this.kind,
    required this.id,
    required this.title,
    this.subtitle = '',
    this.score = 0,
  });

  final SmartSearchKind kind;
  final String id;
  final String title;
  final String subtitle;
  final double score;
}

/// Unified response: hits + suggestions + the query actually executed
/// (post typo-correction).
class SmartSearchResponse {
  const SmartSearchResponse({
    required this.query,
    required this.executedQuery,
    required this.hits,
    required this.suggestions,
    this.corrected = false,
  });

  final String query;
  final String executedQuery;
  final List<SmartSearchHit> hits;
  final List<SearchSuggestion> suggestions;
  final bool corrected;
}

/// Catalog the engine searches. Callers fill from library / servers /
/// podcasts; tests pass in-memory lists.
class SmartSearchCatalog {
  const SmartSearchCatalog({
    this.tracks = const <SmartSearchHit>[],
    this.albums = const <SmartSearchHit>[],
    this.artists = const <SmartSearchHit>[],
    this.playlists = const <SmartSearchHit>[],
    this.podcasts = const <SmartSearchHit>[],
    this.servers = const <SmartSearchHit>[],
  });

  final List<SmartSearchHit> tracks;
  final List<SmartSearchHit> albums;
  final List<SmartSearchHit> artists;
  final List<SmartSearchHit> playlists;
  final List<SmartSearchHit> podcasts;
  final List<SmartSearchHit> servers;

  Iterable<SmartSearchHit> get all => <SmartSearchHit>[
        ...tracks,
        ...albums,
        ...artists,
        ...playlists,
        ...podcasts,
        ...servers,
      ];

  List<String> get dictionary => <String>[
        for (final hit in all) hit.title,
      ];
}

/// Fan-out search with typo correction.
class SmartSearchEngine {
  const SmartSearchEngine({
    this.corrector = const TypoCorrector(),
    this.suggestions = const SearchSuggestionEngine(),
    this.limit = 40,
  });

  final TypoCorrector corrector;
  final SearchSuggestionEngine suggestions;
  final int limit;

  SmartSearchResponse search({
    required String query,
    required SmartSearchCatalog catalog,
    List<String> recent = const <String>[],
    List<String> trending = const <String>[],
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return SmartSearchResponse(
        query: query,
        executedQuery: '',
        hits: const <SmartSearchHit>[],
        suggestions: suggestions.suggest(
          query: '',
          recent: recent,
          trending: trending,
        ),
      );
    }
    final dictionary = <String>{...recent, ...trending, ...catalog.dictionary};
    final corrected = corrector.correct(trimmed, dictionary);
    final executed =
        corrected.isEmpty || corrected == trimmed ? trimmed : corrected;
    final ranked = SearchRankingService().rank(
      <UnifiedSearchItem>[
        for (final hit in catalog.all)
          UnifiedSearchItem(
            kind: _toUnified(hit.kind),
            sourceId: hit.id,
            title: hit.title,
            subtitle: hit.subtitle,
            sourceScore: 0.5,
          ),
      ],
      executed,
      limit: limit,
    );
    final hits = <SmartSearchHit>[
      for (final row in ranked)
        SmartSearchHit(
          kind: _fromUnified(row.item.kind) ??
              _kindOf(catalog, row.item.sourceId),
          id: row.item.sourceId,
          title: row.item.title,
          subtitle: row.item.subtitle,
          score: row.score,
        ),
    ];
    return SmartSearchResponse(
      query: trimmed,
      executedQuery: executed,
      hits: List<SmartSearchHit>.unmodifiable(hits),
      suggestions: suggestions.suggest(
        query: trimmed,
        recent: recent,
        trending: trending,
        library: catalog.dictionary,
      ),
      corrected: executed != trimmed,
    );
  }

  static UnifiedSearchSourceKind _toUnified(SmartSearchKind kind) {
    switch (kind) {
      case SmartSearchKind.track:
      case SmartSearchKind.album:
      case SmartSearchKind.artist:
      case SmartSearchKind.playlist:
        return UnifiedSearchSourceKind.localLibrary;
      case SmartSearchKind.podcast:
        return UnifiedSearchSourceKind.podcast;
      case SmartSearchKind.server:
        return UnifiedSearchSourceKind.server;
    }
  }

  static SmartSearchKind? _fromUnified(UnifiedSearchSourceKind kind) {
    switch (kind) {
      case UnifiedSearchSourceKind.podcast:
        return SmartSearchKind.podcast;
      case UnifiedSearchSourceKind.server:
        return SmartSearchKind.server;
      case UnifiedSearchSourceKind.localLibrary:
      case UnifiedSearchSourceKind.downloads:
      case UnifiedSearchSourceKind.extension:
      case UnifiedSearchSourceKind.streaming:
        return null;
    }
  }

  static SmartSearchKind _kindOf(SmartSearchCatalog catalog, String id) {
    bool has(List<SmartSearchHit> list) =>
        list.any((hit) => hit.id == id);
    if (has(catalog.tracks)) return SmartSearchKind.track;
    if (has(catalog.albums)) return SmartSearchKind.album;
    if (has(catalog.artists)) return SmartSearchKind.artist;
    if (has(catalog.playlists)) return SmartSearchKind.playlist;
    if (has(catalog.podcasts)) return SmartSearchKind.podcast;
    if (has(catalog.servers)) return SmartSearchKind.server;
    return SmartSearchKind.track;
  }
}
