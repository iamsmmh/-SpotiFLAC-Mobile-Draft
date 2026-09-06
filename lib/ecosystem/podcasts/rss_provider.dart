/// RSS / Atom feed ingestion for the podcast platform (Feature Group 9).
///
/// [RssFeedParser] is a **pure** function of the feed body: it takes XML text
/// and returns a [PodcastFeed]. No HTTP, no clock, no database — so the messy
/// part of podcasting (every publisher emits slightly different XML) is fully
/// unit-testable. [RssProvider] is the thin network wrapper around it.
///
/// Handles the dialects that matter in practice:
///   * RSS 2.0 `<channel><item>` with `<enclosure url=... type=audio/*>`
///   * the `itunes:` namespace (author, image, duration, summary, category)
///   * Atom `<feed><entry>` with `<link rel="enclosure">`
///   * `<media:content>` as an enclosure fallback
///   * RFC 822 (`Tue, 10 Jun 2025 08:00:00 GMT`) and ISO-8601 dates
///   * `HH:MM:SS`, `MM:SS` and bare-seconds durations
library;

import 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:xml/xml.dart';

final _log = AppLogger('RssProvider');

/// Thrown when a feed body cannot be understood as a podcast feed.
class PodcastFeedFormatException implements Exception {
  const PodcastFeedFormatException(this.message);

  final String message;

  @override
  String toString() => 'PodcastFeedFormatException: $message';
}

/// Pure XML → [PodcastFeed] translation.
class RssFeedParser {
  const RssFeedParser();

  /// Parses [body] as a podcast feed published at [feedUrl].
  ///
  /// [now] stamps `addedAt` on the produced episodes; injected so tests are
  /// deterministic.
  PodcastFeed parse({
    required String feedUrl,
    required String body,
    DateTime? now,
  }) {
    final stamp = (now ?? DateTime.now()).toUtc();
    final XmlDocument document;
    try {
      document = XmlDocument.parse(body);
    } on XmlException catch (error) {
      throw PodcastFeedFormatException('malformed XML: ${error.message}');
    }

    final channel = _firstElement(document, 'channel');
    if (channel != null) {
      return _parseRss(feedUrl: feedUrl, channel: channel, now: stamp);
    }
    final atom = _firstElement(document, 'feed');
    if (atom != null) {
      return _parseAtom(feedUrl: feedUrl, feed: atom, now: stamp);
    }
    throw const PodcastFeedFormatException(
      'no <channel> (RSS) or <feed> (Atom) element found',
    );
  }

  /// Best-effort variant: returns null instead of throwing. Used by bulk
  /// refresh where one broken feed must not abort the batch.
  PodcastFeed? tryParse({
    required String feedUrl,
    required String body,
    DateTime? now,
  }) {
    try {
      return parse(feedUrl: feedUrl, body: body, now: now);
    } on PodcastFeedFormatException catch (error) {
      _log.w('Feed $feedUrl rejected: ${error.message}');
      return null;
    }
  }

  // -- RSS 2.0 -------------------------------------------------------------

  PodcastFeed _parseRss({
    required String feedUrl,
    required XmlElement channel,
    required DateTime now,
  }) {
    final episodes = <PodcastEpisode>[];
    for (final item in channel.findElements('item')) {
      final episode = _episodeFromRssItem(
        feedUrl: feedUrl,
        item: item,
        now: now,
      );
      if (episode != null) episodes.add(episode);
    }
    _sortNewestFirst(episodes);

    return PodcastFeed(
      feedUrl: feedUrl,
      title: _text(channel, 'title'),
      author: _firstNonEmpty(<String>[
        _text(channel, 'author', namespace: 'itunes'),
        _text(channel, 'owner', namespace: 'itunes'),
        _text(channel, 'managingEditor'),
      ]),
      description: _firstNonEmpty(<String>[
        _text(channel, 'description'),
        _text(channel, 'summary', namespace: 'itunes'),
        _text(channel, 'subtitle', namespace: 'itunes'),
      ]),
      imageUrl: _channelImage(channel),
      categories: _categories(channel),
      episodes: episodes,
    );
  }

  PodcastEpisode? _episodeFromRssItem({
    required String feedUrl,
    required XmlElement item,
    required DateTime now,
  }) {
    final audioUrl = _enclosureUrl(item);
    // An episode without playable audio is not an episode.
    if (audioUrl.isEmpty) return null;

    final guid = _text(item, 'guid');
    final title = _firstNonEmpty(<String>[
      _text(item, 'title'),
      _text(item, 'title', namespace: 'itunes'),
    ]);

    return PodcastEpisode(
      episodeKey: buildEpisodeKey(
        feedUrl: feedUrl,
        guid: guid,
        audioUrl: audioUrl,
        title: title,
      ),
      feedUrl: feedUrl,
      guid: guid,
      title: title,
      description: _firstNonEmpty(<String>[
        _text(item, 'summary', namespace: 'itunes'),
        _text(item, 'description'),
        _text(item, 'encoded', namespace: 'content'),
      ]),
      audioUrl: audioUrl,
      imageUrl: _itemImage(item),
      duration: parseDuration(_text(item, 'duration', namespace: 'itunes')),
      publishedAt: parseFeedDate(
        _firstNonEmpty(<String>[
          _text(item, 'pubDate'),
          _text(item, 'date', namespace: 'dc'),
        ]),
      ),
      addedAt: now,
    );
  }

  // -- Atom ----------------------------------------------------------------

  PodcastFeed _parseAtom({
    required String feedUrl,
    required XmlElement feed,
    required DateTime now,
  }) {
    final episodes = <PodcastEpisode>[];
    for (final entry in feed.findElements('entry')) {
      final audioUrl = _atomEnclosureUrl(entry);
      if (audioUrl.isEmpty) continue;
      final guid = _text(entry, 'id');
      final title = _text(entry, 'title');
      episodes.add(
        PodcastEpisode(
          episodeKey: buildEpisodeKey(
            feedUrl: feedUrl,
            guid: guid,
            audioUrl: audioUrl,
            title: title,
          ),
          feedUrl: feedUrl,
          guid: guid,
          title: title,
          description: _firstNonEmpty(<String>[
            _text(entry, 'summary'),
            _text(entry, 'content'),
          ]),
          audioUrl: audioUrl,
          imageUrl: _itemImage(entry),
          duration: parseDuration(
            _text(entry, 'duration', namespace: 'itunes'),
          ),
          publishedAt: parseFeedDate(
            _firstNonEmpty(<String>[
              _text(entry, 'published'),
              _text(entry, 'updated'),
            ]),
          ),
          addedAt: now,
        ),
      );
    }
    _sortNewestFirst(episodes);

    return PodcastFeed(
      feedUrl: feedUrl,
      title: _text(feed, 'title'),
      author: _firstNonEmpty(<String>[
        _text(feed, 'author', namespace: 'itunes'),
        _authorName(feed),
      ]),
      description: _firstNonEmpty(<String>[
        _text(feed, 'subtitle'),
        _text(feed, 'summary', namespace: 'itunes'),
      ]),
      imageUrl: _channelImage(feed),
      categories: _categories(feed),
      episodes: episodes,
    );
  }

  String _authorName(XmlElement feed) {
    for (final author in feed.findElements('author')) {
      final name = _text(author, 'name');
      if (name.isNotEmpty) return name;
    }
    return '';
  }

  // -- Shared extraction ---------------------------------------------------

  /// Finds the audio URL for an RSS item, preferring a real `<enclosure>`.
  String _enclosureUrl(XmlElement item) {
    for (final enclosure in item.findElements('enclosure')) {
      final url = enclosure.getAttribute('url')?.trim() ?? '';
      if (url.isEmpty) continue;
      final type = enclosure.getAttribute('type')?.toLowerCase() ?? '';
      // Empty type is common and usually still audio; only reject when the
      // publisher explicitly says it is something else (video, pdf...).
      if (type.isEmpty || type.startsWith('audio')) return url;
    }
    // media:content fallback.
    for (final media in _elementsNamed(item, 'content', namespace: 'media')) {
      final url = media.getAttribute('url')?.trim() ?? '';
      if (url.isEmpty) continue;
      final type = media.getAttribute('type')?.toLowerCase() ?? '';
      final medium = media.getAttribute('medium')?.toLowerCase() ?? '';
      if (type.startsWith('audio') || medium == 'audio' || type.isEmpty) {
        return url;
      }
    }
    return '';
  }

  String _atomEnclosureUrl(XmlElement entry) {
    for (final link in entry.findElements('link')) {
      if (link.getAttribute('rel') != 'enclosure') continue;
      final url = link.getAttribute('href')?.trim() ?? '';
      if (url.isEmpty) continue;
      final type = link.getAttribute('type')?.toLowerCase() ?? '';
      if (type.isEmpty || type.startsWith('audio')) return url;
    }
    return _enclosureUrl(entry);
  }

  String? _channelImage(XmlElement channel) {
    // itunes:image carries the artwork in an attribute.
    for (final image in _elementsNamed(
      channel,
      'image',
      namespace: 'itunes',
    )) {
      final href = image.getAttribute('href')?.trim();
      if (href != null && href.isNotEmpty) return href;
    }
    // RSS <image><url>...</url></image>
    for (final image in channel.findElements('image')) {
      final url = _text(image, 'url');
      if (url.isNotEmpty) return url;
      final href = image.getAttribute('href')?.trim();
      if (href != null && href.isNotEmpty) return href;
    }
    return null;
  }

  String? _itemImage(XmlElement item) {
    for (final image in _elementsNamed(item, 'image', namespace: 'itunes')) {
      final href = image.getAttribute('href')?.trim();
      if (href != null && href.isNotEmpty) return href;
    }
    for (final media in _elementsNamed(
      item,
      'thumbnail',
      namespace: 'media',
    )) {
      final url = media.getAttribute('url')?.trim();
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }

  List<String> _categories(XmlElement channel) {
    final seen = <String>{};
    for (final category in _elementsNamed(
      channel,
      'category',
      namespace: 'itunes',
    )) {
      final text = category.getAttribute('text')?.trim() ?? '';
      if (text.isNotEmpty) seen.add(text);
    }
    for (final category in channel.findElements('category')) {
      final text = category.innerText.trim();
      if (text.isNotEmpty) seen.add(text);
    }
    return seen.toList(growable: false);
  }

  void _sortNewestFirst(List<PodcastEpisode> episodes) {
    episodes.sort((a, b) {
      final left = a.publishedAt;
      final right = b.publishedAt;
      // Undated episodes sink below dated ones rather than jumping to the top.
      if (left == null && right == null) return 0;
      if (left == null) return 1;
      if (right == null) return -1;
      return right.compareTo(left);
    });
  }
}

/// Namespace-tolerant single-child text lookup.
///
/// Publishers disagree about prefixes (`itunes:duration` vs a default-namespace
/// `duration`), so we match on local name and, when a [namespace] prefix is
/// requested, prefer the prefixed element but accept the bare one.
String _text(XmlElement parent, String name, {String? namespace}) {
  final matches = _elementsNamed(parent, name, namespace: namespace);
  for (final match in matches) {
    final text = match.innerText.trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

Iterable<XmlElement> _elementsNamed(
  XmlElement parent,
  String name, {
  String? namespace,
}) {
  return parent.childElements.where((element) {
    if (element.name.local != name) return false;
    if (namespace == null) return true;
    final prefix = element.name.prefix;
    return prefix == namespace || prefix == null;
  });
}

XmlElement? _firstElement(XmlDocument document, String name) {
  for (final element in document.descendantElements) {
    if (element.name.local == name) return element;
  }
  return null;
}

String _firstNonEmpty(List<String> candidates) {
  for (final candidate in candidates) {
    if (candidate.isNotEmpty) return candidate;
  }
  return '';
}

const Map<String, int> _months = <String, int>{
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

/// Parses `itunes:duration`, which is `HH:MM:SS`, `MM:SS` or bare seconds.
///
/// Returns [Duration.zero] for anything unparseable — a missing duration is
/// normal and must never fail an import.
Duration parseDuration(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return Duration.zero;

  if (!value.contains(':')) {
    final seconds = int.tryParse(value) ?? double.tryParse(value)?.round();
    if (seconds == null || seconds < 0) return Duration.zero;
    return Duration(seconds: seconds);
  }

  final parts = value.split(':');
  if (parts.length > 3) return Duration.zero;
  final numbers = <int>[];
  for (final part in parts) {
    final parsed = int.tryParse(part.trim());
    if (parsed == null || parsed < 0) return Duration.zero;
    numbers.add(parsed);
  }
  return switch (numbers.length) {
    3 => Duration(hours: numbers[0], minutes: numbers[1], seconds: numbers[2]),
    2 => Duration(minutes: numbers[0], seconds: numbers[1]),
    _ => Duration(seconds: numbers[0]),
  };
}

/// Parses a feed timestamp: RFC 822 (`<pubDate>`) or ISO-8601 (Atom / dc:date).
///
/// Always returns UTC, or null when the value is absent/unparseable.
DateTime? parseFeedDate(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;

  // ISO-8601 first: cheap and unambiguous.
  final iso = DateTime.tryParse(value);
  if (iso != null) return iso.toUtc();

  // RFC 822: "Tue, 10 Jun 2025 08:00:00 GMT" (leading weekday optional).
  var text = value;
  final comma = text.indexOf(',');
  if (comma != -1) text = text.substring(comma + 1);
  final tokens = text.trim().split(RegExp(r'\s+'));
  if (tokens.length < 4) return null;

  final day = int.tryParse(tokens[0]);
  final month = _months[tokens[1].toLowerCase().substring(
    0,
    tokens[1].length < 3 ? tokens[1].length : 3,
  )];
  final year = int.tryParse(tokens[2]);
  if (day == null || month == null || year == null) return null;

  final clock = tokens[3].split(':');
  final hour = clock.isNotEmpty ? int.tryParse(clock[0]) ?? 0 : 0;
  final minute = clock.length > 1 ? int.tryParse(clock[1]) ?? 0 : 0;
  final second = clock.length > 2 ? int.tryParse(clock[2]) ?? 0 : 0;

  final base = DateTime.utc(year, month, day, hour, minute, second);
  final zone = tokens.length > 4 ? tokens[4] : 'GMT';
  return base.subtract(_zoneOffset(zone));
}

/// Numeric (`+0200`) and common alphabetic zone offsets.
Duration _zoneOffset(String zone) {
  final match = RegExp(r'^([+-])(\d{2})(\d{2})$').firstMatch(zone.trim());
  if (match != null) {
    final sign = match.group(1) == '-' ? -1 : 1;
    final hours = int.parse(match.group(2)!);
    final minutes = int.parse(match.group(3)!);
    return Duration(hours: sign * hours, minutes: sign * minutes);
  }
  return switch (zone.toUpperCase()) {
    'GMT' || 'UT' || 'UTC' || 'Z' => Duration.zero,
    'EDT' => const Duration(hours: -4),
    'EST' || 'CDT' => const Duration(hours: -5),
    'CST' || 'MDT' => const Duration(hours: -6),
    'MST' || 'PDT' => const Duration(hours: -7),
    'PST' => const Duration(hours: -8),
    _ => Duration.zero,
  };
}
