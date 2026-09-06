import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';
import 'package:spotiflac_android/ecosystem/podcasts/rss_provider.dart';

const String _rssFeed = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"
     xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"
     xmlns:content="http://purl.org/rss/1.0/modules/content/">
  <channel>
    <title>Signal &amp; Noise</title>
    <description>Weekly audio engineering talk.</description>
    <itunes:author>Ada Lovelace</itunes:author>
    <itunes:image href="https://cdn.example/show.jpg"/>
    <itunes:category text="Technology"/>
    <itunes:category text="Music"/>
    <item>
      <title>Episode 2: Loudness wars</title>
      <guid isPermaLink="false">ep-002</guid>
      <description>All about dynamic range.</description>
      <pubDate>Tue, 10 Jun 2025 08:00:00 GMT</pubDate>
      <itunes:duration>1:02:03</itunes:duration>
      <itunes:image href="https://cdn.example/ep2.jpg"/>
      <enclosure url="https://cdn.example/ep2.mp3" type="audio/mpeg" length="1000"/>
    </item>
    <item>
      <title>Episode 1: Sample rates</title>
      <guid>ep-001</guid>
      <pubDate>Tue, 03 Jun 2025 08:00:00 GMT</pubDate>
      <itunes:duration>2705</itunes:duration>
      <enclosure url="https://cdn.example/ep1.mp3" type="audio/mpeg"/>
    </item>
  </channel>
</rss>
''';

const String _atomFeed = '''
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"
      xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
  <title>Atom Cast</title>
  <subtitle>An Atom-published show.</subtitle>
  <author><name>Grace Hopper</name></author>
  <entry>
    <id>urn:uuid:episode-a</id>
    <title>Atom episode A</title>
    <summary>First one.</summary>
    <published>2025-06-10T08:00:00Z</published>
    <itunes:duration>10:00</itunes:duration>
    <link rel="enclosure" type="audio/mpeg" href="https://cdn.example/a.mp3"/>
  </entry>
</feed>
''';

void main() {
  const parser = RssFeedParser();
  final now = DateTime.utc(2026, 1, 1);

  group('RSS 2.0 parsing', () {
    final feed = parser.parse(
      feedUrl: 'https://example.com/feed.xml',
      body: _rssFeed,
      now: now,
    );

    test('reads channel metadata including the itunes namespace', () {
      expect(feed.title, 'Signal & Noise');
      expect(feed.author, 'Ada Lovelace');
      expect(feed.description, 'Weekly audio engineering talk.');
      expect(feed.imageUrl, 'https://cdn.example/show.jpg');
      expect(feed.categories, containsAll(<String>['Technology', 'Music']));
    });

    test('reads every episode with its enclosure', () {
      expect(feed.episodes.length, 2);
      final latest = feed.episodes.first;
      expect(latest.title, 'Episode 2: Loudness wars');
      expect(latest.audioUrl, 'https://cdn.example/ep2.mp3');
      expect(latest.description, 'All about dynamic range.');
      expect(latest.imageUrl, 'https://cdn.example/ep2.jpg');
      expect(latest.guid, 'ep-002');
    });

    test('orders episodes newest first', () {
      expect(
        feed.episodes.map((episode) => episode.guid),
        <String>['ep-002', 'ep-001'],
      );
    });

    test('parses HH:MM:SS and bare-seconds durations', () {
      expect(feed.episodes[0].duration, const Duration(minutes: 62, seconds: 3));
      expect(feed.episodes[1].duration, const Duration(seconds: 2705));
    });

    test('parses RFC 822 pubDate as UTC', () {
      expect(feed.episodes.first.publishedAt, DateTime.utc(2025, 6, 10, 8));
    });

    test('stamps addedAt from the injected clock', () {
      expect(feed.episodes.first.addedAt, now);
    });
  });

  group('Atom parsing', () {
    test('reads entries with rel=enclosure links', () {
      final feed = parser.parse(
        feedUrl: 'https://example.com/atom.xml',
        body: _atomFeed,
        now: now,
      );
      expect(feed.title, 'Atom Cast');
      expect(feed.author, 'Grace Hopper');
      expect(feed.episodes.single.audioUrl, 'https://cdn.example/a.mp3');
      expect(feed.episodes.single.duration, const Duration(minutes: 10));
      expect(feed.episodes.single.publishedAt, DateTime.utc(2025, 6, 10, 8));
    });
  });

  group('resilience', () {
    test('items without playable audio are skipped, not crashed on', () {
      const body = '''
        <rss><channel><title>T</title>
          <item><title>No audio</title><guid>x</guid></item>
          <item><title>Video</title><guid>v</guid>
            <enclosure url="https://e/v.mp4" type="video/mp4"/></item>
          <item><title>Good</title><guid>g</guid>
            <enclosure url="https://e/g.mp3" type="audio/mpeg"/></item>
        </channel></rss>
      ''';
      final feed = parser.parse(feedUrl: 'f', body: body, now: now);
      expect(feed.episodes.single.guid, 'g');
    });

    test('an enclosure with no type is accepted as audio', () {
      const body = '''
        <rss><channel><title>T</title>
          <item><title>Untyped</title><guid>u</guid>
            <enclosure url="https://e/u.mp3"/></item>
        </channel></rss>
      ''';
      final feed = parser.parse(feedUrl: 'f', body: body, now: now);
      expect(feed.episodes.single.audioUrl, 'https://e/u.mp3');
    });

    test('media:content is used when no enclosure exists', () {
      const body = '''
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><title>T</title>
          <item><title>M</title><guid>m</guid>
            <media:content url="https://e/m.mp3" type="audio/mpeg"/></item>
        </channel></rss>
      ''';
      final feed = parser.parse(feedUrl: 'f', body: body, now: now);
      expect(feed.episodes.single.audioUrl, 'https://e/m.mp3');
    });

    test('undated episodes sort below dated ones', () {
      const body = '''
        <rss><channel><title>T</title>
          <item><title>Undated</title><guid>u</guid>
            <enclosure url="https://e/u.mp3" type="audio/mpeg"/></item>
          <item><title>Dated</title><guid>d</guid>
            <pubDate>Tue, 10 Jun 2025 08:00:00 GMT</pubDate>
            <enclosure url="https://e/d.mp3" type="audio/mpeg"/></item>
        </channel></rss>
      ''';
      final feed = parser.parse(feedUrl: 'f', body: body, now: now);
      expect(feed.episodes.map((e) => e.guid), <String>['d', 'u']);
    });

    test('malformed XML throws a typed exception', () {
      expect(
        () => parser.parse(feedUrl: 'f', body: '<rss><channel>', now: now),
        throwsA(isA<PodcastFeedFormatException>()),
      );
    });

    test('non-feed XML throws a typed exception', () {
      expect(
        () => parser.parse(feedUrl: 'f', body: '<html><body/></html>', now: now),
        throwsA(isA<PodcastFeedFormatException>()),
      );
    });

    test('tryParse returns null instead of throwing', () {
      expect(parser.tryParse(feedUrl: 'f', body: 'not xml'), isNull);
    });
  });

  group('parseDuration', () {
    test('handles the formats publishers actually emit', () {
      expect(parseDuration('90'), const Duration(seconds: 90));
      expect(parseDuration('3:30'), const Duration(minutes: 3, seconds: 30));
      expect(parseDuration('1:02:03'),
          const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(parseDuration(' 45 '), const Duration(seconds: 45));
    });

    test('unparseable input degrades to zero rather than failing', () {
      expect(parseDuration(''), Duration.zero);
      expect(parseDuration('abc'), Duration.zero);
      expect(parseDuration('1:2:3:4'), Duration.zero);
      expect(parseDuration('-5'), Duration.zero);
    });
  });

  group('parseFeedDate', () {
    test('parses RFC 822 with numeric and alphabetic zones', () {
      expect(parseFeedDate('Tue, 10 Jun 2025 08:00:00 GMT'),
          DateTime.utc(2025, 6, 10, 8));
      expect(parseFeedDate('10 Jun 2025 08:00:00 +0200'),
          DateTime.utc(2025, 6, 10, 6));
      expect(parseFeedDate('Tue, 10 Jun 2025 08:00:00 -0500'),
          DateTime.utc(2025, 6, 10, 13));
    });

    test('parses ISO-8601', () {
      expect(parseFeedDate('2025-06-10T08:00:00Z'),
          DateTime.utc(2025, 6, 10, 8));
    });

    test('returns null for junk', () {
      expect(parseFeedDate(''), isNull);
      expect(parseFeedDate('sometime last week'), isNull);
    });
  });

  group('buildEpisodeKey', () {
    test('prefers the guid and namespaces by feed', () {
      final key = buildEpisodeKey(
        feedUrl: 'https://a/f.xml',
        guid: 'g1',
        audioUrl: 'https://a/1.mp3',
        title: 'T',
      );
      expect(key, contains('https://a/f.xml'));
      expect(key, contains('g1'));
    });

    test('falls back to the audio URL, then the title', () {
      expect(
        buildEpisodeKey(feedUrl: 'f', audioUrl: 'https://a/1.mp3', title: 'T'),
        'f\u001fhttps://a/1.mp3',
      );
      expect(buildEpisodeKey(feedUrl: 'f', title: 'Only title'),
          'f\u001fOnly title');
    });

    test('the same feed never collides with another feed', () {
      expect(
        buildEpisodeKey(feedUrl: 'a', guid: 'g'),
        isNot(buildEpisodeKey(feedUrl: 'b', guid: 'g')),
      );
    });
  });
}
