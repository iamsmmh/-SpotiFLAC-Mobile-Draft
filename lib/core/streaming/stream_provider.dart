/// Stream provider port for the native streaming engine (Feature 1).
///
/// This is the *provider* half of `lib/core/streaming/`: implementations
/// answer "where can this track be streamed from right now?" with a
/// protocol-aware [StreamSource]. The resolution, protocol negotiation,
/// validation and failover machinery lives in `stream_resolver.dart` and
/// `streaming_service.dart`; the per-playback lifecycle lives in
/// `stream_session.dart`.
///
/// Layering: this file is pure Dart (model imports only). It must never
/// import Riverpod, Flutter, or the app's services — adapters that bridge
/// real backends (self-hosted servers, extensions) live in the provider
/// layer and feed instances of [StreamProvider] into [StreamingService].
library;

import 'package:spotiflac_android/models/track.dart';

/// Transport protocol a source uses.
enum StreamProtocol {
  /// A single progressive file (FLAC/MP3/AAC/Opus over HTTP range requests).
  progressive,

  /// HTTP Live Streaming (`.m3u8` playlists; media or master playlist).
  hls,

  /// MPEG-DASH (`.mpd` manifest).
  dash;

  static StreamProtocol fromName(Object? name) {
    final text = name?.toString().trim().toLowerCase() ?? '';
    for (final value in StreamProtocol.values) {
      if (value.name == text) return value;
    }
    return StreamProtocol.progressive;
  }

  /// Short label for logs and UI surfaces.
  String get label => switch (this) {
    StreamProtocol.progressive => 'Progressive',
    StreamProtocol.hls => 'HLS',
    StreamProtocol.dash => 'DASH',
  };
}

/// One playable stream location for one track, as reported by a
/// [StreamProvider].
///
/// Deliberately small and transport-agnostic: the resolver enriches it with
/// protocol decisions (variant selection, manifest parsing) and the
/// streaming service validates it before playback.
class StreamSource {
  const StreamSource({
    required this.url,
    required this.format,
    required this.bitrate,
    this.protocol = StreamProtocol.progressive,
    this.providerId = '',
    this.expiresAt,
    this.cachePermitted = false,
    this.headers = const <String, String>{},
    this.label = '',
  });

  /// Absolute URL of the file, media playlist, variant playlist or manifest.
  final String url;

  /// Container/codec label as advertised by the provider (e.g. `FLAC`,
  /// `AAC`, `MP3`, `OPUS`, `TS`).
  final String format;

  /// Declared/observed bitrate in kbps (0 when unknown).
  final int bitrate;

  /// Transport protocol this URL speaks.
  final StreamProtocol protocol;

  /// Identifies the provider that produced this source (for failover logs).
  final String providerId;

  /// Absolute expiry of signed URLs; null when the URL does not expire.
  final DateTime? expiresAt;

  /// Whether the provider's terms permit caching this stream offline.
  final bool cachePermitted;

  /// Extra request headers the player/fetcher must send (auth tokens).
  final Map<String, String> headers;

  /// Human label (e.g. "Jellyfin · FLAC direct").
  final String label;

  bool get isExpired {
    final expiry = expiresAt;
    if (expiry == null) return false;
    return !DateTime.now().isBefore(expiry);
  }

  StreamSource copyWith({
    String? url,
    String? format,
    int? bitrate,
    StreamProtocol? protocol,
    String? providerId,
    DateTime? expiresAt,
    bool? cachePermitted,
    Map<String, String>? headers,
    String? label,
  }) => StreamSource(
    url: url ?? this.url,
    format: format ?? this.format,
    bitrate: bitrate ?? this.bitrate,
    protocol: protocol ?? this.protocol,
    providerId: providerId ?? this.providerId,
    expiresAt: expiresAt ?? this.expiresAt,
    cachePermitted: cachePermitted ?? this.cachePermitted,
    headers: headers ?? this.headers,
    label: label ?? this.label,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'format': format,
    'bitrate_kbps': bitrate,
    'protocol': protocol.name,
    'provider_id': providerId,
    if (expiresAt != null) 'expires_at': expiresAt!.toUtc().toIso8601String(),
    'cache_permitted': cachePermitted,
    'headers': <String, String>{...headers},
    'label': label,
  };

  factory StreamSource.fromJson(Map<String, dynamic> json) => StreamSource(
    url: json['url']?.toString() ?? '',
    format: json['format']?.toString() ?? '',
    bitrate: (json['bitrate_kbps'] as num?)?.toInt() ?? 0,
    protocol: StreamProtocol.fromName(json['protocol']),
    providerId: json['provider_id']?.toString() ?? '',
    expiresAt: DateTime.tryParse(json['expires_at']?.toString() ?? ''),
    cachePermitted: json['cache_permitted'] == true,
    headers: json['headers'] is Map
        ? (json['headers'] as Map)
              .map((k, v) => MapEntry(k.toString(), v.toString()))
        : const <String, String>{},
    label: json['label']?.toString() ?? '',
  );
}

/// A source of streamable audio (Feature 1 port).
///
/// Implementations: self-hosted server providers (Jellyfin/Navidrome/
/// Subsonic/Plex), extension-backed resolvers, and (in tests) fakes. The
/// service calls [resolveTrack] for each registered provider, ordered by
/// [priority] (lower wins), until one returns a usable [StreamSource].
abstract class StreamProvider {
  /// Stable provider identifier used in logs and failover traces.
  String get id;

  /// Human-readable name surfaced in diagnostics.
  String get displayName;

  /// Ordering hint across providers (lower = tried first).
  int get priority => 0;

  /// Whether the provider currently wants to be asked (connected, enabled).
  bool get enabled => true;

  /// Resolves one stream candidate for [track], or null when this provider
  /// cannot serve the track. Must not throw for "not available" — return
  /// null so the service can fail over to the next provider.
  Future<StreamSource?> resolveTrack(Track track);
}
