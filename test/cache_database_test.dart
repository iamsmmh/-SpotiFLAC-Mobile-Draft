import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/cache/cache_database.dart';

void main() {
  group('WarmRequestRecord', () {
    test('row codec round-trip', () {
      final actual = WarmRequestRecord(
        trackKey: 'tk-1',
        url: 'https://cdn/audio.flac',
        priority: 2,
        requestedAt: DateTime.utc(2026, 9, 6, 12, 30),
        state: WarmRequestState.completed,
        bytes: 4096,
      );
      final restored = WarmRequestRecord.fromRow(actual.toRow());
      expect(restored, isNotNull);
      expect(restored!.trackKey, actual.trackKey);
      expect(restored.url, actual.url);
      expect(restored.priority, actual.priority);
      expect(restored.state, WarmRequestState.completed);
      expect(restored.bytes, 4096);
      expect(restored.requestedAt, actual.requestedAt);
    });

    test('row codec tolerates garbage', () {
      expect(WarmRequestRecord.fromRow(<String, Object?>{}), isNull);
      final defaults = WarmRequestRecord.fromRow(<String, Object?>{
        'track_key': 'tk',
      });
      expect(defaults, isNotNull);
      expect(defaults!.state, WarmRequestState.requested);
      expect(defaults.priority, 0);
      expect(defaults.bytes, 0);
    });

    test('JSON list codec round-trips and drops invalid entries', () {
      final records = <WarmRequestRecord>[
        WarmRequestRecord(
          trackKey: 'a',
          url: 'u',
          priority: 1,
          requestedAt: DateTime.utc(2026, 9, 6),
          state: WarmRequestState.requested,
        ),
        WarmRequestRecord(
          trackKey: 'b',
          url: '',
          priority: 0,
          requestedAt: DateTime.utc(2026, 9, 6),
          state: WarmRequestState.failed,
        ),
      ];
      final decoded = WarmRequestRecord.decodeList(
        WarmRequestRecord.encodeList(records),
      );
      expect(decoded.length, 2);
      expect(decoded[0].trackKey, 'a');
      expect(decoded[1].state, WarmRequestState.failed);
      expect(WarmRequestRecord.decodeList('not json'), isEmpty);
      expect(WarmRequestRecord.decodeList('[]'), isEmpty);
    });

    test('copyWith mutates only the given fields', () {
      final base = WarmRequestRecord(
        trackKey: 'a',
        url: 'u',
        priority: 1,
        requestedAt: DateTime.utc(2026, 9, 6),
        state: WarmRequestState.requested,
      );
      final done = base.copyWith(state: WarmRequestState.completed, bytes: 99);
      expect(done.state, WarmRequestState.completed);
      expect(done.bytes, 99);
      expect(done.url, 'u');
    });
  });

  group('CacheMaintenanceRecord', () {
    test('row codec round-trip', () {
      final record = CacheMaintenanceRecord(
        ranAt: DateTime.utc(2026, 9, 6, 9),
        expired: 2,
        evicted: 3,
        freedBytes: 123456,
      );
      final restored = CacheMaintenanceRecord.fromRow(record.toRow());
      expect(restored, isNotNull);
      expect(restored!.expired, 2);
      expect(restored.evicted, 3);
      expect(restored.freedBytes, 123456);
      expect(restored.ranAt, record.ranAt);
    });

    test('row codec rejects missing timestamps', () {
      expect(
        CacheMaintenanceRecord.fromRow(<String, Object?>{'expired': 1}),
        isNull,
      );
    });
  });

  group('WarmRequestState', () {
    test('parses names leniently', () {
      expect(_state('completed'), WarmRequestState.completed);
      expect(_state('bogus'), WarmRequestState.requested);
      expect(_state(null), WarmRequestState.requested);
    });
  });
}

// Re-exported through the library's top-level function for the test above.
WarmRequestState _state(Object? name) {
  final record = WarmRequestRecord.fromRow(<String, Object?>{
    'track_key': 'x',
    'state': name,
  });
  return record!.state;
}
