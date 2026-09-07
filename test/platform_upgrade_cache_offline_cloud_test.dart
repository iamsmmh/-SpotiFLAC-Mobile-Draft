import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/cache/cache.dart';
import 'package:spotiflac_android/services/cloud/cloud_sync_service.dart';
import 'package:spotiflac_android/services/cloud/merge_engine.dart';
import 'package:spotiflac_android/services/offline/offline.dart';

void main() {
  group('StreamCacheBudget', () {
    test('clamps to 1–100 GiB', () {
      expect(StreamCacheBudget.bytes(1).maxBytes, StreamCacheBudget.minBytes);
      expect(
        StreamCacheBudget.gigabytes(200).maxBytes,
        StreamCacheBudget.maxSupportedBytes,
      );
      expect(StreamCacheBudget.gigabytes(8).gigabytes, 8);
    });
  });

  group('PlaybackSourceLadder', () {
    const ladder = PlaybackSourceLadder();

    test('prefers local, then cache, then provider, then preview', () {
      expect(
        ladder
            .resolve(
              const PlaybackSourceFacts(
                hasLocalFile: true,
                hasVerifiedCache: true,
                hasProviderStream: true,
                hasPreviewStream: true,
                offline: false,
              ),
            )
            .kind,
        PlaybackSourceKind.localLibrary,
      );
      expect(
        ladder
            .resolve(
              const PlaybackSourceFacts(
                hasLocalFile: false,
                hasVerifiedCache: true,
                hasProviderStream: true,
                hasPreviewStream: true,
                offline: false,
              ),
            )
            .kind,
        PlaybackSourceKind.streamCache,
      );
      expect(
        ladder
            .resolve(
              const PlaybackSourceFacts(
                hasLocalFile: false,
                hasVerifiedCache: false,
                hasProviderStream: true,
                hasPreviewStream: true,
                offline: false,
              ),
            )
            .kind,
        PlaybackSourceKind.providerStream,
      );
      expect(
        ladder
            .resolve(
              const PlaybackSourceFacts(
                hasLocalFile: false,
                hasVerifiedCache: false,
                hasProviderStream: false,
                hasPreviewStream: true,
                offline: false,
              ),
            )
            .kind,
        PlaybackSourceKind.previewStream,
      );
    });

    test('offline without local/cache is unavailable', () {
      final plan = ladder.resolve(
        const PlaybackSourceFacts(
          hasLocalFile: false,
          hasVerifiedCache: false,
          hasProviderStream: true,
          hasPreviewStream: true,
          offline: true,
        ),
      );
      expect(plan.kind, PlaybackSourceKind.unavailable);
      expect(plan.isOfflineSafe, isFalse);
    });
  });

  group('MemoryCachedTrackRepository', () {
    test('round-trips a complete record and resumes partials', () async {
      final repo = MemoryCachedTrackRepository();
      final now = DateTime.utc(2026, 9, 7);
      final complete = CachedTrackRecord(
        trackId: 't1',
        providerId: 'tidal',
        localPath: '/cache/t1.flac',
        checksum: 'abc',
        lastPlayed: now,
        size: 1000,
        complete: true,
      );
      await repo.upsert(complete);
      expect((await repo.find(trackId: 't1'))!.isPlayable, isTrue);
      expect(await repo.totalBytes(completeOnly: true), 1000);

      final partial = CachedTrackRecord(
        trackId: 't2',
        providerId: 'qobuz',
        localPath: '/cache/t2.part',
        checksum: '',
        lastPlayed: now,
        size: 0,
        complete: false,
        bytesWritten: 128,
        sourceUrl: 'https://example.test/t2',
      );
      await repo.upsert(partial);
      expect((await repo.find(trackId: 't2'))!.isPartial, isTrue);
    });
  });

  group('StreamCacheManager', () {
    test('commits, verifies, resumes and looks up playable copies', () async {
      final repo = MemoryCachedTrackRepository();
      final io = MemoryStreamCacheIo();
      final now = DateTime.utc(2026, 9, 7, 12);
      final manager = StreamCacheManager(
        repository: repo,
        io: io,
        clock: () => now,
      );
      const bytes = <int>[1, 2, 3, 4, 5];
      io.files['/cache/t1.flac'] = bytes;
      final record = await manager.commit(
        trackId: 't1',
        providerId: 'tidal',
        localPath: '/cache/t1.flac',
        bytes: bytes,
      );
      expect(record, isNotNull);
      expect(await manager.verify(record!), CacheIntegrity.valid);
      expect((await manager.lookupPlayable('t1'))!.trackId, 't1');

      await manager.savePartial(
        trackId: 't2',
        providerId: 'qobuz',
        localPath: '/cache/t2.part',
        bytesWritten: 64,
        sourceUrl: 'https://example.test/t2',
        totalSize: 128,
      );
      io.files['/cache/t2.part'] = List<int>.filled(64, 7);
      final resume = await manager.resumeState(
        trackId: 't2',
        providerId: 'qobuz',
      );
      expect(resume, isNotNull);
      expect(resume!.resumeOffset, 64);
      expect(await manager.verify(resume.record), CacheIntegrity.partial);
    });
  });

  group('OfflineSyncScheduler', () {
    test('wifi+charging plans missing liked and playlist tracks', () {
      final scheduler = OfflineSyncScheduler();
      final plan = scheduler.schedule(
        device: const OfflineDeviceState(
          wifi: true,
          charging: true,
          batteryPercent: 80,
        ),
        alreadyLocal: <String>{'have'},
        playlists: const <OfflinePlaylistTarget>[
          OfflinePlaylistTarget(
            playlistId: 'p1',
            name: 'Offline',
            trackIds: <String>['have', 'need'],
          ),
        ],
        shelves: const <OfflineRecommendationShelf>[
          OfflineRecommendationShelf(
            kind: OfflineCollectionKind.likedSongs,
            shelfId: 'liked',
            trackIds: <String>['need', 'liked-new'],
          ),
        ],
      );
      expect(plan.isRunnable, isTrue);
      expect(
        plan.work.map((w) => w.trackId).toList(),
        <String>['need', 'liked-new'],
      );
    });
  });

  group('CacheEvictionService', () {
    test('evicts expired then LRU until the budget fits', () {
      const service = CacheEvictionService(headroomBytes: 0);
      final now = DateTime.utc(2026, 9, 7);
      final expired = CachedTrackRecord(
        trackId: 'old',
        providerId: 'tidal',
        localPath: '/old',
        checksum: 'x',
        lastPlayed: now.subtract(const Duration(days: 30)),
        size: StreamCacheBudget.minBytes,
        expiry: now.subtract(const Duration(days: 1)),
      );
      final fresh = CachedTrackRecord(
        trackId: 'new',
        providerId: 'tidal',
        localPath: '/new',
        checksum: 'y',
        lastPlayed: now,
        size: 1024,
      );
      final plan = service.plan(
        entries: <CachedTrackRecord>[expired, fresh],
        budget: StreamCacheBudget.bytes(StreamCacheBudget.minBytes),
        now: now,
      );
      expect(plan.records.map((r) => r.trackId), contains('old'));
    });
  });

  group('OfflineSyncPolicy', () {
    const policy = OfflineSyncPolicy();

    test('defaults require wifi + charging', () {
      expect(
        policy
            .admission(
              const OfflineDeviceState(
                wifi: false,
                charging: true,
                batteryPercent: 80,
              ),
            )
            .isAllowed,
        isFalse,
      );
      expect(
        policy
            .admission(
              const OfflineDeviceState(
                wifi: true,
                charging: false,
                batteryPercent: 80,
              ),
            )
            .isAllowed,
        isFalse,
      );
      expect(
        policy
            .admission(
              const OfflineDeviceState(
                wifi: true,
                charging: true,
                batteryPercent: 80,
              ),
            )
            .isAllowed,
        isTrue,
      );
    });

    test('unknown battery does not block', () {
      expect(
        policy
            .admission(
              const OfflineDeviceState(
                wifi: true,
                charging: true,
                batteryPercent: -1,
              ),
            )
            .isAllowed,
        isTrue,
      );
    });
  });

  group('SyncMergeEngine', () {
    test('union-merges playlist tracks and honours tombstones', () {
      const engine = SyncMergeEngine();
      final merged = engine.mergePlaylists(
        local: <String, Object?>{
          'title': 'Local',
          'trackIds': <String>['a', 'b'],
          'removedTrackIds': <String>['c'],
        },
        remote: <String, Object?>{
          'title': 'Remote',
          'trackIds': <String>['b', 'c', 'd'],
        },
        localUpdatedAt: DateTime.utc(2026, 9, 7, 10),
        remoteUpdatedAt: DateTime.utc(2026, 9, 7, 11),
      );
      expect(merged.title, 'Remote');
      expect(merged.trackIds, <String>['a', 'b', 'd']);
    });
  });

  test('Daily Mix rides inside settings scope, no new SyncScope', () {
    expect(cloudSyncScopes, isNot(contains(null)));
    expect(cloudSyncScopes.length, 5);
  });
}
