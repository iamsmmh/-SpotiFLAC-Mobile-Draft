// Milestone 12: Production-grade test suite.
//
// Tests cover the new modules added across all milestones:
//   - Playback sync service (Milestone 3)
//   - Smart offline cache / predictive cache (Milestone 7)
//   - Discovery AI improvements (Milestone 8)
//   - Security hardening (Milestone 9)
//   - Collaborative playlist service (Milestone 4)

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/cache/predictive/predictive_cache.dart';
import 'package:spotiflac_android/engine/discovery/discovery_ai_enhanced.dart';
import 'package:spotiflac_android/services/collaborative/collaborative_playlist_service.dart';
import 'package:spotiflac_android/services/playback_sync_service.dart';
import 'package:spotiflac_android/services/security/security_hardening.dart';

void main() {
  group('PlaybackSyncService (Milestone 3)', () {
    test('snapshot serialization round-trip', () {
      final snapshot = PlaybackSyncSnapshot(
        trackId: '/music/song.flac',
        positionMs: 45000,
        queueSnapshot: const ['/music/a.flac', '/music/b.flac', '/music/song.flac'],
        updatedAt: DateTime.utc(2026, 9, 7, 12, 0, 0),
        deviceId: 'device-abc',
        playing: true,
        durationMs: 240000,
        title: 'Test Song',
        artist: 'Test Artist',
        queueIndex: 2,
      );

      final json = snapshot.toJson();
      final restored = PlaybackSyncSnapshot.tryFromJson(json);

      expect(restored, isNotNull);
      expect(restored!.trackId, equals('/music/song.flac'));
      expect(restored.positionMs, equals(45000));
      expect(restored.queueSnapshot, hasLength(3));
      expect(restored.playing, isTrue);
      expect(restored.durationMs, equals(240000));
      expect(restored.title, equals('Test Song'));
      expect(restored.artist, equals('Test Artist'));
      expect(restored.queueIndex, equals(2));
    });

    test('snapshot rejects empty trackId', () {
      final json = <String, Object?>{
        'trackId': '',
        'positionMs': 0,
        'queue': <String>[],
        'updatedAt': DateTime.now().toIso8601String(),
      };
      expect(PlaybackSyncSnapshot.tryFromJson(json), isNull);
    });

    test('service starts and stops cleanly', () {
      final service = PlaybackSyncService(
        stateProvider: () => null,
        config: const PlaybackSyncConfig(enabled: true),
      );

      service.start();
      expect(service.isRunning, isTrue);

      service.stop();
      expect(service.isRunning, isFalse);
    });

    test('service is no-op when disabled', () {
      final service = PlaybackSyncService(
        stateProvider: () => null,
        config: const PlaybackSyncConfig(enabled: false),
      );
      service.start();
      expect(service.isRunning, isFalse);
    });

    test('predict generates next-track predictions', () {
      final manager = PredictiveCacheManager();
      final predictions = manager.predict(
        queue: const ['a', 'b', 'c', 'd'],
        currentIndex: 0,
        favorites: const ['fav-1', 'fav-2'],
      );
      expect(predictions, isNotEmpty);
      // Next in queue should be first.
      expect(predictions.first.trackId, equals('b'));
    });
  });

  group('PredictiveCacheManager (Milestone 7)', () {
    test('adds and retrieves entries', () {
      final manager = PredictiveCacheManager();
      final entry = CachedTrack(
        trackId: 'track-1',
        filePath: '/cache/track-1.flac',
        sizeBytes: 30 * 1024 * 1024,
        cachedAt: DateTime.now(),
        priority: CachePriority.high,
      );

      manager.addEntry(entry);
      expect(manager.isCached('track-1'), isTrue);
      expect(manager.trackCount, equals(1));
      expect(manager.totalSizeBytes, equals(30 * 1024 * 1024));
    });

    test('LRU touch updates access count', () {
      final manager = PredictiveCacheManager();
      final entry = CachedTrack(
        trackId: 'track-1',
        filePath: '/cache/track-1.flac',
        sizeBytes: 1024,
        cachedAt: DateTime.now(),
        accessCount: 0,
      );

      manager.addEntry(entry);
      manager.touch('track-1');

      final updated = manager.getEntry('track-1');
      expect(updated, isNotNull);
      expect(updated!.accessCount, equals(1));
    });

    test('eviction removes lowest-scored non-manual entries', () {
      final manager = PredictiveCacheManager(
        config: const PredictiveCacheConfig(maxTracks: 2),
      );

      manager.addEntry(CachedTrack(
        trackId: 'manual',
        filePath: '/cache/manual.flac',
        sizeBytes: 1024,
        cachedAt: DateTime.now(),
        source: CacheSource.manual,
        priority: CachePriority.low,
      ));
      manager.addEntry(CachedTrack(
        trackId: 'predictive-old',
        filePath: '/cache/old.flac',
        sizeBytes: 1024,
        cachedAt: DateTime.now().subtract(const Duration(days: 30)),
        source: CacheSource.predictive,
        priority: CachePriority.background,
      ));
      manager.addEntry(CachedTrack(
        trackId: 'predictive-new',
        filePath: '/cache/new.flac',
        sizeBytes: 1024,
        cachedAt: DateTime.now(),
        source: CacheSource.predictive,
        priority: CachePriority.medium,
      ));

      // Should evict the old background entry, not the manual one.
      expect(manager.trackCount, lessThanOrEqualTo(2));
      expect(manager.isCached('manual'), isTrue);
    });

    test('cache priority weights affect eviction order', () {
      final high = CachedTrack(
        trackId: 'high',
        filePath: '/high.flac',
        sizeBytes: 100,
        cachedAt: DateTime.now(),
        priority: CachePriority.high,
      );
      final low = CachedTrack(
        trackId: 'low',
        filePath: '/low.flac',
        sizeBytes: 100,
        cachedAt: DateTime.now(),
        priority: CachePriority.background,
      );
      expect(high.evictionScore, greaterThan(low.evictionScore));
    });
  });

  group('Discovery AI Enhancements (Milestone 8)', () {
    test('UserVector cosine similarity is ~1.0 for self', () {
      final vec = UserVector(
        userId: 'user-1',
        dimensions: 4,
        weights: [1.0, 0.5, 0.25, 0.1],
        updatedAt: DateTime.now(),
      );
      expect(vec.similarity(vec), closeTo(1.0, 0.001));
    });

    test('UserVector similarity is 0 for orthogonal vectors', () {
      final v1 = UserVector(
        userId: 'a',
        dimensions: 4,
        weights: [1.0, 0, 0, 0],
        updatedAt: DateTime.now(),
      );
      final v2 = UserVector(
        userId: 'b',
        dimensions: 4,
        weights: [0, 0, 0, 1.0],
        updatedAt: DateTime.now(),
      );
      expect(v1.similarity(v2), closeTo(0.0, 0.001));
    });

    test('TrackVector content-based similarity', () {
      final t1 = TrackVector.fromFeatures(
        'track-1',
        energy: 0.9,
        valence: 0.8,
        danceability: 0.9,
      );
      final t2 = TrackVector.fromFeatures(
        'track-2',
        energy: 0.85,
        valence: 0.75,
        danceability: 0.88,
      );
      final t3 = TrackVector.fromFeatures(
        'track-3',
        energy: 0.1,
        valence: 0.1,
        danceability: 0.1,
      );
      // Similar tracks should be closer than dissimilar ones.
      expect(t1.similarity(t2), greaterThan(t1.similarity(t3)));
    });

    test('ContentBasedRanker ranks similar tracks', () {
      final vectors = <String, TrackVector>{
        'seed': TrackVector.fromFeatures('seed', energy: 0.9, valence: 0.8),
        'similar':
            TrackVector.fromFeatures('similar', energy: 0.88, valence: 0.82),
        'different':
            TrackVector.fromFeatures('different', energy: 0.1, valence: 0.1),
      };
      final ranker = ContentBasedRanker(trackVectors: vectors);
      final results = ranker.rankSimilar(['seed']);

      expect(results, isNotEmpty);
      expect(results.first.trackId, equals('similar'));
    });

    test('EnhancedTrending computes trending scores', () {
      final listenTimes = <String, List<DateTime>>{
        'hot': List.generate(
          20,
          (i) => DateTime.now().subtract(Duration(hours: i)),
        ),
        'cold': [DateTime.now().subtract(const Duration(days: 30))],
      };
      final trending = EnhancedTrending.computeTrending(listenTimes);

      expect(trending, isNotEmpty);
      expect(trending.first.trackId, equals('hot'));
    });

    test('CollaborativeFilter finds neighbors', () {
      final userVectors = {
        'user-a': UserVector(
          userId: 'user-a',
          dimensions: 4,
          weights: [1.0, 0.8, 0.2, 0.0],
          updatedAt: DateTime.now(),
        ),
        'user-b': UserVector(
          userId: 'user-b',
          dimensions: 4,
          weights: [0.9, 0.7, 0.3, 0.1],
          updatedAt: DateTime.now(),
        ),
        'user-c': UserVector(
          userId: 'user-c',
          dimensions: 4,
          weights: [0.0, 0.0, 1.0, 1.0],
          updatedAt: DateTime.now(),
        ),
      };
      final filter = CollaborativeFilter(
        userVectors: userVectors,
        userTrackMatrix: {
          'user-a': {'track-1': 5, 'track-2': 3},
          'user-b': {'track-1': 4, 'track-3': 2},
          'user-c': {'track-4': 10},
        },
      );

      final neighbors = filter.findNeighbors('user-a');
      expect(neighbors, isNotEmpty);
      // user-b should be more similar to user-a than user-c.
      expect(neighbors.first.userId, equals('user-b'));
    });
  });

  group('Security Hardening (Milestone 9)', () {
    test('DownloadUrlValidator blocks internal hosts', () {
      expect(DownloadUrlValidator.validate('http://localhost/secret'),
          isNotNull);
      expect(DownloadUrlValidator.validate('http://127.0.0.1/admin'),
          isNotNull);
      expect(DownloadUrlValidator.validate('http://10.0.0.1/internal'),
          isNotNull);
      expect(DownloadUrlValidator.validate('http://192.168.1.1/router'),
          isNotNull);
    });

    test('DownloadUrlValidator allows valid HTTPS URLs', () {
      expect(
          DownloadUrlValidator.validate('https://cdn.example.com/track.flac'),
          isNull);
    });

    test('DownloadUrlValidator blocks file scheme', () {
      expect(DownloadUrlValidator.validate('file:///etc/passwd'), isNotNull);
    });

    test('PathTraversalGuard blocks traversal', () {
      expect(
          PathTraversalGuard.sanitize('../../../etc/passwd', '/home/user/data'),
          isNull);
    });

    test('PathTraversalGuard allows safe paths', () {
      final result = PathTraversalGuard.sanitize(
          '/home/user/data/song.flac', '/home/user/data');
      expect(result, isNotNull);
      expect(result, contains('/home/user/data'));
    });

    test('ExtensionSandboxAudit flags disallowed permissions', () {
      final manifest = <String, Object?>{
        'permissions': ['network:http', 'system:shell_exec', 'storage:cache'],
      };
      final violations = ExtensionSandboxAudit.audit(manifest);
      expect(violations, isNotEmpty);
      expect(violations.first, contains('system:shell_exec'));
    });

    test('ExtensionSandboxAudit passes valid permissions', () {
      final manifest = <String, Object?>{
        'permissions': ['network:http', 'storage:cache', 'crypto:hash'],
      };
      final violations = ExtensionSandboxAudit.audit(manifest);
      expect(violations, isEmpty);
    });

    test('BackupEncryption round-trip', () {
      final plaintext = [1, 2, 3, 4, 5, 6, 7, 8];
      final key = List.generate(32, (i) => i);
      final encrypted = BackupEncryption.encrypt(Uint8List.fromList(plaintext), key);
      final decrypted = BackupEncryption.decrypt(encrypted, key);
      expect(decrypted, isNotNull);
      expect(decrypted!.toList(), equals(plaintext));
    });

    test('ProviderSecretEncryption round-trip', () {
      final secret = 'my-api-key-12345';
      final key = List.generate(32, (i) => i);
      final encrypted = ProviderSecretEncryption.encrypt(secret, key);
      final decrypted = ProviderSecretEncryption.decrypt(encrypted, key);
      expect(decrypted, equals(secret));
    });
  });

  group('Collaborative Playlist Models (Milestone 4)', () {
    test('CollabRole parses correctly', () {
      expect(CollabRole.parse('OWNER'), equals(CollabRole.owner));
      expect(CollabRole.parse('editor'), equals(CollabRole.editor));
      expect(CollabRole.parse('VIEWER'), equals(CollabRole.viewer));
      expect(CollabRole.parse(null), equals(CollabRole.viewer));
    });

    test('CollabRole permissions', () {
      expect(CollabRole.owner.canEdit, isTrue);
      expect(CollabRole.owner.canManage, isTrue);
      expect(CollabRole.editor.canEdit, isTrue);
      expect(CollabRole.editor.canManage, isFalse);
      expect(CollabRole.viewer.canEdit, isFalse);
      expect(CollabRole.viewer.canManage, isFalse);
    });

    test('CollabMember deserialization', () {
      final json = <String, Object?>{
        'playlistId': 'pl-1',
        'userId': 'user-1',
        'handle': '@testuser',
        'role': 'EDITOR',
        'joinedAt': '2026-09-07T12:00:00Z',
      };
      final member = CollabMember.tryFromJson(json);
      expect(member, isNotNull);
      expect(member!.role, equals(CollabRole.editor));
      expect(member.handle, equals('@testuser'));
    });

    test('CollabInvite expired check', () {
      final expired = CollabInvite(
        id: 'inv-1',
        playlistId: 'pl-1',
        inviterId: 'user-a',
        inviteeId: 'user-b',
        role: CollabRole.editor,
        createdAt: DateTime.now().subtract(const Duration(days: 8)),
        expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(expired.isExpired, isTrue);

      final active = CollabInvite(
        id: 'inv-2',
        playlistId: 'pl-1',
        inviterId: 'user-a',
        inviteeId: 'user-b',
        role: CollabRole.viewer,
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(days: 6)),
      );
      expect(active.isExpired, isFalse);
    });

    test('CollabChange deserialization', () {
      final json = <String, Object?>{
        'id': 'ch-1',
        'playlistId': 'pl-1',
        'userId': 'user-1',
        'action': 'add',
        'trackId': 'track-42',
        'position': 5,
        'revision': 12,
        'createdAt': '2026-09-07T12:00:00Z',
      };
      final change = CollabChange.tryFromJson(json);
      expect(change, isNotNull);
      expect(change!.action, equals('add'));
      expect(change.trackId, equals('track-42'));
      expect(change.revision, equals(12));
    });
  });
}
