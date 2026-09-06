/// Riverpod wiring for self-hosted music servers (Feature Group: servers).
///
/// Bridges the `ecosystem/servers/**` module into the two existing
/// integration points: the streaming engine's adapter chain (playback)
/// and the unified search engine (Feature 6). Credentials live in the
/// platform secure store through a [MusicServerSecretStore] adapter.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:spotiflac_android/core/data/secure_store.dart';
import 'package:spotiflac_android/ecosystem/servers/music_server_models.dart';
import 'package:spotiflac_android/ecosystem/servers/music_server_registry.dart';
import 'package:spotiflac_android/providers/ecosystem_providers.dart';
import 'package:spotiflac_android/providers/provider_accounts_provider.dart'
    show secureStoreProvider;

/// Secure-store adapter for server credentials.
class SecureMusicServerSecretStore implements MusicServerSecretStore {
  const SecureMusicServerSecretStore(this._store);

  final SecureStore _store;

  static String _passwordKey(String serverId) => 'music_server_${serverId}_pw';
  static String _tokenKey(String serverId) => 'music_server_${serverId}_tk';

  @override
  Future<String?> password(String serverId) =>
      _store.readToken(_passwordKey(serverId));

  @override
  Future<void> setPassword(String serverId, String value) =>
      _store.writeToken(_passwordKey(serverId), value);

  @override
  Future<String?> token(String serverId) =>
      _store.readToken(_tokenKey(serverId));

  @override
  Future<void> setToken(String serverId, String value) =>
      _store.writeToken(_tokenKey(serverId), value);

  @override
  Future<void> clear(String serverId) async {
    await _store.deleteToken(_passwordKey(serverId));
    await _store.deleteToken(_tokenKey(serverId));
  }
}

final musicServerSecretStoreProvider = Provider<MusicServerSecretStore>((
  ref,
) {
  return SecureMusicServerSecretStore(ref.watch(secureStoreProvider));
});

/// One shared HTTP client for all server providers (closed with the
/// registry).
final musicServerHttpClientProvider = Provider<http.Client>((ref) {
  final client = http.Client();
  ref.onDispose(client.close);
  return client;
});

final musicServerRegistryProvider = Provider<MusicServerRegistry>((ref) {
  final registry = MusicServerRegistry(
    preferences: ref.watch(ecosystemPreferencesProvider),
    secrets: ref.watch(musicServerSecretStoreProvider),
    client: ref.watch(musicServerHttpClientProvider),
  );
  ref.onDispose(registry.dispose);
  unawaited(registry.load());
  return registry;
});

/// Configured servers as immutable state for settings UIs.
final musicServersProvider = FutureProvider<List<MusicServerConfig>>((ref) {
  final registry = ref.watch(musicServerRegistryProvider);
  return Future<List<MusicServerConfig>>.value(
    List<MusicServerConfig>.from(registry.providers.map((p) => p.config)),
  );
});
