/// Riverpod wiring for the smart stream cache (Phase 2).
///
/// Composes the pure `lib/cache` modules onto the ecosystem byte cache
/// (`StreamingCacheManager`) and arms the two background behaviours:
/// predictive queue warming and policy-driven maintenance. The bindings are
/// watched once from `MainShell`.
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/cache/cache.dart';
import 'package:spotiflac_android/ecosystem/cache/cache_models.dart';
import 'package:spotiflac_android/ecosystem/cache/cache_repository.dart';
import 'package:spotiflac_android/ecosystem/cache/streaming_cache_manager.dart';
import 'package:spotiflac_android/ecosystem/sync/sync_engine.dart'
    show ConnectivityNetworkGate;
import 'package:spotiflac_android/engine/track_identity.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/ecosystem_providers.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart';
import 'package:spotiflac_android/providers/streaming_cache_providers.dart';
import 'package:spotiflac_android/providers/streaming_engine_provider.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('SmartCache');

/// Maps the sync layer's network view onto the cache policy's view.
Future<CacheNetworkState> currentCacheNetwork() async {
  final state = await ConnectivityNetworkGate().current();
  return CacheNetworkState(online: state.online, metered: state.metered);
}

/// Adapts the ecosystem byte cache onto the [StreamByteCache] port so the
/// policy/orchestration layer stays decoupled from ecosystem types.
final smartCacheByteCacheProvider = Provider<StreamByteCache>((ref) {
  final manager = ref.watch(streamingCacheManagerProvider);
  final repository = ref.watch(cacheRepositoryProvider);
  return EcosystemByteCache(manager, repository);
});

/// Policy configuration derived from the existing engine settings: the byte
/// budget follows `maxCacheSizeMb` (0 = the default budget), the warm
/// lookahead follows `preloadWindow`.
final smartCachePolicyProvider = Provider<SmartCachePolicy>((ref) {
  final settings = ref.watch(engineSettingsProvider);
  final budgetMb = settings.maxCacheSizeMb;
  return SmartCachePolicy(
    config: SmartCacheConfig(
      maxBytes: budgetMb > 0 ? budgetMb * 1024 * 1024 : 512 * 1024 * 1024,
      warmLookahead: settings.preloadWindow.clamp(1, 5),
      // Warm fetches follow the streaming master switch: they only ever run
      // when the user allowed stream caching in the first place, and never
      // on metered links (playback itself already streams there).
      allowMeteredWarm: false,
      allowMeteredCapture: false,
    ),
  );
});

final smartCacheMetadataProvider = Provider<CacheMetadataStore>((ref) {
  return FailSafeCacheMetadataStore(SQLiteCacheMetadataStore());
});

/// Playback-facing cache facade.
final streamCacheProvider = Provider<StreamCache>((ref) {
  return StreamCache(
    bytes: ref.watch(smartCacheByteCacheProvider),
    policy: ref.watch(smartCachePolicyProvider),
    metadata: ref.watch(smartCacheMetadataProvider),
  );
});

/// Orchestration facade (warming + maintenance).
final smartCacheManagerProvider = Provider<SmartCacheManager>((ref) {
  return SmartCacheManager(
    bytes: ref.watch(smartCacheByteCacheProvider),
    policy: ref.watch(smartCachePolicyProvider),
    metadata: ref.watch(smartCacheMetadataProvider),
  );
});

/// Cache maintenance scheduling: one policy pass per hour (timer) plus one
/// on each app start. Deletions go through the ecosystem repository and the
/// shared stream-cache directory so files and rows never diverge.
final cacheMaintenanceBindingProvider = Provider<void>((ref) {
  final settings = ref.watch(engineSettingsProvider);
  if (!settings.autoCleanCache) return;
  final manager = ref.read(smartCacheManagerProvider);
  final repository = ref.read(cacheRepositoryProvider);
  Timer? timer;

  Future<void> deleteEntry(String cacheKey) async {
    final entry = await repository.byCacheKey(cacheKey);
    await repository.delete(cacheKey);
    if (entry == null || entry.fileName.isEmpty) return;
    try {
      final dir = await resolveStreamCacheDirectory();
      final file = File('${dir.path}/${entry.fileName}');
      if (await file.exists()) await file.delete();
      final part = File('${file.path}.part');
      if (await part.exists()) await part.delete();
    } catch (_) {
      // Filesystem cleanup is best-effort by design.
    }
  }

  Future<void> runOnce() async {
    try {
      await manager.runMaintenance(
        execute: (expiredKeys, evictedKeys) async {
          for (final key in evictedKeys) {
            await deleteEntry(key);
          }
          for (final key in expiredKeys) {
            await deleteEntry(key);
          }
        },
      );
    } catch (e) {
      _log.w('Cache maintenance failed: $e');
    }
  }

  unawaited(runOnce());
  timer = Timer.periodic(const Duration(hours: 1), (_) {
    unawaited(runOnce());
  });
  ref.onDispose(() {
    timer?.cancel();
  });
});

/// Predictive queue warming. Armed only when the user allowed stream caching
/// AND next-track preloading; listens to queue/current-track changes and
/// resolves + warms the upcoming items through the same provider ladder the
/// player uses, so the warm bytes are exactly the bytes playback consumes.
final predictiveCacheBindingProvider = Provider<void>((ref) {
  final settings = ref.watch(engineSettingsProvider);
  final warmAllowed = settings.preloadNextTrack &&
      settings.cacheStreams &&
      !settings.offlineMode;
  if (!warmAllowed) return;

  final manager = ref.read(smartCacheManagerProvider);
  final engine = ref.read(streamingEngineControllerProvider);
  final byteCache = ref.read(smartCacheByteCacheProvider);

  Timer? debounce;
  var lastSignature = '';
  var planning = false;

  Future<void> plan() async {
    if (planning) return;
    planning = true;
    try {
      final handler = musicPlayerHandler;
      if (handler == null) return;
      final queue = handler.queue.value;
      final currentId = handler.mediaItem.value?.id;
      if (queue.isEmpty || currentId == null) return;
      final currentIndex = queue.indexWhere((item) => item.id == currentId);
      if (currentIndex < 0) return;

      final lookahead = manager.policy.config.warmLookahead;
      final candidates = <WarmQueueCandidate>[];
      var priority = lookahead;
      for (
        var i = currentIndex + 1;
        i <= currentIndex + lookahead && i < queue.length;
        i++
      ) {
        final track = engine.trackFor(queue[i].id);
        if (track == null) continue;
        try {
          final descriptors = await engine.candidatesFor(track);
          String? url;
          for (final descriptor in descriptors) {
            if (descriptor.cachePermitted &&
                descriptor.isRemote &&
                descriptor.uri.startsWith('http')) {
              url = descriptor.uri;
              break;
            }
          }
          if (url == null) continue;
          candidates.add(
            WarmQueueCandidate(
              trackKey: CanonicalTrackKey.fromInput(
                TrackIdentityInput.fromTrack(track),
              ).stableId,
              url: url,
              priority: priority,
            ),
          );
        } catch (e) {
          _log.d('Warm candidate ${track.name} unresolved: $e');
        }
        priority--;
      }
      if (candidates.isEmpty) return;
      final cachedKeys = await byteCache.cachedTrackKeys();
      final network = await currentCacheNetwork();
      await manager.warmQueue(
        candidates: candidates,
        cachedKeys: cachedKeys,
        network: network,
      );
    } catch (e) {
      _log.d('Predictive warm plan failed: $e');
    } finally {
      planning = false;
    }
  }

  void schedule() {
    debounce?.cancel();
    debounce = Timer(const Duration(seconds: 3), () {
      unawaited(plan());
    });
  }

  final queueSub = musicPlayerQueueEvents().listen((queue) {
    final signature = queueSignature(queue);
    if (signature == lastSignature) return;
    lastSignature = signature;
    schedule();
  });
  final mediaSub = musicPlayerMediaItemEvents().listen((item) {
    if (item == null) return;
    lastSignature = '';
    schedule();
  });

  ref.onDispose(() {
    debounce?.cancel();
    queueSub.cancel();
    mediaSub.cancel();
  });
});

/// Queue identity for change detection (pure, test-visible).
String queueSignature(List<MediaItem> queue) => queue.isEmpty
    ? ''
    : '${queue.length}:${queue.first.id}:${queue.last.id}';

/// Adapts `StreamingCacheManager` + `CacheRepository` onto the
/// [StreamByteCache] port.
class EcosystemByteCache implements StreamByteCache {
  EcosystemByteCache(this._manager, this._repository);

  final StreamingCacheManager _manager;
  final CacheRepository _repository;

  @override
  Future<CachedArtifact?> lookupPlayable(String trackKey) async {
    final hit = await _manager.lookupPlayable(trackKey);
    if (hit == null) return null;
    return CachedArtifact(
      trackKey: trackKey,
      filePath: hit.filePath,
      bytes: hit.entry.bytes,
      formatLabel: hit.entry.audioFormat.label,
    );
  }

  @override
  Future<int> totalBytes() => _repository.totalBytes();

  @override
  Future<bool> warm(String trackKey, String url) async {
    final result = await _manager.startFetch(
      CacheFetchRequest(
        trackKey: trackKey,
        title: trackKey,
        artist: '',
        url: url,
        sourceUrl: url,
      ),
    );
    return result.status == CacheFetchStatus.completed ||
        result.status == CacheFetchStatus.skipped;
  }

  @override
  bool isWarming(String trackKey) => _manager.activeFetches.contains(trackKey);

  @override
  Future<void> evict(String key) => _repository.delete(key);

  @override
  Future<List<CachePolicyEntry>> policyEntries() async {
    final entries = await _repository.all();
    return <CachePolicyEntry>[
      for (final entry in entries)
        CachePolicyEntry(
          key: entry.cacheKey,
          bytes: entry.bytes,
          lastAccessedAt: entry.lastAccessedAt,
          complete: entry.isPlayable,
        ),
    ];
  }

  @override
  Future<Set<String>> cachedTrackKeys() async {
    final entries = await _repository.all();
    return <String>{
      for (final entry in entries)
        if (entry.isPlayable) entry.trackKey,
    };
  }
}
