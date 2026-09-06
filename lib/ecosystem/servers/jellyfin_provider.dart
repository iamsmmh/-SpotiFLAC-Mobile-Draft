/// Jellyfin provider (Feature Group: servers).
///
/// Auth: `POST /Users/AuthenticateByName` with the `MediaBrowser`
/// authorization header → long-lived `AccessToken` (persisted in the
/// secret store). Search: `GET /Items?searchTerm=…&IncludeItemTypes=Audio`.
/// Streams:
///   * direct — `/Audio/{id}/stream?static=true` (original file,
///     progressive, cacheable);
///   * universal — `/Audio/{id}/universal?…&TranscodingProtocol=hls`
///     (server-side transcode to HLS when the client bitrate demands it).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:spotimusic/core/streaming/stream_provider.dart';
import 'package:spotimusic/ecosystem/servers/music_server_models.dart';
import 'package:spotimusic/ecosystem/servers/music_server_provider.dart';
import 'package:spotimusic/models/track.dart';

class JellyfinProvider extends MusicServerProvider {
  JellyfinProvider({
    required this.config,
    required this.secrets,
    http.Client? client,
    this.deviceId = 'spotiflac-mobile',
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? http.Client();

  @override
  final MusicServerConfig config;
  final MusicServerSecretStore secrets;
  final String deviceId;
  final Duration timeout;
  final http.Client _client;

  static const String _clientName = 'SpotiFLAC';
  static const String _clientVersion = '5.0.0';

  String get _base => config.baseUrl.replaceAll(RegExp(r'/+$'), '');

  String _authHeader(String? token) => 'MediaBrowser Client="$_clientName", '
      'Device="SpotiFLAC Mobile", DeviceId="$deviceId", '
      'Version="$_clientVersion"'
      '${token == null || token.isEmpty ? '' : ', Token="$token"'}';

  Future<String?> _token() => secrets.token(config.id);

  /// Signs in with username/password and stores the access token.
  /// Returns the display name of the signed-in user.
  Future<String> signIn(String password) async {
    http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_base/Users/AuthenticateByName'),
            headers: <String, String>{
              'Authorization': _authHeader(null),
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, String>{
              'Username': config.username,
              'Pw': password,
            }),
          )
          .timeout(timeout);
    } catch (error) {
      throw MusicServerException('unreachable: $error');
    }
    if (response.statusCode == 401) {
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
    final token = decoded['AccessToken']?.toString() ?? '';
    if (token.isEmpty) {
      throw const MusicServerException('no token in response', kind: 'auth');
    }
    await secrets.setToken(config.id, token);
    return decoded['User'] is Map<String, dynamic>
        ? (decoded['User'] as Map<String, dynamic>)['Name']?.toString() ??
              config.username
        : config.username;
  }

  Future<Map<String, dynamic>> _getJson(String path,
      {Map<String, String> params = const <String, String>{}}) async {
    final token = await _token();
    if (token == null || token.isEmpty) {
      throw const MusicServerException('not signed in', kind: 'auth');
    }
    final uri = Uri.parse('$_base$path').replace(
      queryParameters: <String, String>{...params, 'api_key': token},
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
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const MusicServerException('session expired', kind: 'auth');
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
      await _getJson('/System/Info/Public');
      final token = await _token();
      if (token == null || token.isEmpty) return 'Not signed in';
      await _getJson('/Users/Me');
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
    final decoded = await _getJson('/Items', params: <String, String>{
      'searchTerm': trimmed,
      'IncludeItemTypes': 'Audio',
      'Recursive': 'true',
      'Limit': '$limit',
      'Fields': 'AlbumArtists,MediaStreams',
    });
    final items = decoded['Items'];
    if (items is! List) return const <ServerTrack>[];
    final token = await _token();
    return <ServerTrack>[
      for (final Object? item in items)
        if (item is Map<String, dynamic>) _fromItem(item, token),
    ];
  }

  ServerTrack _fromItem(Map<String, dynamic> item, String? token) {
    final runTimeTicks = (item['RunTimeTicks'] as num?)?.toInt() ?? 0;
    final id = item['Id']?.toString() ?? '';
    final imageTag = '';
    final cover = id.isEmpty
        ? ''
        : '$_base/Items/$id/Images/Primary?maxWidth=512'
              '${token == null || token.isEmpty ? '' : '&api_key=$token'}'
              '$imageTag';
    return ServerTrack(
      itemId: id,
      title: item['Name']?.toString() ?? '',
      artist: _artistsOf(item),
      album: item['Album']?.toString() ?? '',
      albumId: item['AlbumId']?.toString() ?? '',
      artistId: item['ArtistItems'] is List &&
              (item['ArtistItems'] as List).isNotEmpty &&
              (item['ArtistItems'] as List).first is Map
          ? ((item['ArtistItems'] as List).first
                    as Map<String, dynamic>)['Id']
                ?.toString() ??
              ''
          : '',
      coverUrl: cover,
      durationSeconds: runTimeTicks ~/ Duration.microsecondsPerSecond ~/ 10,
      bitrateKbps: (item['MediaSources'] is List &&
              (item['MediaSources'] as List).isNotEmpty &&
              (item['MediaSources'] as List).first is Map)
          ? (((item['MediaSources'] as List).first
                  as Map<String, dynamic>)['Bitrate'] as num?)
                ?.toInt() ??
                0
          : 0,
      codec: _audioCodecOf(item),
      // _audioCodecOf upper-cases the container; compare case-insensitively.
      lossless: _audioCodecOf(item).toLowerCase().contains('flac'),
      year: (item['ProductionYear'] as num?)?.toInt(),
    );
  }

  String _artistsOf(Map<String, dynamic> item) {
    final artists = item['Artists'];
    if (artists is List && artists.isNotEmpty) {
      return artists.whereType<String>().join(', ');
    }
    return item['AlbumArtist']?.toString() ?? '';
  }

  String _audioCodecOf(Map<String, dynamic> item) {
    final sources = item['MediaSources'];
    if (sources is List && sources.isNotEmpty) {
      final first = sources.first;
      if (first is Map<String, dynamic>) {
        return first['Container']?.toString().toUpperCase() ?? '';
      }
    }
    return '';
  }

  @override
  Future<StreamSource?> resolveTrack(Track track) async {
    if (!owns(track)) return null;
    final token = await _token();
    if (token == null || token.isEmpty) return null;
    final maxBitrate = config.maxBitrateKbps;

    if (config.preferDirectPlay) {
      return StreamSource(
        url: '$_base/Audio/${track.id}/stream?static=true&api_key=$token',
        format: 'ORIGINAL',
        bitrate: 0,
        protocol: StreamProtocol.progressive,
        providerId: id,
        cachePermitted: true,
        label: '${config.effectiveName} · direct',
      );
    }

    // Universal endpoint: the server decides direct vs transcode; the
    // transcode target is HLS, exercised by the protocol resolver.
    final codec = config.transcodeFormat.trim().isEmpty
        ? 'aac'
        : config.transcodeFormat.trim().toLowerCase();
    final params = <String, String>{
      'api_key': token,
      'DeviceId': deviceId,
      if (maxBitrate > 0) 'MaxStreamingBitrate': '${maxBitrate * 1000}',
      'AudioCodec': codec,
      'TranscodingContainer': 'ts',
      'TranscodingProtocol': 'hls',
      'Container': 'opus,mp3,aac,m4a,flac,webma,webm,wav',
    };
    final uri = Uri.parse('$_base/Audio/${track.id}/universal').replace(
      queryParameters: params,
    );
    return StreamSource(
      url: uri.toString(),
      format: codec.toUpperCase(),
      bitrate: maxBitrate > 0 ? maxBitrate : 320,
      protocol: StreamProtocol.hls,
      providerId: id,
      cachePermitted: codec == 'flac',
      label: '${config.effectiveName} · adaptive',
    );
  }
}
