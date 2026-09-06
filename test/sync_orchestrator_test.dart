import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/sync/sync_entities.dart';
import 'package:spotiflac_android/core/sync/sync_orchestrator.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 1, 12);
  final t1 = t0.add(const Duration(minutes: 1));
  final t2 = t0.add(const Duration(minutes: 2));

  group('SyncRecord', () {
    test('json round trip preserves fields', () {
      final record = SyncRecord(
        scope: SyncScope.favorites,
        recordId: 'isrc:USRC12345',
        revision: 3,
        updatedAt: t1,
        payload: const <String, Object?>{'title': 'Song'},
      );
      final parsed = SyncRecord.tryParse(record.toJson());
      expect(parsed, isNotNull);
      expect(parsed!.scope, SyncScope.favorites);
      expect(parsed.recordId, 'isrc:USRC12345');
      expect(parsed.revision, 3);
      expect(parsed.updatedAt, t1);
      expect(parsed.deleted, isFalse);
      expect(parsed.payload['title'], 'Song');
    });

    test('tombstone round trip', () {
      final record = SyncRecord(
        scope: SyncScope.playlists,
        recordId: 'pl1',
        revision: 2,
        updatedAt: t1,
        deleted: true,
      );
      final parsed = SyncRecord.tryParse(record.toJson());
      expect(parsed!.deleted, isTrue);
      expect(parsed.payload, isEmpty);
    });

    test('tryParse rejects malformed payloads', () {
      expect(SyncRecord.tryParse(const <String, Object?>{}), isNull);
      expect(
        SyncRecord.tryParse(const <String, Object?>{
          'scope': 'nope',
          'recordId': 'x',
          'updatedAt': '2026-09-01T12:00:00Z',
        }),
        isNull,
      );
    });
  });

  group('conflict resolution', () {
    late SyncOrchestrator orchestrator;

    setUp(() {
      orchestrator = SyncOrchestrator();
    });

    test('newer updatedAt wins', () {
      final local = SyncRecord(
        scope: SyncScope.favorites,
        recordId: 'r',
        revision: 1,
        updatedAt: t0,
      );
      final remote = local.copyWith(revision: 2, updatedAt: t1);
      expect(orchestrator.resolve(local, remote), SyncConflictWinner.remote);
      expect(orchestrator.resolve(remote, local), SyncConflictWinner.local);
    });

    test('timestamp tie breaks on revision', () {
      final local = SyncRecord(
        scope: SyncScope.favorites,
        recordId: 'r',
        revision: 1,
        updatedAt: t0,
      );
      final remote = local.copyWith(revision: 5);
      expect(orchestrator.resolve(local, remote), SyncConflictWinner.remote);
      expect(
        orchestrator.resolve(local, local.copyWith()),
        SyncConflictWinner.identical,
      );
    });

    test('full tie but different tombstone converges to deletion', () {
      final live = SyncRecord(
        scope: SyncScope.favorites,
        recordId: 'r',
        revision: 2,
        updatedAt: t0,
      );
      final tombstone = live.copyWith(deleted: true);
      expect(orchestrator.resolve(live, tombstone), SyncConflictWinner.remote);
      expect(orchestrator.resolve(tombstone, live), SyncConflictWinner.local);
    });
  });

  group('outbox cycle', () {
    late SyncOrchestrator orchestrator;

    setUp(() {
      orchestrator = SyncOrchestrator();
    });

    test('upsertLocal bumps revision and queues the record', () {
      final first = orchestrator.upsertLocal(
        SyncScope.favorites,
        'track:1',
        const <String, Object?>{'title': 'One'},
        at: t0,
      );
      expect(first.revision, 1);
      final second = orchestrator.upsertLocal(
        SyncScope.favorites,
        'track:1',
        const <String, Object?>{'title': 'One (remaster)'},
        at: t1,
      );
      expect(second.revision, 2);
      expect(orchestrator.pendingPushCount(SyncScope.favorites), 1);
      expect(orchestrator.totalPendingPushCount, 1);
      expect(
        orchestrator.pendingPush(SyncScope.favorites).single.payload['title'],
        'One (remaster)',
      );
    });

    test('markDeleted writes a tombstone and hides the record from live', () {
      orchestrator.upsertLocal(
        SyncScope.playlists,
        'pl:1',
        const <String, Object?>{'name': 'Gym'},
        at: t0,
      );
      final tombstone = orchestrator.markDeleted(
        SyncScope.playlists,
        'pl:1',
        at: t1,
      );
      expect(tombstone.deleted, isTrue);
      expect(tombstone.revision, 2);
      expect(orchestrator.liveRecords(SyncScope.playlists), isEmpty);
      expect(orchestrator.pendingPushCount(SyncScope.playlists), 1);
    });

    test('acknowledgePush drains only acknowledged ids', () {
      orchestrator.upsertLocal(SyncScope.settings, 'a', const {}, at: t0);
      orchestrator.upsertLocal(SyncScope.settings, 'b', const {}, at: t0);
      orchestrator.acknowledgePush(SyncScope.settings, <String>['a']);
      expect(orchestrator.pendingPushCount(SyncScope.settings), 1);
      // Late/duplicate ack of an unknown id is a no-op.
      orchestrator.acknowledgePush(SyncScope.settings, <String>['a', 'b']);
      expect(orchestrator.pendingPushCount(SyncScope.settings), 0);
    });
  });

  group('mergeRemote', () {
    late SyncOrchestrator orchestrator;

    setUp(() {
      orchestrator = SyncOrchestrator();
    });

    test('unknown remote records are applied verbatim', () {
      final remote = SyncRecord(
        scope: SyncScope.history,
        recordId: 'h:1',
        revision: 4,
        updatedAt: t1,
        payload: const <String, Object?>{'track': 'x'},
      );
      final result = orchestrator.mergeRemote(SyncScope.history, [remote]);
      expect(result.appliedFromRemote, [remote]);
      expect(result.conflictsResolved, 0);
      expect(orchestrator.recordFor(SyncScope.history, 'h:1'), remote);
    });

    test('remote win supersedes a pending outbox write', () {
      orchestrator.upsertLocal(
        SyncScope.favorites,
        'track:1',
        const <String, Object?>{'title': 'Mine'},
        at: t0,
      );
      final remote = SyncRecord(
        scope: SyncScope.favorites,
        recordId: 'track:1',
        revision: 8,
        updatedAt: t2,
        payload: const <String, Object?>{'title': 'Theirs'},
      );
      final result = orchestrator.mergeRemote(SyncScope.favorites, [remote]);
      expect(result.appliedFromRemote.single.payload['title'], 'Theirs');
      expect(result.conflictsResolved, 1);
      // The losing local write must not be resurrected by the next push.
      expect(orchestrator.pendingPushCount(SyncScope.favorites), 0);
    });

    test('local win keeps the outbox entry alive for push', () {
      orchestrator.upsertLocal(
        SyncScope.favorites,
        'track:1',
        const <String, Object?>{'title': 'Mine'},
        at: t2,
      );
      final remote = SyncRecord(
        scope: SyncScope.favorites,
        recordId: 'track:1',
        revision: 1,
        updatedAt: t0,
        payload: const <String, Object?>{'title': 'Theirs'},
      );
      final result = orchestrator.mergeRemote(SyncScope.favorites, [remote]);
      expect(result.hasChanges, isFalse);
      expect(result.keptLocal, ['track:1']);
      expect(orchestrator.pendingPushCount(SyncScope.favorites), 1);
    });

    test('server revision watermark tracks the highest seen revision', () {
      expect(orchestrator.serverRevisionWatermark(SyncScope.history), isNull);
      orchestrator.mergeRemote(SyncScope.history, <SyncRecord>[
        SyncRecord(
          scope: SyncScope.history,
          recordId: 'a',
          revision: 3,
          updatedAt: t0,
        ),
        SyncRecord(
          scope: SyncScope.history,
          recordId: 'b',
          revision: 7,
          updatedAt: t1,
        ),
      ]);
      expect(orchestrator.serverRevisionWatermark(SyncScope.history), 7);
      // A lower batch must not rewind the watermark.
      orchestrator.mergeRemote(SyncScope.history, <SyncRecord>[
        SyncRecord(
          scope: SyncScope.history,
          recordId: 'c',
          revision: 2,
          updatedAt: t1,
        ),
      ]);
      expect(orchestrator.serverRevisionWatermark(SyncScope.history), 7);
    });
  });

  group('state export/import', () {
    test('outbox survives a restart round trip', () {
      final first = SyncOrchestrator();
      first.upsertLocal(
        SyncScope.favorites,
        'track:9',
        const <String, Object?>{'title': 'Offline edit'},
        at: t0,
      );
      first.mergeRemote(SyncScope.favorites, <SyncRecord>[
        SyncRecord(
          scope: SyncScope.favorites,
          recordId: 'track:10',
          revision: 12,
          updatedAt: t1,
        ),
      ]);

      final restored = SyncOrchestrator()..importState(first.exportState());
      expect(
        restored.serverRevisionWatermark(SyncScope.favorites),
        12,
      );
      expect(restored.pendingPushCount(SyncScope.favorites), 1);
      final pending = restored.pendingPush(SyncScope.favorites).single;
      expect(pending.recordId, 'track:9');
      expect(pending.payload['title'], 'Offline edit');
    });

    test('import tolerates garbage', () {
      final orchestrator = SyncOrchestrator()
        ..importState(const <String, Object?>{
          'watermarks': <String, Object?>{'favorites': 'not-a-number'},
          'outbox': <String, Object?>{
            'favorites': <Object?>['junk', 42],
          },
        });
      expect(orchestrator.totalPendingPushCount, 0);
    });
  });

  group('SyncSnapshot', () {
    test('isActive only for engaged states', () {
      const disabled = SyncSnapshot(status: SyncStatus.disabled);
      const syncing = SyncSnapshot(status: SyncStatus.syncing);
      expect(disabled.isActive, isFalse);
      expect(syncing.isActive, isTrue);
      expect(syncing.copyWith(lastError: 'boom').lastError, 'boom');
    });
  });
}
