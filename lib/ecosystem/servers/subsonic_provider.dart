/// Subsonic-family provider: Subsonic, Navidrome, Airsonic (Feature Group:
/// servers).
///
/// All three speak the Subsonic REST API (`/rest/<view>.view`). Auth uses
/// the salted token scheme (`t = md5(password + salt)`, API 1.13.0+);
/// Navidrome additionally keeps a session token but accepts the same
/// scheme. Streams are progressive `stream.view` URLs with query auth so
/// they play through the existing `UrlSource` pipeline without custom
/// headers.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:spotimusic/core/streaming/stream_provider.dart';
import 'package:spotimusic/ecosystem/servers/music_server_models.dart';
import 'package:spotimusic/ecosystem/servers/music_server_provider.dart';
import 'package:spotimusic/models/track.dart';
import 'package:spotimusic/utils/md5.dart';

/// Shared HTTP behaviour for the Subsonic dialect.
class SubsonicProvider extends MusicServerProvider {
  SubsonicProvider({
    required this.config,
    required this.secrets,
    http.Client? client,
    this.clientName = 'SpotiFLAC',
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  @override
  final MusicServerConfig config;

  final MusicServerSecretStore secrets;
  final String clientName;
  final Duration timeout;
  final http.Client _client;

  static const String _apiVersion = '1.16.1';

  @override
  String get id => config.sourceTag;

  @override
  String get displayName => config.effectiveName;

  @override
  int get priority => 20;

  @override
  bool get enabled => config.enabled;

  /// Subsonic wants the token per request; build query params fresh.
  Future<Map<String, String>> _authParams() async {
    final password = await secrets.password(config.id) ?? '';
    final (salt, token) = subsonicAuthToken(password);
    return <String, String>{
      'u': config.username,
      't': token,
      's': salt,
      'v': _apiVersion,
      'c': clientName,
      'f': 'json',
    };
  }

  Uri _endpoint(String view, Map<String, String> params) {
    final base = config.baseUrl.replaceAll(RegExp(r'/+$'), '');
    final merged = <String, String>{...params};
    return Uri.parse('$base/rest/$view').replace(
      queryParameters: merged,
    );
  }

  Future<Map<String, dynamic>> _getJson(String view,
      {Map<String, String> params = const <String, String>{}}) async {
    final auth = await _authParams();
    final uri = _endpoint(view, <String, String>{...params, ...auth});
    http.Response response;
    try {
      response = await _client
          .get(uri, headers: <String, String>{'Accept': 'application/json'})
          .timeout(timeout);
    } catch (error) {
      throw MusicServerException('unreachable: $error');
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const MusicServerException('invalid credentials', kind: 'auth');
    }
    if (response.statusCode != 200) {
      throw MusicServerException('HTTP ${response.statusCode}');
    }
    Map<String, dynamic> decoded;
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is! Map<String, dynamic>) {
        throw const MusicServerException('bad payload', kind: 'parse');
      }
      decoded = parsed;
    } on FormatException {
      throw const MusicServerException('bad payload', kind: 'parse');
    }
    final envelope = decoded['subsonic-response'];
    if (envelope is! Map<String, dynamic>) {
      throw const MusicServerException('bad payload', kind: 'parse');
    }
    final status = envelope['status']?.toString();
    if (status != null && status != 'ok') {
      throw MusicServerException(
        envelope['message']?.toString() ?? 'server error ($status)',
        kind: 'auth',
      );
    }
    return envelope;
  }

  @override
  Future<String?> testConnection() async {
    try {
      await _getJson('ping');
      return null;
    } on MusicServerException catch (error) {
      return error.message;
    }
  }

  @override
  Future<List<ServerTrack>> search(String query,
      {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <ServerTrack>[];
    final envelope = await _getJson('search3', params: <String, String>{
      'query': trimmed,
      'songCount': '$limit',
      'artistCount': '0',
      'albumCount': '0',
    });
    final results = envelope['searchResult3'];
    if (results is! Map<String, dynamic>) return const <ServerTrack>[];
    final songs = results['song'];
    if (songs is! List) return const <ServerTrack>[];
    return <ServerTrack>[
      for (final Object? song in songs)
        if (song is Map<String, dynamic>) _fromSong(song),
    ];
  }

  Future<ServerTrack> _songById(String itemId) async {
    final envelope = await _getJson('getSong', params: <String, String>{
      'id': itemId,
    });
    final song = envelope['song'];
    if (song is Map<String, dynamic>) return _fromSong(song);
    throw const MusicServerException('track not found', kind: 'parse');
  }

  ServerTrack _fromSong(Map<String, dynamic> song) {
    final coverId = song['coverArt']?.toString() ?? '';
    final suffix = song['suffix']?.toString() ?? '';
    final codec = suffix.toUpperCase();
    return ServerTrack(
      itemId: song['id']?.toString() ?? '',
      title: song['title']?.toString() ?? '',
      artist: song['artist']?.toString() ?? '',
      album: song['album']?.toString() ?? '',
      albumId: song['albumId']?.toString() ?? '',
      artistId: song['artistId']?.toString() ?? '',
      coverUrl: coverId.isEmpty ? '' : _coverArtUrl(coverId),
      durationSeconds: (song['duration'] as num?)?.toInt() ?? 0,
      bitrateKbps: (song['bitRate'] as num?)?.toInt() ?? 0,
      codec: codec,
      lossless: codec == 'FLAC' || codec == 'WAV' || codec == 'ALAC',
      year: (song['year'] as num?)?.toInt(),
    );
  }

  String _coverArtUrl(String coverId) {
    // Built lazily with auth; used by CachedNetworkImage.
    return '${config.baseUrl.replaceAll(RegExp(r'/+$'), '')}/rest/getCoverArt'
        '?id=$coverId&size=512&u=${config.username}';
  }

  @override
  Future<StreamSource?> resolveTrack(Track track) async {
    if (!owns(track)) return null;
    final auth = await _authParams();
    final maxBitRate = config.maxBitrateKbps > 0 ? config.maxBitrateKbps : 0;
    final format = config.transcodeFormat.trim();
    final params = <String, String>{
      'id': track.id,
      if (maxBitRate > 0) 'maxBitRate': '$maxBitRate',
      if (format.isNotEmpty) 'format': format,
      ...auth,
    }..remove('f');
    final uri = _endpoint('stream', params);
    var bitrate = 320;
    var formatLabel = format.toUpperCase();
    if (formatLabel.isEmpty) {
      formatLabel = 'RAW';
      bitrate = 1000;
    }
    return StreamSource(
      url: uri.toString(),
      format: formatLabel,
      bitrate: bitrate,
      protocol: StreamProtocol.progressive,
      providerId: id,
      // Self-hosted servers are the user's own files: caching is the
      // user's decision, and the default honours it.
      cachePermitted: true,
      label: '${config.effectiveName} · ${formatLabel == 'RAW' ? 'original' : formatLabel}',
    );
  }

  /// Re-resolves full metadata for a track id (used by hybrid caching to
  /// label artifacts).
  Future<ServerTrack> trackDetails(String itemId) => _songById(itemId);
}

/// Navidrome: Subsonic dialect with its own branding and slightly
/// different transcoding defaults.
class NavidromeProvider extends SubsonicProvider {
  NavidromeProvider({
    required super.config,
    required super.secrets,
    super.client,
  }) : assert(config.kind == MusicServerKind.navidrome);

  @override
  int get priority => 19;
}

/// Airsonic: the reference Subsonic server.
class AirsonicProvider extends SubsonicProvider {
  AirsonicProvider({
    required super.config,
    required super.secrets,
    super.client,
  }) : assert(config.kind == MusicServerKind.airsonic);
}
