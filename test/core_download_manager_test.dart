import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/application/download_manager.dart';
import 'package:spotiflac_android/core/application/queue_engine.dart';
import 'package:spotiflac_android/core/data/atomic_file_ops.dart';
import 'package:spotiflac_android/core/data/audio_sanity.dart';
import 'package:spotiflac_android/core/data/sha256.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';

const _flacBytes = <int>[
  0x66, 0x4C, 0x61, 0x43, // fLaC
  0x00, 0x00, 0x00, 0x22, 0x10, 0x00, 0x10, 0x00,
  0xDE, 0xAD, 0xBE, 0xEF,
];

class _FakeBackend implements DownloadBackend {
  /// Per-job handler; defaults to writing the FLAC header bytes.
  Future<DownloadTaskResult> Function(DownloadTask task)? handler;
  final abortedJobIds = <String>[];
  final startedJobIds = <String>[];

  @override
  Future<DownloadTaskResult> download(DownloadTask task) async {
    startedJobIds.add(task.job.id);
    final custom = handler;
    if (custom != null) return custom(task);
    await File(task.tempPath).writeAsBytes(_flacBytes, flush: true);
    return DownloadTaskResult.success(byteSize: _flacBytes.length);
  }

  @override
  void abort(String jobId) {
    abortedJobIds.add(jobId);
  }
}

DownloadJobSpec jobSpec(
  String id,
  String finalPath, {
  String? expectedSha256Hex,
  int? expectedSizeBytes,
  JobPriority priority = JobPriority.normal,
}) {
  return DownloadJobSpec(
    jobId: id,
    track: TrackRef(id: id, name: 'Song $id', artistName: 'Artist'),
    finalPath: finalPath,
    priority: priority,
    expectedSha256Hex: expectedSha256Hex,
    expectedSizeBytes: expectedSizeBytes,
  );
}

void main() {
  late Directory tempRoot;
  late LocalFileStorageRepository storage;
  late _FakeBackend backend;
  late TransactionalDownloadManager manager;

  String outPath(String name) => '${tempRoot.path}/$name';

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('core_manager_test');
    storage = LocalFileStorageRepository(stagingRoot: tempRoot.path);
    backend = _FakeBackend();
    manager = TransactionalDownloadManager(
      backend: backend,
      storage: storage,
      sanityChecker: const AudioMagicSanityChecker(),
      integrityVerifier: const Sha256FileIntegrityVerifier(),
      config: const QueueEngineConfig(
        maxConcurrent: 1,
        shutdownGrace: Duration(milliseconds: 50),
      ),
    );
  });

  tearDown(() async {
    await manager.dispose();
    if (await tempRoot.exists()) {
      await tempRoot.delete(recursive: true);
    }
  });

  group('transactional finalize', () {
    test('success commits the staged artifact atomically', () async {
      final events = <QueueEvent>[];
      manager.events.listen(events.add);

      final job = manager.enqueue(jobSpec('t1', outPath('song.flac')));
      await manager.drained;
      await flushQueue();

      final view = manager.snapshot.firstWhere((j) => j.id == job.id);
      expect(view.lifecycle, JobLifecycle.completed);
      expect(await File(outPath('song.flac')).readAsBytes(), _flacBytes);
      expect(
        await File('${outPath('song.flac')}.tmp').exists(),
        isFalse,
        reason: 'staged temp must be consumed by the atomic commit',
      );
      expect(events.whereType<QueueJobCompleted>(), hasLength(1));
    });

    test('backend failure rolls the temp file back', () async {
      backend.handler = (task) async {
        await File(task.tempPath).writeAsBytes(_flacBytes);
        return const DownloadTaskResult.failure(
          CoreError(category: CoreErrorCategory.network, message: 'offline'),
        );
      };

      manager.enqueue(jobSpec('t2', outPath('fail.flac')));
      await manager.drained;
      await flushQueue();

      final view = manager.snapshot.firstWhere((j) => j.id == 't2');
      expect(view.lifecycle, JobLifecycle.failed);
      expect(view.error?.category, CoreErrorCategory.network);
      expect(await File(outPath('fail.flac')).exists(), isFalse);
      expect(
        await _tempFilesIn(tempRoot),
        isEmpty,
        reason: 'rollback must purge staged artifacts',
      );
    });

    test('metadata sanity gate rejects non-audio payloads before commit',
        () async {
      backend.handler = (task) async {
        // An HTML error page masquerading as audio.
        await File(task.tempPath).writeAsString('<html>401 Unauthorized');
        return const DownloadTaskResult.success();
      };

      manager.enqueue(jobSpec('t3', outPath('fake.flac')));
      await manager.drained;
      await flushQueue();

      final view = manager.snapshot.firstWhere((j) => j.id == 't3');
      expect(view.lifecycle, JobLifecycle.failed);
      expect(view.error?.category, CoreErrorCategory.integrity);
      expect(view.error?.message, contains('sanity'));
      expect(await File(outPath('fake.flac')).exists(), isFalse);
      expect(await _tempFilesIn(tempRoot), isEmpty);
    });

    test('SHA-256 expectation gates the commit', () async {
      final goodSha = sha256Hex(_flacBytes);

      // Matching digest → committed.
      manager.enqueue(
        jobSpec('ok', outPath('ok.flac'), expectedSha256Hex: goodSha),
      );
      // Wrong digest → integrity failure, temp purged.
      manager.enqueue(
        jobSpec(
          'bad',
          outPath('bad.flac'),
          expectedSha256Hex: List.filled(64, '0').join(),
        ),
      );
      await manager.drained;
      await flushQueue();

      final ok = manager.snapshot.firstWhere((j) => j.id == 'ok');
      final bad = manager.snapshot.firstWhere((j) => j.id == 'bad');
      expect(ok.lifecycle, JobLifecycle.completed);
      expect(await File(outPath('ok.flac')).exists(), isTrue);
      expect(bad.lifecycle, JobLifecycle.failed);
      expect(bad.error?.category, CoreErrorCategory.integrity);
      expect(bad.error?.message, contains('SHA-256'));
      expect(await File(outPath('bad.flac')).exists(), isFalse);
      expect(await _tempFilesIn(tempRoot), isEmpty);
    });

    test('exact size expectation is enforced when provided', () async {
      manager.enqueue(
        jobSpec(
          'sized',
          outPath('sized.flac'),
          expectedSizeBytes: _flacBytes.length + 1,
        ),
      );
      await manager.drained;
      await flushQueue();

      final view = manager.snapshot.firstWhere((j) => j.id == 'sized');
      expect(view.lifecycle, JobLifecycle.failed);
      expect(view.error?.category, CoreErrorCategory.integrity);
      expect(await _tempFilesIn(tempRoot), isEmpty);
    });
  });

  group('cancellation plumbing', () {
    test('cancel mid-download aborts the backend and purges the temp file',
        () async {
      final gate = Completer<void>();
      backend.handler = (task) async {
        await File(task.tempPath).writeAsBytes(_flacBytes);
        await gate.future; // transfer in flight
        task.cancellation.throwIfCancelled(jobId: task.job.id);
        return const DownloadTaskResult.success();
      };

      manager.enqueue(jobSpec('cancelled-run', outPath('gone.flac')));
      await flushQueue();

      manager.cancel('cancelled-run');
      expect(
        backend.abortedJobIds,
        contains('cancelled-run'),
        reason: 'abort must fan out to the backend synchronously',
      );
      gate.complete();
      await manager.drained;
      await flushQueue();

      final view = manager.snapshot.firstWhere((j) => j.id == 'cancelled-run');
      expect(view.lifecycle, JobLifecycle.cancelled);
      expect(await File(outPath('gone.flac')).exists(), isFalse);
      expect(await _tempFilesIn(tempRoot), isEmpty);
    });

    test('pause mid-download holds the job and the next attempt re-runs',
        () async {
      var attempt = 0;
      final firstRunGate = Completer<void>();
      backend.handler = (task) async {
        attempt++;
        if (attempt == 1) {
          await firstRunGate.future;
          // First attempt was paused by the test below: this throws.
          task.cancellation.throwIfCancelled(jobId: task.job.id);
        }
        await File(task.tempPath).writeAsBytes(_flacBytes);
        return const DownloadTaskResult.success();
      };

      manager.enqueue(jobSpec('paused-run', outPath('resume.flac')));
      await flushQueue();
      manager.pause('paused-run');
      firstRunGate.complete();
      await manager.drained;
      await flushQueue();

      var view = manager.snapshot.firstWhere((j) => j.id == 'paused-run');
      expect(view.lifecycle, JobLifecycle.held);

      manager.resume('paused-run');
      await manager.drained;
      await flushQueue();

      view = manager.snapshot.firstWhere((j) => j.id == 'paused-run');
      expect(view.lifecycle, JobLifecycle.completed);
      expect(attempt, 2);
      expect(await File(outPath('resume.flac')).readAsBytes(), _flacBytes);
    });
  });

  group('stale artifact sweep', () {
    test('sweepStaleArtifacts purges old temps via the janitor', () async {
      final stale = File(outPath('leftover.tmp'));
      await stale.writeAsBytes(const <int>[1, 2, 3]);
      final fresh = File(outPath('recent.tmp'));
      await fresh.writeAsBytes(const <int>[4]);
      // Backdate the stale artifact beyond any sane retention window.
      await stale.setLastModified(
        DateTime.now().subtract(const Duration(days: 3)),
      );

      final removed = await manager.sweepStaleArtifacts(
        olderThan: const Duration(hours: 24),
      );
      expect(removed, 1);
      expect(await stale.exists(), isFalse);
      expect(await fresh.exists(), isTrue);
    });
  });
}

Future<List<File>> _tempFilesIn(Directory root) async {
  final files = <File>[];
  await for (final entity in root.list(followLinks: false)) {
    if (entity is File && entity.path.endsWith(kStagingTempSuffix)) {
      files.add(entity);
    }
  }
  return files;
}


/// Binding-free async flush: each zero-delay timer lets one round of queued
/// microtasks run, so a few rounds drain the whole event chain.
Future<void> flushQueue([int rounds = 10]) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
