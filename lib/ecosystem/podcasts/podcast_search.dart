/// Podcast directory search (Feature Group 9).
///
/// Uses the public iTunes Search API, which needs no key, no account and no
/// backend of ours — consistent with the app's "works without a cloud backend"
/// rule. The provider is behind an interface so a future directory (Podcast
/// Index, a self-hosted catalogue) drops in without touching the UI.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('PodcastSearch');

/// One directory hit. Deliberately smaller than a subscription: the feed is
/// only parsed once the user actually subscribes.
class PodcastSearchResult {
  const PodcastSearchResult({
    required this.feedUrl,
    required this.title,
    this.author = '',
    this.imageUrl,
    this.episodeCount = 0,
    this.categories = const <String>[],
  });

  final String feedUrl;
  final String title;
  final String author;
  final String? imageUrl;
  final int episodeCount;
  final List<String> categories;
}

/// Directory port.
abstract interface class PodcastSearchProvider {
  /// Stable id for logging and provider-priority settings.
  String get providerId;

  /// Human-readable name for the UI.
  String get displayName;

  Future<List<PodcastSearchResult>> search(String query, {int limit});
}

/// iTunes Search API implementation.
class ITunesPodcastSearchProvider implements PodcastSearchProvider {
  ITunesPodcastSearchProvider({http.Client? client, this.country = 'US'})
    : _client = client ?? http.Client();

  final http.Client _client;

  /// Storefront to search; affects ranking and localized titles.
  final String country;

  static const Duration _timeout = Duration(seconds: 12);

  @override
  String get providerId => 'itunes';

  @override
  String get displayName => 'Apple Podcasts';

  @override
  Future<List<PodcastSearchResult>> search(String query, {int limit = 25}) async {
    final term = query.trim();
    if (term.isEmpty) return const <PodcastSearchResult>[];

    final uri = Uri.https('itunes.apple.com', '/search', <String, String>{
      'term': term,
      'media': 'podcast',
      'entity': 'podcast',
      'limit': '${limit.clamp(1, 200)}',
      'country': country,
    });

    try {
      final response = await _client.get(uri).timeout(_timeout);
      if (response.statusCode != 200) {
        _log.w('iTunes search HTTP ${response.statusCode}');
        return const <PodcastSearchResult>[];
      }
      return parseResults(response.body);
    } catch (error) {
      _log.w('iTunes search failed: $error');
      return const <PodcastSearchResult>[];
    }
  }

  /// Pure decoder, exposed for tests.
  ///
  /// Skips entries without a usable feed URL rather than surfacing dead rows.
  static List<PodcastSearchResult> parseResults(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return const <PodcastSearchResult>[];
    }
    if (decoded is! Map) return const <PodcastSearchResult>[];
    final results = Map<String, Object?>.from(decoded)['results'];
    if (results is! List) return const <PodcastSearchResult>[];

    final parsed = <PodcastSearchResult>[];
    final seenFeeds = <String>{};
    for (final entry in results) {
      if (entry is! Map) continue;
      final row = Map<String, Object?>.from(entry);
      final feedUrl = row['feedUrl']?.toString().trim() ?? '';
      if (feedUrl.isEmpty || !seenFeeds.add(feedUrl)) continue;

      final genres = row['genres'];
      parsed.add(
        PodcastSearchResult(
          feedUrl: feedUrl,
          title: row['collectionName']?.toString() ??
              row['trackName']?.toString() ??
              '',
          author: row['artistName']?.toString() ?? '',
          imageUrl: _firstImage(row),
          episodeCount: row['trackCount'] is num
              ? (row['trackCount']! as num).toInt()
              : 0,
          categories: genres is List
              ? genres
                    .map((genre) => genre.toString())
                    .where((genre) => genre.isNotEmpty)
                    .toList(growable: false)
              : const <String>[],
        ),
      );
    }
    return parsed;
  }

  /// Prefers the largest artwork the directory offers.
  static String? _firstImage(Map<String, Object?> entry) {
    for (final key in const <String>[
      'artworkUrl600',
      'artworkUrl100',
      'artworkUrl60',
      'artworkUrl30',
    ]) {
      final value = entry[key]?.toString();
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  void dispose() => _client.close();
}
