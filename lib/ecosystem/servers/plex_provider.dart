/// Plex provider (Feature Group: servers).
///
/// Auth: the user pastes a long-lived X-Plex-Token (the standard
/// self-hosted flow) or signs in once through `plex.tv`; the token is
/// stored in the secret store. Search: `/hubs/search?query=…` filtered to
/// `type == 'track'`. Streams: the track's `Media > Part` `key` with the
/// token as a query parameter — progressive HTTP, cacheable.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:spotimusic/core/streaming/stream_provider.dart';
import 'package:spotimusic/ecosystem/servers/music_server_models.dart';
import 'package:spotimusic/ecosystem/servers/music_server_provider.dart';
import 'package:spotimusic/models/track.dart';

class PlexProvider extends MusicServerProvider {
  PlexProvider({
    required this.config,
    required this.secrets,
    http.Client? client,
    this.clientIdentifier = 'spotiflac-mobile',
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  @override
  final MusicServerConfig config;
  final MusicServerSecretStore secrets;
  final String clientIdentifier;
  final Duration timeout;
  final http.Client _client;

  String get _base => config.baseUrl.replaceAll(RegExp(r'/+$'), '');

  Future<String?> _token() => secrets.token(config.id);

  /// Exchanges username/password for an account token via plex.tv and
  /// stores it. Returns the account display name.
  Future<String> signIn(String username, String password) async {
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('https://plex.tv/users/signin.json'),
            headers: <String, String>{
              'X-Plex-Client-Identifier': clientIdentifier,
              'X-Plex-Product': 'SpotiFLAC',
            },
            body: <String, String>{
              'user[login]': username,
              'user[password]': password,
            },
          )
          .timeout(timeout);
    } catch (error) {
      throw MusicServerException('plex.tv unreachable: $error');
    }
    if (response.statusCode == 401) {
      throw const MusicServerException('invalid credentials', kind: 'auth');
    }
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw MusicServerException('HTTP ${response.statusCode}');
    }
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is! Map<String, dynamic>) {
        throw const MusicServerException('bad payload', kind: 'parse');
      }
      final user = parsed['user'];
      if (user is! Map<String, dynamic>) {
        throw const MusicServerException('bad payload', kind: 'parse');
      }
      final token = user['authToken']?.toString() ?? '';
      if (token.isEmpty) {
        throw const MusicServerException('no token in response', kind: 'auth');
      }
      await secrets.setToken(config.id, token);
      return user['username']?.toString() ?? username;
    } on FormatException {
      throw const MusicServerException('bad payload', kind: 'parse');
    }
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String> params = const <String, String>{},
  }) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const MusicServerException('no token', kind: 'auth');
    }
    final uri = Uri.parse('$_base$path').replace(
      queryParameters: <String, String>{
        ...params,
        'X-Plex-Token': token,
      },
    );
    http.Response response;
    try {
      response = await _client.get(
        uri,
        headers: <String, String>{'Accept': 'application/json'},
      ).timeout(timeout);
    } catch (error) {
      throw MusicServerException('unreachable: $error');
    }
    if (response.statusCode == 401) {
      throw const MusicServerException('token rejected', kind: 'auth');
    }
    if (response.statusCode != 200) {
      throw MusicServerException('HTTP ${response.statusCode}');
    }
    try {
      final parsed = jsonDecode(response.body);
      if (parsed is! Map<String, dynamic>) {
        throw const MusicServerException('bad payload', kind: 'parse');
      }
      return parsed;
    } on FormatException {
      throw const MusicServerException('bad payload', kind: 'parse');
    }
  }

  @override
  Future<String?> testConnection() async {
    try {
      await _getJson('/');
      return null;
    } on MusicServerException catch (error) {
      return error.message;
    }
  }

  @override
  Future<List<ServerTrack>> search(String query, {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const <ServerTrack>[];
    final decoded = await _getJson('/hubs/search', params: <String, String>{
      'query': trimmed,
      'includeExternalMedia': '0',
      'limit': '$limit',
    });
    final container = decoded['MediaContainer'];
    if (container is! Map<String, dynamic>) return const <ServerTrack>[];
    final hubs = container['Hub'];
    if (hubs is! List) return const <ServerTrack>[];
    final tracks = <ServerTrack>[];
    for (final Object? hub in hubs) {
      if (hub is! Map<String, dynamic>) continue;
      if (hub['type']?.toString() != 'track') continue;
      final metadata = hub['Metadata'];
      if (metadata is! List) continue;
      for (final Object? item in metadata) {
        if (item is! Map<String, dynamic>) continue;
        if (tracks.length >= limit) break;
        tracks.add(await _fromMetadata(item));
      }
    }
    return tracks;
  }

  Future<ServerTrack> _fromMetadata(Map<String, dynamic> item) async {
    final token = await _token();
    final ratingKey = item['ratingKey']?.toString() ?? '';
    final thumb = item['thumb']?.toString() ?? '';
    final media = item['Media'];
    int bitrate = 0;
    String container = '';
    if (media is List && media.isNotEmpty) {
      final first = media.first;
      if (first is Map<String, dynamic>) {
        bitrate = (first['bitrate'] as num?)?.toInt() ?? 0;
        container = first['container']?.toString() ?? '';
        final parts = first['Part'];
        if (parts is List && parts.isNotEmpty) {
          final part = parts.first;
          if (part is Map<String, dynamic>) {
            container = part['container']?.toString() ?? container;
          }
        }
      }
    }
    return ServerTrack(
      itemId: ratingKey,
      title: item['title']?.toString() ?? '',
      artist: _grandparentTitle(item),
      album: item['parentTitle']?.toString() ?? '',
      albumId: item['parentRatingKey']?.toString() ?? '',
      artistId: item['grandparentRatingKey']?.toString() ?? '',
      // Cover URLs embed the token as a query param so plain image
      // widgets can fetch them.
      coverUrl: _coverUrl(thumb, token),
      durationSeconds:
          ((item['duration'] as num?)?.toInt() ?? 0) ~/ 1000,
      bitrateKbps: bitrate,
      codec: container.toUpperCase(),
      lossless: container.toLowerCase() == 'flac',
      year: (item['year'] as num?)?.toInt(),
    );
  }

  String _coverUrl(String thumb, String? token) {
    if (thumb.isEmpty) return '';
    final uri = Uri.parse('$_base$thumb');
    if (token == null || token.isEmpty) return uri.toString();
    return uri.replace(
      queryParameters: <String, String>{'X-Plex-Token': token},
    ).toString();
  }

  String _grandparentTitle(Map<String, dynamic> item) =>
      item['grandparentTitle']?.toString() ??
      item['originalTitle']?.toString() ??
      '';

  /// Resolves the part key (the playable file) for a rating key.
  Future<String?> _partKeyFor(String ratingKey) async {
    final decoded = await _getJson('/library/metadata/$ratingKey');
    final container = decoded['MediaContainer'];
    if (container is! Map<String, dynamic>) return null;
    final metadata = container['Metadata'];
    if (metadata is! List || metadata.isEmpty) return null;
    final first = metadata.first;
    if (first is! Map<String, dynamic>) return null;
    final media = first['Media'];
    if (media is! List || media.isEmpty) return null;
    final mediaFirst = media.first;
    if (mediaFirst is! Map<String, dynamic>) return null;
    final parts = mediaFirst['Part'];
    if (parts is! List || parts.isEmpty) return null;
    final part = parts.first;
    if (part is! Map<String, dynamic>) return null;
    return part['key']?.toString();
  }

  @override
  Future<StreamSource?> resolveTrack(Track track) async {
    if (!owns(track)) return null;
    final token = await _token();
    if (token == null || token.isEmpty) return null;
    final partKey = await _partKeyFor(track.id);
    if (partKey == null || partKey.isEmpty) return null;
    final maxBitrate = config.maxBitrateKbps;
    final direct = config.preferDirectPlay;
    final params = <String, String>{
      'X-Plex-Token': token,
      // download=1 keeps the original bytes (no implicit transcode).
      if (direct) 'download': '1',
      if (!direct && maxBitrate > 0) 'maxVideoBitrate': '$maxBitrate',
    };
    final uri = Uri.parse('$_base$partKey').replace(
      queryParameters: params,
    );
    return StreamSource(
      url: uri.toString(),
      format: 'ORIGINAL',
      bitrate: 0,
      protocol: StreamProtocol.progressive,
      providerId: id,
      cachePermitted: true,
      label: '${config.effectiveName} · ${direct ? 'direct' : 'bounded'}',
    );
  }
}
