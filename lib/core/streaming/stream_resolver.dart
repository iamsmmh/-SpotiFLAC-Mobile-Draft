/// Protocol negotiation for the native streaming engine (Feature 1).
///
/// Progressive files, HLS (`.m3u8`) and DASH (`.mpd`) all flow through one
/// pure-Dart resolver so the policy ("which URL do we hand the player, and
/// in which protocol mode?") is unit-testable and identical on every
/// platform:
///
///   * **Progressive** — pass-through; the existing preflight/health chain
///     in `engine/streaming_engine.dart` already owns ranged-GET validation.
///   * **HLS** — when the `.m3u8` is a *master* playlist the resolver
///     parses `#EXT-X-STREAM-INF` variants and rewrites the source to the
///     best variant under the current bandwidth budget (or the highest
///     when no budget is known). Media playlists pass through untouched:
///     ExoPlayer (Android) and AVPlayer (iOS) both render HLS natively.
///   * **DASH** — the manifest passes through for players that render DASH
///     natively (ExoPlayer), while static MPDs that expose representation
///     `BaseURL`s can be narrowed to one direct progressive file when a
///     lower-capability player or the cache fetcher needs a plain file.
///
/// No I/O happens here: manifest bytes arrive through an injected fetcher
/// (`ManifestFetcher`) so tests (and callers) stay hermetic.
library;

import 'package:spotimusic/core/streaming/stream_provider.dart';

/// Fetches manifest text for a URL. Returns null on any transport failure.
typedef ManifestFetcher = Future<String?> Function(Uri uri);

/// Detects protocols from URL shape and response content types.
class StreamProtocolDetector {
  const StreamProtocolDetector._();

  static const Set<String> _hlsContentTypes = <String>{
    'application/vnd.apple.mpegurl',
    'application/x-mpegurl',
    'audio/mpegurl',
    'audio/x-mpegurl',
  };

  static const Set<String> _dashContentTypes = <String>{
    'application/dash+xml',
    'video/mp4', // conservative: many MPDs are served with the mp4 type
  };

  /// Protocol implied by a URL's extension, else null.
  static StreamProtocol? fromUrl(String url) {
    final clean = url.split('#').first.split('?').first.toLowerCase();
    if (clean.endsWith('.m3u8')) return StreamProtocol.hls;
    if (clean.endsWith('.mpd')) return StreamProtocol.dash;
    return null;
  }

  /// Protocol implied by an HTTP `Content-Type`, else null. Unknown and
  /// generic types (octet-stream, audio/*) map to nothing — the URL shape
  /// decides.
  static StreamProtocol? fromContentType(String? contentType) {
    if (contentType == null) return null;
    final mime = contentType.split(';').first.trim().toLowerCase();
    if (_hlsContentTypes.contains(mime)) return StreamProtocol.hls;
    if (_dashContentTypes.contains(mime)) return StreamProtocol.dash;
    return null;
  }

  /// Combined detection: URL shape wins, content type breaks ties.
  static StreamProtocol detect(String url, {String? contentType}) =>
      fromUrl(url) ?? fromContentType(contentType) ?? StreamProtocol.progressive;

  /// True when the content type is a manifest type that DASH players may
  /// misreport. Used by the service to keep dash+xml authoritative.
  static bool isDashContentType(String? contentType) {
    if (contentType == null) return false;
    return _dashContentTypes.contains(
      contentType.split(';').first.trim().toLowerCase(),
    );
  }
}

/// One `#EXT-X-STREAM-INF` variant of an HLS master playlist.
class HlsVariant {
  const HlsVariant({
    required this.uri,
    required this.bandwidthBps,
    this.codecs = '',
    this.resolution = '',
    this.name = '',
    this.isAudioOnly = false,
  });

  final String uri;
  final int bandwidthBps;
  final String codecs;
  final String resolution;
  final String name;

  /// Variant playlists that only carry audio streams are preferred for a
  /// music player: video-only variant bandwidth says nothing about audio
  /// quality and would waste the whole budget.
  final bool isAudioOnly;

  int get bitrateKbps => bandwidthBps ~/ 1000;

  bool get isLossless =>
      codecs.toUpperCase().contains('FLAC') && isAudioOnly;
}

/// Parsed HLS master playlist (pure, lenient, bounded).
class HlsMasterPlaylist {
  const HlsMasterPlaylist({required this.variants});

  final List<HlsVariant> variants;

  bool get isEmpty => variants.isEmpty;

  /// Parses master-playlist text. Media playlists (no `#EXT-X-STREAM-INF`)
  /// return an empty list — the caller keeps the original URL.
  static HlsMasterPlaylist parse(String text, {required Uri baseUrl}) {
    final variants = <HlsVariant>[];
    final lines = text.split('\n');
    const maxVariants = 64;
    String pendingCodecs = '';
    String pendingResolution = '';
    var pendingBandwidth = 0;

    for (var i = 0; i < lines.length && variants.length < maxVariants; i++) {
      final line = lines[i].trim();
      if (line.startsWith('#EXT-X-STREAM-INF')) {
        pendingCodecs = _attribute(line, 'CODECS') ?? '';
        pendingResolution = _attribute(line, 'RESOLUTION') ?? '';
        final bandwidth =
            int.tryParse(_attribute(line, 'BANDWIDTH') ?? '') ?? 0;
        final average = _attribute(line, 'AVERAGE-BANDWIDTH');
        pendingBandwidth =
            int.tryParse(average ?? '') ?? bandwidth;
        // The URI is the next non-empty, non-comment line.
        for (var j = i + 1; j < lines.length; j++) {
          final candidate = lines[j].trim();
          if (candidate.isEmpty) continue;
          if (candidate.startsWith('#')) {
            // NAME etc. may follow on their own tag lines; keep scanning.
            continue;
          }
          final resolved = baseUrl.resolve(candidate);
          variants.add(
            HlsVariant(
              uri: resolved.toString(),
              bandwidthBps: pendingBandwidth,
              codecs: pendingCodecs,
              resolution: pendingResolution,
              name: _attribute(line, 'NAME') ?? '',
              isAudioOnly: _looksAudioOnly(pendingCodecs, pendingResolution),
            ),
          );
          i = j;
          break;
        }
      }
    }

    // Stable, useful order: best (highest-bandwidth) variant first, so
    // consumers can take variants.first as "top quality" without sorting.
    variants.sort((a, b) => b.bandwidthBps.compareTo(a.bandwidthBps));
    return HlsMasterPlaylist(variants: variants);
  }

  /// Best variant for [budgetBps]; highest quality when the budget is null
  /// or unreachable. Audio-only variants are preferred when present.
  HlsVariant? bestVariant(int? budgetBps) {
    if (variants.isEmpty) return null;
    final audioFirst = <HlsVariant>[
      for (final variant in variants)
        if (variant.isAudioOnly) variant,
    ];
    final pool = audioOnlyPreference(audioFirst.isNotEmpty)
        ? audioFirst
        : variants;
    final sorted = <HlsVariant>[...pool]
      ..sort((a, b) => b.bandwidthBps.compareTo(a.bandwidthBps));
    if (budgetBps == null || budgetBps <= 0) return sorted.first;
    for (final variant in sorted) {
      if (variant.bandwidthBps <= budgetBps) return variant;
    }
    return sorted.last;
  }

  static bool audioOnlyPreference(bool anyAudioOnly) => anyAudioOnly;

  static String? _attribute(String line, String name) {
    // #EXT-X-STREAM-INF:BANDWIDTH=1280000,CODECS="mp4a.40.2",…
    final colon = line.indexOf(':');
    final body = colon >= 0 ? line.substring(colon + 1) : '';
    for (var part in body.split(',')) {
      part = part.trim();
      if (!part.toUpperCase().startsWith('$name=')) continue;
      var value = part.substring(name.length + 1);
      if (value.startsWith('"') && value.endsWith('"') && value.length >= 2) {
        value = value.substring(1, value.length - 1);
      }
      return value;
    }
    return null;
  }

  static bool _looksAudioOnly(String codecs, String resolution) {
    if (resolution.isNotEmpty) return false;
    final upper = codecs.toUpperCase();
    if (upper.isEmpty) return true; // unknown codec + no resolution: assume
    const videoMarkers = <String>['AVC', 'HEVC', 'H264', 'MP4V', 'AV01'];
    for (final marker in videoMarkers) {
      if (upper.contains(marker)) return false;
    }
    return true;
  }
}

/// One audio representation of a DASH period.
class DashRepresentation {
  const DashRepresentation({
    required this.id,
    required this.bandwidthBps,
    required this.mimeCodec,
    this.baseUrl = '',
  });

  final String id;
  final int bandwidthBps;
  final String mimeCodec;

  /// Direct file URL when the MPD exposes per-representation BaseURL
  /// (static/on-demand profile). Empty for SegmentTemplate streams.
  final String baseUrl;

  int get bitrateKbps => bandwidthBps ~/ 1000;

  bool get isLossless => mimeCodec.toUpperCase().contains('FLAC');
}

/// Parsed DASH manifest (static-MPD subset used by music servers).
///
/// Handles the two layouts real music back-ends emit:
///   * `Representation/BaseURL` — a single addressable file per quality
///     tier (Jellyfin's non-transcoding profiles, some Plex outputs);
///   * `SegmentTemplate` — segmented; the manifest URL itself is handed to
///     players that demux DASH natively (ExoPlayer) and never rewritten.
class DashManifest {
  const DashManifest({required this.representations, required this.isStatic});

  final List<DashRepresentation> representations;

  /// MPD@type == "static". Dynamic/live manifests are not downloadable.
  final bool isStatic;

  bool get isEmpty => representations.isEmpty;

  /// Best audio representation for [budgetBps] that exposes a direct file
  /// URL; null when the manifest is segmented or empty.
  DashRepresentation? bestFileRepresentation(int? budgetBps) {
    final withUrl = <DashRepresentation>[
      for (final representation in representations)
        if (representation.baseUrl.isNotEmpty) representation,
    ];
    if (withUrl.isEmpty) return null;
    final sorted = <DashRepresentation>[...withUrl]
      ..sort((a, b) => b.bandwidthBps.compareTo(a.bandwidthBps));
    if (budgetBps == null || budgetBps <= 0) return sorted.first;
    for (final representation in sorted) {
      if (representation.bandwidthBps <= budgetBps) return representation;
    }
    return sorted.last;
  }

  /// Lenient regex-free tag scanner for the MPD subset. Bounded to 64
  /// representations; unknown structure yields an empty (but usable)
  /// manifest — the caller falls back to passing the `.mpd` URL through.
  static DashManifest parse(String text, {required Uri manifestUrl}) {
    final isStatic = !text.contains('type="dynamic"');
    final representations = <DashRepresentation>[];

    // Walk <Representation …> chunks (self-closing or paired) without an
    // XML dependency.
    var cursor = 0;
    const maxRepresentations = 64;
    while (representations.length < maxRepresentations) {
      final open = text.indexOf('<Representation', cursor);
      if (open < 0) break;
      final tagEnd = text.indexOf('>', open);
      if (tagEnd < 0) break;
      final tag = text.substring(open, tagEnd + 1);
      final selfClosing = tag.endsWith('/>');
      final close = text.indexOf('</Representation>', tagEnd);
      final chunkEnd = selfClosing || close < 0 ? tagEnd : close;

      final id = _attr(tag, 'id') ?? '';
      final bandwidth = int.tryParse(_attr(tag, 'bandwidth') ?? '') ?? 0;
      var mimeCodec = _attr(tag, 'codecs') ?? '';
      final repMime = _attr(tag, 'mimeType') ?? '';
      final setMime = _parentAdaptationMime(text, open);
      final effectiveMime = repMime.isNotEmpty ? repMime : setMime;
      if (mimeCodec.isEmpty && effectiveMime.isNotEmpty) {
        mimeCodec = effectiveMime;
      }
      if (_isVideoOnly(effectiveMime)) {
        cursor = chunkEnd + 1;
        continue;
      }

      var baseUrl = '';
      if (!selfClosing && close > tagEnd) {
        final chunk = text.substring(tagEnd + 1, close);
        final baseOpen = chunk.indexOf('<BaseURL');
        if (baseOpen >= 0) {
          final contentStart = chunk.indexOf('>', baseOpen);
          final contentEnd = chunk.indexOf('</BaseURL>', baseOpen);
          if (contentStart >= 0 && contentEnd > contentStart) {
            final raw = chunk.substring(contentStart + 1, contentEnd).trim();
            if (raw.isNotEmpty) {
              baseUrl = manifestUrl.resolve(raw).toString();
            }
          }
        }
      }

      representations.add(
        DashRepresentation(
          id: id,
          bandwidthBps: bandwidth,
          mimeCodec: mimeCodec,
          baseUrl: baseUrl,
        ),
      );
      cursor = chunkEnd + 1;
    }

    return DashManifest(representations: representations, isStatic: isStatic);
  }

  /// Only representations that are explicitly video-only (an audio mime is
  /// absent) are skipped; ambiguous sets are kept so lenient manifests
  /// still resolve.
  static bool _isVideoOnly(String mimeType) {
    final lower = mimeType.toLowerCase();
    return lower.contains('video/') && !lower.contains('audio/');
  }

  /// Best-effort: the opening `<AdaptationSet …>` tag containing [offset].
  static String _parentAdaptationMime(String text, int offset) {
    final setStart = text.lastIndexOf('<AdaptationSet', offset);
    if (setStart < 0) return '';
    final setEnd = text.indexOf('>', setStart);
    if (setEnd < 0 || setEnd > offset) return '';
    return text.substring(setStart, setEnd + 1);
  }

  static String? _attr(String chunk, String name) {
    // Simple "name=\"value\"" scanner over the tag head.
    final search = '$name="';
    final start = chunk.indexOf(search);
    if (start < 0) return null;
    final valueStart = start + search.length;
    final valueEnd = chunk.indexOf('"', valueStart);
    if (valueEnd < 0) return null;
    return chunk.substring(valueStart, valueEnd);
  }
}

/// Ordered, protocol-aware candidate chain for one track.
class StreamResolverRequest {
  const StreamResolverRequest({
    required this.candidates,
    this.bandwidthBps,
    this.preferLossless = true,
    this.allowHls = true,
    this.allowDash = true,
  });

  final List<StreamSource> candidates;

  /// Current bandwidth estimate in bits per second (null = unknown →
  /// prefer highest quality).
  final int? bandwidthBps;
  final bool preferLossless;
  final bool allowHls;
  final bool allowDash;
}

/// Pure protocol resolver: orders candidates and narrows manifests.
class StreamProtocolResolver {
  const StreamProtocolResolver();

  /// Rank order across candidates: allowed protocols first (progressive
  /// beats HLS beats DASH at equal quality because it is cacheable and
  /// seekable everywhere), then bitrate fit against the budget, then
  /// lossless preference.
  List<StreamSource> orderCandidates(StreamResolverRequest request) {
    final budgetKbps = request.bandwidthBps == null
        ? null
        : request.bandwidthBps! ~/ 1000;
    final scored = <_ScoredSource>[];
    for (final candidate in request.candidates) {
      final protocolRank = switch (candidate.protocol) {
        StreamProtocol.progressive => 0,
        StreamProtocol.hls => request.allowHls ? 1 : 99,
        StreamProtocol.dash => request.allowDash ? 2 : 99,
      };
      if (protocolRank >= 99) continue;
      final bitrate = candidate.bitrate <= 0 ? 0 : candidate.bitrate;
      // Budget fit: prefer the highest bitrate at or under the budget;
      // over-budget candidates rank behind everything affordable, ordered
      // by how little they overshoot. No budget → pure quality ranking.
      final int budgetFit;
      if (budgetKbps == null || budgetKbps <= 0) {
        budgetFit = -bitrate;
      } else if (bitrate <= budgetKbps) {
        budgetFit = -bitrate;
      } else {
        budgetFit = bitrate - budgetKbps + (1 << 20);
      }
      final losslessBonus = request.preferLossless && _isLossless(candidate)
          ? -(1 << 30)
          : 0;
      scored.add(
        _ScoredSource(
          source: candidate,
          protocolRank: protocolRank,
          budgetFit: budgetFit + losslessBonus,
        ),
      );
    }
    scored.sort(
      (a, b) => a.protocolRank == b.protocolRank
          ? a.budgetFit.compareTo(b.budgetFit)
          : a.protocolRank.compareTo(b.protocolRank),
    );
    return <StreamSource>[for (final s in scored) s.source];
  }

  static bool _isLossless(StreamSource source) {
    final format = source.format.toUpperCase();
    return format.contains('FLAC') || format.contains('ALAC');
  }

  /// Narrows a manifest source to a direct file/variant URL when possible.
  ///
  ///   * HLS master → best audio variant under [bandwidthBps]; the returned
  ///     source switches protocol to `progressive` only when the variant
  ///     URL itself is a file; in practice variant playlists stay HLS.
  ///   * DASH with representation BaseURLs → the direct file (progressive),
  ///     which also makes the source cacheable.
  ///   * Anything else → the original source.
  Future<StreamSource> narrow(
    StreamSource source, {
    required ManifestFetcher fetch,
    int? bandwidthBps,
  }) async {
    if (source.protocol == StreamProtocol.hls) {
      final text = await fetch(Uri.parse(source.url));
      if (text == null || text.isEmpty) return source;
      if (!text.contains('#EXT-X-STREAM-INF')) {
        // Media playlist: hand it to the platform HLS renderer as-is.
        return source;
      }
      final playlist = HlsMasterPlaylist.parse(
        text,
        baseUrl: Uri.parse(source.url),
      );
      final variant = playlist.bestVariant(bandwidthBps);
      if (variant == null) return source;
      // Variant playlists remain HLS (that is what the renderer expects);
      // only the URL and declared bitrate change.
      return source.copyWith(
        url: variant.uri,
        bitrate: variant.bitrateKbps > 0 ? variant.bitrateKbps : source.bitrate,
        label: source.label.isEmpty
            ? 'HLS ${variant.bitrateKbps} kbps'
            : source.label,
      );
    }
    if (source.protocol == StreamProtocol.dash) {
      final text = await fetch(Uri.parse(source.url));
      if (text == null || text.isEmpty) return source;
      final manifest = DashManifest.parse(
        text,
        manifestUrl: Uri.parse(source.url),
      );
      final representation = manifest.bestFileRepresentation(bandwidthBps);
      if (representation == null) {
        // Segmented/dynamic: only DASH-capable players can render this.
        return source;
      }
      return source.copyWith(
        url: representation.baseUrl,
        bitrate: representation.bitrateKbps > 0
            ? representation.bitrateKbps
            : source.bitrate,
        protocol: StreamProtocol.progressive,
        format: representation.isLossless ? 'FLAC' : source.format,
        label: source.label.isEmpty
            ? 'DASH ${representation.bitrateKbps} kbps'
            : source.label,
      );
    }
    return source;
  }
}

class _ScoredSource {
  const _ScoredSource({
    required this.source,
    required this.protocolRank,
    required this.budgetFit,
  });

  final StreamSource source;
  final int protocolRank;
  final int budgetFit;
}
