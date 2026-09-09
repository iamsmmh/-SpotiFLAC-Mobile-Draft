# Flutter analyze & test — evidence
- run: https://github.com/iamsmmh/-SpotiFLAC-Mobile-Draft/actions/runs/34413232146
- sha: e15d618e872f20df5bae247147bb0752d9f24e4e

## Steps
- success: Set up job
- success: Checkout repository
- success: Setup Flutter
- success: Cache pub dependencies
- success: Get Flutter dependencies
- success: Analyze
- success: Run tests
- : Record evidence (dispatch only)
- : Post Cache pub dependencies
- : Post Setup Flutter
- : Post Checkout repository

## flutter analyze
Resolving dependencies...
Downloading packages...
  _fe_analyzer_shared 99.0.0 (107.0.0 available)
  analysis_server_plugin 0.3.14 (0.3.22 available)
  analyzer 12.1.0 (14.3.0 available)
  analyzer_plugin 0.14.8 (0.14.16 available)
  audio_session 0.1.25 (0.2.4 available)
  build 4.0.7 (4.0.11 available)
  build_runner 2.15.1 (2.16.1 available)
  cached_network_image 3.4.1 (4.0.0 available)
  cached_network_image_platform_interface 4.1.1 (5.0.0 available)
  cached_network_image_web 1.3.1 (2.0.0 available)
  cli_util 0.4.2 (0.6.0 available)
  clock 1.1.2 (1.1.3 available)
  code_assets 1.2.1 (2.0.0 available)
  dart_style 3.1.8 (3.1.13 available)
  dynamic_color 1.9.0 (2.1.0 available)
  flutter_riverpod 3.3.2 (3.4.3 available)
  flutter_secure_storage_darwin 0.4.0 (0.4.1 available)
  flutter_secure_storage_platform_interface 2.0.3 (2.1.0 available)
  go_router 17.5.0 (18.0.1 available)
  hooks 2.0.2 (2.2.0 available)
  intl 0.20.2 (0.20.3 available)
  matcher 0.12.19 (0.12.20 available)
  material_color_utilities 0.13.0 (0.13.1 available)
  meta 1.18.0 (1.19.0 available)
  objective_c 9.5.0 (9.6.0 available)
  package_config 2.2.0 (3.0.0 available)
  platform 3.1.6 (3.2.0 available)
  record_use 0.6.0 (1.1.1 available)
  riverpod 3.3.2 (3.4.3 available)
  riverpod_analyzer_utils 1.0.0-dev.10 (1.0.0-dev.12 available)
  riverpod_lint 3.1.4 (3.1.9 available)
  source_gen 4.2.4 (4.3.0 available)
  stack_trace 1.12.1 (1.12.2 available)
  test 1.31.0 (1.32.0 available)
  test_api 0.7.11 (0.7.14 available)
  test_core 0.6.17 (0.6.20 available)
  vector_math 2.2.0 (2.4.2 available)
  xml 6.6.1 (7.0.1 available)
  youtube_explode_dart 2.5.3 (3.1.0 available)
Got dependencies!
39 packages have newer versions incompatible with dependency constraints.
Try `flutter pub outdated` for more information.
Analyzing -SpotiFLAC-Mobile-Draft...                            
No issues found! (ran in 50.2s)

## flutter test — summary
🎉 1604 tests passed.

### failing tests (reporter titles)
(none captured)

### last 80 lines of test output
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/unified_search_test.dart: UnifiedSearchEngine empty query short-circuits
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/unified_search_test.dart: UnifiedSearchEngine register/unregister keeps one source per id
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_sha256_test.dart: sha256Hex one-shot empty input matches the FIPS 180-4 empty digest
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_sha256_test.dart: sha256Hex one-shot "abc" matches the canonical NIST vector
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_sha256_test.dart: sha256Hex one-shot two-block NIST message vector
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_sha256_test.dart: sha256Hex one-shot one million "a" bytes (multi-block streaming)
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_sha256_test.dart: Sha256Accumulator streaming chunked feeding equals one-shot for every boundary length
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_sha256_test.dart: Sha256Accumulator streaming digest seals the accumulator
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_sha256_test.dart: Sha256Accumulator streaming digestBytes returns 32 bytes consistent with digestHex
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_sha256_test.dart: Sha256Accumulator streaming tracks the number of bytes fed
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/cache_database_test.dart: WarmRequestRecord row codec round-trip
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/cache_database_test.dart: WarmRequestRecord row codec tolerates garbage
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/cache_database_test.dart: WarmRequestRecord JSON list codec round-trips and drops invalid entries
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/cache_database_test.dart: WarmRequestRecord copyWith mutates only the given fields
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/cache_database_test.dart: CacheMaintenanceRecord row codec round-trip
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/cache_database_test.dart: CacheMaintenanceRecord row codec rejects missing timestamps
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/cache_database_test.dart: WarmRequestState parses names leniently
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_download_manager_test.dart: transactional finalize success commits the staged artifact atomically
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_download_manager_test.dart: transactional finalize backend failure rolls the temp file back
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_download_manager_test.dart: transactional finalize metadata sanity gate rejects non-audio payloads before commit
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_download_manager_test.dart: transactional finalize SHA-256 expectation gates the commit
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_download_manager_test.dart: transactional finalize exact size expectation is enforced when provided
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_download_manager_test.dart: cancellation plumbing cancel mid-download aborts the backend and purges the temp file
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_download_manager_test.dart: cancellation plumbing pause mid-download holds the job and the next attempt re-runs
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/core_download_manager_test.dart: stale artifact sweep sweepStaleArtifacts purges old temps via the janitor
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/shell_navigation_service_test.dart: ShellNavigationService tab requests forwards a named tab request to the registered shell
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/shell_navigation_service_test.dart: ShellNavigationService tab requests does not remove a newer shell handler
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/shell_navigation_service_test.dart: ShellNavigationService tab requests reports when no shell can handle the request
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/gain_format_test.dart: formatGainDb positive gains carry an explicit + sign
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/gain_format_test.dart: formatGainDb negative gains carry a - sign
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/gain_format_test.dart: formatGainDb zero is rendered unsigned, including negative zero
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/gain_format_test.dart: formatGainDb decimals controls precision
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/shell_navigation_service_test.dart: ShellNavigationService tab requests View Queue snackbar action requests the Library tab
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/progress_stream_poller_test.dart: stop and restart ignore stale in-flight poll results
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/progress_stream_poller_test.dart: a stale stream error cannot start polling after stop
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: download history identity serializes download timestamps with an explicit UTC offset
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: download history identity same track metadata does not merge files from different albums
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: download history identity equivalent paths still update one stored file record
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: download history identity duplicate track identities keep the newest lookup item
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: download history identity actual audio quality survives history serialization
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: download history identity explicit metadata survives history serialization
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: download history identity placeholder refresh cannot erase an existing measured quality
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: startup orphan reconciliation requires consecutive missing checks before confirmation
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: startup orphan reconciliation ignores unchecked stale suspects
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: download completion persistence publishes completion only after history persistence
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/download_history_logic_test.dart: download completion persistence does not publish completion when history persistence fails
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/hero_animation_controller_test.dart: HeroControllerScope.none reaches the MaterialApp root Navigator
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/hero_animation_controller_test.dart: removing an explicit HeroController detaches it
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: Subsonic family auth params use the salted token scheme
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: Subsonic family search3 maps songs to ServerTrack
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: Subsonic family auth failures surface as MusicServerException(auth)
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: Jellyfin signIn stores the access token
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: Jellyfin resolveTrack direct play is a static progressive URL
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: Jellyfin resolveTrack adaptive uses the universal HLS endpoint
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: Jellyfin search maps Items with RunTimeTicks
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: Plex hub search filters track hubs and converts durations
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: MusicServerConfig json round trip
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: MusicServerConfig rejects corrupt rows
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/music_servers_test.dart: providers only resolve tracks they own
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/cover_download_service_test.dart: detects common cover formats from file headers
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/cover_download_service_test.dart: builds a collision-free file path
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: PodcastEpisode playback source streams from the network when nothing is downloaded
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: PodcastEpisode playback source plays the local file once downloaded
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: PodcastEpisode playback source a downloaded state with no path is not treated as offline
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: PodcastEpisode progress is a clamped fraction of the duration
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: PodcastEpisode progress is zero when the feed declares no duration
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: PodcastEpisode progress remaining never goes negative
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: row round-trips an episode survives toRow/fromRow unchanged
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: row round-trips a subscription survives toRow/fromRow including categories
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: row round-trips an empty category list round-trips as empty
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: row round-trips missing columns fall back to safe defaults
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: EpisodeDownloadState.parse round-trips known names and defaults unknown ones
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: PodcastFeed builds a subscription stamped with the given clock
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: iTunes search decoding maps directory rows to results
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: iTunes search decoding drops rows with no feed URL and de-duplicates feeds
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/podcast_models_test.dart: iTunes search decoding malformed payloads yield an empty list
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/track_metadata_header_contrast_test.dart: metadata hero keeps technical text legible in light theme
✅ /home/runner/work/-SpotiFLAC-Mobile-Draft/-SpotiFLAC-Mobile-Draft/test/re_enrich_release_policy_test.dart: only deliberate single-file re-enrich can replace release identity

🎉 1604 tests passed.

## coverage
line coverage: 20276/99006 — 20.5%
