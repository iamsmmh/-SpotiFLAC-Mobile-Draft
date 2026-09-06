import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/data/atomic_file_ops.dart';

void main() {
  late Directory root;
  const ops = AtomicFileOps();

  String p(String name) => '${root.path}/$name';

  setUp(() {
    root = Directory.systemTemp.createTempSync('core_atomic_test');
  });

  tearDown(() async {
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  });

  group('tempPathFor', () {
    test('appends the staging suffix', () {
      expect(ops.tempPathFor('/a/b/song.flac'), '/a/b/song.flac.tmp');
    });
  });

  group('commitAtomic', () {
    test('renames the staged file to its final destination', () async {
      final temp = File(p('song.flac.tmp'));
      await temp.writeAsBytes(const <int>[1, 2, 3]);

      await ops.commitAtomic(temp.path, p('song.flac'));

      expect(await temp.exists(), isFalse);
      expect(await File(p('song.flac')).readAsBytes(), const <int>[1, 2, 3]);
    });

    test('replaces an existing destination', () async {
      await File(p('song.flac')).writeAsBytes(const <int>[9, 9, 9, 9]);
      final temp = File(p('song.flac.tmp'));
      await temp.writeAsBytes(const <int>[1]);

      await ops.commitAtomic(temp.path, p('song.flac'));

      expect(await File(p('song.flac')).readAsBytes(), const <int>[1]);
    });

    test('creates missing parent directories', () async {
      final nested = p('Album/Disc 1/song.flac');
      final temp = File(p('song.flac.tmp'));
      await temp.writeAsBytes(const <int>[5]);

      await ops.commitAtomic(temp.path, nested);

      expect(await File(nested).readAsBytes(), const <int>[5]);
    });

    test('refuses to commit a missing or empty staging file', () async {
      expect(
        ops.commitAtomic(p('ghost.tmp'), p('ghost.flac')),
        throwsA(isA<FileSystemException>()),
      );

      final empty = File(p('empty.tmp'));
      await empty.create();
      expect(
        ops.commitAtomic(empty.path, p('empty.flac')),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  group('rollback', () {
    test('deletes an existing temp and ignores a missing one', () async {
      final temp = File(p('x.tmp'));
      await temp.writeAsBytes(const <int>[1]);
      await ops.rollback(temp.path);
      expect(await temp.exists(), isFalse);
      // Idempotent: second rollback must not throw.
      await ops.rollback(temp.path);
    });
  });

  group('TempFileJanitor', () {
    test('purges only stale .tmp files, recursively', () async {
      const janitor = TempFileJanitor();
      final now = DateTime(2026, 9, 1, 12);

      final staleNested = Directory(p('nested'))..createSync();
      final stale = File('${staleNested.path}/old.tmp')
        ..writeAsBytesSync(const <int>[1]);
      await stale.setLastModified(now.subtract(const Duration(days: 2)));
      final recent = File(p('recent.tmp'))..writeAsBytesSync(const <int>[2]);
      await recent.setLastModified(now.subtract(const Duration(minutes: 5)));
      final keep = File(p('song.flac'))..writeAsBytesSync(const <int>[3]);

      final removed = await janitor.purgeStaleTemps(
        root,
        olderThan: const Duration(hours: 24),
        now: now,
      );

      expect(removed, 1);
      expect(await stale.exists(), isFalse);
      expect(await recent.exists(), isTrue);
      expect(await keep.exists(), isTrue);
    });

    test('returns zero for a missing root directory', () async {
      const janitor = TempFileJanitor();
      final removed = await janitor.purgeStaleTemps(
        Directory(p('does-not-exist')),
        olderThan: const Duration(hours: 24),
      );
      expect(removed, 0);
    });
  });

  group('LocalFileStorageRepository', () {
    test('stage → commit round trip honours the StorageRepository contract',
        () async {
      final repo = LocalFileStorageRepository(stagingRoot: root.path);
      final target = await repo.stage(p('Album/song.flac'));
      expect(target.scheme, 'file');
      expect(target.tempPath, p('Album/song.flac.tmp'));

      await File(target.tempPath).writeAsBytes(const <int>[7, 7]);
      await repo.commit(target);

      expect(await repo.exists(p('Album/song.flac')), isTrue);
      expect(await repo.exists(target.tempPath), isFalse);
    });

    test('stage clears a leftover temp from a previous attempt', () async {
      final repo = LocalFileStorageRepository(stagingRoot: root.path);
      final leftover = File(p('song.flac.tmp'));
      await leftover.writeAsBytes(const <int>[1]);

      final target = await repo.stage(p('song.flac'));
      expect(await File(target.tempPath).exists(), isFalse);
    });

    test('rollback purges the staged artifact idempotently', () async {
      final repo = LocalFileStorageRepository(stagingRoot: root.path);
      final target = await repo.stage(p('song.flac'));
      await File(target.tempPath).writeAsBytes(const <int>[1]);

      await repo.rollback(target);
      expect(await File(target.tempPath).exists(), isFalse);
      await repo.rollback(target); // idempotent
    });
  });
}
