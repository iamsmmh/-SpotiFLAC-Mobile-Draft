/// Stream cache playback surface (Phase 2).
///
/// The facade the playback path talks to:
///
///   * **Offline playback from cache** — [resolveForPlayback] consults the
///     byte cache first; a complete, verified entry swaps the network URL for
///     a local file so queued tracks play from disk (also when offline).
///   * **Capture admission** — [captureAdmission] asks the policy whether the
///     bytes of a stream should be captured while playing.
///   * **Predictive warm** — [warm] pre-caches an upcoming queue item within
///     the same policy guardrails.
///
/// The actual bytes live in the ecosystem cache (`ecosystem/cache/**`); this
/// module depends on the small [StreamByteCache] port below, which the
/// Riverpod layer adapts onto `StreamingCacheManager`. That keeps `lib/cache`
/// free of ecosystem types and unit-testable with fakes.
library;

import 'package:spotiflac_android/cache/cache_database.dart';
import 'package:spotiflac_android/cache/cache_policy.dart';

/// One playable cached artifact.
class CachedArtifact {
  final String trackKey;
  final String filePath;
  final int bytes;
  final String formatLabel;

  const CachedArtifact({
    required this.trackKey,
    required this.filePath,
    required this.bytes,
    this.formatLabel = '',
  });
}

/// Port onto the byte cache (adapted from `StreamingCacheManager`).
abstract interface class StreamByteCache {
  /// Complete + verified entry for [trackKey], or null. Implementations must
  /// verify the backing file still exists.
  Future<CachedArtifact?> lookupPlayable(String trackKey);

  /// Total bytes currently stored (complete + partial).
  Future<int> totalBytes();

  /// Starts a background fetch of [url] for [trackKey]. Returns false when
  /// the fetch could not start (already cached/active, network error).
  Future<bool> warm(String trackKey, String url);

  /// True while a fetch for [trackKey] is in flight.
  bool isWarming(String trackKey);

  /// Deletes the stored bytes for [key] (cache key or track key).
  Future<void> evict(String key);

  /// All entries as policy views (for maintenance planning).
  Future<List<CachePolicyEntry>> policyEntries();

  /// Track keys that have a complete cached copy (for warm planning).
  Future<Set<String>> cachedTrackKeys();
}

/// The playback-facing cache.
class StreamCache {
  StreamCache({
    required StreamByteCache bytes,
    required SmartCachePolicy policy,
    required CacheMetadataStore metadata,
  }) : _bytes = bytes,
       _policy = policy,
       _metadata = metadata;

  final StreamByteCache _bytes;
  final SmartCachePolicy _policy;
  final CacheMetadataStore _metadata;

  SmartCachePolicy get policy => _policy;

  /// Cache-first resolution: returns the local artifact when available
  /// (offline playback, instant restarts), null to keep playing from the
  /// network.
  Future<CachedArtifact?> resolveForPlayback(String trackKey) async {
    if (trackKey.isEmpty) return null;
    return _bytes.lookupPlayable(trackKey);
  }

  /// Whether a stream about to play should be captured, with the reason.
  Future<CacheAdmission> captureAdmission({
    required bool captureEnabled,
    required CacheNetworkState network,
    int? estimatedBytes,
  }) async {
    final currentBytes = await _bytes.totalBytes();
    return _policy.admission(
      captureEnabled: captureEnabled,
      network: network,
      currentBytes: currentBytes,
      bytes: estimatedBytes,
    );
  }

  /// Warm one upcoming item. Records the attempt in the metadata store so
  /// the diagnostics surface can explain what the predictor did.
  /// Returns true when a fetch was started (or was already running).
  Future<bool> warm({
    required String trackKey,
    required String url,
    required bool warmEnabled,
    required CacheNetworkState network,
  }) async {
    if (trackKey.isEmpty || url.isEmpty) return false;
    final admission = await captureAdmission(
      captureEnabled: warmEnabled,
      network: network,
    );
    if (!admission.isAllowed) {
      await _metadata.upsertWarmRequest(
        WarmRequestRecord(
          trackKey: trackKey,
          url: url,
          priority: 0,
          requestedAt: DateTime.now().toUtc(),
          state: WarmRequestState.cancelled,
        ),
      );
      return false;
    }
    if (_bytes.isWarming(trackKey)) return true;
    final started = await _bytes.warm(trackKey, url);
    await _metadata.upsertWarmRequest(
      WarmRequestRecord(
        trackKey: trackKey,
        url: url,
        priority: 0,
        requestedAt: DateTime.now().toUtc(),
        state: started
            ? WarmRequestState.requested
            : WarmRequestState.failed,
      ),
    );
    return started;
  }

  /// The cached-vs-remote decision for one track, for diagnostics.
  Future<CacheAdmission> offlineAvailability(String trackKey) async {
    final artifact = await resolveForPlayback(trackKey);
    return artifact == null
        ? const CacheAdmission.deny('not cached')
        : CacheAdmission.allow('cached at ${artifact.filePath}');
  }
}
