import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:spotiflac_android/services/search_history_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<SearchHistoryStore> newStore() async {
    return SearchHistoryStore(
      preferences: await SharedPreferences.getInstance(),
    );
  }

  group('SearchHistoryStore', () {
    test('empty store loads an empty history', () async {
      final store = await newStore();
      expect(await store.load(), isEmpty);
    });

    test('record inserts most-recent-first and preserves casing', () async {
      final store = await newStore();
      await store.record('daft punk', at: DateTime.utc(2026, 9, 1));
      final history = await store.record(
        'The Weeknd',
        at: DateTime.utc(2026, 9, 2),
      );
      expect(history.map((entry) => entry.query), <String>[
        'The Weeknd',
        'daft punk',
      ]);
    });

    test('re-recording dedupes case-insensitively and refreshes order', ()
    async {
      final store = await newStore();
      await store.record('Blinding Lights');
      await store.record('save your tears');
      final history = await store.record('  BLINDING lights ');
      expect(history.length, 2);
      expect(history.first.query, 'BLINDING lights');
      expect(history.last.query, 'save your tears');
    });

    test('blank queries are ignored', () async {
      final store = await newStore();
      expect(await store.record('   '), isEmpty);
    });

    test('history is capped at maxEntries', () async {
      final store = await newStore();
      for (var i = 0; i < SearchHistoryStore.maxEntries + 10; i++) {
        await store.record('query $i');
      }
      final history = await store.load();
      expect(history.length, SearchHistoryStore.maxEntries);
      expect(history.first.query, 'query ${SearchHistoryStore.maxEntries + 9}');
    });

    test('remove deletes case-insensitively', () async {
      final store = await newStore();
      await store.record('Radiohead');
      await store.record('Portishead');
      final history = await store.remove('radiohead');
      expect(history.map((entry) => entry.query), <String>['Portishead']);
    });

    test('clear wipes the history', () async {
      final store = await newStore();
      await store.record('tool');
      await store.clear();
      expect(await store.load(), isEmpty);
    });

    test('corrupt payloads degrade to empty history', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(SearchHistoryStore.storageKey, '{{{not-json');
      final store = SearchHistoryStore(preferences: prefs);
      expect(await store.load(), isEmpty);
      // …and junk entries inside the list are dropped individually.
      await prefs.setString(
        SearchHistoryStore.storageKey,
        '["ok query", 42, null, {"query": ""}]',
      );
      final history = await store.load();
      expect(history.map((entry) => entry.query), <String>['ok query']);
    });
  });
}
