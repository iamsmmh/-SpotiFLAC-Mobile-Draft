import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_search.dart';

PodcastEpisode _episode({
  String key = 'k',
  Duration duration = const Duration(minutes: 30),
  Duration played = Duration.zero,
  String? filePath,
  EpisodeDownloadState state = EpisodeDownloadState.none,
}) {
  return PodcastEpisode(
    episodeKey: key,
    feedUrl: 'https://a/f.xml',
    guid: key,
    title: 'Episode',
    audioUrl: 'https://a/e.mp3',
    duration: duration,
    playedPosition: played,
    filePath: filePath,
    downloadState: state,
    addedAt: DateTime.utc(2026),
  );
}

void main() {
  group('PodcastEpisode playback source', () {
    test('streams from the network when nothing is downloaded', () {
      expect(_episode().playbackSource, 'https://a/e.mp3');
      expect(_episode().isDownloaded, isFalse);
    });

    test('plays the local file once downloaded', () {
      final episode = _episode(
        filePath: '/data/e.mp3',
        state: EpisodeDownloadState.downloaded,
      );
      expect(episode.isDownloaded, isTrue);
      expect(episode.playbackSource, '/data/e.mp3');
    });

    test('a downloaded state with no path is not treated as offline', () {
      final episode = _episode(state: EpisodeDownloadState.downloaded);
      expect(episode.isDownloaded, isFalse);
      expect(episode.playbackSource, 'https://a/e.mp3');
    });
  });

  group('PodcastEpisode progress', () {
    test('is a clamped fraction of the duration', () {
      expect(_episode(played: const Duration(minutes: 15)).progress, 0.5);
      expect(_episode(played: const Duration(minutes: 45)).progress, 1.0);
      expect(_episode(played: Duration.zero).progress, 0.0);
    });

    test('is zero when the feed declares no duration', () {
      final episode = _episode(
        duration: Duration.zero,
        played: const Duration(minutes: 5),
      );
      expect(episode.progress, 0.0);
    });

    test('remaining never goes negative', () {
      expect(
        _episode(played: const Duration(minutes: 45)).remaining,
        Duration.zero,
      );
      expect(
        _episode(played: const Duration(minutes: 10)).remaining,
        const Duration(minutes: 20),
      );
    });
  });

  group('row round-trips', () {
    test('an episode survives toRow/fromRow unchanged', () {
      final original = PodcastEpisode(
        episodeKey: 'key',
        feedUrl: 'https://a/f.xml',
        guid: 'g',
        title: 'T',
        description: 'D',
        audioUrl: 'https://a/e.mp3',
        imageUrl: 'https://a/e.jpg',
        duration: const Duration(minutes: 42),
        publishedAt: DateTime.utc(2025, 6, 10, 8),
        filePath: '/data/e.mp3',
        playedPosition: const Duration(minutes: 3),
        isPlayed: true,
        downloadState: EpisodeDownloadState.downloaded,
        addedAt: DateTime.utc(2026),
      );

      final restored = PodcastEpisode.fromRow(original.toRow());

      expect(restored.episodeKey, original.episodeKey);
      expect(restored.title, original.title);
      expect(restored.audioUrl, original.audioUrl);
      expect(restored.duration, original.duration);
      expect(restored.publishedAt, original.publishedAt);
      expect(restored.filePath, original.filePath);
      expect(restored.playedPosition, original.playedPosition);
      expect(restored.isPlayed, isTrue);
      expect(restored.downloadState, EpisodeDownloadState.downloaded);
    });

    test('a subscription survives toRow/fromRow including categories', () {
      final original = PodcastSubscription(
        feedUrl: 'https://a/f.xml',
        title: 'Show',
        author: 'Ada',
        description: 'Desc',
        imageUrl: 'https://a/s.jpg',
        categories: const <String>['Tech', 'Music'],
        addedAt: DateTime.utc(2026),
        lastCheckedAt: DateTime.utc(2026, 2),
        autoDownload: true,
        keepEpisodes: 7,
        notifyNew: false,
      );

      final restored = PodcastSubscription.fromRow(original.toRow());

      expect(restored.feedUrl, original.feedUrl);
      expect(restored.categories, <String>['Tech', 'Music']);
      expect(restored.autoDownload, isTrue);
      expect(restored.keepEpisodes, 7);
      expect(restored.notifyNew, isFalse);
      expect(restored.lastCheckedAt, DateTime.utc(2026, 2));
    });

    test('an empty category list round-trips as empty', () {
      final subscription = PodcastSubscription(
        feedUrl: 'f',
        title: 'T',
        addedAt: DateTime.utc(2026),
      );
      expect(
        PodcastSubscription.fromRow(subscription.toRow()).categories,
        isEmpty,
      );
    });

    test('missing columns fall back to safe defaults', () {
      final episode = PodcastEpisode.fromRow(<String, Object?>{
        'episode_key': 'k',
        'feed_url': 'f',
        'audio_url': 'https://a/e.mp3',
      });
      expect(episode.duration, Duration.zero);
      expect(episode.isPlayed, isFalse);
      expect(episode.downloadState, EpisodeDownloadState.none);
      expect(episode.publishedAt, isNull);
    });
  });

  group('EpisodeDownloadState.parse', () {
    test('round-trips known names and defaults unknown ones', () {
      for (final state in EpisodeDownloadState.values) {
        expect(EpisodeDownloadState.parse(state.name), state);
      }
      expect(EpisodeDownloadState.parse('nonsense'),
          EpisodeDownloadState.none);
      expect(EpisodeDownloadState.parse(null), EpisodeDownloadState.none);
    });
  });

  group('PodcastFeed', () {
    test('builds a subscription stamped with the given clock', () {
      const feed = PodcastFeed(
        feedUrl: 'https://a/f.xml',
        title: 'Show',
        author: 'Ada',
        categories: <String>['Tech'],
      );
      final now = DateTime.utc(2026, 5, 1);
      final subscription = feed.toSubscription(now: now, keepEpisodes: 5);

      expect(subscription.addedAt, now);
      expect(subscription.lastCheckedAt, now);
      expect(subscription.keepEpisodes, 5);
      expect(subscription.title, 'Show');
    });
  });

  group('iTunes search decoding', () {
    test('maps directory rows to results', () {
      const body = '''
      {"resultCount":1,"results":[{
        "collectionName":"Signal & Noise",
        "artistName":"Ada",
        "feedUrl":"https://a/f.xml",
        "artworkUrl600":"https://a/600.jpg",
        "artworkUrl100":"https://a/100.jpg",
        "trackCount":42,
        "genres":["Technology","Music"]}]}
      ''';
      final results = ITunesPodcastSearchProvider.parseResults(body);
      expect(results.single.title, 'Signal & Noise');
      expect(results.single.author, 'Ada');
      expect(results.single.feedUrl, 'https://a/f.xml');
      expect(results.single.imageUrl, 'https://a/600.jpg');
      expect(results.single.episodeCount, 42);
      expect(results.single.categories, <String>['Technology', 'Music']);
    });

    test('drops rows with no feed URL and de-duplicates feeds', () {
      const body = '''
      {"results":[
        {"collectionName":"No feed"},
        {"collectionName":"A","feedUrl":"https://a/f.xml"},
        {"collectionName":"A duplicate","feedUrl":"https://a/f.xml"}]}
      ''';
      final results = ITunesPodcastSearchProvider.parseResults(body);
      expect(results.length, 1);
      expect(results.single.title, 'A');
    });

    test('malformed payloads yield an empty list', () {
      expect(ITunesPodcastSearchProvider.parseResults('not json'), isEmpty);
      expect(ITunesPodcastSearchProvider.parseResults('[]'), isEmpty);
      expect(ITunesPodcastSearchProvider.parseResults('{}'), isEmpty);
    });
  });
}
