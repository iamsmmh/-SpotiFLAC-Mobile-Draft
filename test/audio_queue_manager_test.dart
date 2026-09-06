import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/audio/queue_manager.dart';

class _MemoryStore implements QueueSnapshotStore {
  final Map<String, QueueSnapshot> _byId = <String, QueueSnapshot>{};

  @override
  Future<void> put(QueueSnapshot snapshot) async =>
      _byId[snapshot.id] = snapshot;

  @override
  Future<List<QueueSnapshot>> all() async =>
      _byId.values.toList(growable: false);

  @override
  Future<void> delete(String id) async => _byId.remove(id);

  @override
  Future<void> clear() async => _byId.clear();
}

QueueSnapshot _sample({
  String id = 's1',
  String name = 'Morning mix',
  QueueSnapshotSource source = QueueSnapshotSource.manual,
  DateTime? updatedAt,
  int currentIndex = 1,
}) {
  final at = updatedAt ?? DateTime.utc(2026, 9, 1, 8);
  return QueueSnapshot(
    id: id,
    name: name,
    source: source,
    createdAt: at,
    updatedAt: at,
    items: const <Map<String, Object?>>[
      {'id': 't1', 'source': '/music/a.flac', 'title': 'A'},
      {'id': 't2', 'source': '/music/b.flac', 'title': 'B'},
      {'id': 't3', 'source': '/music/c.flac', 'title': 'C'},
    ],
    currentIndex: currentIndex,
    positionMs: 42000,
    shuffle: true,
    repeatMode: 'all',
  );
}

void main() {
  group('QueueSnapshot', () {
    test('JSON round-trip preserves every queue fact', () {
      final snapshot = _sample();
      final restored = QueueSnapshot.tryParse(snapshot.toJson());
      expect(restored, isNotNull);
      expect(restored!.id, 's1');
      expect(restored.name, 'Morning mix');
      expect(restored.source, QueueSnapshotSource.manual);
      expect(restored.itemCount, 3);
      expect(restored.items[1]['id'], 't2');
      expect(restored.currentIndex, 1);
      expect(restored.positionMs, 42000);
      expect(restored.shuffle, isTrue);
      expect(restored.repeatMode, 'all');
    });

    test('rejects structurally invalid payloads', () {
      expect(QueueSnapshot.tryParse(<String, Object?>{}), isNull);
      expect(
        QueueSnapshot.tryParse(<String, Object?>{'id': 'x'}),
        isNull,
      );
      expect(
        QueueSnapshot.tryParse(<String, Object?>{
          'id': 'x',
          'items': <Object?>[],
          'created_at': '2026-09-01T00:00:00Z',
        }),
        isNull,
      );
      expect(
        QueueSnapshot.tryParse(<String, Object?>{
          'id': 'x',
          'items': <Object?>[
            <String, Object?>{'id': 't1', 'source': '/a'},
          ],
          'created_at': 'not-a-date',
        }),
        isNull,
      );
    });

    test('clamps an out-of-range current index', () {
      final restored = QueueSnapshot.tryParse(
        _sample(currentIndex: 99).toJson(),
      );
      expect(restored!.currentIndex, 2);
    });
  });

  group('QueueExportCodec', () {
    test('envelope round-trip', () {
      final envelope = QueueExportCodec.encode(_sample());
      expect(envelope['format'], QueueExportCodec.formatId);
      expect(envelope['version'], QueueExportCodec.currentVersion);
      final decoded = QueueExportCodec.tryDecode(envelope);
      expect(decoded, isNotNull);
      expect(decoded!.itemCount, 3);
      expect(decoded.source, QueueSnapshotSource.imported);
    });

    test('a newer envelope version is rejected', () {
      final envelope = <String, Object?>{
        'format': QueueExportCodec.formatId,
        'version': QueueExportCodec.currentVersion + 1,
        'snapshot': _sample().toJson(),
      };
      expect(QueueExportCodec.tryDecode(envelope), isNull);
    });

    test('a foreign format is rejected', () {
      final envelope = <String, Object?>{
        'format': 'other.app.queue',
        'version': 1,
        'snapshot': _sample().toJson(),
      };
      expect(QueueExportCodec.tryDecode(envelope), isNull);
    });

    test('import truncates oversized queues to the cap', () {
      final snapshot = QueueSnapshot(
        id: 'big',
        name: 'big',
        source: QueueSnapshotSource.manual,
        createdAt: DateTime.utc(2026, 9, 1),
        updatedAt: DateTime.utc(2026, 9, 1),
        items: <Map<String, Object?>>[
          for (var i = 0; i < QueueExportCodec.maxImportItems + 5; i++)
            <String, Object?>{'id': 't$i', 'source': '/m/$i'},
        ],
        currentIndex: QueueExportCodec.maxImportItems + 4,
      );
      final decoded = QueueExportCodec.tryDecode(
        QueueExportCodec.encode(snapshot),
      );
      expect(decoded!.itemCount, QueueExportCodec.maxImportItems);
      expect(decoded.currentIndex, QueueExportCodec.maxImportItems - 1);
    });
  });

  group('QueueRetentionPolicy', () {
    test('keeps the newest N autos and M manuals', () {
      const policy = QueueRetentionPolicy(
        maxAutoSnapshots: 2,
        maxManualSnapshots: 1,
      );
      DateTime at(int hour) => DateTime.utc(2026, 9, 1, hour);
      final deletions = policy.planDeletions([
        _sample(id: 'auto-old', source: QueueSnapshotSource.auto, updatedAt: at(1)),
        _sample(id: 'auto-new', source: QueueSnapshotSource.auto, updatedAt: at(3)),
        _sample(id: 'auto-mid', source: QueueSnapshotSource.auto, updatedAt: at(2)),
        _sample(id: 'manual-keep', updatedAt: at(5)),
        _sample(id: 'manual-drop', updatedAt: at(4)),
      ]);
      expect(deletions, containsAll(<String>['auto-old', 'manual-drop']));
      expect(deletions, isNot(contains('auto-new')));
      expect(deletions, isNot(contains('manual-keep')));
      expect(deletions.length, 2);
    });
  });

  group('QueueManager', () {
    late _MemoryStore store;
    late QueueManager manager;

    setUp(() {
      store = _MemoryStore();
      manager = QueueManager(store: store);
    });

    test('snapshot stores and lists', () async {
      final created = await manager.snapshot(
        name: 'Focus',
        items: const [
          {'id': 't1', 'source': '/a'},
        ],
        currentIndex: 0,
      );
      expect(created.name, 'Focus');
      await manager.reload();
      expect(manager.snapshots.single.id, created.id);
    });

    test('empty queues are rejected', () async {
      expect(
        () => manager.snapshot(
          name: 'x',
          items: const <Map<String, Object?>>[],
          currentIndex: 0,
        ),
        throwsArgumentError,
      );
    });

    test('snapshotAuto ignores empty queues', () async {
      expect(
        await manager.snapshotAuto(
          items: const <Map<String, Object?>>[],
          currentIndex: 0,
        ),
        isNull,
      );
    });

    test('auto snapshots roll: retention keeps only the newest N', () async {
      final rolling = QueueManager(
        store: store,
        retention: const QueueRetentionPolicy(maxAutoSnapshots: 2),
      );
      for (var i = 0; i < 4; i++) {
        await rolling.snapshotAuto(
          items: [
            <String, Object?>{'id': 't$i', 'source': '/m/$i'},
          ],
          currentIndex: 0,
        );
      }
      await rolling.reload();
      expect(rolling.snapshots.length, 2);
      expect(
        rolling.snapshots.every((s) => s.source == QueueSnapshotSource.auto),
        isTrue,
      );
    });

    test('rename updates the name', () async {
      final created = await manager.snapshot(
        name: 'Before',
        items: const [
          {'id': 't1', 'source': '/a'},
        ],
        currentIndex: 0,
      );
      await manager.rename(created.id, 'After');
      await manager.reload();
      expect(manager.snapshots.single.name, 'After');
    });

    test('rename ignores blank names', () async {
      final created = await manager.snapshot(
        name: 'Kept',
        items: const [
          {'id': 't1', 'source': '/a'},
        ],
        currentIndex: 0,
      );
      await manager.rename(created.id, '   ');
      await manager.reload();
      expect(manager.snapshots.single.name, 'Kept');
    });

    test('delete removes one snapshot', () async {
      final a = await manager.snapshot(
        name: 'A',
        items: const [
          {'id': 't1', 'source': '/a'},
        ],
        currentIndex: 0,
      );
      await manager.snapshot(
        name: 'B',
        items: const [
          {'id': 't1', 'source': '/a'},
        ],
        currentIndex: 0,
      );
      await manager.delete(a.id);
      await manager.reload();
      expect(manager.snapshots.length, 1);
      expect(manager.snapshots.single.name, 'B');
    });

    test('export/import JSON round-trips through the manager', () async {
      await manager.snapshot(
        name: 'Trip',
        items: const [
          {'id': 't1', 'source': '/a'},
          {'id': 't2', 'source': '/b'},
        ],
        currentIndex: 1,
        positionMs: 12000,
      );
      await manager.reload();
      final payload = await manager.exportJson(manager.snapshots.single.id);
      expect(payload, isNotNull);

      final other = QueueManager(store: _MemoryStore());
      final imported = await other.importJson(payload!);
      expect(imported.name, 'Trip');
      expect(imported.source, QueueSnapshotSource.imported);
      expect(imported.itemCount, 2);
      expect(imported.currentIndex, 1);
      expect(imported.positionMs, 12000);
    });

    test('importJson rejects garbage', () async {
      expect(
        () => manager.importJson('not json at all'),
        throwsFormatException,
      );
      expect(
        () => manager.importJson('{"format":"spotiflac.queue","version":1}'),
        throwsFormatException,
      );
    });

    test('exportCurrent produces an importable payload', () async {
      final payload = manager.exportCurrent(
        items: const [
          {'id': 't1', 'source': '/a'},
        ],
        currentIndex: 0,
      );
      final imported = await manager.importJson(payload);
      expect(imported.itemCount, 1);
      expect(imported.source, QueueSnapshotSource.imported);
    });

    test('deleteAll clears the store', () async {
      await manager.snapshot(
        name: 'A',
        items: const [
          {'id': 't1', 'source': '/a'},
        ],
        currentIndex: 0,
      );
      await manager.deleteAll();
      expect(manager.snapshots, isEmpty);
    });
  });
}
