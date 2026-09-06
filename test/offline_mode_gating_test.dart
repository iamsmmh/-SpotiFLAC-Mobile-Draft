import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart';
import 'package:spotiflac_android/providers/streaming_engine_provider.dart';

void main() {
  group('shouldAttemptStreamResolution', () {
    test('offline network blocks stream resolution even when enabled', () {
      expect(
        shouldAttemptStreamResolution(
          streamingEnabled: true,
          network: NetworkProfile.offline,
        ),
        isFalse,
      );
    });

    test('enabled streaming + online network resolves', () {
      expect(
        shouldAttemptStreamResolution(
          streamingEnabled: true,
          network: NetworkProfile.wifi,
        ),
        isTrue,
      );
    });

    test('disabled streaming never resolves', () {
      expect(
        shouldAttemptStreamResolution(
          streamingEnabled: false,
          network: NetworkProfile.wifi,
        ),
        isFalse,
      );
    });

    test('offline mode forces an offline network profile', () {
      expect(NetworkProfile.offline.isOffline, isTrue);
      expect(NetworkProfile.wifi.isOffline, isFalse);
    });
  });

  group('EngineSettings offline & storage policy', () {
    test('defaults keep the network reachable and the cache unlimited', () {
      const settings = EngineSettings();
      expect(settings.offlineMode, isFalse);
      expect(settings.maxCacheSizeMb, 0);
      expect(settings.autoCleanCache, isTrue);
    });

    test('round-trips the new fields through JSON', () {
      const original = EngineSettings(
        offlineMode: true,
        maxCacheSizeMb: 512,
        autoCleanCache: false,
      );
      final restored = EngineSettings.fromJson(original.toJson());
      expect(restored.offlineMode, isTrue);
      expect(restored.maxCacheSizeMb, 512);
      expect(restored.autoCleanCache, isFalse);
    });

    test('tolerates missing keys from older stored settings', () {
      final restored = EngineSettings.fromJson(const <String, dynamic>{});
      expect(restored.offlineMode, isFalse);
      expect(restored.maxCacheSizeMb, 0);
      expect(restored.autoCleanCache, isTrue);
    });

    test('copyWith replaces only the requested field', () {
      const base = EngineSettings(maxCacheSizeMb: 256);
      final updated = base.copyWith(offlineMode: true);
      expect(updated.offlineMode, isTrue);
      expect(updated.maxCacheSizeMb, 256);
    });
  });
}
