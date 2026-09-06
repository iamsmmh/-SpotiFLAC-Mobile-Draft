import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/download_item.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_schedule_settings_provider.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/services/queue_transfer_service.dart';
import 'package:spotiflac_android/services/storage_breakdown_service.dart';

Track _track(String id, String name) => Track(
  id: id,
  name: name,
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);

DownloadItem _item(String id) => DownloadItem(
  id: id,
  track: _track('spotify:$id', 'Track $id'),
  service: 'tidal',
  createdAt: DateTime.utc(2026, 9, 1),
);

void main() {
  group('DownloadScheduleSettings', () {
    test('day window checks containment', () {
      const settings = DownloadScheduleSettings(
        enabled: true,
        startMinute: 9 * 60,
        endMinute: 17 * 60,
      );
      expect(settings.isWithinWindow(DateTime(2026, 9, 1, 10)), isTrue);
      expect(settings.isWithinWindow(DateTime(2026, 9, 1, 8)), isFalse);
      expect(settings.isWithinWindow(DateTime(2026, 9, 1, 18)), isFalse);
    });

    test('nightly crossing window works', () {
      const settings = DownloadScheduleSettings(
        enabled: true,
        startMinute: 22 * 60,
        endMinute: 7 * 60,
      );
      expect(settings.isWithinWindow(DateTime(2026, 9, 1, 23)), isTrue);
      expect(settings.isWithinWindow(DateTime(2026, 9, 1, 5)), isTrue);
      expect(settings.isWithinWindow(DateTime(2026, 9, 1, 12)), isFalse);
      expect(settings.startLabel, '22:00');
      expect(settings.endLabel, '07:00');
    });

    test('nextOpenMoment is always in the future', () {
      const dayWindow = DownloadScheduleSettings(
        enabled: true,
        startMinute: 9 * 60,
        endMinute: 17 * 60,
      );
      // Inside the window: no resume moment.
      expect(
        dayWindow.nextOpenMoment(DateTime(2026, 9, 1, 12)),
        isNull,
      );
      // Before the window opens: today at 09:00.
      expect(
        dayWindow.nextOpenMoment(DateTime(2026, 9, 1, 8)),
        DateTime(2026, 9, 1, 9),
      );
      // After the window closed: *tomorrow* at 09:00, never a past moment.
      expect(
        dayWindow.nextOpenMoment(DateTime(2026, 9, 1, 18)),
        DateTime(2026, 9, 2, 9),
      );

      const nightlyWindow = DownloadScheduleSettings(
        enabled: true,
        startMinute: 22 * 60,
        endMinute: 7 * 60,
      );
      // After the nightly window ended this morning: tonight at 22:00.
      expect(
        nightlyWindow.nextOpenMoment(DateTime(2026, 9, 1, 12)),
        DateTime(2026, 9, 1, 22),
      );
      // Mid-window: no resume moment.
      expect(nightlyWindow.nextOpenMoment(DateTime(2026, 9, 1, 23)), isNull);
    });

    test('legacy json roundtrips with defaults', () {
      const settings = DownloadScheduleSettings(
        enabled: true,
        startMinute: 22 * 60,
        endMinute: 7 * 60,
      );
      final restored = DownloadScheduleSettings.fromJson(settings.toJson());
      expect(restored.enabled, isTrue);
      expect(restored.startMinute, 22 * 60);
      expect(restored.endMinute, 7 * 60);
    });

    test('v1 store without device conditions decodes with them off', () {
      final restored = DownloadScheduleSettings.fromJson({
        'enabled': true,
        'start_minute': 22 * 60,
        'end_minute': 7 * 60,
      });
      expect(restored.requireCharging, isFalse);
      expect(restored.requireWifi, isFalse);
      expect(restored.minBatteryPercent, 0);
      expect(restored.hasDeviceConditions, isFalse);
      expect(restored.allDay, isFalse);
    });

    test('device conditions roundtrip and clamp', () {
      const settings = DownloadScheduleSettings(
        enabled: true,
        startMinute: 0,
        endMinute: 0,
        requireCharging: true,
        minBatteryPercent: 30,
        requireWifi: true,
      );
      final restored = DownloadScheduleSettings.fromJson(settings.toJson());
      expect(restored.requireCharging, isTrue);
      expect(restored.minBatteryPercent, 30);
      expect(restored.requireWifi, isTrue);
      expect(restored.allDay, isTrue);
      expect(restored.isWithinWindow(DateTime(2026, 9, 1, 12)), isTrue);
      expect(settings.copyWith(minBatteryPercent: 250).minBatteryPercent, 100);
      expect(settings.copyWith(minBatteryPercent: -5).minBatteryPercent, 0);
    });

    test('blockedReason honours WiFi, charger and battery floor', () {
      const wifi = DownloadScheduleSettings(enabled: true, requireWifi: true);
      expect(
        wifi.blockedReason(
          charging: false,
          batteryLevel: 80,
          powerKnown: true,
          onWifi: false,
        ),
        'waiting for WiFi',
      );
      expect(
        wifi.blockedReason(
          charging: false,
          batteryLevel: 80,
          powerKnown: true,
          onWifi: true,
        ),
        isNull,
      );

      const charger = DownloadScheduleSettings(
        enabled: true,
        requireCharging: true,
      );
      expect(
        charger.blockedReason(
          charging: false,
          batteryLevel: 90,
          powerKnown: true,
          onWifi: true,
        ),
        'waiting for charger',
      );
      expect(
        charger.blockedReason(
          charging: true,
          batteryLevel: 10,
          powerKnown: true,
          onWifi: true,
        ),
        isNull,
      );
      // Unknown power information never holds the queue hostage.
      expect(
        charger.blockedReason(
          charging: false,
          batteryLevel: -1,
          powerKnown: false,
          onWifi: true,
        ),
        isNull,
      );

      const floor = DownloadScheduleSettings(
        enabled: true,
        minBatteryPercent: 20,
      );
      expect(
        floor.blockedReason(
          charging: false,
          batteryLevel: 15,
          powerKnown: true,
          onWifi: false,
        ),
        'battery below 20%',
      );
      // Plugged in: the floor does not apply.
      expect(
        floor.blockedReason(
          charging: true,
          batteryLevel: 15,
          powerKnown: true,
          onWifi: false,
        ),
        isNull,
      );
      expect(
        floor.blockedReason(
          charging: false,
          batteryLevel: 20,
          powerKnown: true,
          onWifi: false,
        ),
        isNull,
      );
    });

    test('PowerStatus decodes platform payloads defensively', () {
      final status = PowerStatus.fromMap({
        'charging': true,
        'level': 87,
        'known': true,
      });
      expect(status.charging, isTrue);
      expect(status.level, 87);
      expect(status.hasLevel, isTrue);
      final unknown = PowerStatus.fromMap(const {});
      expect(unknown.charging, isFalse);
      expect(unknown.level, -1);
      expect(unknown.hasLevel, isFalse);
      expect(PowerStatus.fromMap({'level': 250}).level, 100);
    });
  });

  group('QueueTransferService', () {
    test('encodes and decodes queue items', () {
      final items = [_item('t1'), _item('t2')];
      final encoded = QueueTransferService.encode(items);
      final decoded = QueueTransferService.decode(encoded);
      expect(decoded.length, 2);
      expect(decoded.first.track.name, 'Track t1');
      expect(decoded.first.service, 'tidal');
    });

    test('rejects unrelated json payloads', () {
      expect(QueueTransferService.decode('{"foo": 1}'), isEmpty);
      expect(QueueTransferService.decode('{"format":"other","items":[]}'),
          isEmpty);
    });
  });

  group('StorageBreakdownService', () {
    test('formats byte sizes readably', () {
      expect(formatStorageBytes(0), '0 B');
      expect(formatStorageBytes(500), '500 B');
      expect(formatStorageBytes(2048), '2.0 KB');
      expect(formatStorageBytes(5 * 1024 * 1024), '5.0 MB');
      expect(formatStorageBytes(3 * 1024 * 1024 * 1024), '3.00 GB');
    });
  });
}
