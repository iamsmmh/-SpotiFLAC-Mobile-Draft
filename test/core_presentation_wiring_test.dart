import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/presentation/core_queue_providers.dart';

void main() {
  group('UnconfiguredDownloadManager placeholder', () {
    const manager = UnconfiguredDownloadManager();

    test('reports an empty, healthy engine', () async {
      expect(manager.snapshot, isEmpty);
      await manager.drained; // completes immediately
      expect(
        manager.events,
        isA<Stream<QueueEvent>>(),
      );
      expect(await manager.events.isEmpty, isTrue);
    });

    test('control commands are safe no-ops', () {
      expect(() {
        manager.cancel('x');
        manager.pause('x');
        manager.resume('x');
        manager.reorder('x', JobPriority.high);
        manager.pauseAll();
        manager.resumeAll();
      }, returnsNormally);
    });

    test('enqueue fails loudly with configuration guidance', () {
      expect(
        () => manager.enqueue(
          DownloadJobSpec(
            track: const TrackRef(id: 't', name: 'n', artistName: 'a'),
            finalPath: '/out/t.flac',
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('coreBridgePayloadBuilderProvider'),
          ),
        ),
      );
    });

    test('stale sweep is a no-op returning zero', () async {
      expect(await manager.sweepStaleArtifacts(), 0);
    });
  });

  group('CoreQueueViewState', () {
    QueueJob job(String id, JobLifecycle lifecycle) => QueueJob(
      id: id,
      sequence: id.hashCode,
      spec: DownloadJobSpec(
        track: TrackRef(id: id, name: id, artistName: 'a'),
        finalPath: '/out/$id.flac',
      ),
      lifecycle: lifecycle,
    );

    test('derives running/pending counts from the job view', () {
      final state = CoreQueueViewState(
        jobs: <QueueJob>[
          job('a', JobLifecycle.running),
          job('b', JobLifecycle.pending),
          job('c', JobLifecycle.held),
          job('d', JobLifecycle.completed),
        ],
        isEngineConfigured: true,
      );
      expect(state.runningCount, 1);
      expect(state.pendingCount, 2);
      expect(state.isEngineConfigured, isTrue);
    });
  });
}
