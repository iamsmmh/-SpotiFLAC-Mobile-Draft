import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/multi_provider_stream_service.dart';
import 'package:spotiflac_android/services/provider_credentials.dart';

class _MapCredentials implements StreamCredentialResolver {
  _MapCredentials(this.values);

  final Map<String, String> values;
  int reads = 0;

  @override
  Future<String?> read(String name) async {
    reads++;
    return values[name];
  }
}

void main() {
  group('resolveStreamCredential', () {
    test('explicit token wins and the resolver is not consulted', () async {
      var consulted = false;
      final result = await resolveStreamCredential('direct', () async {
        consulted = true;
        return 'resolver';
      });
      expect(result, 'direct');
      expect(consulted, isFalse);
    });

    test('blank explicit token falls through to the resolver', () async {
      final result = await resolveStreamCredential('   ', () async => 'tok');
      expect(result, 'tok');
    });

    test('blank resolver values count as missing', () async {
      expect(await resolveStreamCredential(null, () async => '  '), isNull);
      expect(await resolveStreamCredential(null, null), isNull);
      expect(
        await resolveStreamCredential('  padded  ', null),
        'padded',
      );
    });
  });

  group('handler credential precedence (no network)', () {
    test('tidal resolves the access token', () async {
      expect(
        await TidalStreamHandler(
          accessTokenResolver: () async => 'tidal-tok',
        ).resolveAccessToken(),
        'tidal-tok',
      );
      expect(
        await TidalStreamHandler(
          accessToken: 'direct',
          accessTokenResolver: () async => throw StateError('consulted'),
        ).resolveAccessToken(),
        'direct',
      );
      expect(
        await TidalStreamHandler().resolveAccessToken(),
        isNull,
      );
    });

    test('apple resolves the developer token', () async {
      expect(
        await AppleMusicStreamHandler(
          bearerTokenResolver: () async => 'apple-tok',
        ).resolveBearerToken(),
        'apple-tok',
      );
      expect(
        await AppleMusicStreamHandler().resolveBearerToken(),
        isNull,
      );
    });

    test('qobuz resolves app id and auth token independently', () async {
      final handler = QobuzStreamHandler(
        appIdResolver: () async => 'app',
        authTokenResolver: () async => 'tok',
      );
      expect(await handler.resolveAppId(), 'app');
      expect(await handler.resolveAuthToken(), 'tok');
      expect(await QobuzStreamHandler().resolveAppId(), isNull);
      expect(await QobuzStreamHandler().resolveAuthToken(), isNull);
    });

    test('deezer resolves the ARL', () async {
      expect(
        await DeezerStreamHandler(
          arlTokenResolver: () async => 'arl',
        ).resolveArlToken(),
        'arl',
      );
      expect(await DeezerStreamHandler().resolveArlToken(), isNull);
    });

    test('amazon resolves bearer and device tokens', () async {
      final handler = AmazonMusicStreamHandler(
        bearerTokenResolver: () async => 'bearer',
        deviceTokenResolver: () async => 'device',
      );
      expect(await handler.resolveBearerToken(), 'bearer');
      expect(await handler.resolveDeviceToken(), 'device');
      expect(
        await AmazonMusicStreamHandler().resolveBearerToken(),
        isNull,
      );
    });

    test('anonymous handlers return null before any network traffic',
        () async {
      const request = StreamTrackRequest(title: 'Song', artist: 'Artist');
      // Each of these returns null on the missing-credential path, which runs
      // before the first HTTP call — the test would hang or throw if any of
      // them touched the network.
      expect(await TidalStreamHandler().resolve(request), isNull);
      expect(await AppleMusicStreamHandler().resolve(request), isNull);
      expect(await QobuzStreamHandler().resolve(request), isNull);
      expect(await AmazonMusicStreamHandler().resolve(request), isNull);
    });
  });

  group('service credential wiring', () {
    test('credential store reaches every credentialed handler', () async {
      final credentials = _MapCredentials(<String, String>{
        StreamCredentialNames.tidalAccessToken: 'tidal-tok',
        StreamCredentialNames.qobuzAppId: 'app',
        StreamCredentialNames.qobuzAuthToken: 'tok',
        StreamCredentialNames.appleDeveloperToken: 'apple-tok',
        StreamCredentialNames.deezerArl: 'arl',
        StreamCredentialNames.amazonBearerToken: 'bearer',
        StreamCredentialNames.amazonDeviceToken: 'device',
      });
      final service = MultiProviderStreamService(credentials: credentials);
      addTearDown(service.dispose);

      final tidal =
          service.handlerFor(StreamProviderId.tidal) as TidalStreamHandler;
      final qobuz =
          service.handlerFor(StreamProviderId.qobuz) as QobuzStreamHandler;
      final apple =
          service.handlerFor(StreamProviderId.appleMusic)
              as AppleMusicStreamHandler;
      final deezer =
          service.handlerFor(StreamProviderId.deezer) as DeezerStreamHandler;
      final amazon =
          service.handlerFor(StreamProviderId.amazonMusic)
              as AmazonMusicStreamHandler;

      expect(await tidal.resolveAccessToken(), 'tidal-tok');
      expect(await qobuz.resolveAppId(), 'app');
      expect(await qobuz.resolveAuthToken(), 'tok');
      expect(await apple.resolveBearerToken(), 'apple-tok');
      expect(await deezer.resolveArlToken(), 'arl');
      expect(await amazon.resolveBearerToken(), 'bearer');
      expect(await amazon.resolveDeviceToken(), 'device');
      expect(credentials.reads, 7);
    });

    test('no credential store preserves the legacy behavior', () async {
      final service = MultiProviderStreamService();
      addTearDown(service.dispose);

      final tidal =
          service.handlerFor(StreamProviderId.tidal) as TidalStreamHandler;
      expect(await tidal.resolveAccessToken(), isNull);
    });
  });
}
