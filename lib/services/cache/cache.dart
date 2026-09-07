/// Persistent stream cache (Phase 1) — public surface.
///
/// LRU byte cache with a 1 GiB–100 GiB budget, offline reuse of verified
/// streams, integrity validation, resume of partial fetches, and background
/// cleanup. The audio engine walks [PlaybackSourceLadder] before any
/// network request.
library;

export 'package:spotiflac_android/services/cache/cache_eviction_service.dart';
export 'package:spotiflac_android/services/cache/cached_track.dart';
export 'package:spotiflac_android/services/cache/cached_track_repository.dart';
export 'package:spotiflac_android/services/cache/playback_source_ladder.dart';
export 'package:spotiflac_android/services/cache/stream_cache_manager.dart';
