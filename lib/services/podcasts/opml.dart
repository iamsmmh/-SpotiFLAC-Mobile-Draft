/// OPML import/export for podcast subscriptions (Phase 9).
///
/// Wraps the existing [PodcastSubscription] model. Parsing is deliberately
/// tolerant: a feed outline only needs `xmlUrl` (or `url`) to be imported.
library;

import 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';

/// One OPML outline that can become a subscription.
class OpmlOutline {
  const OpmlOutline({
    required this.xmlUrl,
    this.title = '',
    this.htmlUrl,
    this.text = '',
  });

  final String xmlUrl;
  final String title;
  final String? htmlUrl;
  final String text;

  String get displayTitle {
    final named = title.trim().isNotEmpty ? title.trim() : text.trim();
    return named.isEmpty ? xmlUrl : named;
  }
}

/// Parse / serialize OPML 2.0 podcast lists.
class OpmlCodec {
  const OpmlCodec();

  /// Extracts feed URLs from an OPML document. Never throws.
  List<OpmlOutline> parse(String xml) {
    final outlines = <OpmlOutline>[];
    final seen = <String>{};
    final outlinePattern = RegExp(
      r'<outline\b([^>]*)/?>',
      caseSensitive: false,
    );
    for (final match in outlinePattern.allMatches(xml)) {
      final attrs = match.group(1) ?? '';
      final xmlUrl = _attr(attrs, 'xmlUrl') ?? _attr(attrs, 'url') ?? '';
      if (xmlUrl.isEmpty) continue;
      final type = (_attr(attrs, 'type') ?? '').toLowerCase();
      if (type.isNotEmpty && type != 'rss' && type != 'link') continue;
      if (!seen.add(xmlUrl)) continue;
      outlines.add(
        OpmlOutline(
          xmlUrl: xmlUrl,
          title: _attr(attrs, 'title') ?? '',
          htmlUrl: _attr(attrs, 'htmlUrl'),
          text: _attr(attrs, 'text') ?? '',
        ),
      );
    }
    return List<OpmlOutline>.unmodifiable(outlines);
  }

  /// Builds a podcast OPML document from subscriptions.
  String export(
    Iterable<PodcastSubscription> subscriptions, {
    String title = 'SpotiFLAC Podcasts',
  }) {
    final buffer = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<opml version="2.0">')
      ..writeln('  <head>')
      ..writeln('    <title>${_escape(title)}</title>')
      ..writeln('  </head>')
      ..writeln('  <body>');
    for (final sub in subscriptions) {
      buffer.writeln(
        '    <outline type="rss" text="${_escape(sub.title)}" '
        'title="${_escape(sub.title)}" xmlUrl="${_escape(sub.feedUrl)}"/>',
      );
    }
    buffer
      ..writeln('  </body>')
      ..writeln('</opml>');
    return buffer.toString();
  }

  /// Maps outlines onto first-time [PodcastSubscription] records.
  List<PodcastSubscription> toSubscriptions(
    Iterable<OpmlOutline> outlines, {
    required DateTime now,
  }) {
    return <PodcastSubscription>[
      for (final outline in outlines)
        PodcastSubscription(
          feedUrl: outline.xmlUrl,
          title: outline.displayTitle,
          addedAt: now,
        ),
    ];
  }

  static String? _attr(String attrs, String name) {
    final match = RegExp(
      '$name\\s*=\\s*"([^"]*)"',
      caseSensitive: false,
    ).firstMatch(attrs);
    final value = match?.group(1)?.trim();
    if (value == null || value.isEmpty) return null;
    return _unescape(value);
  }

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _unescape(String value) => value
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
}
