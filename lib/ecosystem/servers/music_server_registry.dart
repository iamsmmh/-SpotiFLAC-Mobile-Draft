/// Registry of configured self-hosted servers (Feature Group: servers).
///
/// Owns the persisted [MusicServerConfig] list (KeyValueStore, JSON) and
/// instantiates the matching [MusicServerProvider] per config. Credentials
/// stay in the [MusicServerSecretStore]; the registry itself is safe to
/// export/backup.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:spotiflac_android/ecosystem/ecosystem_kv.dart';
import 'package:spotiflac_android/ecosystem/servers/jellyfin_provider.dart';
import 'package:spotiflac_android/ecosystem/servers/music_server_models.dart';
import 'package:spotiflac_android/ecosystem/servers/music_server_provider.dart';
import 'package:spotiflac_android/ecosystem/servers/plex_provider.dart';
import 'package:spotiflac_android/ecosystem/servers/subsonic_provider.dart';

/// Builds one HTTP client per registry (closed with the registry).
typedef ServerHttpClientFactory = http.Client Function();

class MusicServerRegistry {
  MusicServerRegistry({
    required KeyValueStore preferences,
    required this.secrets,
    http.Client? client,
  }) : _preferences = preferences,
       _client = client ?? http.Client();

  static const String storageKey = 'music_servers_v1';

  final KeyValueStore _preferences;
  final MusicServerSecretStore secrets;
  final http.Client _client;

  final List<MusicServerProvider> _providers = <MusicServerProvider>[];

  /// All configured providers (enabled and disabled — callers filter by
  /// `provider.enabled`).
  List<MusicServerProvider> get providers =>
      List<MusicServerProvider>.unmodifiable(_providers);

  List<MusicServerProvider> get enabledProviders => List<
    MusicServerProvider
  >.unmodifiable(_providers.where((provider) => provider.enabled));

  /// Loads persisted configs and (re)builds providers. Call at start.
  Future<void> load() async {
    final raw = await _preferences.read(storageKey);
    _providers.clear();
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final Object? entry in decoded) {
        final config = MusicServerConfig.fromJson(entry);
        if (config == null) continue;
        _providers.add(_build(config));
      }
    } catch (_) {
      // A corrupt registry degrades to "no servers" — never a crash.
    }
  }

  Future<void> _persist() async {
    final encoded = jsonEncode(
      <Map<String, Object?>>[
        for (final provider in _providers) provider.config.toJson(),
      ],
    );
    await _preferences.write(storageKey, encoded);
  }

  MusicServerProvider _build(MusicServerConfig config) {
    switch (config.kind) {
      case MusicServerKind.jellyfin:
        return JellyfinProvider(
          config: config,
          secrets: secrets,
          client: _client,
        );
      case MusicServerKind.navidrome:
        return NavidromeProvider(
          config: config,
          secrets: secrets,
          client: _client,
        );
      case MusicServerKind.airsonic:
        return AirsonicProvider(
          config: config,
          secrets: secrets,
          client: _client,
        );
      case MusicServerKind.plex:
        return PlexProvider(config: config, secrets: secrets, client: _client);
      case MusicServerKind.subsonic:
        return SubsonicProvider(
          config: config,
          secrets: secrets,
          client: _client,
        );
    }
  }

  /// Adds a server (config already validated for base URL shape).
  /// Returns the created provider.
  Future<MusicServerProvider> add(MusicServerConfig config) async {
    remove(config.id);
    final provider = _build(config);
    _providers.add(provider);
    await _persist();
    return provider;
  }

  Future<void> update(MusicServerConfig config) async {
    final index = _providers.indexWhere(
      (provider) => provider.config.id == config.id,
    );
    if (index < 0) return;
    _providers[index] = _build(config);
    await _persist();
  }

  Future<void> remove(String serverId) async {
    _providers.removeWhere((provider) => provider.config.id == serverId);
    await secrets.clear(serverId);
    await _persist();
  }

  MusicServerProvider? byId(String serverId) {
    for (final provider in _providers) {
      if (provider.config.id == serverId) return provider;
    }
    return null;
  }

  void dispose() {
    _client.close();
  }
}

/// Generates registry ids without a uuid dependency: time + counter.
String newMusicServerId({DateTime? at}) {
  final now = at ?? DateTime.now();
  final stamp = now.microsecondsSinceEpoch.toRadixString(36);
  return 'srv_$stamp';
}
