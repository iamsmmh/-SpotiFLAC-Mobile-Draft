/// Self-hosted music server port (Feature Group: servers).
///
/// Every back-end (Jellyfin, Navidrome, Subsonic, Airsonic, Plex)
/// implements this one interface and is wired into the app through the
/// *existing* integration points — no parallel playback stack:
///
///   * `search` feeds the unified search engine (`engine/unified_search.dart`);
///   * `resolveTrack` (from the Feature-1 [StreamProvider] port) feeds the
///     streaming engine's adapter chain;
///   * `testConnection` powers the "Add server" settings flow.
library;

import 'package:spotiflac_android/core/streaming/stream_provider.dart';
import 'package:spotiflac_android/ecosystem/servers/music_server_models.dart';
import 'package:spotiflac_android/models/track.dart';

/// Base contract shared by all server integrations.
abstract class MusicServerProvider implements StreamProvider {
  MusicServerConfig get config;

  /// The kind of back-end (branding + dialect switches).
  MusicServerKind get kind => config.kind;

  @override
  String get id => config.sourceTag;

  @override
  String get displayName => config.effectiveName;

  /// Server adapters join the resolution chain after local providers.
  @override
  int get priority => 20;

  @override
  bool get enabled => config.enabled;

  /// Cheap authenticated round-trip; returns an error message on failure
  /// and null when the server answers with a valid session.
  Future<String?> testConnection();

  /// Searches this server. Never throws for "no results" — return an
  /// empty list (errors surface as [MusicServerException] only for real
  /// transport/auth failures the UI must explain).
  Future<List<ServerTrack>> search(String query, {int limit = 20});

  /// Whether [track] belongs to this server (source tag check).
  bool owns(Track track) => track.source == config.sourceTag;

  /// Resolves the playable stream for a track this server produced
  /// ([StreamProvider.resolveTrack] for every other track returns null).
  @override
  Future<StreamSource?> resolveTrack(Track track);

  /// Optional album/artist covers for browse surfaces.
  Future<List<ServerTrack>> recentTracks({int limit = 20}) async => const [];
}
