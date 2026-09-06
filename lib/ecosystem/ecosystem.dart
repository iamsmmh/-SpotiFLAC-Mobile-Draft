/// SpotiFLAC **ecosystem** barrel (Feature Groups 1–12).
///
/// Import this from application code (providers, screens, `main.dart`) instead
/// of reaching into subfolders, so the module keeps one public surface:
///
///   * `account/`          — pluggable cloud accounts (Group 1)
///   * `sync/`             — sync payloads, backend adapters, engine (Group 2)
///   * `favorites/`        — unified favorites index (Group 3)
///   * `history/`          — listening history + insights (Groups 4 & 12)
///   * `recommendations/`  — cloud + similarity + daily-mix providers (Group 5)
///   * `smart_playlists/`  — auto-updating playlists (Group 6)
///   * `cache/`            — streaming cache (Group 7)
///   * `servers/`          — Jellyfin/Navidrome/Subsonic/Airsonic/Plex
///   * `offline/`          — smart offline mode (Group 8; tables reserved)
///   * `podcasts/`         — RSS platform (Group 9)
///   * `recognition/`      — music identification (Group 10)
///   * `social/`           — optional social layer (Group 11)
///   * `discovery/`        — on-device recommendation engine (Phases 1-13)
///
/// Layering follows the same rule as `core/`: dependencies point inward —
/// domain values know nothing about Flutter, adapters know nothing about UI,
/// UI talks to ports through Riverpod.
library;

export 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
export 'package:spotiflac_android/ecosystem/ecosystem_kv.dart';

export 'package:spotiflac_android/ecosystem/account/account_models.dart';
export 'package:spotiflac_android/ecosystem/account/account_service.dart';
export 'package:spotiflac_android/ecosystem/account/auth_adapters.dart';
export 'package:spotiflac_android/ecosystem/account/auth_provider.dart';
export 'package:spotiflac_android/ecosystem/account/token_store.dart';

export 'package:spotiflac_android/ecosystem/sync/cloud_sync_adapters.dart';
export 'package:spotiflac_android/ecosystem/sync/sync_engine.dart';
export 'package:spotiflac_android/ecosystem/sync/sync_payloads.dart';

export 'package:spotiflac_android/ecosystem/favorites/favorite_playlists_repository.dart';
export 'package:spotiflac_android/ecosystem/favorites/favorites.dart';

export 'package:spotiflac_android/ecosystem/history/listening_history.dart';
export 'package:spotiflac_android/ecosystem/history/listening_insights.dart';

export 'package:spotiflac_android/ecosystem/recommendations/recommendation_providers.dart';

export 'package:spotiflac_android/ecosystem/podcasts/podcast_library.dart';
export 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';
export 'package:spotiflac_android/ecosystem/podcasts/podcast_player.dart';
export 'package:spotiflac_android/ecosystem/podcasts/podcast_repository.dart';
export 'package:spotiflac_android/ecosystem/podcasts/podcast_search.dart';
export 'package:spotiflac_android/ecosystem/podcasts/rss_provider.dart';

export 'package:spotiflac_android/ecosystem/recognition/fingerprint_engine.dart';
export 'package:spotiflac_android/ecosystem/recognition/recognition_models.dart';
export 'package:spotiflac_android/ecosystem/recognition/recognition_provider.dart';
export 'package:spotiflac_android/ecosystem/recognition/recognition_service.dart';

export 'package:spotiflac_android/ecosystem/social/social_models.dart';
export 'package:spotiflac_android/ecosystem/social/social_service.dart';

// ---- smart playlists (Group 6) -----------------------------------------
export 'package:spotiflac_android/ecosystem/smart_playlists/smart_playlist_engine.dart';
export 'package:spotiflac_android/ecosystem/smart_playlists/smart_playlist_models.dart';
export 'package:spotiflac_android/ecosystem/smart_playlists/smart_playlist_store.dart';

// ---- streaming cache (Group 7) -----------------------------------------
export 'package:spotiflac_android/ecosystem/cache/cache_cipher.dart';
export 'package:spotiflac_android/ecosystem/cache/cache_cleanup_worker.dart';
export 'package:spotiflac_android/ecosystem/cache/cache_index.dart';
export 'package:spotiflac_android/ecosystem/cache/cache_models.dart';
export 'package:spotiflac_android/ecosystem/cache/cache_repository.dart';
export 'package:spotiflac_android/ecosystem/cache/streaming_cache_manager.dart';

// ---- on-device discovery engine (Phases 1-13) -------------------------
// Roll-ups, profile, scoring, generated shelves, radio, trending and
// continue-listening. The pure algorithms live in `engine/discovery/` and are
// deliberately *not* exported here: they import only `dart:` libraries and are
// reached through `DiscoveryService`, which is the one supported entry point.
export 'package:spotiflac_android/ecosystem/discovery/continue_listening_repository.dart';
export 'package:spotiflac_android/ecosystem/discovery/discovery_schema.dart';
export 'package:spotiflac_android/ecosystem/discovery/discovery_service.dart';
export 'package:spotiflac_android/ecosystem/discovery/listening_statistics_repository.dart';
export 'package:spotiflac_android/ecosystem/discovery/playlist_generators.dart';
export 'package:spotiflac_android/ecosystem/discovery/radio_service.dart';
export 'package:spotiflac_android/ecosystem/discovery/recommendation_cache.dart';
export 'package:spotiflac_android/ecosystem/discovery/recommendation_engine.dart';
export 'package:spotiflac_android/ecosystem/discovery/recommendation_repository.dart';
export 'package:spotiflac_android/ecosystem/discovery/shelf_stores.dart';
export 'package:spotiflac_android/ecosystem/discovery/trending_repository.dart';
export 'package:spotiflac_android/ecosystem/discovery/user_profile_engine.dart';

// ---- self-hosted servers (Jellyfin/Navidrome/Subsonic/Airsonic/Plex) ----
export 'package:spotiflac_android/ecosystem/servers/jellyfin_provider.dart';
export 'package:spotiflac_android/ecosystem/servers/music_server_models.dart';
export 'package:spotiflac_android/ecosystem/servers/music_server_provider.dart';
export 'package:spotiflac_android/ecosystem/servers/music_server_registry.dart';
export 'package:spotiflac_android/ecosystem/servers/plex_provider.dart';
export 'package:spotiflac_android/ecosystem/servers/subsonic_provider.dart';
