import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/apple_integration_service.dart';

void main() {
  group('AudioRouteChange parsing', () {
    test('parses a full AVAudioSession payload', () {
      final change = AudioRouteChange.parse(<String, Object?>{
        'reason': 'oldDeviceUnavailable',
        'isAirPlay': false,
        'isBluetooth': true,
        'shouldPause': true,
        'outputs': [
          {
            'name': 'AirPods Pro',
            'type': 'BluetoothA2DPOutput',
            'isBluetooth': true,
          },
        ],
      });

      expect(change.reason, AudioRouteReason.oldDeviceUnavailable);
      expect(change.isBluetooth, isTrue);
      expect(change.displayName, 'AirPods Pro');
      expect(change.outputs.single.isBluetooth, isTrue);
    });

    test('unplugging headphones asks the player to pause', () {
      // The whole point of the flag: continuing would blast the track out of
      // the built-in speaker.
      final change = AudioRouteChange.parse(<String, Object?>{
        'reason': 'oldDeviceUnavailable',
        'shouldPause': true,
        'outputs': const [],
      });
      expect(change.shouldPause, isTrue);
    });

    test('a new device appearing does not pause', () {
      final change = AudioRouteChange.parse(<String, Object?>{
        'reason': 'newDeviceAvailable',
        'shouldPause': false,
        'outputs': const [],
      });
      expect(change.shouldPause, isFalse);
      expect(change.reason, AudioRouteReason.newDeviceAvailable);
    });

    test('malformed payloads degrade instead of throwing', () {
      final change = AudioRouteChange.parse('not a map');
      expect(change.reason, AudioRouteReason.unknown);
      expect(change.outputs, isEmpty);
      expect(change.displayName, isEmpty);
    });

    test('unknown reasons map to unknown', () {
      expect(AudioRouteReason.parse('somethingNew'), AudioRouteReason.unknown);
      expect(AudioRouteReason.parse(null), AudioRouteReason.unknown);
    });

    test('malformed output entries are skipped, not fatal', () {
      final change = AudioRouteChange.parse(<String, Object?>{
        'outputs': [
          'garbage',
          {'no_name': true},
          {'name': 'Speaker', 'type': 'Speaker', 'isBuiltIn': true},
        ],
      });
      expect(change.outputs, hasLength(1));
      expect(change.outputs.single.isBuiltIn, isTrue);
    });
  });

  group('AirPlayRoute parsing', () {
    test('parses names and AirPlay state', () {
      final route = AirPlayRoute.parse(<String, Object?>{
        'name': 'Kitchen',
        'names': ['Kitchen', 'Living Room'],
        'isAirPlay': true,
        'isExternal': true,
      });
      expect(route.name, 'Kitchen');
      expect(route.names, hasLength(2));
      expect(route.isAirPlay, isTrue);
    });

    test('a malformed payload yields an empty route', () {
      final route = AirPlayRoute.parse(null);
      expect(route.name, isEmpty);
      expect(route.isAirPlay, isFalse);
      expect(route.names, isEmpty);
    });
  });

  group('LiveActivityState update throttling', () {
    const base = LiveActivityState(
      title: 'Nightcall',
      artist: 'Kavinsky',
      isPlaying: true,
      position: Duration(seconds: 30),
      duration: Duration(minutes: 4),
    );

    test('the first state always differs', () {
      expect(base.differsMeaningfullyFrom(null), isTrue);
    });

    test('a small position drift is not worth an update', () {
      // ActivityKit throttles updates and the widget interpolates progress,
      // so pushing every tick wastes the budget and gets dropped anyway.
      const drifted = LiveActivityState(
        title: 'Nightcall',
        artist: 'Kavinsky',
        isPlaying: true,
        position: Duration(seconds: 32),
        duration: Duration(minutes: 4),
      );
      expect(drifted.differsMeaningfullyFrom(base), isFalse);
    });

    test('a seek is worth an update', () {
      const seeked = LiveActivityState(
        title: 'Nightcall',
        artist: 'Kavinsky',
        isPlaying: true,
        position: Duration(minutes: 2),
        duration: Duration(minutes: 4),
      );
      expect(seeked.differsMeaningfullyFrom(base), isTrue);
    });

    test('pausing is always worth an update', () {
      const paused = LiveActivityState(
        title: 'Nightcall',
        artist: 'Kavinsky',
        isPlaying: false,
        position: Duration(seconds: 30),
        duration: Duration(minutes: 4),
      );
      expect(paused.differsMeaningfullyFrom(base), isTrue);
    });

    test('a track change is always worth an update', () {
      const next = LiveActivityState(
        title: 'Rampage',
        artist: 'Kavinsky',
        isPlaying: true,
        position: Duration(seconds: 30),
        duration: Duration(minutes: 4),
      );
      expect(next.differsMeaningfullyFrom(base), isTrue);
    });

    test('arguments carry the timestamp the widget interpolates from', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1757000000000);
      final args = base.toArguments(now);
      expect(args['updatedAt'], 1757000000000);
      expect(args['positionMs'], 30000);
      expect(args['durationMs'], 240000);
      expect(args['isPlaying'], isTrue);
      expect(args['title'], 'Nightcall');
    });
  });

  group('SiriPlayRequest parsing', () {
    test('parses a song request', () {
      final request = SiriPlayRequest.parse(<String, Object?>{
        'kind': 'track',
        'title': 'Nightcall',
        'artist': 'Kavinsky',
        'shuffle': false,
      });
      expect(request.kind, SiriRequestKind.track);
      expect(request.searchQuery, 'Nightcall Kavinsky');
    });

    test('parses an album request', () {
      final request = SiriPlayRequest.parse(<String, Object?>{
        'kind': 'album',
        'title': 'OutRun',
        'artist': 'Kavinsky',
      });
      expect(request.kind, SiriRequestKind.album);
    });

    test('parses an artist request', () {
      final request = SiriPlayRequest.parse(<String, Object?>{
        'kind': 'artist',
        'title': 'Kavinsky',
      });
      expect(request.kind, SiriRequestKind.artist);
      expect(request.searchQuery, 'Kavinsky');
    });

    test('a bare resume carries no query', () {
      final request = SiriPlayRequest.parse(<String, Object?>{'kind': 'resume'});
      expect(request.kind, SiriRequestKind.resume);
      expect(request.searchQuery, isEmpty);
    });

    test('shuffle is propagated', () {
      final request = SiriPlayRequest.parse(<String, Object?>{
        'kind': 'playlist',
        'title': 'Roadtrip',
        'shuffle': true,
      });
      expect(request.shuffle, isTrue);
      expect(request.kind, SiriRequestKind.playlist);
    });

    test('an unknown kind falls back to track', () {
      final request = SiriPlayRequest.parse(<String, Object?>{
        'kind': 'hologram',
        'title': 'x',
      });
      expect(request.kind, SiriRequestKind.track);
    });

    test('search query collapses blank fields', () {
      final request = SiriPlayRequest.parse(<String, Object?>{
        'kind': 'track',
        'title': 'Nightcall',
        'artist': '   ',
        'album': '',
      });
      expect(request.searchQuery, 'Nightcall');
    });
  });

  group('platform guards', () {
    test('isAppleHost is false in the test host', () {
      // Every service in this file short-circuits on it, which is what makes
      // them safe to construct in widget tests and on Android.
      expect(isAppleHost, isFalse);
    });

    test('audio session calls resolve rather than throw off iOS', () async {
      final service = AppleAudioSessionService();
      service.start();
      expect(await service.activate(), isFalse);
      expect(await service.deactivate(), isFalse);
      expect(await service.currentRoute(), isNull);
      await service.dispose();
    });

    test('AirPlay calls resolve rather than throw off iOS', () async {
      final service = AirPlayService();
      service.start();
      expect(await service.showRoutePicker(), isFalse);
      expect(await service.isActive(), isFalse);
      expect(await service.currentRoute(), isNull);
      await service.dispose();
    });

    test('Live Activity calls resolve rather than throw off iOS', () async {
      final service = LiveActivityService();
      expect(await service.isSupported(), isFalse);
      expect(
        await service.start(
          const LiveActivityState(
            title: 't',
            artist: 'a',
            isPlaying: true,
            position: Duration.zero,
            duration: Duration(minutes: 1),
          ),
        ),
        isFalse,
      );
      expect(service.isActive, isFalse);
      // update() on an inactive activity must be a cheap no-op.
      expect(
        await service.update(
          const LiveActivityState(
            title: 't',
            artist: 'a',
            isPlaying: false,
            position: Duration.zero,
            duration: Duration(minutes: 1),
          ),
        ),
        isFalse,
      );
      await service.end();
    });

    test('Siri registration is inert off iOS', () {
      final service = SiriService();
      service.register((_) async => true);
      expect(service.isRegistered, isFalse);
      service.dispose();
    });
  });
}
