import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spotimusic/core/streaming/stream_provider.dart';
import 'package:spotimusic/ecosystem/servers/jellyfin_provider.dart';
import 'package:spotimusic/ecosystem/servers/music_server_models.dart';
import 'package:spotimusic/ecosystem/servers/plex_provider.dart';
import 'package:spotimusic/ecosystem/servers/subsonic_provider.dart';
import 'package:spotimusic/models/track.dart';
import 'package:spotimusic/utils/md5.dart';

class _FakeSecrets implements MusicServerSecretStore {
  final Map<String, String> _store = <String, String>{};

  @override
  Future<String?> password(String serverId) async =>
      _store['pw:$serverId'];

  @override
  Future<void> setPassword(String serverId, String value) async {
    _store['pw:$serverId'] = value;
  }

  @override
  Future<String?> token(String serverId) async => _store['tk:$serverId'];

  @override
  Future<void> setToken(String serverId, String value) async {
    _store['tk:$serverId'] = value;
  }

  @override
  Future<void> clear(String serverId) async {
    _store
      ..remove('pw:$serverId')
      ..remove('tk:$serverId');
  }
}

MusicServerConfig _config(
  MusicServerKind kind, {
  String url = 'https://music.example.com',
  bool direct = true,
}) => MusicServerConfig(
  id: 'srv1',
  kind: kind,
  baseUrl: url,
  username: 'user',
  preferDirectPlay: direct,
);

Track _ownedTrack(String source) => Track(
  id: '42',
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 200,
  source: source,
);

void main() {
  group('Subsonic family', () {
    test('auth params use the salted token scheme', () async {
      final secrets = _FakeSecrets();
      await secrets.setPassword('srv1', 'secret');
      final provider = SubsonicProvider(
        config: _config(MusicServerKind.subsonic),
        secrets: secrets,
      );

      final seenUrls = <Uri>[];
      final client = MockClient((request) async {
        seenUrls.add(request.url);
        return http.Response(
          jsonEncode(<String, dynamic>{
            'subsonic-response': <String, dynamic>{'status': 'ok'},
          }),
          200,
        );
      });
      final probing = SubsonicProvider(
        config: _config(MusicServerKind.subsonic),
        secrets: secrets,
        client: client,
      );
      expect(await probing.testConnection(), isNull);

      // resolveTrack builds a query-authed progressive URL.
      final source = await provider.resolveTrack(
        _ownedTrack('subsonic:srv1'),
      );
      expect(source, isNotNull);
      final uri = Uri.parse(source!.url);
      expect(uri.path, contains('/rest/stream'));
      expect(uri.queryParameters['u'], 'user');
      expect(uri.queryParameters['id'], '42');
      final token = uri.queryParameters['t']!;
      final salt = uri.queryParameters['s']!;
      expect(token, md5Hex('secret$salt'));
      expect(uri.queryParameters['v'], '1.16.1');
      expect(source.protocol, StreamProtocol.progressive);
      expect(source.cachePermitted, isTrue);
      expect(seenUrls, isNotEmpty);
    });

    test('search3 maps songs to ServerTrack', () async {
      final secrets = _FakeSecrets();
      await secrets.setPassword('srv1', 'secret');
      final client = MockClient((request) async {
        expect(request.url.path, contains('search3'));
        return http.Response(
          jsonEncode(<String, dynamic>{
            'subsonic-response': <String, dynamic>{
              'status': 'ok',
              'searchResult3': <String, dynamic>{
                'song': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'id': '42',
                    'title': 'Song',
                    'artist': 'Artist',
                    'album': 'Album',
                    'duration': 200,
                    'bitRate': 900,
                    'suffix': 'flac',
                    'coverArt': 'c1',
                    'year': 2024,
                  },
                ],
              },
            },
          }),
          200,
        );
      });
      final provider = SubsonicProvider(
        config: _config(MusicServerKind.navidrome),
        secrets: secrets,
        client: client,
      );
      final results = await provider.search('song');
      expect(results, hasLength(1));
      expect(results.first.lossless, isTrue);
      expect(results.first.durationSeconds, 200);
      final track = results.first.toTrack(provider.config);
      expect(track.source, 'navidrome:srv1');
    });

    test('auth failures surface as MusicServerException(auth)', () async {
      final secrets = _FakeSecrets();
      await secrets.setPassword('srv1', 'wrong');
      final client = MockClient(
        (request) async => http.Response('denied', 401),
      );
      final provider = SubsonicProvider(
        config: _config(MusicServerKind.airsonic),
        secrets: secrets,
        client: client,
      );
      final error = await provider.testConnection();
      expect(error, isNotNull);
    });
  });

  group('Jellyfin', () {
    test('signIn stores the access token', () async {
      final secrets = _FakeSecrets();
      final client = MockClient((request) async {
        expect(request.url.path, contains('AuthenticateByName'));
        return http.Response(
          jsonEncode(<String, dynamic>{
            'AccessToken': 'tok123',
            'User': <String, dynamic>{'Name': 'displayName'},
          }),
          200,
        );
      });
      final provider = JellyfinProvider(
        config: _config(MusicServerKind.jellyfin),
        secrets: secrets,
        client: client,
      );
      final name = await provider.signIn('pw');
      expect(name, 'displayName');
      expect(await secrets.token('srv1'), 'tok123');
    });

    test('resolveTrack direct play is a static progressive URL', () async {
      final secrets = _FakeSecrets();
      await secrets.setToken('srv1', 'tok123');
      final provider = JellyfinProvider(
        config: _config(MusicServerKind.jellyfin),
        secrets: secrets,
      );
      final source = await provider.resolveTrack(
        _ownedTrack('jellyfin:srv1'),
      );
      expect(source!.url, contains('/Audio/42/stream?static=true'));
      expect(source.url, contains('api_key=tok123'));
      expect(source.cachePermitted, isTrue);
    });

    test('resolveTrack adaptive uses the universal HLS endpoint', () async {
      final secrets = _FakeSecrets();
      await secrets.setToken('srv1', 'tok123');
      final provider = JellyfinProvider(
        config: _config(
          MusicServerKind.jellyfin,
          direct: false,
        ).copyWith(transcodeFormat: 'flac'),
        secrets: secrets,
      );
      final source = await provider.resolveTrack(
        _ownedTrack('jellyfin:srv1'),
      );
      expect(source!.url, contains('/Audio/42/universal'));
      expect(source.protocol, StreamProtocol.hls);
      expect(source.url, contains('TranscodingProtocol=hls'));
    });

    test('search maps Items with RunTimeTicks', () async {
      final secrets = _FakeSecrets();
      await secrets.setToken('srv1', 'tok123');
      final client = MockClient((request) async {
        expect(request.url.queryParameters['searchTerm'], 'song');
        return http.Response(
          jsonEncode(<String, dynamic>{
            'Items': <Map<String, dynamic>>[
              <String, dynamic>{
                'Id': 'abc',
                'Name': 'Song',
                'Artists': <String>['Artist'],
                'Album': 'Album',
                'AlbumId': 'alb1',
                'RunTimeTicks': 2000000000, // 200s in 100ns ticks
                'ProductionYear': 2023,
                'MediaSources': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'Container': 'flac',
                    'Bitrate': 900000,
                  },
                ],
              },
            ],
          }),
          200,
        );
      });
      final provider = JellyfinProvider(
        config: _config(MusicServerKind.jellyfin),
        secrets: secrets,
        client: client,
      );
      final results = await provider.search('song');
      expect(results.single.durationSeconds, 200);
      expect(results.single.lossless, isTrue);
    });
  });

  group('Plex', () {
    test('hub search filters track hubs and converts durations', () async {
      final secrets = _FakeSecrets();
      await secrets.setToken('srv1', 'plex-token');
      final client = MockClient((request) async {
        if (request.url.path.contains('/library/metadata/')) {
          return http.Response(
            jsonEncode(<String, dynamic>{
              'MediaContainer': <String, dynamic>{
                'Metadata': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'ratingKey': '42',
                    'Media': <Map<String, dynamic>>[
                      <String, dynamic>{
                        'Part': <Map<String, dynamic>>[
                          <String, dynamic>{
                            'key': '/library/parts/77/file.flac',
                          },
                        ],
                      },
                    ],
                  },
                ],
              },
            }),
            200,
          );
        }
        expect(request.url.path, contains('/hubs/search'));
        return http.Response(
          jsonEncode(<String, dynamic>{
            'MediaContainer': <String, dynamic>{
              'Hub': <Map<String, dynamic>>[
                <String, dynamic>{
                  'type': 'artist',
                  'Metadata': <Map<String, dynamic>>[
                    <String, dynamic>{'ratingKey': '9'},
                  ],
                },
                <String, dynamic>{
                  'type': 'track',
                  'Metadata': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'ratingKey': '42',
                      'title': 'Song',
                      'grandparentTitle': 'Artist',
                      'parentTitle': 'Album',
                      'duration': 200000,
                      'year': 2020,
                      'thumb': '/thumb/42',
                      'Media': <Map<String, dynamic>>[
                        <String, dynamic>{
                          'bitrate': 900,
                          'container': 'flac',
                          'Part': <Map<String, dynamic>>[
                            <String, dynamic>{
                              'key': '/library/parts/77/file.flac',
                              'container': 'flac',
                            },
                          ],
                        },
                      ],
                    },
                  ],
                },
              ],
            },
          }),
          200,
        );
      });
      final provider = PlexProvider(
        config: _config(MusicServerKind.plex),
        secrets: secrets,
        client: client,
      );
      final results = await provider.search('song');
      expect(results, hasLength(1));
      expect(results.single.durationSeconds, 200);
      expect(results.single.coverUrl, contains('X-Plex-Token=plex-token'));

      final source = await provider.resolveTrack(_ownedTrack('plex:srv1'));
      expect(source!.url, contains('/library/parts/77/file.flac'));
      expect(source.url, contains('X-Plex-Token=plex-token'));
      expect(source.cachePermitted, isTrue);
    });
  });

  group('MusicServerConfig', () {
    test('json round trip', () {
      final config = _config(
        MusicServerKind.jellyfin,
      ).copyWith(displayName: 'Home', maxBitrateKbps: 1000);
      final restored = MusicServerConfig.fromJson(config.toJson());
      expect(restored!.kind, MusicServerKind.jellyfin);
      expect(restored.effectiveName, 'Home');
      expect(restored.maxBitrateKbps, 1000);
      expect(restored.sourceTag, 'jellyfin:srv1');
    });

    test('rejects corrupt rows', () {
      expect(MusicServerConfig.fromJson(<String, String>{'id': 'x'}), isNull);
      expect(MusicServerConfig.fromJson('junk'), isNull);
    });
  });

  test('providers only resolve tracks they own', () async {
    final secrets = _FakeSecrets();
    final subsonic = SubsonicProvider(
      config: _config(MusicServerKind.subsonic),
      secrets: secrets,
    );
    expect(
      await subsonic.resolveTrack(_ownedTrack('jellyfin:other')),
      isNull,
    );
    expect(subsonic.owns(_ownedTrack('subsonic:srv1')), isTrue);
  });
}
