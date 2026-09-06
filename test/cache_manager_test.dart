import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/cache/cache_database.dart';
import 'package:spotiflac_android/cache/cache_manager.dart';
import 'package:spotiflac_android/cache/cache_policy.dart';
import 'package:spotiflac_android/cache/stream_cache.dart';

class _FakeByteCache implements StreamByteCache {
  final Map<String, CachedArtifact> playable = <String, CachedArtifact>{};
  final Map<String, List<CachePolicyEntry>> entryViews =
      <String, List<CachePolicyEntry>>{};
  final Set<String> warming = <String>{};
  int totalStoredBytes = 0;
  final List<String> warmedUrls = <String>[];
  final Set<String> deletedKeys = <String>{};
  bool failWarm = false;

  @override
  Future<CachedArtifact?> lookupPlayable(String trackKey) async =>
      playable[trackKey];

  @override
  Future<int> totalBytes() async => totalStoredBytes;

  @override
  Future<bool> warm(String trackKey, String url) async {
    if (failWarm) return false;
    warmedUrls.add('$trackKey|$url');
    return true;
  }

  @override
  bool isWarming(String trackKey) => warming.contains(trackKey);

  @override
  Future<void> evict(String key) async {
    deletedKeys.add(key);
  }

  @override
  Future<List<CachePolicyEntry>> policyEntries() async => <CachePolicyEntry>[
    ...entryViews.values.expand((entries) => entries),
  ];

  @override
  Future<Set<String>> cachedTrackKeys() async => playable.keys.toSet();
}

class _MemoryMetadata implements CacheMetadataStore {
  final Map<String, WarmRequestRecord> warm = <String, WarmRequestRecord>{};
  CacheMaintenanceRecord? maintenance;

  @override
  Future<void> upsertWarmRequest(WarmRequestRecord record) async =>
      warm[record.trackKey] = record;

  @override
  Future<List<WarmRequestRecord>> warmRequests({int limit = 200}) async =>
      warm.values.toList(growable: false);

  @override
  Future<void> clearWarmRequests() async => warm.clear();

  @override
  Future<void> recordMaintenance(CacheMaintenanceRecord record) async =>
      maintenance = record;

  @override
  Future<CacheMaintenanceRecord?> lastMaintenance() async => maintenance;
}

void main() {
  DateTime clock() => DateTime.utc(2026, 9, 6, 12);

  group('SmartCacheManager.warmQueue', () {
    test('warms planned candidates in priority order and records metadata',
        () async {
      final bytes = _FakeByteCache();
      final metadata = _MemoryMetadata();
      final manager = SmartCacheManager(
        bytes: bytes,
        policy: const SmartCachePolicy(
          config: SmartCacheConfig(warmLookahead: 2),
        ),
        metadata: metadata,
        clock: clock,
      );
      final report = await manager.warmQueue(
        candidates: const [
          WarmQueueCandidate(trackKey: 'next1', url: 'https://x/1', priority: 2),
          WarmQueueCandidate(trackKey: 'next2', url: 'https://x/2', priority: 1),
          WarmQueueCandidate(trackKey: 'next3', url: 'https://x/3', priority: 0),
        ],
        cachedKeys: const <String>{},
        network: CacheNetworkState.wifi,
      );
      expect(report.started, <String>['next1', 'next2']);
      expect(report.skipped, <String>['next3']);
      expect(bytes.warmedUrls, <String>['next1|https://x/1', 'next2|https://x/2']);
      expect(metadata.warm.keys, containsAll(<String>['next1', 'next2']));
    });

    test('offline networks warm nothing', () async {
      final bytes = _FakeByteCache();
      final manager = SmartCacheManager(
        bytes: bytes,
        policy: const SmartCachePolicy(),
        metadata: _MemoryMetadata(),
        clock: clock,
      );
      final report = await manager.warmQueue(
        candidates: const [
          WarmQueueCandidate(trackKey: 'a', url: 'https://x/a'),
        ],
        cachedKeys: const <String>{},
        network: CacheNetworkState.offline,
      );
      expect(report.isEmpty, isTrue);
      expect(bytes.warmedUrls, isEmpty);
    });

    test('failed fetches are reported and logged as failed', () async {
      final bytes = _FakeByteCache()..failWarm = true;
      final metadata = _MemoryMetadata();
      final manager = SmartCacheManager(
        bytes: bytes,
        policy: const SmartCachePolicy(),
        metadata: metadata,
        clock: clock,
      );
      final report = await manager.warmQueue(
        candidates: const [
          WarmQueueCandidate(trackKey: 'a', url: 'https://x/a'),
        ],
        cachedKeys: const <String>{},
        network: CacheNetworkState.wifi,
      );
      expect(report.failed, <String>['a']);
      expect(metadata.warm['a']?.state, WarmRequestState.failed);
    });
  });

  group('SmartCacheManager.runMaintenance', () {
    test('executes the plan and records the pass', () async {
      final at = DateTime.utc(2026, 1, 1);
      final bytes = _FakeByteCache()
        ..entryViews['a'] = [
          CachePolicyEntry(
            key: 'ck-a',
            bytes: 100,
            lastAccessedAt: at,
            complete: true,
          ),
        ]
        ..totalStoredBytes = 100;
      final metadata = _MemoryMetadata();
      final manager = SmartCacheManager(
        bytes: bytes,
        policy: SmartCachePolicy(
          config: SmartCacheConfig(
            ttl: const Duration(days: 30),
            maxBytes: 50,
            evictionHeadroomBytes: 0,
          ),
        ),
        metadata: metadata,
        clock: clock,
      );
      final executed = <String>[];
      final report = await manager.runMaintenance(
        execute: (expired, evicted) async {
          executed.addAll(['expired:${expired.toList()}', 'evicted:${evicted.toList()}']);
        },
      );
      expect(report.evicted, 1);
      expect(report.freedBytes, 100);
      expect(executed.single, contains('ck-a'));
      expect(metadata.maintenance?.evicted, 1);
      expect(await manager.lastMaintenance(), isNotNull);
    });

    test('a concurrent second pass is a no-op', () async {
      final bytes = _FakeByteCache()..totalStoredBytes = 0;
      final manager = SmartCacheManager(
        bytes: bytes,
        policy: const SmartCachePolicy(),
        metadata: _MemoryMetadata(),
        clock: clock,
      );
      final first = manager.runMaintenance(execute: (_, _) async {});
      final second = await manager.runMaintenance(execute: (_, _) async {});
      expect(second.isEmpty, isTrue);
      await first;
    });

    test('nothing to do produces an empty report', () async {
      final manager = SmartCacheManager(
        bytes: _FakeByteCache(),
        policy: const SmartCachePolicy(),
        metadata: _MemoryMetadata(),
        clock: clock,
      );
      final report = await manager.runMaintenance(execute: (_, _) async {});
      expect(report.isEmpty, isTrue);
    });
  });

  group('StreamCache', () {
    test('resolveForPlayback returns the local artifact when cached',
        () async {
      final bytes = _FakeByteCache()
        ..playable['t1'] = const CachedArtifact(
          trackKey: 't1',
          filePath: '/cache/t1.flac',
          bytes: 4096,
          formatLabel: 'FLAC',
        );
      final cache = StreamCache(
        bytes: bytes,
        policy: const SmartCachePolicy(),
        metadata: _MemoryMetadata(),
      );
      final artifact = await cache.resolveForPlayback('t1');
      expect(artifact, isNotNull);
      expect(artifact!.filePath, '/cache/t1.flac');
      expect((await cache.resolveForPlayback('missing')), isNull);
      expect((await cache.resolveForPlayback('')), isNull);
    });

    test('captureAdmission delegates to the policy with live totals',
        () async {
      final bytes = _FakeByteCache()..totalStoredBytes = 90;
      final cache = StreamCache(
        bytes: bytes,
        policy: const SmartCachePolicy(
          config: SmartCacheConfig(maxBytes: 100),
        ),
        metadata: _MemoryMetadata(),
      );
      final denied = await cache.captureAdmission(
        captureEnabled: true,
        network: CacheNetworkState.wifi,
        estimatedBytes: 50,
      );
      expect(denied.isAllowed, isFalse);
      final disabled = await cache.captureAdmission(
        captureEnabled: false,
        network: CacheNetworkState.wifi,
      );
      expect(disabled.isAllowed, isFalse);
    });

    test('warm records cancelled attempts when the policy denies', () async {
      final bytes = _FakeByteCache();
      final metadata = _MemoryMetadata();
      final cache = StreamCache(
        bytes: bytes,
        policy: const SmartCachePolicy(),
        metadata: metadata,
      );
      final started = await cache.warm(
        trackKey: 't1',
        url: 'https://x/1',
        warmEnabled: false,
        network: CacheNetworkState.wifi,
      );
      expect(started, isFalse);
      expect(metadata.warm['t1']?.state, WarmRequestState.cancelled);
      expect(bytes.warmedUrls, isEmpty);
    });

    test('offlineAvailability reports cached vs remote', () async {
      final bytes = _FakeByteCache()
        ..playable['t1'] = const CachedArtifact(
          trackKey: 't1',
          filePath: '/cache/t1.flac',
          bytes: 1,
        );
      final cache = StreamCache(
        bytes: bytes,
        policy: const SmartCachePolicy(),
        metadata: _MemoryMetadata(),
      );
      expect(
        (await cache.offlineAvailability('t1')).isAllowed,
        isTrue,
      );
      expect(
        (await cache.offlineAvailability('t2')).isAllowed,
        isFalse,
      );
    });
  });
}
