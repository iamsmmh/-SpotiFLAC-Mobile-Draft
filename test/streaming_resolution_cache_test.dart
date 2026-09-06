import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/multi_provider_stream_service.dart';

ResolvedStream _stream(
  String uri, {
  DateTime? expiresAt,
  bool preview = false,
}) => ResolvedStream(
  uri: Uri.parse(uri),
  provider: StreamProviderId.youtube,
  qualityLabel: 'Opus 160kbps',
  matchedTitle: 'Song',
  expiresAt: expiresAt,
  isPreview: preview,
);

void main() {
  var clock = DateTime(2026, 1, 1);
  StreamResolutionCache cache({int maxEntries = 4}) => StreamResolutionCache(
    maxEntries: maxEntries,
    clock: () => clock,
  );

  setUp(() {
    clock = DateTime(2026, 1, 1);
  });

  group('positive entries', () {
    test('round-trip a resolved stream', () {
      final c = cache();
      c.put('k', _stream('https://cdn/a'));
      final hit = c.get('k');
      expect(hit, isNotNull);
      expect(hit!.uri.toString(), 'https://cdn/a');
    });

    test('unknown keys miss without throwing', () {
      expect(cache().get('nope'), isNull);
    });

    test('expire with the signed URL they carry', () {
      final c = cache();
      c.put('k', _stream('https://cdn/a', expiresAt: clock.add(const Duration(minutes: 30))));

      // 20 minutes later: still valid (the 5-minute refresh lead has not been
      // reached yet).
      clock = clock.add(const Duration(minutes: 20));
      expect(c.get('k'), isNotNull);

      // Past the lead time the entry is dropped so playback re-resolves
      // instead of starting on a URL that dies mid-buffer.
      clock = clock.add(const Duration(minutes: 10));
      expect(c.get('k'), isNull);
    });

    test('entries without an expiry fall back to a 30 minute TTL', () {
      final c = cache();
      c.put('k', _stream('https://cdn/a'));
      clock = clock.add(const Duration(minutes: 29));
      expect(c.get('k'), isNotNull);
      clock = clock.add(const Duration(minutes: 2));
      expect(c.get('k'), isNull);
    });

    test('LRU eviction keeps the cache bounded', () {
      final c = cache(maxEntries: 3);
      c.put('a', _stream('https://cdn/a'));
      c.put('b', _stream('https://cdn/b'));
      c.put('c', _stream('https://cdn/c'));
      // Touching 'a' makes it the most recently used, so 'b' is the victim.
      expect(c.get('a'), isNotNull);
      c.put('d', _stream('https://cdn/d'));

      expect(c.length, 3);
      expect(c.keys, isNot(contains('b')));
      expect(c.get('a'), isNotNull);
      expect(c.get('d'), isNotNull);
    });
  });

  group('negative entries', () {
    test('remember a failure briefly so providers are not hammered', () {
      final c = cache();
      c.putNegative('k', 'No source');
      expect(c.negativeError('k'), 'No source');
      expect(c.get('k'), isNull);
    });

    test('expire after the negative TTL so a later retry can succeed', () {
      final c = cache();
      c.putNegative('k', 'No source');
      clock = clock.add(const Duration(seconds: 46));
      expect(c.negativeError('k'), isNull);
    });

    test('a success replaces a cached failure', () {
      final c = cache();
      c.putNegative('k', 'No source');
      c.put('k', _stream('https://cdn/a'));
      expect(c.negativeError('k'), isNull);
      expect(c.get('k'), isNotNull);
    });

    test('a failure replaces a cached success', () {
      final c = cache();
      c.put('k', _stream('https://cdn/a'));
      c.putNegative('k', 'No source');
      expect(c.get('k'), isNull);
      expect(c.negativeError('k'), 'No source');
    });
  });

  group('invalidation', () {
    test('invalidate drops one key, clear drops everything', () {
      final c = cache();
      c.put('a', _stream('https://cdn/a'));
      c.put('b', _stream('https://cdn/b'));
      c.invalidate('a');
      expect(c.get('a'), isNull);
      expect(c.get('b'), isNotNull);

      c.clear();
      expect(c.length, 0);
    });
  });
}
