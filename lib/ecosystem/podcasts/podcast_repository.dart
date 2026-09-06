/// Podcast persistence + refresh (Feature Group 9).
///
/// Owns the `ec_podcast_subscriptions` / `ec_podcast_episodes` tables declared
/// in schema v1..v4. Nothing here is podcast-*player* logic — playback reuses
/// the existing `MusicPlayerHandler` via `PodcastPlayer`.
///
/// Refresh contract: re-parsing a feed is idempotent. Existing episodes keep
/// their local state (resume position, played flag, downloaded file); only
/// publisher-owned metadata is refreshed. That is what makes "refresh" safe to
/// run on every app start.
library;

import 'package:http/http.dart' as http;
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';
import 'package:spotiflac_android/ecosystem/podcasts/rss_provider.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:sqflite/sqflite.dart';

final _log = AppLogger('PodcastRepo');

/// Fetches feed bodies. Split out so tests inject canned XML with no network.
abstract interface class FeedFetcher {
  Future<String> fetch(String feedUrl);
}

/// HTTP feed fetcher.
class HttpFeedFetcher implements FeedFetcher {
  HttpFeedFetcher({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const Duration _timeout = Duration(seconds: 20);

  @override
  Future<String> fetch(String feedUrl) async {
    final uri = Uri.parse(feedUrl);
    final response = await _client
        .get(uri, headers: const <String, String>{
          'Accept': 'application/rss+xml, application/xml, text/xml, */*',
          'User-Agent': 'SpotiFLAC-Mobile/5.0 (podcast client)',
        })
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw PodcastFeedFormatException('HTTP ${response.statusCode}');
    }
    // Feeds routinely mis-declare their charset; utf8 with malformed bytes
    // allowed is the pragmatic choice.
    return response.body;
  }

  void dispose() => _client.close();
}

class PodcastRepository {
  PodcastRepository({
    EcosystemDatabase? database,
    FeedFetcher? fetcher,
    RssFeedParser parser = const RssFeedParser(),
  }) : _database = database ?? EcosystemDatabase.instance,
       _fetcher = fetcher ?? HttpFeedFetcher(),
       _parser = parser;

  final EcosystemDatabase _database;
  final FeedFetcher _fetcher;
  final RssFeedParser _parser;

  // -- Subscriptions -------------------------------------------------------

  Future<List<PodcastSubscription>> subscriptions() async {
    final db = await _database.database;
    final rows = await db.query(
      tablePodcastSubscriptions,
      orderBy: 'title COLLATE NOCASE ASC',
    );
    return rows
        .map(PodcastSubscription.fromRow)
        .where((entry) => entry.feedUrl.isNotEmpty)
        .toList(growable: false);
  }

  Future<PodcastSubscription?> subscription(String feedUrl) async {
    final db = await _database.database;
    final rows = await db.query(
      tablePodcastSubscriptions,
      where: 'feed_url = ?',
      whereArgs: <Object?>[feedUrl],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PodcastSubscription.fromRow(rows.first);
  }

  Future<bool> isSubscribed(String feedUrl) async =>
      (await subscription(feedUrl)) != null;

  /// Subscribes to [feedUrl], fetching and storing the feed in one step.
  ///
  /// Returns the stored subscription. Safe to call on an already-subscribed
  /// feed: it behaves as a refresh and preserves user settings.
  Future<PodcastSubscription> subscribe(
    String feedUrl, {
    bool autoDownload = false,
    int keepEpisodes = 3,
    DateTime? now,
  }) async {
    final stamp = (now ?? DateTime.now()).toUtc();
    final body = await _fetcher.fetch(feedUrl);
    final feed = _parser.parse(feedUrl: feedUrl, body: body, now: stamp);

    final existing = await subscription(feedUrl);
    final record = existing == null
        ? feed.toSubscription(
            now: stamp,
            autoDownload: autoDownload,
            keepEpisodes: keepEpisodes,
          )
        : existing.copyWith(
            title: feed.title.isEmpty ? existing.title : feed.title,
            author: feed.author,
            description: feed.description,
            imageUrl: feed.imageUrl,
            categories: feed.categories,
            lastCheckedAt: stamp,
          );

    final db = await _database.database;
    await db.insert(
      tablePodcastSubscriptions,
      record.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _mergeEpisodes(db, feed.episodes);
    return record;
  }

  /// Removes a subscription and all of its episode rows.
  ///
  /// Downloaded files are deleted by [PodcastLibrary.unsubscribe], which owns
  /// the filesystem; the repository only owns rows.
  Future<void> unsubscribe(String feedUrl) async {
    final db = await _database.database;
    await db.delete(
      tablePodcastEpisodes,
      where: 'feed_url = ?',
      whereArgs: <Object?>[feedUrl],
    );
    await db.delete(
      tablePodcastSubscriptions,
      where: 'feed_url = ?',
      whereArgs: <Object?>[feedUrl],
    );
  }

  Future<void> updateSubscription(PodcastSubscription subscription) async {
    final db = await _database.database;
    await db.update(
      tablePodcastSubscriptions,
      subscription.toRow(),
      where: 'feed_url = ?',
      whereArgs: <Object?>[subscription.feedUrl],
    );
  }

  // -- Episodes ------------------------------------------------------------

  Future<List<PodcastEpisode>> episodes(
    String feedUrl, {
    int? limit,
    bool unplayedOnly = false,
  }) async {
    final db = await _database.database;
    final rows = await db.query(
      tablePodcastEpisodes,
      where: unplayedOnly ? 'feed_url = ? AND is_played = 0' : 'feed_url = ?',
      whereArgs: <Object?>[feedUrl],
      orderBy: 'published_at DESC',
      limit: limit,
    );
    return rows.map(PodcastEpisode.fromRow).toList(growable: false);
  }

  Future<PodcastEpisode?> episode(String episodeKey) async {
    final db = await _database.database;
    final rows = await db.query(
      tablePodcastEpisodes,
      where: 'episode_key = ?',
      whereArgs: <Object?>[episodeKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return PodcastEpisode.fromRow(rows.first);
  }

  /// Newest episodes across every subscription — the "Latest" inbox.
  Future<List<PodcastEpisode>> latestEpisodes({int limit = 50}) async {
    final db = await _database.database;
    final rows = await db.query(
      tablePodcastEpisodes,
      orderBy: 'published_at DESC',
      limit: limit,
    );
    return rows.map(PodcastEpisode.fromRow).toList(growable: false);
  }

  /// Episodes with a resume point but not yet finished — "Continue listening".
  Future<List<PodcastEpisode>> inProgressEpisodes({int limit = 20}) async {
    final db = await _database.database;
    final rows = await db.query(
      tablePodcastEpisodes,
      where: 'played_seconds > 0 AND is_played = 0',
      orderBy: 'published_at DESC',
      limit: limit,
    );
    return rows.map(PodcastEpisode.fromRow).toList(growable: false);
  }

  Future<List<PodcastEpisode>> downloadedEpisodes() async {
    final db = await _database.database;
    final rows = await db.query(
      tablePodcastEpisodes,
      where: "download_state = ? AND file_path IS NOT NULL AND file_path != ''",
      whereArgs: <Object?>[EpisodeDownloadState.downloaded.name],
      orderBy: 'published_at DESC',
    );
    return rows.map(PodcastEpisode.fromRow).toList(growable: false);
  }

  Future<void> upsertEpisode(PodcastEpisode episode) async {
    final db = await _database.database;
    await db.insert(
      tablePodcastEpisodes,
      episode.toRow(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Stores a resume point. Marks the episode played once it is within
  /// [completionSlack] of the end, so a listener who stops during the outro
  /// still gets it checked off.
  Future<void> saveProgress(
    String episodeKey,
    Duration position, {
    Duration completionSlack = const Duration(seconds: 30),
  }) async {
    final current = await episode(episodeKey);
    if (current == null) return;

    final total = current.duration;
    final completed = total > Duration.zero &&
        position >= (total - completionSlack);

    // Reaching the end marks it played; otherwise the existing flag stands, so
    // saving progress can never silently un-complete an episode.
    final played = completed || current.isPlayed;

    final db = await _database.database;
    await db.update(
      tablePodcastEpisodes,
      <String, Object?>{
        'played_seconds': position.inSeconds,
        'is_played': played ? 1 : 0,
      },
      where: 'episode_key = ?',
      whereArgs: <Object?>[episodeKey],
    );
  }

  Future<void> markPlayed(String episodeKey, {bool played = true}) async {
    final db = await _database.database;
    await db.update(
      tablePodcastEpisodes,
      <String, Object?>{
        'is_played': played ? 1 : 0,
        // Un-marking rewinds to the start so the episode is genuinely fresh.
        if (!played) 'played_seconds': 0,
      },
      where: 'episode_key = ?',
      whereArgs: <Object?>[episodeKey],
    );
  }

  Future<void> setDownloadState(
    String episodeKey,
    EpisodeDownloadState state, {
    String? filePath,
  }) async {
    final db = await _database.database;
    await db.update(
      tablePodcastEpisodes,
      <String, Object?>{
        'download_state': state.name,
        'file_path': state == EpisodeDownloadState.downloaded ? filePath : null,
      },
      where: 'episode_key = ?',
      whereArgs: <Object?>[episodeKey],
    );
  }

  // -- Refresh -------------------------------------------------------------

  /// Re-fetches one feed and returns the episodes that were not already known.
  ///
  /// Never throws: transport and parse failures come back as a failed
  /// [PodcastRefreshResult] so a batch refresh keeps going.
  Future<PodcastRefreshResult> refresh(String feedUrl, {DateTime? now}) async {
    final stamp = (now ?? DateTime.now()).toUtc();
    try {
      final body = await _fetcher.fetch(feedUrl);
      final feed = _parser.parse(feedUrl: feedUrl, body: body, now: stamp);
      final db = await _database.database;

      final knownKeys = await _existingKeys(db, feedUrl);
      final fresh = feed.episodes
          .where((episode) => !knownKeys.contains(episode.episodeKey))
          .toList(growable: false);

      await _mergeEpisodes(db, feed.episodes);
      await db.update(
        tablePodcastSubscriptions,
        <String, Object?>{
          'last_checked_at': stamp.toIso8601String(),
          if (feed.title.isNotEmpty) 'title': feed.title,
          if (feed.imageUrl != null) 'image_url': feed.imageUrl,
        },
        where: 'feed_url = ?',
        whereArgs: <Object?>[feedUrl],
      );

      return PodcastRefreshResult(
        feedUrl: feedUrl,
        newEpisodes: fresh,
        totalEpisodes: feed.episodes.length,
      );
    } catch (error) {
      _log.w('Refresh failed for $feedUrl: $error');
      return PodcastRefreshResult(
        feedUrl: feedUrl,
        failed: true,
        error: '$error',
      );
    }
  }

  /// Refreshes every subscription, sequentially to stay polite to publishers
  /// and to keep memory flat on large libraries.
  Future<List<PodcastRefreshResult>> refreshAll({DateTime? now}) async {
    final results = <PodcastRefreshResult>[];
    for (final subscription in await subscriptions()) {
      results.add(await refresh(subscription.feedUrl, now: now));
    }
    return results;
  }

  Future<Set<String>> _existingKeys(DatabaseExecutor db, String feedUrl) async {
    final rows = await db.query(
      tablePodcastEpisodes,
      columns: <String>['episode_key'],
      where: 'feed_url = ?',
      whereArgs: <Object?>[feedUrl],
    );
    return rows
        .map((row) => row['episode_key']?.toString() ?? '')
        .where((key) => key.isNotEmpty)
        .toSet();
  }

  /// Inserts new episodes and refreshes publisher metadata on known ones,
  /// **without** clobbering local listening/download state.
  Future<void> _mergeEpisodes(
    DatabaseExecutor db,
    List<PodcastEpisode> episodes,
  ) async {
    if (episodes.isEmpty) return;
    final batch = db.batch();
    for (final episode in episodes) {
      if (episode.episodeKey.isEmpty) continue;
      batch.insert(
        tablePodcastEpisodes,
        episode.toRow(),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      // Publisher-owned columns only — file_path, played_seconds, is_played
      // and download_state are intentionally absent.
      batch.update(
        tablePodcastEpisodes,
        <String, Object?>{
          'title': episode.title,
          'description': episode.description,
          'audio_url': episode.audioUrl,
          'image_url': episode.imageUrl,
          'duration_seconds': episode.duration.inSeconds,
          'published_at': episode.publishedAt?.toIso8601String(),
        },
        where: 'episode_key = ?',
        whereArgs: <Object?>[episode.episodeKey],
      );
    }
    await batch.commit(noResult: true);
  }
}
