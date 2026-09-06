import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/services/search_history_store.dart';
import 'package:spotiflac_android/utils/fuzzy_match.dart';

/// Search history state: most recent queries first, capped by the store.
final searchHistoryProvider =
    NotifierProvider<SearchHistoryNotifier, List<SearchHistoryEntry>>(
      SearchHistoryNotifier.new,
    );

class SearchHistoryNotifier extends Notifier<List<SearchHistoryEntry>> {
  final SearchHistoryStore _store = SearchHistoryStore();

  @override
  List<SearchHistoryEntry> build() => const <SearchHistoryEntry>[];

  /// Loads persisted history. Called once from app bootstrap; failures must
  /// never break startup (mirrors the statistics provider contract).
  Future<void> load() async {
    try {
      state = await _store.load();
    } catch (_) {
      state = const <SearchHistoryEntry>[];
    }
  }

  /// Records a submitted query (deduped, capped, most-recent-first).
  Future<void> recordQuery(String query) async {
    final next = await _store.record(query);
    state = next;
  }

  Future<void> remove(String query) async {
    state = await _store.remove(query);
  }

  Future<void> clearAll() async {
    await _store.clear();
    state = const <SearchHistoryEntry>[];
  }
}

// ---------------------------------------------------------------------------
// Suggestions
// ---------------------------------------------------------------------------

enum SearchSuggestionKind { history, lovedTrack, favoriteArtist, favoriteAlbum }

/// One suggestion row: a past query, or a matched library entity.
class SearchSuggestion {
  const SearchSuggestion({
    required this.kind,
    required this.label,
    this.subtitle = '',
    this.imageUrl,
    this.score = 0,
  });

  final SearchSuggestionKind kind;

  /// For [SearchSuggestionKind.history] the query itself; otherwise the
  /// entity name/title.
  final String label;
  final String subtitle;
  final String? imageUrl;

  /// Fuzzy rank score (higher = better); 0 for plain history rows.
  final double score;
}

/// Fast local suggestions (Phase 9), ranked with [fuzzyRank] over
///   1. the user's own query history,
///   2. loved tracks,
///   3. favorite artists,
///   4. favorite albums.
///
/// Fully on-device (no network); realtime-typed input stays under a frame.
/// An empty [query] surfaces the recent-query list unchanged so the Home
/// screen can offer one-tap re-runs.
final searchSuggestionsProvider =
    Provider.family<List<SearchSuggestion>, String>((ref, String query) {
      final trimmed = query.trim();
      final history = ref.watch(searchHistoryProvider);
      if (trimmed.isEmpty) {
        return history
            .map(
              (entry) => SearchSuggestion(
                kind: SearchSuggestionKind.history,
                label: entry.query,
              ),
            )
            .toList(growable: false);
      }

      final collections = ref.watch(libraryCollectionsProvider);
      final suggestions = <SearchSuggestion>[];

      for (final hit in fuzzyRank<SearchHistoryEntry>(
        trimmed,
        history,
        textOf: (entry) => entry.query,
        limit: 4,
      )) {
        suggestions.add(
          SearchSuggestion(
            kind: SearchSuggestionKind.history,
            label: hit.item.query,
            score: hit.score,
          ),
        );
      }

      for (final hit in fuzzyRank<CollectionTrackEntry>(
        trimmed,
        collections.loved,
        textOf: (entry) => entry.track.name,
        secondaryTextOf: (entry) => entry.track.artistName,
        limit: 4,
      )) {
        suggestions.add(
          SearchSuggestion(
            kind: SearchSuggestionKind.lovedTrack,
            label: hit.item.track.name,
            subtitle: hit.item.track.artistName,
            imageUrl: hit.item.track.coverUrl,
            score: hit.score,
          ),
        );
      }

      for (final hit in fuzzyRank<CollectionArtistEntry>(
        trimmed,
        collections.favoriteArtists,
        textOf: (entry) => entry.name,
        limit: 3,
      )) {
        suggestions.add(
          SearchSuggestion(
            kind: SearchSuggestionKind.favoriteArtist,
            label: hit.item.name,
            imageUrl: hit.item.imageUrl,
            score: hit.score,
          ),
        );
      }

      for (final hit in fuzzyRank<CollectionAlbumEntry>(
        trimmed,
        collections.favoriteAlbums,
        textOf: (entry) => entry.name,
        secondaryTextOf: (entry) => entry.artistName ?? '',
        limit: 3,
      )) {
        suggestions.add(
          SearchSuggestion(
            kind: SearchSuggestionKind.favoriteAlbum,
            label: hit.item.name,
            subtitle: hit.item.artistName ?? '',
            imageUrl: hit.item.imageUrl,
            score: hit.score,
          ),
        );
      }

      suggestions.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });
      return suggestions.length > 10
          ? suggestions.sublist(0, 10)
          : suggestions;
    });
