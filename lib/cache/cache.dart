/// Smart stream cache (Phase 2) — public surface.
///
/// Cache-while-streaming with predictive warming, TTL expiration, LRU
/// eviction under a byte budget and offline playback from the cache.
/// Composed in `providers/smart_cache_providers.dart` onto the ecosystem
/// byte cache.
library;

export 'cache_database.dart';
export 'cache_manager.dart';
export 'cache_policy.dart';
export 'stream_cache.dart';
