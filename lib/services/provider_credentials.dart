import 'package:spotiflac_android/core/data/secure_store.dart';

/// Secure-storage token names for user-supplied streaming credentials.
///
/// Spellings are stable: they key Keychain / EncryptedSharedPreferences items
/// via [SecureStoreKeys.token], so a rename orphans previously saved tokens.
abstract final class StreamCredentialNames {
  static const String tidalAccessToken = 'stream.tidal.access_token';
  static const String qobuzAppId = 'stream.qobuz.app_id';
  static const String qobuzAuthToken = 'stream.qobuz.auth_token';
  static const String appleDeveloperToken = 'stream.apple.developer_token';
  static const String deezerArl = 'stream.deezer.arl';
  static const String amazonBearerToken = 'stream.amazon.bearer_token';
  static const String amazonDeviceToken = 'stream.amazon.device_token';

  static const List<String> all = <String>[
    tidalAccessToken,
    qobuzAppId,
    qobuzAuthToken,
    appleDeveloperToken,
    deezerArl,
    amazonBearerToken,
    amazonDeviceToken,
  ];
}

/// Reads streaming credentials. Streaming handlers consult this only when no
/// explicit constructor token was supplied, so unit tests keep working with
/// plain constructor arguments and production resolves from secure storage.
abstract class StreamCredentialResolver {
  Future<String?> read(String name);
}

/// Production [StreamCredentialResolver] backed by the encrypted keystore.
class SecureStoreStreamCredentials implements StreamCredentialResolver {
  SecureStoreStreamCredentials([SecureStore? store])
    : _store = store ?? SecureStore.instance;

  final SecureStore _store;

  @override
  Future<String?> read(String name) => _store.readToken(name);
}
