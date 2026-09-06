import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/constants/app_info.dart';
import 'package:spotiflac_android/core/data/android_storage_permission_policy.dart';
import 'package:spotiflac_android/core/data/background_playback_policy.dart';
import 'package:spotiflac_android/core/data/cold_start_policy.dart';
import 'package:spotiflac_android/core/data/network_switch_policy.dart';
import 'package:spotiflac_android/core/data/release_artifact_policy.dart';
import 'package:spotiflac_android/core/data/secure_store.dart';
import 'package:spotiflac_android/core/data/session_resource_budget.dart';

void main() {
  group('SecureStorePolicy', () {
    test('accepts namespaced tokens secrets and signatures', () {
      expect(SecureStorePolicy.isAllowedKey(SecureStoreKeys.token('access')), isTrue);
      expect(SecureStorePolicy.isAllowedKey(SecureStoreKeys.secret('api')), isTrue);
      expect(
        SecureStorePolicy.isAllowedKey(SecureStoreKeys.extensionSignature('tidal')),
        isTrue,
      );
      expect(
        SecureStorePolicy.isAllowedKey(SecureStoreKeys.schemaVersion),
        isTrue,
      );
    });

    test('retired Spotify client secret can still be deleted', () {
      expect(
        SecureStorePolicy.retiredKeys,
        contains(SecureStoreKeys.spotifyClientSecret),
      );
      expect(
        SecureStorePolicy.isAllowedKey(SecureStoreKeys.spotifyClientSecret),
        isTrue,
      );
    });

    test('rejects empty prefix-only and oversized keys', () {
      expect(SecureStorePolicy.isAllowedKey(''), isFalse);
      expect(SecureStorePolicy.isAllowedKey('spotiflac.token.'), isFalse);
      expect(SecureStorePolicy.isAllowedKey('plaintext'), isFalse);
      expect(SecureStorePolicy.isAllowedKey('a' * 129), isFalse);
      expect(SecureStorePolicy.isAllowedValue('x' * (16 * 1024 + 1)), isFalse);
    });
  });

  group('SessionResourceBudget 2h leak audit', () {
    const idle = SessionResourceSnapshot(
      imageCacheEntries: 0,
      imageCacheBytes: 0,
      coverDiskBytes: 0,
      liveSubscriptions: 0,
      decodedCoversInFlight: 0,
      nativeWorkerItems: 0,
      streamBufferBytes: 0,
    );

    test('idle snapshot is inside every tier', () {
      for (final budget in [
        SessionResourceBudget.low,
        SessionResourceBudget.standard,
        SessionResourceBudget.high,
      ]) {
        expect(budget.allows(idle), isTrue);
        expect(budget.violations(idle), isEmpty);
      }
    });

    test('low / standard / high image-cache caps match ColdStartPolicy', () {
      expect(
        SessionResourceBudget.low.maxImageCacheEntries,
        ColdStartPolicy.imageCacheEntriesForTier('low'),
      );
      expect(
        SessionResourceBudget.standard.maxImageCacheBytes,
        ColdStartPolicy.imageCacheBytesForTier('standard'),
      );
      expect(
        SessionResourceBudget.high.maxImageCacheEntries,
        ColdStartPolicy.imageCacheEntriesForTier('high'),
      );
    });

    test('a leaking 2-hour session is reported by field', () {
      const leak = SessionResourceSnapshot(
        imageCacheEntries: 10_000,
        imageCacheBytes: 1 << 30,
        coverDiskBytes: 1 << 30,
        liveSubscriptions: 10_000,
        decodedCoversInFlight: 10_000,
        nativeWorkerItems: 10_000,
        streamBufferBytes: 1 << 30,
      );
      final violations = SessionResourceBudget.standard.violations(leak);
      expect(violations, contains('imageCacheEntries'));
      expect(violations, contains('streamBufferBytes'));
      expect(SessionResourceBudget.standard.allows(leak), isFalse);
    });

    test('list tiles at or below 256 logical px resize the disk cache', () {
      expect(RebuildBudget.shouldResizeDiskCache(48, 48), isTrue);
      expect(RebuildBudget.shouldResizeDiskCache(256, 256), isTrue);
      expect(RebuildBudget.shouldResizeDiskCache(512, 512), isFalse);
      expect(RebuildBudget.decodeExtent(48, 2.0), 96);
      expect(RebuildBudget.shouldSkipRebuild('a', 'a'), isTrue);
      expect(RebuildBudget.progressRebuildFloor, const Duration(milliseconds: 200));
    });
  });

  group('NetworkSwitchPolicy WiFi ↔ cellular', () {
    final now = DateTime.utc(2026, 9, 2, 12);
    final stale = now.subtract(const Duration(seconds: 5));

    test('identical transport set is ignored', () {
      final decision = NetworkSwitchPolicy.decide(
        current: const [NetworkTransport.wifi],
        previous: const [NetworkTransport.wifi],
        now: now,
        lastCleanupAt: stale,
        wifiOnlyMode: false,
        queueProcessing: true,
        queuePausedForWifi: false,
      );
      expect(decision.action, NetworkSwitchAction.ignore);
    });

    test('first observation is record-only', () {
      final decision = NetworkSwitchPolicy.decide(
        current: const [NetworkTransport.wifi],
        previous: null,
        now: now,
        lastCleanupAt: stale,
        wifiOnlyMode: true,
        queueProcessing: true,
        queuePausedForWifi: false,
      );
      expect(decision.action, NetworkSwitchAction.observe);
    });

    test('wifi → cellular recycles sockets and pauses a wifi-only queue', () {
      final decision = NetworkSwitchPolicy.decide(
        current: const [NetworkTransport.mobile],
        previous: const [NetworkTransport.wifi],
        now: now,
        lastCleanupAt: stale,
        wifiOnlyMode: true,
        queueProcessing: true,
        queuePausedForWifi: false,
      );
      expect(decision.action, NetworkSwitchAction.recycleConnections);
      expect(decision.hasWifi, isFalse);
      expect(decision.shouldPauseWifiOnlyQueue, isTrue);
      expect(decision.shouldResumeWifiOnlyQueue, isFalse);
    });

    test('cellular → wifi resumes a wifi-only queue', () {
      final decision = NetworkSwitchPolicy.decide(
        current: const [NetworkTransport.wifi],
        previous: const [NetworkTransport.mobile],
        now: now,
        lastCleanupAt: stale,
        wifiOnlyMode: true,
        queueProcessing: false,
        queuePausedForWifi: true,
      );
      expect(decision.shouldResumeWifiOnlyQueue, isTrue);
      expect(decision.shouldPauseWifiOnlyQueue, isFalse);
    });

    test('flapping inside the 2s debounce skips cleanup', () {
      final decision = NetworkSwitchPolicy.decide(
        current: const [NetworkTransport.mobile],
        previous: const [NetworkTransport.wifi],
        now: now,
        lastCleanupAt: now.subtract(const Duration(milliseconds: 500)),
        wifiOnlyMode: false,
        queueProcessing: true,
        queuePausedForWifi: false,
      );
      expect(decision.action, NetworkSwitchAction.debounce);
    });

    test('ethernet counts as wifi; none is offline', () {
      expect(NetworkSwitchPolicy.hasWifi(const [NetworkTransport.ethernet]), isTrue);
      expect(NetworkSwitchPolicy.isOffline(const [NetworkTransport.none]), isTrue);
      expect(NetworkSwitchPolicy.isOffline(const [NetworkTransport.wifi]), isFalse);
    });
  });

  group('AndroidStoragePermissionPolicy Android 13–16+', () {
    test('API 33+ requests READ_MEDIA_AUDIO and POST_NOTIFICATIONS', () {
      for (final sdk in [33, 34, 35, 36]) {
        final set = AndroidStoragePermissionPolicy.forSdk(sdk);
        expect(set.runtime, contains(AndroidStoragePermission.readMediaAudio));
        expect(set.runtime, contains(AndroidStoragePermission.postNotifications));
        expect(set.notificationsAreRuntime, isTrue);
        expect(set.usesSafForDownloads, isTrue);
        expect(
          AndroidStoragePermissionPolicy.libraryScanPermission(sdk),
          AndroidStoragePermission.readMediaAudio,
        );
      }
    });

    test('API 30–32 uses MANAGE_EXTERNAL_STORAGE', () {
      final set = AndroidStoragePermissionPolicy.forSdk(31);
      expect(set.runtime, [AndroidStoragePermission.manageExternalStorage]);
      expect(set.notificationsAreRuntime, isFalse);
    });

    test('legacy storage below API 30', () {
      final set = AndroidStoragePermissionPolicy.forSdk(28);
      expect(set.runtime, contains(AndroidStoragePermission.readExternalStorage));
      expect(set.usesSafForDownloads, isFalse);
      expect(AndroidStoragePermissionPolicy.usesSafForDownloads(29), isTrue);
    });

    test('dataSync FGS budget starts at API 35', () {
      expect(AndroidStoragePermissionPolicy.hasDataSyncForegroundBudget(34), isFalse);
      expect(AndroidStoragePermissionPolicy.hasDataSyncForegroundBudget(35), isTrue);
    });
  });

  group('BackgroundPlaybackPolicy iOS 17+ / media session', () {
    test('duck is ignored; pause is resumable; unknown is sticky', () {
      expect(
        BackgroundPlaybackPolicy.onInterruptionBegan(AudioInterruptionKind.duck).action,
        BackgroundPlaybackAction.ignore,
      );
      expect(
        BackgroundPlaybackPolicy.onInterruptionBegan(AudioInterruptionKind.pause).action,
        BackgroundPlaybackAction.pauseAndMarkResumable,
      );
      expect(
        BackgroundPlaybackPolicy.onInterruptionBegan(AudioInterruptionKind.unknown).action,
        BackgroundPlaybackAction.pauseSticky,
      );
    });

    test('pause-type end resumes only when we paused and the user did not', () {
      expect(
        BackgroundPlaybackPolicy.onInterruptionEnded(
          kind: AudioInterruptionKind.pause,
          pausedByInterruption: true,
          userPaused: false,
        ).action,
        BackgroundPlaybackAction.resume,
      );
      expect(
        BackgroundPlaybackPolicy.onInterruptionEnded(
          kind: AudioInterruptionKind.pause,
          pausedByInterruption: true,
          userPaused: true,
        ).action,
        BackgroundPlaybackAction.stayPaused,
      );
    });

    test('becoming noisy never auto-resumes; restore is always paused', () {
      expect(
        BackgroundPlaybackPolicy.becomingNoisy.action,
        BackgroundPlaybackAction.pauseSticky,
      );
      expect(BackgroundPlaybackPolicy.restoreSessionPaused(), isTrue);
      expect(BackgroundPlaybackPolicy.iosBackgroundMode, 'audio');
      expect(
        BackgroundPlaybackPolicy.androidPlaybackChannelId,
        'com.zarz.spotiflac.playback',
      );
    });
  });

  group('ColdStartPolicy', () {
    test('secure store and image-cache caps block first frame; cover cache does not', () {
      expect(
        ColdStartPolicy.blockingSteps.map((s) => s.id),
        containsAll(['secure_store_init', 'image_cache_caps', 'run_app']),
      );
      expect(ColdStartPolicy.isDeferred('cover_cache'), isTrue);
      expect(ColdStartPolicy.isDeferred('secure_store_init'), isFalse);
    });
  });

  group('ReleaseArtifactPolicy production splits', () {
    test('requires arm64, arm32, x86_64 APKs plus AAB and unsigned IPA', () {
      final artifacts = ReleaseArtifactPolicy.expectedArtifacts('v4.9.0');
      expect(
        artifacts.map((a) => a.fileName),
        containsAll([
          'SpotiFLAC-v4.9.0-arm64.apk',
          'SpotiFLAC-v4.9.0-arm32.apk',
          'SpotiFLAC-v4.9.0-x86_64.apk',
          'SpotiFLAC-v4.9.0.aab',
          'SpotiFLAC-v4.9.0-ios-unsigned.ipa',
        ]),
      );
      expect(
        ReleaseArtifactPolicy.flutterTargetPlatforms,
        ['android-arm64', 'android-arm', 'android-x64'],
      );
      expect(
        ReleaseArtifactPolicy.gomobileAndroidTarget,
        'android/arm,android/arm64,android/amd64',
      );
      expect(
        AppInfo.productionAndroidAbis,
        ReleaseArtifactPolicy.androidAbis,
      );
      expect(AppInfo.releaseArtifactPrefix, 'SpotiFLAC');
    });

    test('SHA256SUMS parse + verify round-trips via sha256.dart', () {
      const bytes = <int>[0, 1, 2, 3, 4];
      final line = ReleaseArtifactPolicy.checksumLine('SpotiFLAC-v4.9.0-arm64.apk', bytes);
      final parsed = ReleaseArtifactPolicy.parseChecksums('# comment\n$line\n');
      expect(
        ReleaseArtifactPolicy.verify(
          fileName: 'SpotiFLAC-v4.9.0-arm64.apk',
          bytes: bytes,
          checksums: parsed,
        ),
        isTrue,
      );
      expect(
        () => ReleaseArtifactPolicy.parseChecksums('not-a-checksum'),
        throwsFormatException,
      );
    });
  });
}
