import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

import 'package:spotiflac_android/engine/streaming_engine.dart'
    show AdaptiveBitrateSelector, StreamVariant;
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/provider_credentials.dart';
import 'package:spotiflac_android/core/monitoring/crash_reporter.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('MultiProviderStream');

/// Returns the explicit constructor credential when set, otherwise consults
/// [resolver] (secure storage in production). Blank values count as missing,
/// so a whitespace-only token never reaches a provider gateway.
Future<String?> resolveStreamCredential(
  String? direct,
  Future<String?> Function()? resolver,
) async {
  final trimmedDirect = direct?.trim();
  if (trimmedDirect != null && trimmedDirect.isNotEmpty) {
    return trimmedDirect;
  }
  final viaResolver = await resolver?.call();
  final trimmed = viaResolver?.trim();
  return (trimmed != null && trimmed.isNotEmpty) ? trimmed : null;
}

/// The eight ecosystem sources supported by the SpotiFLAC streaming engine.
enum StreamProviderId {
  spotify,
  youtube,
  appleMusic,
  tidal,
  qobuz,
  deezer,
  amazonMusic,
  soundCloud,
}

/// Static presentation + capability metadata for a [StreamProviderId].
class StreamProviderInfo {
  final StreamProviderId id;
  final String displayName;
  final String shortName;

  /// Material icon codepoint used by the selector chip (kept UI-package-free
  /// so the service can be unit tested without Flutter).
  final int iconCodePoint;

  /// True when the provider needs user-supplied credentials/tokens before a
  /// full-fidelity stream can be resolved. Such providers resolve what they
  /// can anonymously (metadata / previews) and otherwise defer to the
  /// universal fallback engine.
  final bool requiresCredentials;

  /// True when the provider's native stream tier is lossless.
  final bool nativeLossless;

  /// Highest stream tier the provider *can* offer with valid credentials.
  final String maxTierLabel;

  const StreamProviderInfo({
    required this.id,
    required this.displayName,
    required this.shortName,
    required this.iconCodePoint,
    required this.requiresCredentials,
    required this.nativeLossless,
    required this.maxTierLabel,
  });

  static const Map<StreamProviderId, StreamProviderInfo> _registry = {
    StreamProviderId.spotify: StreamProviderInfo(
      id: StreamProviderId.spotify,
      displayName: 'Spotify',
      shortName: 'Spotify',
      iconCodePoint: 0xe083, // Icons.podcasts-like glyph fallback in UI
      requiresCredentials: true,
      nativeLossless: false,
      maxTierLabel: 'Ogg Vorbis 320kbps',
    ),
    StreamProviderId.youtube: StreamProviderInfo(
      id: StreamProviderId.youtube,
      displayName: 'YouTube Music',
      shortName: 'YT Music',
      iconCodePoint: 0xe040,
      requiresCredentials: false,
      nativeLossless: false,
      maxTierLabel: 'Opus/AAC ~160kbps',
    ),
    StreamProviderId.appleMusic: StreamProviderInfo(
      id: StreamProviderId.appleMusic,
      displayName: 'Apple Music',
      shortName: 'Apple',
      iconCodePoint: 0xe040,
      requiresCredentials: true,
      nativeLossless: true,
      maxTierLabel: 'ALAC 24-bit/192kHz',
    ),
    StreamProviderId.tidal: StreamProviderInfo(
      id: StreamProviderId.tidal,
      displayName: 'Tidal',
      shortName: 'Tidal',
      iconCodePoint: 0xe040,
      requiresCredentials: true,
      nativeLossless: true,
      maxTierLabel: 'FLAC 24-bit/192kHz HiFi',
    ),
    StreamProviderId.qobuz: StreamProviderInfo(
      id: StreamProviderId.qobuz,
      displayName: 'Qobuz',
      shortName: 'Qobuz',
      iconCodePoint: 0xe040,
      requiresCredentials: true,
      nativeLossless: true,
      maxTierLabel: 'FLAC 24-bit/192kHz Studio',
    ),
    StreamProviderId.deezer: StreamProviderInfo(
      id: StreamProviderId.deezer,
      displayName: 'Deezer',
      shortName: 'Deezer',
      iconCodePoint: 0xe040,
      requiresCredentials: true,
      nativeLossless: true,
      maxTierLabel: 'FLAC HiFi',
    ),
    StreamProviderId.amazonMusic: StreamProviderInfo(
      id: StreamProviderId.amazonMusic,
      displayName: 'Amazon Music',
      shortName: 'Amazon',
      iconCodePoint: 0xe040,
      requiresCredentials: true,
      nativeLossless: true,
      maxTierLabel: 'FLAC Ultra HD 24-bit',
    ),
    StreamProviderId.soundCloud: StreamProviderInfo(
      id: StreamProviderId.soundCloud,
      displayName: 'SoundCloud',
      shortName: 'SoundCloud',
      iconCodePoint: 0xe040,
      requiresCredentials: false,
      nativeLossless: false,
      maxTierLabel: 'Opus/MP3 256kbps',
    ),
  };

  static StreamProviderInfo of(StreamProviderId id) => _registry[id]!;

  static List<StreamProviderInfo> get all =>
      StreamProviderId.values.map(of).toList(growable: false);
}

/// A track to resolve, expressed in a provider-neutral shape.
class StreamTrackRequest {
  final String title;
  final String artist;
  final String? album;

  /// ISRC when available — the strongest match key.
  final String? isrc;
  final Duration? duration;
  final String? coverUrl;

  /// Provider-native id (Spotify id, Deezer id, …) when known.
  final String? nativeId;

  /// Short preview URL already carried by the metadata (Spotify/Deezer).
  final String? previewUrl;

  const StreamTrackRequest({
    required this.title,
    required this.artist,
    this.album,
    this.isrc,
    this.duration,
    this.coverUrl,
    this.nativeId,
    this.previewUrl,
  });

  factory StreamTrackRequest.fromTrack(Track track) => StreamTrackRequest(
    title: track.name,
    artist: track.artistName,
    album: track.albumName,
    isrc: track.isrc,
    duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
    coverUrl: track.coverUrl,
    nativeId: track.id,
    previewUrl: track.previewUrl,
  );

  /// Best-effort search query: `"Title Artist"` (album name omitted — it adds
  /// noise to cross-catalog matching).
  String get searchQuery => '$title $artist'.trim();
}

/// A playable stream resolved by a provider handler.
class ResolvedStream {
  /// The progressive/HLS URL handed to the audio player.
  final Uri uri;
  final StreamProviderId provider;

  /// "FLAC 24/192 HiFi", "Opus 160kbps", "MP3 128kbps preview", …
  final String qualityLabel;
  final int? bitrateKbps;
  final bool isLossless;
  final bool isPreview;
  final String? codec;
  final String? container;

  /// When the signed URL expires; null if unknown/long-lived.
  final DateTime? expiresAt;

  /// Title/artist the provider matched — used to explain fallback choices.
  final String matchedTitle;
  final String? matchedArtist;

  /// True when this resolution was produced by the universal fallback engine
  /// rather than the originally requested provider.
  final bool viaFallback;

  const ResolvedStream({
    required this.uri,
    required this.provider,
    required this.qualityLabel,
    required this.matchedTitle,
    this.bitrateKbps,
    this.isLossless = false,
    this.isPreview = false,
    this.codec,
    this.container,
    this.expiresAt,
    this.matchedArtist,
    this.viaFallback = false,
  });

  MediaItem toMediaItem({String? fallbackArtUri}) => MediaItem(
    id: uri.toString(),
    title: matchedTitle,
    artist: matchedArtist,
    artUri: fallbackArtUri != null ? Uri.tryParse(fallbackArtUri) : null,
    extras: <String, dynamic>{
      'provider': provider.name,
      'qualityLabel': qualityLabel,
      'isLossless': isLossless,
      'isPreview': isPreview,
      'viaFallback': viaFallback,
    },
  );
}

/// Raised when every provider — including the universal fallback — fails.
class StreamResolutionException implements Exception {
  final String message;
  final Object? cause;

  StreamResolutionException(this.message, {this.cause});

  @override
  String toString() => 'StreamResolutionException: $message';
}

/// One provider's resolution strategy.
abstract class StreamProviderHandler {
  StreamProviderInfo get info;
  StreamProviderId get id => info.id;

  /// Resolves a full (or preview) stream. Returning null means "no playable
  /// result" (missing credentials, no match) and the caller moves on to the
  /// next provider / fallback.
  Future<ResolvedStream?> resolve(StreamTrackRequest request);

  /// Shared HTTP helper with a sane timeout + browser UA.
  Future<http.Response> getJson(
    Uri url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final response = await http
        .get(
          url,
          headers: <String, String>{
            'User-Agent': _browserUserAgent,
            'Accept': 'application/json, text/plain, */*',
            ...?headers,
          },
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'HTTP ${response.statusCode} for $url',
      );
    }
    return response;
  }

  /// JSON POST variant, used by the provider gateways that refuse GET
  /// (Deezer's `gw-light.php` among them).
  Future<http.Response> postJson(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final response = await http
        .post(
          url,
          headers: <String, String>{
            'User-Agent': _browserUserAgent,
            'Accept': 'application/json, text/plain, */*',
            if (body != null) 'Content-Type': 'application/json',
            ...?headers,
          },
          body: body == null ? null : jsonEncode(body),
        )
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw http.ClientException(
        'HTTP ${response.statusCode} for $url',
      );
    }
    return response;
  }
}

/// Shared UA so every provider request looks like a normal mobile browser.
const String _browserUserAgent =
    'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36';

// ---------------------------------------------------------------------------
// Provider 1 — Spotify: metadata lookup + official 30s preview playback.
// Full on-demand streams require Spotify's restricted proprietary endpoint,
// so anything beyond a preview defers to the universal fallback engine.
// ---------------------------------------------------------------------------
class SpotifyStreamHandler extends StreamProviderHandler {
  @override
  StreamProviderInfo get info => StreamProviderInfo.of(StreamProviderId.spotify);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final preview = request.previewUrl;
    if (preview == null || preview.isEmpty) {
      _log.i('Spotify: no preview URL for "${request.title}"; falling back');
      return null;
    }
    final uri = Uri.tryParse(preview);
    if (uri == null || !uri.isScheme('HTTPS')) return null;
    return ResolvedStream(
      uri: uri,
      provider: StreamProviderId.spotify,
      qualityLabel: 'Ogg Vorbis 96kbps preview',
      bitrateKbps: 96,
      isPreview: true,
      codec: 'vorbis',
      matchedTitle: request.title,
      matchedArtist: request.artist,
    );
  }
}

// ---------------------------------------------------------------------------
// Pure match-confidence scoring shared by the anonymous fallback providers.
//
// Both gates enforce the same policy: a candidate that is neither a
// Topic/official upload nor duration-verified is *rejected* rather than
// silently substituted — an honest "no stream" beats playing the wrong song.
// ---------------------------------------------------------------------------

/// Minimum YouTube match score required to accept a candidate. Chosen so a
/// candidate passes only with either a Topic/official-catalog signal or a
/// title match backed by duration evidence — a same-length unrelated video
/// alone never clears it.
const int youTubeMinimumMatchScore = 40;

/// Hard duration guard: a video more than this many seconds off the requested
/// track can never be the same recording.
const int youTubeMaxDurationDriftSeconds = 60;

/// Scores one YouTube search result against the requested track.
///
/// Positive signals: "- Topic" author (official catalog upload), the requested
/// title appearing in the video title, "official audio"/"audio" in the title,
/// duration proximity. Negative signals: live, concert, cover, karaoke,
/// instrumental uploads, missing title signal and large duration drift.
int scoreYouTubeSearchResult({
  required String author,
  required String title,
  int? targetSeconds,
  int? videoSeconds,
  String? requestTitle,
}) {
  final authorLower = author.toLowerCase();
  final titleLower = title.toLowerCase();
  var score = 0;
  if (authorLower.endsWith('- topic') || authorLower.contains('topic')) {
    score += 60;
  }
  final requestedTitle = requestTitle?.trim().toLowerCase() ?? '';
  if (requestedTitle.isNotEmpty) {
    if (titleLower.contains(requestedTitle)) {
      score += 35;
    } else {
      // The search engine matched keywords, but the video title does not even
      // contain the requested song title: weak evidence at best.
      score -= 15;
    }
  }
  if (titleLower.contains('official audio') || titleLower.contains('audio')) {
    score += 25;
  }
  if (titleLower.contains('live') || titleLower.contains('concert')) score -= 40;
  if (titleLower.contains('cover') || titleLower.contains('karaoke')) {
    score -= 60;
  }
  if (targetSeconds != null && videoSeconds != null) {
    final drift = (videoSeconds - targetSeconds).abs();
    if (drift > youTubeMaxDurationDriftSeconds) {
      score -= 30;
    } else if (drift <= 3) {
      score += 50;
    } else if (drift <= 10) {
      score += 25;
    }
  }
  return score;
}

/// Minimum SoundCloud match score required to accept a candidate: a title
/// match plus one corroborating signal (duration or official marker).
const int soundCloudMinimumMatchScore = 40;

/// Scores one SoundCloud search result against the requested track.
int scoreSoundCloudResult({
  required String title,
  required String requestTitle,
  int? targetSeconds,
  int? durationMs,
}) {
  final lower = title.toLowerCase();
  var score = 0;
  if (lower.contains(requestTitle.toLowerCase())) {
    score += 30;
  } else {
    score -= 15;
  }
  if (lower.contains('official')) score += 10;
  if (lower.contains('cover') || lower.contains('remix')) score -= 25;
  if (targetSeconds != null && durationMs != null) {
    final driftSec = (durationMs - (targetSeconds * 1000)).abs() ~/ 1000;
    if (driftSec > youTubeMaxDurationDriftSeconds) {
      score -= 30;
    } else if (driftSec <= 5) {
      score += 40;
    }
  }
  return score;
}

/// Safe JSON accessors shared by the credentialed provider handlers.
///
/// Provider payloads are untyped JSON; every value is type-checked instead of
/// being invoked through `dynamic` (the analyzer runs with
/// `avoid_dynamic_calls`), and a malformed node degrades to "no match" rather
/// than throwing into the resolution chain.
Map<String, dynamic>? _asMap(Object? value) =>
    value is Map<String, dynamic> ? value : null;

List<dynamic>? _asList(Object? value) => value is List<dynamic> ? value : null;

String? _asString(Object? value) => value is String ? value : null;

/// First directly-playable URL in a provider payload, checked across the key
/// names the licensed endpoints are known to use (`url`, `streamUrl`,
/// `hlsUrl`, sometimes nested under `urls` / `playbackUrls` / `streams`).
String? _firstUrlIn(Map<String, dynamic> body) {
  for (final key in const <String>['url', 'streamUrl', 'hlsUrl', 'playbackUrl']) {
    final value = _asString(body[key]);
    if (value != null && value.startsWith('http')) return value;
  }
  for (final key in const <String>['urls', 'playbackUrls', 'streams']) {
    final entries = _asList(body[key]);
    if (entries == null) continue;
    for (final entry in entries) {
      final direct = _asString(entry);
      if (direct != null && direct.startsWith('http')) return direct;
      final nested = _asMap(entry);
      if (nested == null) continue;
      for (final key in const <String>['url', 'streamUrl', 'hlsUrl']) {
        final value = _asString(nested[key]);
        if (value != null && value.startsWith('http')) return value;
      }
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Provider 2 — YouTube / YouTube Music: direct audio stream resolution via
// youtube_explode_dart. This is also the engine that powers the universal
// fallback, so it is public and shared.
// ---------------------------------------------------------------------------
class YouTubeStreamHandler extends StreamProviderHandler {
  final yt.YoutubeExplode _youtube;

  /// Optional adaptive-bitrate policy. When set, the audio-only ladder is
  /// walked against the current bandwidth estimate (see [bandwidthProvider])
  /// instead of blindly taking the highest rung — a 2G link then gets a
  /// 48kbps Opus stream that plays, rather than a 160kbps one that stalls.
  AdaptiveBitrateSelector? bitrateSelector;

  /// Supplies the latest throughput estimate in bytes/second (from the
  /// engine's [BandwidthMonitor]); null when nothing has been measured yet.
  int Function()? bandwidthProvider;

  YouTubeStreamHandler(this._youtube, {this.bitrateSelector, this.bandwidthProvider});

  @override
  StreamProviderInfo get info => StreamProviderInfo.of(StreamProviderId.youtube);

  /// Searches YouTube Music for the best matching video.
  ///
  /// Low-confidence matches are rejected (null) instead of silently
  /// substituting an unrelated video: the universal fallback then moves on to
  /// SoundCloud or the resolution fails loudly.
  Future<yt.Video?> _findBestMatch(
    StreamTrackRequest request, {
    bool audioOnly = true,
  }) async {
    final query = audioOnly
        ? '${request.searchQuery} official audio'
        : '${request.searchQuery} topic';
    final results = await _youtube.search.search(query);
    if (results.isEmpty) return null;

    // Prefer "Topic" / "Official Audio" uploads (they are clean studio audio,
    // not live/acoustic re-uploads), then score by duration proximity.
    yt.Video? best;
    int bestScore = -1 << 30;
    final targetSeconds = request.duration?.inSeconds;
    for (final video in results.take(12)) {
      final score = scoreYouTubeSearchResult(
        author: video.author,
        title: video.title,
        targetSeconds: targetSeconds,
        videoSeconds: video.duration?.inSeconds,
        requestTitle: request.title,
      );
      if (score > bestScore) {
        bestScore = score;
        best = video;
      }
    }
    if (best == null) return null;
    // Confidence floor: a result that is neither a Topic/official upload nor
    // duration-verified carries no real evidence it is the requested track.
    if (bestScore < youTubeMinimumMatchScore) {
      _log.i(
        'YouTube: no confident match for "${request.title}" '
        '(best score $bestScore < $youTubeMinimumMatchScore); rejecting',
      );
      return null;
    }
    return best;
  }

  /// Resolves the highest-bitrate progressive audio stream for [video].
  Future<ResolvedStream?> resolveVideo(
    yt.Video video, {
    StreamProviderId provider = StreamProviderId.youtube,
    bool viaFallback = false,
  }) async {
    final manifest = await _youtube.videos.streamsClient.getManifest(video.id);
    final audioStreams = manifest.audioOnly.toList();
    if (audioStreams.isEmpty) return null;

    // The platform decoders (MediaPlayer/ExoPlayer on Android, AVPlayer on
    // iOS) play both Opus/WebM and AAC/M4A; pick
    // the highest bitrate, breaking ties toward AAC for device compatibility.
    audioStreams.sort((a, b) {
      final byBitrate = b.bitrate.bitsPerSecond.compareTo(
        a.bitrate.bitsPerSecond,
      );
      if (byBitrate != 0) return byBitrate;
      final aAac = a.audioCodec.toLowerCase().contains('mp4a') ? 1 : 0;
      final bAac = b.audioCodec.toLowerCase().contains('mp4a') ? 1 : 0;
      return bAac.compareTo(aAac);
    });

    var best = audioStreams.first;
    // Adaptive bitrate: with a measured throughput the ladder walks down to
    // the highest rung the link can actually sustain. Without a measurement
    // (or without a selector) the behaviour is unchanged: highest rung wins.
    final selector = bitrateSelector;
    if (selector != null) {
      final variants = audioStreams
          .map(
            (stream) => StreamVariant(
              uri: stream.url.toString(),
              bitrateKbps: (stream.bitrate.bitsPerSecond / 1000).round(),
              codec: stream.audioCodec,
              container: stream.container.name,
            ),
          )
          .toList(growable: false);
      final decision = selector.select(
        variants,
        measuredBytesPerSecond: bandwidthProvider?.call(),
      );
      final target = decision.targetKbps;
      if (target != null) {
        // `audioStreams` is sorted high → low, so the first rung at or below
        // the target is the best sustainable one.
        for (final stream in audioStreams) {
          if ((stream.bitrate.bitsPerSecond / 1000).round() <= target) {
            best = stream;
            break;
          }
        }
      }
    }
    final kbps = (best.bitrate.bitsPerSecond / 1000).round();
    final codecLabel = best.audioCodec.toLowerCase().contains('opus')
        ? 'Opus'
        : best.audioCodec.toLowerCase().contains('mp4a')
        ? 'AAC'
        : 'Audio';

    return ResolvedStream(
      uri: best.url,
      provider: provider,
      qualityLabel: '$codecLabel ${kbps}kbps',
      bitrateKbps: kbps,
      isLossless: false,
      codec: best.audioCodec,
      container: best.container.name,
      expiresAt: DateTime.now().add(const Duration(hours: 5, minutes: 30)),
      matchedTitle: video.title,
      matchedArtist: video.author,
      viaFallback: viaFallback,
    );
  }

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final video = await _findBestMatch(request);
    if (video == null) return null;
    return resolveVideo(video);
  }
}

// ---------------------------------------------------------------------------
// Provider 3 — Apple Music: web stream resolution interface.
// Full ALAC streams require a signed developer token (JWT); anonymous callers
// get a structured "requires token" miss and fall through to YouTube.
// ---------------------------------------------------------------------------
class AppleMusicStreamHandler extends StreamProviderHandler {
  AppleMusicStreamHandler({this.bearerToken, this.bearerTokenResolver});

  final String? bearerToken;
  final Future<String?> Function()? bearerTokenResolver;

  /// Explicit credential wins; otherwise the credential store (secure
  /// storage) is consulted. Separate method so tests can verify the
  /// precedence without touching the network.
  Future<String?> resolveBearerToken() =>
      resolveStreamCredential(bearerToken, bearerTokenResolver);

  @override
  StreamProviderInfo get info =>
      StreamProviderInfo.of(StreamProviderId.appleMusic);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final token = await resolveBearerToken();
    if (token == null || token.isEmpty) {
      _log.i('Apple Music: no developer token; using fallback');
      return null;
    }
    final uri = Uri.https('api.music.apple.com', '/v1/catalog/us/search', {
      'term': request.searchQuery,
      'types': 'songs',
      'limit': '5',
    });
    final response = await getJson(uri, headers: <String, String>{
      'Authorization': 'Bearer $token',
    });
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final results = (body['results'] as Map<String, dynamic>?)?['songs']
        as Map<String, dynamic>?;
    final data = results?['data'] as List<dynamic>?;
    if (data == null || data.isEmpty) return null;
    final first = data.first as Map<String, dynamic>;
    final attributes = first['attributes'] as Map<String, dynamic>;
    final isrc = attributes['isrc'] as String?;
    if (request.isrc != null && isrc != null && isrc != request.isrc) {
      return null;
    }
    // Full ALAC playback is minted by Apple's licensed playback endpoint and
    // is not available to third-party API clients. What *is* available through
    // the catalog API is the official 30-second preview (`previews[].url`), so
    // an authorized caller gets a real Apple-hosted stream instead of a
    // metadata match that can never play.
    final previews = attributes['previews'] as List<dynamic>?;
    for (final raw in previews ?? const <dynamic>[]) {
      final preview = raw as Map<String, dynamic>?;
      final url = preview?['url'] as String?;
      if (url == null || url.isEmpty) continue;
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.isScheme('HTTPS')) continue;
      _log.i(
        'Apple Music: preview stream for "${attributes['name']}" '
        '(full ALAC needs the licensed playback endpoint)',
      );
      return ResolvedStream(
        uri: uri,
        provider: StreamProviderId.appleMusic,
        qualityLabel: 'AAC 256kbps preview',
        bitrateKbps: 256,
        isPreview: true,
        codec: 'aac',
        expiresAt: DateTime.now().add(const Duration(hours: 6)),
        matchedTitle: (attributes['name'] as String?) ?? request.title,
        matchedArtist: (attributes['artistName'] as String?) ?? request.artist,
      );
    }
    _log.i(
      'Apple Music: matched "${attributes['name']}" but exposed no playable '
      'URL; deferring to the fallback engine',
    );
    return null;
  }
}

// ---------------------------------------------------------------------------
// Provider 4 — Tidal: lossless HiFi stream URL resolver interface.
// https://api.tidal.com requires an OAuth access token; authenticated callers
// receive FLAC manifest URLs. Anonymous callers fall through to the fallback.
// ---------------------------------------------------------------------------
class TidalStreamHandler extends StreamProviderHandler {
  TidalStreamHandler({
    this.accessToken,
    this.accessTokenResolver,
    this.countryCode = 'US',
  });

  final String? accessToken;
  final Future<String?> Function()? accessTokenResolver;
  final String countryCode;

  /// Explicit credential wins; otherwise the credential store (secure
  /// storage) is consulted. Separate method so tests can verify the
  /// precedence without touching the network.
  Future<String?> resolveAccessToken() =>
      resolveStreamCredential(accessToken, accessTokenResolver);

  @override
  StreamProviderInfo get info => StreamProviderInfo.of(StreamProviderId.tidal);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final token = await resolveAccessToken();
    if (token == null || token.isEmpty) {
      _log.i('Tidal: no access token; using fallback');
      return null;
    }
    final searchUri = Uri.https('api.tidal.com', '/v1/search/tracks', {
      'query': request.searchQuery,
      'limit': '5',
      'countryCode': countryCode,
    });
    final response = await getJson(searchUri, headers: <String, String>{
      'Authorization': 'Bearer $token',
    });
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final items = body['items'] as List<dynamic>?;
    if (items == null || items.isEmpty) return null;
    final track = items.first as Map<String, dynamic>;
    final trackId = track['id']?.toString();
    if (trackId == null) return null;

    // LOSSLESS (FLAC) playbackinfoPostPaywall → manifestMimeType for
    // application/vnd.tidal.bt+json resolves to chunked FLAC base URLs.
    final playbackUri = Uri.https(
      'api.tidal.com',
      '/v1/tracks/$trackId/playbackinfoPostPaywall',
      {
        'audioquality': 'LOSSLESS',
        'playbackmode': 'STREAM',
        'assetpresentation': 'FULL',
        'countryCode': countryCode,
      },
    );
    final playbackResponse = await getJson(
      playbackUri,
      headers: <String, String>{'Authorization': 'Bearer $token'},
    );
    final playback = jsonDecode(playbackResponse.body) as Map<String, dynamic>;
    final manifestB64 = playback['manifest'] as String?;
    if (manifestB64 == null) return null;
    final manifestJson = utf8.decode(base64Decode(manifestB64));
    final manifest = jsonDecode(manifestJson) as Map<String, dynamic>;
    final urls = manifest['urls'] as List<dynamic>?;
    if (urls == null || urls.isEmpty) return null;
    return ResolvedStream(
      uri: Uri.parse(urls.first as String),
      provider: StreamProviderId.tidal,
      qualityLabel: 'FLAC HiFi 16-bit/44.1kHz',
      isLossless: true,
      codec: 'flac',
      matchedTitle: (track['title'] as String?) ?? request.title,
      matchedArtist: request.artist,
    );
  }
}

// ---------------------------------------------------------------------------
// Provider 5 — Qobuz: 24-bit studio stream URL resolver interface.
// Requires app_id + user auth token; track/file endpoints then mint time-
// limited FLAC URLs (format_id 27 = 24-bit/up to 192kHz).
// ---------------------------------------------------------------------------
class QobuzStreamHandler extends QobuzStreamHandlerBase {
  QobuzStreamHandler({
    super.appId,
    super.authToken,
    super.appIdResolver,
    super.authTokenResolver,
  });

  @override
  StreamProviderInfo get info => StreamProviderInfo.of(StreamProviderId.qobuz);
}

abstract class QobuzStreamHandlerBase extends StreamProviderHandler {
  final String? appId;
  final String? authToken;
  final Future<String?> Function()? appIdResolver;
  final Future<String?> Function()? authTokenResolver;

  QobuzStreamHandlerBase({
    this.appId,
    this.authToken,
    this.appIdResolver,
    this.authTokenResolver,
  });

  /// Explicit credentials win; otherwise the credential store (secure
  /// storage) is consulted. Separate methods so tests can verify the
  /// precedence without touching the network.
  Future<String?> resolveAppId() =>
      resolveStreamCredential(appId, appIdResolver);

  Future<String?> resolveAuthToken() =>
      resolveStreamCredential(authToken, authTokenResolver);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final app = await resolveAppId();
    final token = await resolveAuthToken();
    if (app == null || app.isEmpty || token == null || token.isEmpty) {
      _log.i('Qobuz: no app credentials; using fallback');
      return null;
    }
    final searchUri = Uri.https(
      'www.qobuz.com',
      '/api.json/0.2/track/search',
      <String, String>{
        'query': request.searchQuery,
        'limit': '5',
        'app_id': app,
      },
    );
    final response = await getJson(searchUri);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final items = body['tracks'] as Map<String, dynamic>?;
    final tracks = items?['items'] as List<dynamic>?;
    if (tracks == null || tracks.isEmpty) return null;
    final track = tracks.first as Map<String, dynamic>;
    final trackId = track['id']?.toString();
    if (trackId == null) return null;

    // format_id: 5 = 16/44 FLAC, 6 = 24/96, 7 = 24/192 (27 = highest studio).
    final fileUri = Uri.https(
      'www.qobuz.com',
      '/api.json/0.2/track/getFileUrl',
      <String, String>{
        'track_id': trackId,
        'format_id': '27',
        'app_id': app,
        'user_auth_token': token,
      },
    );
    final fileResponse = await getJson(fileUri);
    final fileBody = jsonDecode(fileResponse.body) as Map<String, dynamic>;
    final url = fileBody['url'] as String?;
    if (url == null || url.isEmpty) return null;
    final bitDepth = fileBody['bit_depth']?.toString() ?? '24';
    final sampleRate = fileBody['sampling_rate']?.toString() ?? '192';
    return ResolvedStream(
      uri: Uri.parse(url),
      provider: StreamProviderId.qobuz,
      qualityLabel: 'FLAC Studio $bitDepth-bit/${sampleRate}kHz',
      isLossless: true,
      codec: 'flac',
      expiresAt: DateTime.now().add(const Duration(minutes: 30)),
      matchedTitle: (track['title'] as String?) ?? request.title,
      matchedArtist: request.artist,
    );
  }
}

// ---------------------------------------------------------------------------
// Provider 6 — Deezer: FLAC audio stream URL resolver interface.
// Anonymous access exposes metadata + 30s previews (api.deezer.com is public);
// full FLAC needs a licensed ARL token. Previews are returned so the chip is
// instantly playable; full tracks fall through to the fallback engine.
// ---------------------------------------------------------------------------
class DeezerStreamHandler extends StreamProviderHandler {
  DeezerStreamHandler({this.arlToken, this.arlTokenResolver});

  final String? arlToken;
  final Future<String?> Function()? arlTokenResolver;

  /// Explicit credential wins; otherwise the credential store (secure
  /// storage) is consulted. Separate method so tests can verify the
  /// precedence without touching the network.
  Future<String?> resolveArlToken() =>
      resolveStreamCredential(arlToken, arlTokenResolver);

  @override
  StreamProviderInfo get info => StreamProviderInfo.of(StreamProviderId.deezer);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final uri = Uri.https('api.deezer.com', '/search', {
      'q': request.isrc ?? request.searchQuery,
      'limit': '5',
    });
    final response = await getJson(uri);
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final data = body['data'] as List<dynamic>?;
    if (data == null || data.isEmpty) return null;
    final track = data.first as Map<String, dynamic>;
    final isrc = track['isrc'] as String?;
    if (request.isrc != null && isrc != null && isrc != request.isrc) {
      return null;
    }
    final preview = track['preview'] as String?;
    final arl = await resolveArlToken();
    if (arl != null && arl.isNotEmpty) {
      final authenticated = await _resolveAuthenticated(track, arl, request);
      if (authenticated != null) return authenticated;
      _log.i(
        'Deezer: no licensed stream for "${request.title}" on this account; '
        'using the public preview',
      );
    }
    // Public 30s preview — better than nothing while the fallback runs.
    if (preview == null || preview.isEmpty) return null;
    return ResolvedStream(
      uri: Uri.parse(preview),
      provider: StreamProviderId.deezer,
      qualityLabel: 'MP3 128kbps preview',
      bitrateKbps: 128,
      isPreview: true,
      codec: 'mp3',
      matchedTitle: (track['title'] as String?) ?? request.title,
      matchedArtist: (track['artist'] as Map<String, dynamic>?)?['name']
          as String? ??
          request.artist,
    );
  }

  /// Licensed FLAC/320 resolution through Deezer's gateway.
  ///
  /// The gateway is the only surface that hands out full streams, and it
  /// answers with an encrypted media path for every tier that is not
  /// entitlement-free. This therefore probes it for a *directly playable*
  /// URL and returns null when the account can only produce an encrypted
  /// path — the caller then falls back to the public preview instead of
  /// handing the player a URL it cannot decode.
  Future<ResolvedStream?> _resolveAuthenticated(
    Map<String, dynamic> track,
    String arl,
    StreamTrackRequest request,
  ) async {
    final sngId = track['id']?.toString();
    if (sngId == null || sngId.isEmpty) return null;
    final cookies = <String, String>{'Cookie': 'arl=$arl'};
    try {
      final pingUri = Uri.https('www.deezer.com', '/ajax/gw-light.php', {
        'method': 'deezer.getUserData',
        'input': '3',
        'api_version': '1.0',
        'api_token': '',
      });
      final pingBody = jsonDecode(
        (await getJson(pingUri, headers: cookies)).body,
      ) as Map<String, dynamic>;
      final user = pingBody['results'] as Map<String, dynamic>?;
      final token = (user?['checkForm'] as String?) ?? '';
      if (token.isEmpty) {
        // The ARL was rejected: this is a credential problem, not a missing
        // track, so it is reported once and never retried in this session.
        _log.i('Deezer: ARL rejected by the gateway');
        return null;
      }
      final dataUri = Uri.https('www.deezer.com', '/ajax/gw-light.php', {
        'method': 'song.getData',
        'input': '3',
        'api_version': '1.0',
        'api_token': token,
      });
      final dataBody = jsonDecode(
        (await postJson(
          dataUri,
          headers: cookies,
          body: <String, String>{'sng_id': sngId},
        )).body,
      ) as Map<String, dynamic>;
      final data = dataBody['results'] as Map<String, dynamic>?;
      if (data == null) return null;
      final url = _firstUrlIn(data);
      final direct = data['MEDIA'];
      final mediaUrl = direct is List ? direct : null;
      if (mediaUrl != null) {
        for (final raw in mediaUrl) {
          final medium = raw as Map<String, dynamic>?;
          final href = medium?['HREF'] as String?;
          final format = (medium?['TYPE'] ?? medium?['FORMAT']) as String?;
          if (href == null || !href.startsWith('http')) continue;
          final isFlac = (format ?? '').toUpperCase().contains('FLAC');
          return _streamFor(href, request, track, isFlac);
        }
      }
      if (url != null) {
        // `song.getData` only exposes a raw URL when the account's tier does
        // not require path decryption.
        final isFlac = url.toUpperCase().contains('FLAC');
        return _streamFor(url, request, track, isFlac);
      }
      return null;
    } catch (e) {
      _log.i('Deezer gateway unavailable for "${request.title}": $e');
      return null;
    }
  }

  ResolvedStream _streamFor(
    String url,
    StreamTrackRequest request,
    Map<String, dynamic> track,
    bool isFlac,
  ) =>
      ResolvedStream(
        uri: Uri.parse(url),
        provider: StreamProviderId.deezer,
        qualityLabel: isFlac ? 'FLAC 16-bit/44.1kHz' : 'MP3 320kbps',
        bitrateKbps: isFlac ? 1411 : 320,
        isLossless: isFlac,
        codec: isFlac ? 'flac' : 'mp3',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        matchedTitle: (track['title'] as String?) ?? request.title,
        matchedArtist: (track['artist'] as Map<String, dynamic>?)?['name']
            as String? ??
            request.artist,
      );
}

// ---------------------------------------------------------------------------
// Provider 7 — Amazon Music: HD audio stream URL resolver interface.
// Amazon has no public web API; playback URLs are minted by the licensed
// AMAPI endpoint (https://api.music.amazon.dev) with a bearer + device token.
// Anonymous callers always defer to the universal fallback.
// ---------------------------------------------------------------------------
class AmazonMusicStreamHandler extends StreamProviderHandler {
  AmazonMusicStreamHandler({
    this.bearerToken,
    this.deviceToken,
    this.bearerTokenResolver,
    this.deviceTokenResolver,
    this.marketplace = 'ATVPDKIKX0DER',
  });

  final String? bearerToken;
  final String? deviceToken;
  final Future<String?> Function()? bearerTokenResolver;
  final Future<String?> Function()? deviceTokenResolver;

  /// Explicit credentials win; otherwise the credential store (secure
  /// storage) is consulted. Separate methods so tests can verify the
  /// precedence without touching the network.
  Future<String?> resolveBearerToken() =>
      resolveStreamCredential(bearerToken, bearerTokenResolver);

  Future<String?> resolveDeviceToken() =>
      resolveStreamCredential(deviceToken, deviceTokenResolver);

  /// AMAPI marketplace id (`ATVPDKIKX0DER` = amazon.com).
  final String marketplace;

  /// Highest quality the AMAPI stream endpoint is asked for.
  static const String _bitDepth = '24';
  static const String _sampleRate = '192000';

  @override
  StreamProviderInfo get info =>
      StreamProviderInfo.of(StreamProviderId.amazonMusic);

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    final token = await resolveBearerToken();
    final device = await resolveDeviceToken();
    if (token == null ||
        token.isEmpty ||
        device == null ||
        device.isEmpty) {
      _log.i('Amazon Music: no AMAPI credentials; using fallback');
      return null;
    }
    final headers = <String, String>{
      'Authorization': 'Bearer $token',
      'x-amz-music-device-token': device,
      'x-amz-music-marketplace': marketplace,
      'x-amz-music-customer-id': '',
    };
    try {
      final searchUri = Uri.https('api.music.amazon.dev', '/v1/search', {
        'query': request.searchQuery,
        'type': 'TRACK',
        'limit': '5',
      });
      final searchBody =
          jsonDecode((await getJson(searchUri, headers: headers)).body)
              as Map<String, dynamic>;
      final trackId = _firstTrackId(searchBody);
      if (trackId == null) {
        _log.i('Amazon Music: no catalog match for "${request.title}"');
        return null;
      }
      final streamUri = Uri.https(
        'api.music.amazon.dev',
        '/v1/playables/$trackId/stream',
        <String, String>{
          'bitDepth': _bitDepth,
          'sampleRate': _sampleRate,
        },
      );
      final streamBody =
          jsonDecode((await getJson(streamUri, headers: headers)).body)
              as Map<String, dynamic>;
      final url = _firstUrlIn(streamBody);
      if (url == null || url.isEmpty) {
        _log.i(
          'Amazon Music: no stream URL for "${request.title}" '
          '(tier not entitled on this account)',
        );
        return null;
      }
      final bitDepth = streamBody['bitDepth']?.toString() ?? _bitDepth;
      final sampleRate = streamBody['sampleRate']?.toString() ?? _sampleRate;
      return ResolvedStream(
        uri: Uri.parse(url),
        provider: StreamProviderId.amazonMusic,
        qualityLabel: 'FLAC Ultra HD $bitDepth-bit/'
            '${(int.tryParse(sampleRate) ?? 192000) ~/ 1000}kHz',
        isLossless: true,
        codec: 'flac',
        expiresAt: DateTime.now().add(const Duration(minutes: 30)),
        matchedTitle: _firstTrackName(searchBody) ?? request.title,
        matchedArtist: _firstArtistName(searchBody) ?? request.artist,
      );
    } catch (e) {
      // AMAPI is device-entitlement gated: a 403 simply means this account
      // cannot stream, which is a legitimate miss, not a resolution error.
      _log.i('Amazon Music resolution unavailable for "${request.title}": $e');
      return null;
    }
  }

  /// Track items from an AMAPI search payload. The response nests results
  /// under `results` → `tracks` → `items`; older deployments return a flat
  /// `tracks` list, and both shapes are accepted.
  static List<Map<String, dynamic>> _trackItems(Map<String, dynamic> body) {
    final items = <Map<String, dynamic>>[];
    for (final node in <Object?>[body['results'], body]) {
      final container = _asMap(node);
      if (container == null) continue;
      final tracks = container['tracks'];
      final trackMap = _asMap(tracks);
      final direct = _asList(tracks);
      for (final raw in <List<dynamic>?>[
        direct,
        if (trackMap != null) _asList(trackMap['items']),
      ]) {
        if (raw == null) continue;
        for (final entry in raw) {
          final map = _asMap(entry);
          if (map != null) items.add(map);
        }
      }
    }
    return items;
  }

  /// Pulls the first playable track id out of an AMAPI search payload.
  static String? _firstTrackId(Map<String, dynamic> body) {
    for (final track in _trackItems(body)) {
      final id = _asString(track['id']) ?? _asString(track['trackId']);
      if (id != null && id.isNotEmpty) return id;
    }
    return null;
  }

  static String? _firstTrackName(Map<String, dynamic> body) {
    for (final track in _trackItems(body)) {
      final name = _asString(track['name']) ?? _asString(track['title']);
      if (name != null && name.isNotEmpty) return name;
    }
    return null;
  }

  static String? _firstArtistName(Map<String, dynamic> body) {
    for (final track in _trackItems(body)) {
      final artists = _asList(track['artists']);
      if (artists != null) {
        for (final raw in artists) {
          final artist = _asMap(raw);
          final name = artist == null ? null : _asString(artist['name']);
          if (name != null && name.isNotEmpty) return name;
        }
      }
      final display = _asString(track['artistName']);
      if (display != null && display.isNotEmpty) return display;
    }
    return null;
  }

}

// ---------------------------------------------------------------------------
// Provider 8 — SoundCloud: progressive audio stream URL resolver.
// Fully anonymous: the public api-v2 search + a scraped public client_id give
// progressive HLS/Opus stream URLs without any account.
// ---------------------------------------------------------------------------
class SoundCloudStreamHandler extends StreamProviderHandler {
  final http.Client _client;
  String? _clientId;

  SoundCloudStreamHandler({http.Client? client})
    : _client = client ?? http.Client();

  @override
  StreamProviderInfo get info =>
      StreamProviderInfo.of(StreamProviderId.soundCloud);

  /// Extracts the public api-v2 client_id from soundcloud.com's bundled JS.
  Future<String?> _resolveClientId() async {
    final cached = _clientId;
    if (cached != null) return cached;
    try {
      final home = await _client.get(
        Uri.parse('https://soundcloud.com/'),
        headers: const <String, String>{
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36',
        },
      ).timeout(const Duration(seconds: 12));
      final scriptUrls = RegExp(
        r'https://a-v2\.sndcdn\.com/assets/[^"]+\.js',
      ).allMatches(home.body).map((m) => m.group(0)!).toSet();
      for (final url in scriptUrls) {
        final js = await _client.get(Uri.parse(url)).timeout(
          const Duration(seconds: 12),
        );
        var match = RegExp(r'client_id=([A-Za-z0-9]{20,})').firstMatch(
          js.body,
        );
        match ??= RegExp(r'"client_id":"([A-Za-z0-9]{20,})"').firstMatch(
          js.body,
        );
        final id = match?.group(1);
        if (id != null && id.isNotEmpty) {
          _clientId = id;
          return id;
        }
      }
    } catch (e) {
      _log.w('SoundCloud client_id resolution failed: $e');
    }
    return null;
  }

  @override
  Future<ResolvedStream?> resolve(StreamTrackRequest request) async {
    try {
      final clientId = await _resolveClientId();
      if (clientId == null) return null;
      final searchUri = Uri.https(
        'api-v2.soundcloud.com',
        '/search/tracks',
        <String, String>{
          'q': request.searchQuery,
          'limit': '10',
          'client_id': clientId,
        },
      );
      final response = await getJson(searchUri);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final collection = body['collection'] as List<dynamic>?;
      if (collection == null || collection.isEmpty) return null;

      Map<String, dynamic>? best;
      int bestScore = -1 << 30;
      final targetSeconds = request.duration?.inSeconds;
      for (final raw in collection) {
        final track = raw as Map<String, dynamic>;
        final title = (track['title'] as String?) ?? '';
        final score = scoreSoundCloudResult(
          title: title,
          requestTitle: request.title,
          targetSeconds: targetSeconds,
          durationMs: (track['duration'] as num?)?.toInt(),
        );
        if (score > bestScore) {
          bestScore = score;
          best = track;
        }
      }
      if (best == null) return null;
      // Confidence floor: reject weak matches instead of substituting an
      // unrelated upload (policy mirrors the YouTube fallback gate).
      if (bestScore < soundCloudMinimumMatchScore) {
        _log.i(
          'SoundCloud: no confident match for "${request.title}" '
          '(best score $bestScore < $soundCloudMinimumMatchScore); rejecting',
        );
        return null;
      }

      final transcodings = (best['media'] as Map<String, dynamic>?)?['transcodings']
          as List<dynamic>?;
      if (transcodings == null || transcodings.isEmpty) return null;

      // Prefer the progressive (non-HLS) transcoding for gapless progressive
      // playback; fall back to HLS.
      Map<String, dynamic>? progressive;
      for (final raw in transcodings) {
        final t = raw as Map<String, dynamic>;
        final proto = (t['format'] as Map<String, dynamic>?)?['protocol']
            as String?;
        if (proto == 'progressive') {
          progressive = t;
          break;
        }
        progressive ??= t;
      }
      if (progressive == null) return null;
      final streamEndpoint = Uri.parse(
        progressive['url'] as String,
      ).replace(queryParameters: <String, String>{'client_id': clientId});
      final streamResponse = await getJson(streamEndpoint);
      final streamBody = jsonDecode(streamResponse.body) as Map<String, dynamic>;
      final streamUrl = streamBody['url'] as String?;
      if (streamUrl == null || streamUrl.isEmpty) return null;

      final user = (best['user'] as Map<String, dynamic>?)?['username']
          as String?;
      return ResolvedStream(
        uri: Uri.parse(streamUrl),
        provider: StreamProviderId.soundCloud,
        qualityLabel: 'Opus ~256kbps',
        bitrateKbps: 256,
        codec: 'opus',
        matchedTitle: (best['title'] as String?) ?? request.title,
        matchedArtist: user ?? request.artist,
      );
    } catch (e) {
      _log.w('SoundCloud resolution failed: $e');
      return null;
    }
  }
}

// ---------------------------------------------------------------------------
// Provider health
// ---------------------------------------------------------------------------

/// Live health record for one provider, fed by *real* resolution attempts
/// (not by synthetic pings): every success and failure observed while the app
/// is in use updates it.
///
/// Health *metrics* (counts, latency, last outcome) are persisted across
/// sessions via [ProviderHealthStore]; the circuit state is deliberately not:
/// a restored record always comes back *available* so a stale "provider is
/// down" flag can never permanently hide a service that recovered while the
/// app was closed.
class StreamProviderHealth {
  const StreamProviderHealth({
    required this.provider,
    this.successCount = 0,
    this.failureCount = 0,
    this.consecutiveFailures = 0,
    this.lastLatencyMs,
    this.lastSuccessAt,
    this.lastFailureAt,
    this.cooldownUntil,
    this.lastError,
  });

  final StreamProviderId provider;

  final int successCount;
  final int failureCount;

  /// Failures since the last success — the value the cooldown is derived from.
  final int consecutiveFailures;

  final int? lastLatencyMs;
  final DateTime? lastSuccessAt;
  final DateTime? lastFailureAt;

  /// When the provider may be tried again after repeated failures.
  final DateTime? cooldownUntil;

  final String? lastError;

  static const int _maxCooldownSeconds = 15 * 60;

  double get successRate {
    final total = successCount + failureCount;
    if (total == 0) return 1.0;
    return successCount / total;
  }

  /// Whether the provider is currently eligible for resolution attempts.
  bool isAvailable(DateTime now) {
    final cooldown = cooldownUntil;
    if (cooldown == null) return true;
    return !now.isBefore(cooldown);
  }

  /// Seconds left on the cooldown (0 when available).
  int cooldownRemainingSeconds(DateTime now) {
    final cooldown = cooldownUntil;
    if (cooldown == null) return 0;
    final remaining = cooldown.difference(now).inSeconds;
    return remaining > 0 ? remaining : 0;
  }

  StreamProviderHealth recordSuccess({required int? latencyMs, DateTime? now}) =>
      StreamProviderHealth(
        provider: provider,
        successCount: successCount + 1,
        failureCount: failureCount,
        consecutiveFailures: 0,
        lastLatencyMs: latencyMs ?? lastLatencyMs,
        lastSuccessAt: now ?? DateTime.now(),
        lastFailureAt: lastFailureAt,
        cooldownUntil: null,
        lastError: null,
      );

  StreamProviderHealth recordFailure({
    required String error,
    int? latencyMs,
    DateTime? now,
  }) {
    final current = now ?? DateTime.now();
    final failures = consecutiveFailures + 1;
    final backoffSeconds = math.min(
      _maxCooldownSeconds,
      1 << math.min(failures, 8),
    );
    return StreamProviderHealth(
      provider: provider,
      successCount: successCount,
      failureCount: failureCount + 1,
      consecutiveFailures: failures,
      lastLatencyMs: latencyMs ?? lastLatencyMs,
      lastSuccessAt: lastSuccessAt,
      lastFailureAt: current,
      cooldownUntil: failures < 2
          ? null
          : current.add(Duration(seconds: backoffSeconds)),
      lastError: error,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'provider': provider.name,
    'success_count': successCount,
    'failure_count': failureCount,
    'consecutive_failures': consecutiveFailures,
    if (lastLatencyMs != null) 'last_latency_ms': lastLatencyMs,
    if (lastSuccessAt != null)
      'last_success_at': lastSuccessAt!.toUtc().toIso8601String(),
    if (lastFailureAt != null)
      'last_failure_at': lastFailureAt!.toUtc().toIso8601String(),
    if (cooldownUntil != null)
      'cooldown_until': cooldownUntil!.toUtc().toIso8601String(),
    if (lastError != null) 'last_error': lastError,
  };

  /// Restores a persisted record. Unknown provider names yield null (the
  /// provider list evolves; stale entries must not crash a newer build).
  ///
  /// Hardening rules for data that has been on disk and may be corrupt or
  /// hostile:
  ///   * counters are clamped to sane ranges (0 … 1e9),
  ///   * negative latencies are dropped,
  ///   * [cooldownUntil] is ignored — a restored provider is always available
  ///     (fresh session, fresh circuit state; see the class comment).
  static StreamProviderHealth? fromJson(Map<String, dynamic> json) {
    final providerName = json['provider'];
    if (providerName is! String) return null;
    StreamProviderId? id;
    for (final candidate in StreamProviderId.values) {
      if (candidate.name == providerName) {
        id = candidate;
        break;
      }
    }
    if (id == null) return null;

    const maxCounter = 1000000000;
    int clampCounter(Object? raw) {
      if (raw is! int || raw.isNegative) return 0;
      return raw > maxCounter ? maxCounter : raw;
    }

    DateTime? parseUtc(Object? raw) {
      if (raw is! String || raw.isEmpty) return null;
      return DateTime.tryParse(raw)?.toUtc();
    }

    final latency = json['last_latency_ms'];
    final lastError = json['last_error'];
    return StreamProviderHealth(
      provider: id,
      successCount: clampCounter(json['success_count']),
      failureCount: clampCounter(json['failure_count']),
      consecutiveFailures: clampCounter(json['consecutive_failures']),
      lastLatencyMs: latency is! int || latency < 0 ? null : latency,
      lastSuccessAt: parseUtc(json['last_success_at']),
      lastFailureAt: parseUtc(json['last_failure_at']),
      lastError: lastError is String && lastError.isNotEmpty ? lastError : null,
    );
  }
}

/// Health rows for every provider, with bounded memory and a hard cooldown
/// policy so a dead provider cannot stall every play request.
class StreamProviderHealthRegistry {
  final Map<StreamProviderId, StreamProviderHealth> _health =
      <StreamProviderId, StreamProviderHealth>{};

  /// Change listeners (used by [ProviderHealthStore] to persist snapshots).
  /// Listeners must never throw; mutations wrap notification in a try/catch
  /// so a broken observer cannot take down playback.
  final List<void Function()> _listeners = <void Function()>[];

  StreamProviderHealth of(StreamProviderId id) =>
      _health[id] ?? StreamProviderHealth(provider: id);

  bool isAvailable(StreamProviderId id, {DateTime? now}) =>
      of(id).isAvailable(now ?? DateTime.now());

  int cooldownRemainingSeconds(StreamProviderId id, {DateTime? now}) =>
      of(id).cooldownRemainingSeconds(now ?? DateTime.now());

  int consecutiveFailures(StreamProviderId id) => of(id).consecutiveFailures;

  void recordSuccess(StreamProviderId id, {int? latencyMs, DateTime? now}) {
    _health[id] = of(id).recordSuccess(latencyMs: latencyMs, now: now);
    _notifyChanged();
  }

  void recordFailure(
    StreamProviderId id, {
    required String error,
    int? latencyMs,
    DateTime? now,
  }) {
    _health[id] = of(
      id,
    ).recordFailure(error: error, latencyMs: latencyMs, now: now);
    _notifyChanged();
  }

  void reset(StreamProviderId id) {
    _health[id] = StreamProviderHealth(provider: id);
    _notifyChanged();
  }

  void resetAll() {
    _health.clear();
    _notifyChanged();
  }

  /// Subscribes to metric changes. Returns a function that unsubscribes.
  void Function() addListener(void Function() listener) {
    _listeners.add(listener);
    return () {
      _listeners.remove(listener);
    };
  }

  void _notifyChanged() {
    if (_listeners.isEmpty) return;
    for (final listener in List<void Function()>.of(_listeners)) {
      try {
        listener();
      } catch (e) {
        _log.w('provider health listener failed: $e');
      }
    }
  }

  /// Merges persisted records into the live registry. Live (this-session)
  /// observations always win over disk; persisted rows only seed providers
  /// that have not been measured yet. Cooldowns are not restored.
  ///
  /// Returns the number of records merged (0 for corrupt/empty payloads).
  int mergeRestored(Map<String, dynamic>? json) {
    if (json == null) return 0;
    final rows = json['providers'];
    if (rows is! List) return 0;
    var merged = 0;
    for (final row in rows) {
      if (row is! Map) continue;
      final restored = StreamProviderHealth.fromJson(
        Map<String, dynamic>.from(row),
      );
      if (restored == null) continue;
      if (_health.containsKey(restored.provider)) continue;
      _health[restored.provider] = restored;
      merged++;
    }
    return merged;
  }

  /// Immutable snapshot ordered by provider id (stable for the UI).
  List<StreamProviderHealth> snapshot() {
    final ids = _health.keys.toList(growable: false)
      ..sort((a, b) => a.name.compareTo(b.name));
    return List<StreamProviderHealth>.unmodifiable(ids.map(of));
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'providers': snapshot().map((h) => h.toJson()).toList(growable: false),
  };
}

// ---------------------------------------------------------------------------
// Stream validation
// ---------------------------------------------------------------------------

/// Outcome of checking that a resolved URL is actually playable.
class StreamValidationResult {
  const StreamValidationResult({
    required this.ok,
    this.statusCode,
    this.contentType,
    this.contentLengthBytes,
    this.latencyMs,
    this.error,
  });

  final bool ok;
  final int? statusCode;
  final String? contentType;
  final int? contentLengthBytes;
  final int? latencyMs;
  final String? error;

  static const StreamValidationResult unsupportedScheme =
      StreamValidationResult(ok: false, error: 'Unsupported URI scheme');

  /// Cheap guard against HTML error pages served with a 200 status.
  static bool isPlausibleAudioContentType(String? contentType) {
    final value = contentType?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return true; // Unknown is fine; never a hard failure.
    if (value.startsWith('text/html') || value.startsWith('application/json')) {
      return false;
    }
    return true;
  }

  @override
  String toString() =>
      'StreamValidationResult(ok: $ok, status: $statusCode, error: $error)';
}

/// Validates a resolved stream before it reaches the audio engine.
abstract class StreamValidator {
  Future<StreamValidationResult> validate(ResolvedStream stream);
}

/// Default validator: a single-byte ranged GET.
///
/// A full download would defeat the purpose (and violate provider terms), so
/// the check only proves that the URL responds, is not an HTML error page, and
/// reports a plausible audio payload.
class HttpStreamValidator implements StreamValidator {
  HttpStreamValidator({http.Client? client, this.timeout = const Duration(seconds: 10)})
    : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  @override
  Future<StreamValidationResult> validate(ResolvedStream stream) async {
    final uri = stream.uri;
    if (!uri.isScheme('HTTP') && !uri.isScheme('HTTPS')) {
      return StreamValidationResult.unsupportedScheme;
    }
    final stopwatch = Stopwatch()..start();
    try {
      final request =
          http.Request('GET', uri)
            ..headers['Range'] = 'bytes=0-0'
            ..headers['Accept'] = 'audio/*, application/octet-stream';
      final response = await _client.send(request).timeout(
        timeout,
        onTimeout: () => throw TimeoutException('stream validation timed out'),
      );
      stopwatch.stop();
      // Drain a single chunk: never buffer the payload.
      unawaited(
        response.stream.take(1).drain<void>().catchError((Object _) {}),
      );
      final status = response.statusCode;
      if (status < 200 || status >= 400) {
        return StreamValidationResult(
          ok: false,
          statusCode: status,
          latencyMs: stopwatch.elapsedMilliseconds,
          error: 'HTTP $status',
        );
      }
      final contentType = response.headers['content-type'];
      if (!StreamValidationResult.isPlausibleAudioContentType(contentType)) {
        return StreamValidationResult(
          ok: false,
          statusCode: status,
          contentType: contentType,
          latencyMs: stopwatch.elapsedMilliseconds,
          error: 'Unexpected content type: $contentType',
        );
      }
      final rawLength = response.headers['content-length'];
      return StreamValidationResult(
        ok: true,
        statusCode: status,
        contentType: contentType,
        contentLengthBytes: rawLength == null ? null : int.tryParse(rawLength),
        latencyMs: stopwatch.elapsedMilliseconds,
      );
    } on TimeoutException {
      stopwatch.stop();
      return StreamValidationResult(
        ok: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        error: 'Timed out',
      );
    } catch (e) {
      stopwatch.stop();
      return StreamValidationResult(
        ok: false,
        latencyMs: stopwatch.elapsedMilliseconds,
        error: e.toString(),
      );
    }
  }

  void dispose() => _client.close();
}

// ---------------------------------------------------------------------------
// Resolution cache
// ---------------------------------------------------------------------------

class _CacheEntry {
  _CacheEntry.positive(this.stream, DateTime now)
    : error = null,
      storedAt = now;

  _CacheEntry.negative(this.error, DateTime now)
    : stream = null,
      storedAt = now;

  final ResolvedStream? stream;
  final String? error;
  final DateTime storedAt;

  bool get isPositive => stream != null;

  bool isExpired(DateTime now, {Duration? negativeTtl}) {
    if (isPositive) {
      final expiry = stream!.expiresAt;
      if (expiry == null) {
        // Unknown expiry: CDN URLs still rotate, so hold them for 30 minutes.
        return now.difference(storedAt) > const Duration(minutes: 30);
      }
      // Refresh slightly early so a track that starts right at the boundary
      // never plays a URL that expires mid-buffer.
      return now.isAfter(expiry.subtract(const Duration(minutes: 5)));
    }
    return now.difference(storedAt) > (negativeTtl ?? const Duration(seconds: 45));
  }
}

/// Bounded LRU cache of resolved streams, with negative caching and an
/// explicit invalidation API used by the recovery paths.
///
/// Positive entries expire with the signed URL they carry (or after a
/// conservative 30 minutes when the provider does not publish an expiry).
/// Negative entries ("this track has no source on this provider") are kept
/// briefly so a scrolling list cannot hammer a provider with doomed requests.
class StreamResolutionCache {
  StreamResolutionCache({
    this.maxEntries = 128,
    this.negativeTtl = const Duration(seconds: 45),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxEntries;
  final Duration negativeTtl;
  final DateTime Function() _clock;

  final LinkedHashMap<String, _CacheEntry> _entries = LinkedHashMap<String, _CacheEntry>();

  int get length => _entries.length;

  Iterable<String> get keys => List<String>.unmodifiable(_entries.keys);

  /// Cached stream for [key], or null when absent/expired. Touches the entry
  /// so hot keys survive eviction.
  ///
  /// A negative ("no source on this provider") entry is *not* consumed here:
  /// every resolution looks for a positive hit first, so removing it would
  /// silently disable negative caching and let a scrolling list hammer a dead
  /// provider. Negative entries are read by [negativeError] and expire on
  /// [negativeTtl].
  ResolvedStream? get(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (!entry.isPositive) return null;
    if (entry.isExpired(_clock(), negativeTtl: negativeTtl)) {
      _entries.remove(key);
      return null;
    }
    // Re-insert so a hot key becomes the most-recently-used one.
    _entries.remove(key);
    _entries[key] = entry;
    return entry.stream;
  }

  /// Error message of a cached failure, or null when the key is not
  /// negatively cached (or the entry expired).
  String? negativeError(String key) {
    final entry = _entries[key];
    if (entry == null || entry.isPositive) return null;
    if (entry.isExpired(_clock(), negativeTtl: negativeTtl)) return null;
    return entry.error;
  }

  void put(String key, ResolvedStream stream) {
    _entries.remove(key);
    _entries[key] = _CacheEntry.positive(stream, _clock());
    _evict();
  }

  void putNegative(String key, String error) {
    _entries.remove(key);
    _entries[key] = _CacheEntry.negative(error, _clock());
    _evict();
  }

  void invalidate(String key) => _entries.remove(key);

  void clear() => _entries.clear();

  void _evict() {
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

// ---------------------------------------------------------------------------
// The service: orchestrates handlers, health, resolution order, validation,
// the result cache and the universal fallback engine.
// ---------------------------------------------------------------------------
class MultiProviderStreamService {
  final yt.YoutubeExplode _youtube;
  late final YouTubeStreamHandler _youTubeHandler;
  late final Map<StreamProviderId, StreamProviderHandler> _handlers;
  late final http.Client _httpClient;

  /// Keyed by "provider|isrc-or-query"; signed URLs are cached until expiry.
  final StreamResolutionCache cache;

  /// Live provider health, fed by every resolution attempt.
  final StreamProviderHealthRegistry health;

  /// Optional URL-check before a resolved stream is handed to the player.
  late final StreamValidator? validator;

  /// Coalesces concurrent resolutions of the same track so a scrolling list
  /// (or a flaky UI retry) cannot trigger duplicate provider traffic.
  final Map<String, Future<ResolvedStream>> _inFlight =
      <String, Future<ResolvedStream>>{};

  MultiProviderStreamService({
    yt.YoutubeExplode? youtube,
    http.Client? httpClient,
    Map<StreamProviderId, StreamProviderHandler>? overrides,
    StreamResolutionCache? cache,
    StreamProviderHealthRegistry? health,
    StreamValidator? validator,
    StreamCredentialResolver? credentials,
    this.validateResolutions = true,
  }) : _youtube = youtube ?? yt.YoutubeExplode(),
       cache = cache ?? StreamResolutionCache(),
       health = health ?? StreamProviderHealthRegistry() {
    // The validator shares the service's HTTP client so `dispose()` closes
    // both with a single call (an implicit client would leak one per service).
    final client = httpClient ?? http.Client();
    _httpClient = client;
    this.validator = validator ?? HttpStreamValidator(client: client);
    _youTubeHandler = YouTubeStreamHandler(_youtube);
    // Credentialed handlers resolve user-supplied tokens from [credentials]
    // (secure storage in production) at request time, so saving a token in
    // Settings → Provider accounts applies to the next stream with no
    // restart. Null keeps the historical constructor-only behavior for tests.
    Future<String?> Function()? resolverFor(String name) =>
        credentials == null ? null : () => credentials.read(name);
    _handlers = <StreamProviderId, StreamProviderHandler>{
      StreamProviderId.spotify: SpotifyStreamHandler(),
      StreamProviderId.youtube: _youTubeHandler,
      StreamProviderId.appleMusic: AppleMusicStreamHandler(
        bearerTokenResolver: resolverFor(
          StreamCredentialNames.appleDeveloperToken,
        ),
      ),
      StreamProviderId.tidal: TidalStreamHandler(
        accessTokenResolver: resolverFor(
          StreamCredentialNames.tidalAccessToken,
        ),
      ),
      StreamProviderId.qobuz: QobuzStreamHandler(
        appIdResolver: resolverFor(StreamCredentialNames.qobuzAppId),
        authTokenResolver: resolverFor(StreamCredentialNames.qobuzAuthToken),
      ),
      StreamProviderId.deezer: DeezerStreamHandler(
        arlTokenResolver: resolverFor(StreamCredentialNames.deezerArl),
      ),
      StreamProviderId.amazonMusic: AmazonMusicStreamHandler(
        bearerTokenResolver: resolverFor(
          StreamCredentialNames.amazonBearerToken,
        ),
        deviceTokenResolver: resolverFor(
          StreamCredentialNames.amazonDeviceToken,
        ),
      ),
      StreamProviderId.soundCloud:
          SoundCloudStreamHandler(client: _httpClient),
      ...?overrides,
    };
  }

  /// Whether resolved URLs are validated before being returned. Enabled by
  /// default: handing the audio engine a dead URL costs far more than the
  /// single-byte ranged GET that proves it is alive.
  final bool validateResolutions;

  StreamProviderHandler handlerFor(StreamProviderId id) => _handlers[id]!;

  /// Publishes the adaptive-bitrate policy and the live bandwidth estimate to
  /// every provider that exposes a bitrate ladder (YouTube Music today).
  ///
  /// Cheap and idempotent: the engine calls it before each candidate
  /// resolution so the ladder always reflects the latest throughput sample.
  void configureAdaptiveBitrate({
    required AdaptiveBitrateSelector selector,
    required int Function() bandwidthProvider,
  }) {
    for (final handler in _handlers.values) {
      if (handler is YouTubeStreamHandler) {
        handler.bitrateSelector = selector;
        handler.bandwidthProvider = bandwidthProvider;
      }
    }
  }

  String _cacheKey(StreamProviderId provider, StreamTrackRequest request) {
    final identity =
        request.isrc ?? '${request.title}|${request.artist}'.toLowerCase();
    return '${provider.name}|$identity';
  }

  /// Ordered failover chain for [request].
  ///
  /// The preferred provider leads, then the two anonymous providers that can
  /// always serve a track without credentials (YouTube Music, SoundCloud),
  /// then the preview-only catalogs as a last resort. Providers that require
  /// credentials are kept in the chain: they either resolve (credentials were
  /// supplied via an extension) or return null immediately.
  List<StreamProviderId> failoverChain(StreamProviderId preferred) {
    final chain = <StreamProviderId>[
      preferred,
      StreamProviderId.youtube,
      StreamProviderId.soundCloud,
      StreamProviderId.deezer,
      StreamProviderId.spotify,
      StreamProviderId.appleMusic,
      StreamProviderId.tidal,
      StreamProviderId.qobuz,
      StreamProviderId.amazonMusic,
    ];
    final seen = <StreamProviderId>{};
    return chain.where(seen.add).toList(growable: false);
  }

  /// Drops the cached resolution for [request] (all providers when
  /// [provider] is omitted). Called by the recovery paths so a dead URL is
  /// never replayed from cache.
  void invalidate(
    StreamTrackRequest request, [
    StreamProviderId? provider,
  ]) {
    if (provider != null) {
      cache.invalidate(_cacheKey(provider, request));
      return;
    }
    for (final id in StreamProviderId.values) {
      cache.invalidate(_cacheKey(id, request));
    }
  }

  /// Resolves a playable stream.
  ///
  /// Order:
  ///   1. The resolution cache (positive hits return immediately).
  ///   2. [preferredProvider] (if given) — e.g. the chip the user tapped.
  ///   3. Universal fallback engine: YouTube matched by ISRC or
  ///      "Title + Artist" (YouTube always works without credentials).
  ///   4. SoundCloud as a secondary anonymous fallback.
  ///   5. Preview-only catalogs (Deezer, Spotify, Apple) when [allowPreview]
  ///      is set — otherwise they count as a miss like any other.
  ///
  /// Providers in a health cooldown are skipped; the chain is still attempted
  /// end-to-end once all candidates are cooling down, so a temporary outage
  /// degrades to "try everything" instead of "silently fail".
  Future<ResolvedStream> resolveStream(
    StreamTrackRequest request, {
    StreamProviderId? preferredProvider,
    bool allowPreview = false,
    bool? validate,
  }) async {
    final preferred = preferredProvider ?? StreamProviderId.youtube;
    final cacheKey = _cacheKey(preferred, request);

    final cached = cache.get(cacheKey);
    if (cached != null && (allowPreview || !cached.isPreview)) {
      return cached;
    }

    final negative = cache.negativeError(cacheKey);
    if (negative != null) {
      throw StreamResolutionException(negative);
    }

    final inFlight = _inFlight[cacheKey];
    if (inFlight != null) return inFlight;

    final future = _resolveChain(
      request,
      preferred: preferred,
      allowPreview: allowPreview,
      validate: validate ?? validateResolutions,
    );
    _inFlight[cacheKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[cacheKey], future)) {
        _inFlight.remove(cacheKey);
      }
    }
  }

  Future<ResolvedStream> _resolveChain(
    StreamTrackRequest request, {
    required StreamProviderId preferred,
    required bool allowPreview,
    required bool validate,
  }) async {
    final chain = failoverChain(preferred);
    final now = DateTime.now();
    final healthy = chain
        .where((id) => health.isAvailable(id, now: now))
        .toList(growable: false);
    // Never skip everything: if every provider is cooling down, retry them all
    // rather than failing a track the user can plainly hear elsewhere.
    final order = healthy.isNotEmpty ? healthy : chain;

    Object? lastError;
    for (final provider in order) {
      final handler = _handlers[provider];
      if (handler == null) continue;
      final stopwatch = Stopwatch()..start();
      try {
        final resolved = await handler.resolve(request);
        stopwatch.stop();
        if (resolved == null) {
          // "No match / no credentials" is not a provider failure: it is a
          // legitimate miss and must not put the provider in a cooldown.
          _log.d('${provider.name}: no candidate for "${request.title}"');
          continue;
        }
        if (resolved.isPreview && !allowPreview) {
          _log.i(
            '${provider.name} only offers a preview for "${request.title}"; '
            'continuing down the chain',
          );
          continue;
        }
        if (validate && validator != null) {
          final validation = await validator!.validate(resolved);
          if (!validation.ok) {
            stopwatch.stop();
            health.recordFailure(
              provider,
              error: validation.error ?? 'validation failed',
              latencyMs: validation.latencyMs ?? stopwatch.elapsedMilliseconds,
            );
            _log.w(
              '${provider.name} stream failed validation for '
              '"${request.title}": ${validation.error}',
            );
            lastError = StreamResolutionException(
              '${provider.name}: ${validation.error}',
            );
            continue;
          }
        }
        health.recordSuccess(
          provider,
          latencyMs: stopwatch.elapsedMilliseconds,
        );
        final annotated = provider == preferred
            ? resolved
            : _withFallbackFlag(resolved, preferred);
        cache.put(_cacheKey(preferred, request), annotated);
        return annotated;
      } on StreamResolutionException catch (e) {
        lastError = e;
        health.recordFailure(
          provider,
          error: e.message,
          latencyMs: stopwatch.elapsedMilliseconds,
        );
        _log.w('${provider.name} resolution failed: ${e.message}');
      } catch (e) {
        lastError = e;
        health.recordFailure(
          provider,
          error: e.toString(),
          latencyMs: stopwatch.elapsedMilliseconds,
        );
        _log.w('${provider.name} resolution failed: $e');
      }
    }

    final message =
        'No playable stream for "${request.title}" by ${request.artist} '
        'across any provider';
    cache.putNegative(
      _cacheKey(preferred, request),
      lastError?.toString() ?? message,
    );
    // Phase 10: full-chain failures are provider-category events (deduped by
    // fingerprint so a provider outage reports once, not per track).
    final reporter = CrashReporter.instance;
    if (reporter.isEnabled) {
      reporter.addBreadcrumb(
        'stream resolution failed across all providers',
        category: CrashCategory.streaming,
        level: CrashSeverity.warning,
        data: {'title': request.title},
      );
      unawaited(
        reporter.captureError(
          lastError ?? StateError(message),
          null,
          category: CrashCategory.provider,
          severity: CrashSeverity.error,
          context: {
            'title': request.title,
            'artist': request.artist,
            'preferred': preferred.name,
            'chain': [for (final id in order) id.name],
          },
          fingerprint: ['stream-resolution', preferred.name],
        ),
      );
    }
    throw StreamResolutionException(message, cause: lastError);
  }

  ResolvedStream _withFallbackFlag(
    ResolvedStream stream,
    StreamProviderId requested,
  ) =>
      stream.provider == requested
      ? stream
      : ResolvedStream(
          uri: stream.uri,
          provider: stream.provider,
          qualityLabel: '${stream.qualityLabel} · fallback',
          bitrateKbps: stream.bitrateKbps,
          isLossless: stream.isLossless,
          isPreview: stream.isPreview,
          codec: stream.codec,
          container: stream.container,
          expiresAt: stream.expiresAt,
          matchedTitle: stream.matchedTitle,
          matchedArtist: stream.matchedArtist,
          viaFallback: true,
        );

  void dispose() {
    _youtube.close();
    _httpClient.close();
    cache.clear();
  }
}

