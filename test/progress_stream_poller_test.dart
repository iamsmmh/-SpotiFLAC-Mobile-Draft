import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/progress_stream_poller.dart';

void main() {
  test('stop and restart ignore stale in-flight poll results', () async {
    final first = Completer<int>();
    final second = Completer<int>();
    var pollCalls = 0;
    final received = <int>[];
    final errors = <Object>[];

    final poller = ProgressStreamPoller<int>(
      streamProvider: () => const Stream<int>.empty(),
      pollProvider: () {
        pollCalls++;
        return pollCalls == 1 ? first.future : second.future;
      },
      onProgress: (value) async => received.add(value),
      pollingInterval: const Duration(days: 1),
      bootstrapTimeout: const Duration(days: 1),
      onStreamProcessingError: errors.add,
      onStreamFailed: errors.add,
      onStreamTimeout: () {},
      onPollError: errors.add,
    );

    poller.start(useStream: false);
    final stalePoll = poller.pollOnce(errors.add);
    await Future<void>.delayed(Duration.zero);
    expect(pollCalls, 1);

    poller.stop();
    poller.start(useStream: false);
    final currentPoll = poller.pollOnce(errors.add);
    await Future<void>.delayed(Duration.zero);
    expect(pollCalls, 2);

    first.complete(1);
    await stalePoll;
    expect(received, isEmpty);

    // The stale poll's finally block must not clear the newer run's guard.
    await poller.pollOnce(errors.add);
    expect(pollCalls, 2);

    second.complete(2);
    await currentPoll;
    expect(received, [2]);
    expect(errors, isEmpty);
    poller.stop();
  });

  test('a stale stream error cannot start polling after stop', () async {
    final stream = StreamController<int>();
    var pollCalls = 0;
    final poller = ProgressStreamPoller<int>(
      streamProvider: () => stream.stream,
      pollProvider: () async {
        pollCalls++;
        return 1;
      },
      onProgress: (_) async {},
      pollingInterval: const Duration(milliseconds: 1),
      bootstrapTimeout: const Duration(days: 1),
      onStreamProcessingError: (_) {},
      onStreamFailed: (_) {},
      onStreamTimeout: () {},
      onPollError: (_) {},
    );

    poller.start(useStream: true);
    poller.stop();
    stream.addError(StateError('late event'));
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(pollCalls, 0);
    await stream.close();
  });
}
