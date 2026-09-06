import 'dart:async';
import 'dart:collection';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/logger.dart';
import 'package:spotiflac_android/utils/lyrics_metadata_helper.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';

final _log = AppLogger('NowPlayingLyrics');

/// Signature of the online lyrics lookup used by [nowPlayingLyricsProvider].
/// Mirrors `PlatformBridge.getLyricsLRC`; injectable so the provider logic
/// is unit-testable without the native bridge.
typedef OnlineLyricsFetcher =
    Future<String> Function({
      required String trackId,
      required String title,
      required String artist,
      required int durationMs,
    });

/// Injection point for the online lyrics lookup (tests override this).
final onlineLyricsFetcherProvider = Provider<OnlineLyricsFetcher>(
  (ref) => _bridgeLyricsFetcher,
);

Future<String> _bridgeLyricsFetcher({
  required String trackId,
  required String title,
  required String artist,
  required int durationMs,
}) => PlatformBridge.getLyricsLRC(
  trackId,
  title,
  artist,
  durationMs: durationMs,
);

/// Session-scoped memo of online lyrics per track so a stream that fails over
/// (new URL, same track) or a lyrics sheet that is reopened never re-queries
/// the providers. Bounded LRU; negative results are cached too, because a
/// track the providers do not know stays unknown for the session.
class OnlineLyricsCache {
  OnlineLyricsCache({this.maxEntries = 64});

  final int maxEntries;
  final LinkedHashMap<String, ParsedLyrics> _entries =
      LinkedHashMap<String, ParsedLyrics>();
  final Map<String, Future<ParsedLyrics>> _inFlight = {};

  ParsedLyrics? get(String key) {
    final hit = _entries.remove(key);
    if (hit == null) return null;
    _entries[key] = hit; // refresh recency
    return hit;
  }

  void put(String key, ParsedLyrics value) {
    _entries.remove(key);
    _entries[key] = value;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  /// Coalesces concurrent lookups of the same key into one provider call.
  Future<ParsedLyrics> fetchOnce(
    String key,
    Future<ParsedLyrics> Function() load,
  ) {
    final cached = get(key);
    if (cached != null) return Future<ParsedLyrics>.value(cached);
    final pending = _inFlight[key];
    if (pending != null) return pending;
    late final Future<ParsedLyrics> future;
    future = load().then((value) {
      put(key, value);
      return value;
    }).whenComplete(() {
      // Block body on purpose: `whenComplete` awaits any Future its callback
      // returns, and `Map.remove` would hand back this very future — an
      // expression body would make the lookup wait on itself forever.
      _inFlight.remove(key);
    });
    _inFlight[key] = future;
    return future;
  }

  int get length => _entries.length;
  void clear() {
    _entries.clear();
  }
}

final onlineLyricsCacheProvider = Provider<OnlineLyricsCache>(
  (ref) => OnlineLyricsCache(),
);

/// Identity of a queue item for online lyrics: title + artist (+ id) so a
/// stream URL swap during failover maps to the same cache entry.
String lyricsCacheKeyFor(MediaItem item) {
  final title = item.title.trim().toLowerCase();
  final artist = (item.artist ?? '').trim().toLowerCase();
  return '${item.id}|$title|$artist';
}

/// Whether a media item is a streamed (non-local) source: its raw or
/// resolved source is an http(s) URL, or it is a deferred engine item whose
/// concrete source has not been published yet.
bool isStreamedMediaItem(MediaItem item) {
  final path = sourcePathForLyrics(item);
  if (path.startsWith('http://') || path.startsWith('https://')) return true;
  return path.startsWith('${PlayableMedia.deferredStreamScheme}://');
}

/// Resolves the current track's lyrics into a [ParsedLyrics] for the
/// synchronized lyrics viewer.
///
/// Local/downloaded files: embedded lyrics read back through the same
/// metadata bridge the classic Now Playing screen uses
/// (`readPlaybackFileMetadataWithRetry`).
///
/// Streamed tracks: the configured online providers (LRCLIB, Musixmatch,
/// Apple Music, NetEase, QQ Music, Paxsenix — with the priority and fallback
/// order set in Lyrics settings) are queried through the Go lyrics client,
/// memoized per track for the session. Offline mode never touches the
/// network. Every dead end yields an empty result — the viewer renders a
/// friendly "no lyrics" state rather than throwing.
final nowPlayingLyricsProvider = FutureProvider.autoDispose<ParsedLyrics>((
  ref,
) async {
  final item = ref.watch(currentMediaItemProvider).value;
  if (item == null) return ParsedLyrics.empty;

  final path = sourcePathForLyrics(item);
  if (path.isEmpty) return ParsedLyrics.empty;

  if (isStreamedMediaItem(item)) {
    return loadStreamedLyrics(
      item,
      offline: ref.watch(engineOfflineModeProvider),
      cache: ref.watch(onlineLyricsCacheProvider),
      fetch: ref.watch(onlineLyricsFetcherProvider),
    );
  }

  try {
    final meta = await readPlaybackFileMetadataWithRetry(path);
    return LyricsParser.parse((meta['lyrics'] ?? '').toString());
  } catch (e) {
    _log.w('Failed to read lyrics for "${item.title}": $e');
    return ParsedLyrics.empty;
  }
});

/// Online lyrics for a streamed [item]: offline mode short-circuits to empty,
/// otherwise the session [cache] coalesces and memoizes the provider lookup.
Future<ParsedLyrics> loadStreamedLyrics(
  MediaItem item, {
  required bool offline,
  required OnlineLyricsCache cache,
  required OnlineLyricsFetcher fetch,
}) {
  if (offline) return Future<ParsedLyrics>.value(ParsedLyrics.empty);
  return cache.fetchOnce(
    lyricsCacheKeyFor(item),
    () => fetchOnlineLyrics(item, fetch),
  );
}

/// Looks up lyrics for a streamed [item] through [fetch]; never throws.
Future<ParsedLyrics> fetchOnlineLyrics(
  MediaItem item,
  OnlineLyricsFetcher fetch,
) async {
  final title = item.title.trim();
  final artist = (item.artist ?? '').trim();
  if (title.isEmpty) return ParsedLyrics.empty;
  try {
    final lrc = await fetch(
      trackId: item.id,
      title: title,
      artist: artist,
      durationMs: item.duration?.inMilliseconds ?? 0,
    ).timeout(const Duration(seconds: 15));
    if (lrc.trim().isEmpty || isInstrumentalLyricsMarker(lrc)) {
      return ParsedLyrics.empty;
    }
    return LyricsParser.parse(lrc);
  } on TimeoutException {
    _log.w('Online lyrics lookup timed out for "$title"');
    return ParsedLyrics.empty;
  } catch (e) {
    _log.w('Online lyrics lookup failed for "$title": $e');
    return ParsedLyrics.empty;
  }
}

/// Derives the concrete file/stream path whose metadata should be probed for
/// lyrics. Prefers the engine-resolved local source (an SAF URI is left as-is
/// and resolved by the platform bridge) over the raw queue source.
String sourcePathForLyrics(MediaItem item) {
  final extras = item.extras;
  if (extras == null) return '';
  final resolved = extras['resolvedSource']?.toString().trim() ?? '';
  if (resolved.isNotEmpty) return resolved;
  return extras['source']?.toString().trim() ?? '';
}
