import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// One entry in the local search history.
class SearchHistoryEntry {
  const SearchHistoryEntry({required this.query, required this.searchedAt});

  /// The query as the user typed it (trimmed, original casing preserved).
  final String query;
  final DateTime searchedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'query': query,
    'searchedAt': searchedAt.toIso8601String(),
  };

  static SearchHistoryEntry? tryParse(Object? raw) {
    // Bare strings are accepted as a legacy payload shape (query only, no
    // timestamp); everything else that is not a well-formed map is dropped
    // individually so one junk entry never blanks the whole history.
    if (raw is String) {
      final legacy = raw.trim();
      if (legacy.isEmpty) return null;
      return SearchHistoryEntry(
        query: legacy,
        searchedAt: DateTime.fromMillisecondsSinceEpoch(0),
      );
    }
    if (raw is! Map) return null;
    final query = raw['query']?.toString().trim() ?? '';
    if (query.isEmpty) return null;
    return SearchHistoryEntry(
      query: query,
      searchedAt:
          DateTime.tryParse(raw['searchedAt']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SearchHistoryEntry &&
      other.query.toLowerCase() == query.toLowerCase();

  @override
  int get hashCode => query.toLowerCase().hashCode;
}

/// Capped, deduplicated, on-device search history.
///
/// Storage is a single JSON list in shared preferences (the payload is tiny:
/// [SearchHistoryStore.maxEntries] short strings). The store is deliberately
/// free of Riverpod/Flutter imports so it stays unit-testable and reusable
/// from any layer; `SharedPreferences` is injected.
class SearchHistoryStore {
  SearchHistoryStore({SharedPreferences? preferences})
    : _preferencesOverride = preferences;

  static const int maxEntries = 20;
  static const String storageKey = 'search_history_v1';

  final SharedPreferences? _preferencesOverride;

  Future<SharedPreferences> get _prefs =>
      Future<SharedPreferences?>.value(
        _preferencesOverride,
      ).then((override) => override ?? SharedPreferences.getInstance());

  /// History, most recent first. Corrupt payloads degrade to empty.
  Future<List<SearchHistoryEntry>> load() async {
    final prefs = await _prefs;
    final raw = prefs.getString(storageKey);
    if (raw == null || raw.isEmpty) return const <SearchHistoryEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <SearchHistoryEntry>[];
      final entries = decoded
          .map(SearchHistoryEntry.tryParse)
          .whereType<SearchHistoryEntry>()
          .toList(growable: false);
      return entries.length > maxEntries
          ? entries.sublist(0, maxEntries)
          : entries;
    } catch (_) {
      return const <SearchHistoryEntry>[];
    }
  }

  /// Records [query] at the front of the history. Repeats move the existing
  /// entry to the front instead of duplicating (case-insensitive identity).
  /// Blank queries are ignored.
  Future<List<SearchHistoryEntry>> record(String query, {DateTime? at}) async {
    final trimmed = query.trim();
    final current = await load();
    if (trimmed.isEmpty) return current;
    final next = <SearchHistoryEntry>[
      SearchHistoryEntry(query: trimmed, searchedAt: at ?? DateTime.now()),
      ...current.where(
        (entry) => entry.query.toLowerCase() != trimmed.toLowerCase(),
      ),
    ];
    final capped = next.length > maxEntries
        ? next.sublist(0, maxEntries)
        : next;
    await _persist(capped);
    return capped;
  }

  /// Removes every entry matching [query] (case-insensitive).
  Future<List<SearchHistoryEntry>> remove(String query) async {
    final trimmed = query.trim().toLowerCase();
    final current = await load();
    final next = current
        .where((entry) => entry.query.toLowerCase() != trimmed)
        .toList(growable: false);
    await _persist(next);
    return next;
  }

  /// Clears the whole history.
  Future<void> clear() async {
    final prefs = await _prefs;
    await prefs.remove(storageKey);
  }

  Future<void> _persist(List<SearchHistoryEntry> entries) async {
    final prefs = await _prefs;
    await prefs.setString(
      storageKey,
      jsonEncode(entries.map((entry) => entry.toJson()).toList()),
    );
  }
}
