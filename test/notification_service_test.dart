import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AndroidFlutterLocalNotificationsPlugin.registerWith();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  final methodCalls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          methodCalls.add(call);
          if (call.method == 'initialize') return true;
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    methodCalls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('verification uses a distinct audible Android alert channel', () async {
    final notificationService = NotificationService();
    await notificationService.showVerificationRequired();

    final alertChannelCall = methodCalls.firstWhere(
      (call) =>
          call.method == 'createNotificationChannel' &&
          (call.arguments as Map<Object?, Object?>)['id'] ==
              NotificationService.alertChannelId,
    );
    final alertChannel = alertChannelCall.arguments as Map<Object?, Object?>;

    expect(alertChannel['importance'], Importance.defaultImportance.value);
    expect(alertChannel['playSound'], isTrue);
    expect(alertChannel['enableVibration'], isTrue);

    final showCall = methodCalls.lastWhere((call) => call.method == 'show');
    final showArguments = showCall.arguments as Map<Object?, Object?>;
    final androidDetails =
        showArguments['platformSpecifics'] as Map<Object?, Object?>;

    expect(
      NotificationService.verificationRequiredId,
      isNot(NotificationService.downloadProgressId),
    );
    expect(showArguments['id'], NotificationService.verificationRequiredId);
    expect(androidDetails['channelId'], NotificationService.alertChannelId);
    expect(androidDetails['importance'], Importance.defaultImportance.value);
    expect(androidDetails['playSound'], isTrue);
    expect(androidDetails['enableVibration'], isTrue);

    await notificationService.cancelVerificationRequired();
    expect(
      methodCalls.last,
      isMethodCall(
        'cancel',
        arguments: <String, Object?>{
          'id': NotificationService.verificationRequiredId,
          'tag': null,
        },
      ),
    );
  });
}
