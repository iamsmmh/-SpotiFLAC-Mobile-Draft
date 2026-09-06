import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/library_ledger_service.dart';

void main() {
  group('LedgerEntry match keys', () {
    test('ISRC wins when present and well-formed', () {
      const entry = LedgerEntry(
        title: 'Song',
        artist: 'Artist',
        isrc: 'USUM71703868',
        spotifyId: '4cOdK2wGLETKBW3PvgPWqT',
      );
      expect(entry.matchKey, 'isrc:USUM71703868');
    });

    test('Spotify id is second best, artist-title is the fallback', () {
      const withId = LedgerEntry(
        title: 'Song',
        artist: 'Artist',
        spotifyId: '4cOdK2wGLETKBW3PvgPWqT',
      );
      expect(withId.matchKey, 'sp:4cOdK2wGLETKBW3PvgPWqT');

      const bare = LedgerEntry(title: 'Song!', artist: 'The Artist');
      expect(bare.matchKey, 'ta:the artist|song');
    });

    test('feat suffix and punctuation do not change the identity', () {
      const a = LedgerEntry(title: 'Song', artist: 'Artist');
      const b = LedgerEntry(title: 'Song (feat. Someone)', artist: 'artist ');
      expect(a.matchKey, b.matchKey);
    });
  });

  group('encode/decode round trip', () {
    test('entries survive JSON round trip and unknown fields are ignored', () {
      final entries = <LedgerEntry>[
        const LedgerEntry(
          title: 'Alpha',
          artist: 'One',
          isrc: 'XXYYY1234567',
          quality: 'LOSSLESS',
          durationSeconds: 210,
        ),
        const LedgerEntry(title: 'Beta', artist: 'Two', spotifyId: '4cOdK2wGLETKBW3PvgPWqT'),
      ];

      final raw = LibraryLedgerService.encodeLedger(entries);
      // Simulate a future producer adding a field: decoding must ignore it.
      final withExtra = raw.replaceFirst(
        '"entries": [',
        '"extra": {"anything": true}, "entries": [',
      );

      final decoded = LibraryLedgerService.decodeLedger(withExtra)!;
      expect(decoded.length, 2);
      expect(decoded.first.matchKey, entries.first.matchKey);
      expect(decoded.first.durationSeconds, 210);
      expect(decoded.last.spotifyId, '4cOdK2wGLETKBW3PvgPWqT');
    });

    test('garbage and wrong formats return null', () {
      expect(LibraryLedgerService.decodeLedger('nope'), isNull);
      expect(LibraryLedgerService.decodeLedger('{"entries":[]}'), isNull);
      expect(
        LibraryLedgerService.decodeLedger('{"format":"other","entries":[]}'),
        isNull,
      );
    });
  });

  group('history rows to entries', () {
    test('skips empty titles and de-duplicates by identity (newest first)', () {
      final entries = LibraryLedgerService.entriesFromHistoryRows(<Map<String, dynamic>>[
        <String, dynamic>{
          'track_name': 'Alpha',
          'artist_name': 'One',
          'album_name': 'Album',
          'isrc': 'XXYYY1234567',
          'duration': 200,
          'quality': 'LOSSLESS',
          'downloaded_at': '2026-09-01',
        },
        <String, dynamic>{
          // Same ISRC re-download — must not create a second entry.
          'track_name': 'Alpha (remaster)',
          'artist_name': 'One',
          'isrc': 'xx-yyy-1234567',
          'duration': 205,
        },
        <String, dynamic>{'track_name': '', 'artist_name': 'Ghost'},
        <String, dynamic>{'track_name': 'Beta', 'artist_name': 'Two'},
      ]);

      expect(entries.length, 2);
      expect(entries.first.title, 'Alpha'); // sorted by display label
      expect(entries.last.title, 'Beta');
    });
  });

  group('missing diff', () {
    test('returns only imported entries absent locally, deduped', () {
      final imported = LibraryLedgerService.entriesFromHistoryRows(<Map<String, dynamic>>[
        <String, dynamic>{'track_name': 'Have', 'artist_name': 'A', 'isrc': 'AAA111222333'},
        <String, dynamic>{'track_name': 'Lack', 'artist_name': 'B', 'isrc': 'BBB111222333'},
        <String, dynamic>{'track_name': 'Lack (live)', 'artist_name': 'B', 'isrc': 'BBB111222333'},
      ]);
      final local = LibraryLedgerService.entriesFromHistoryRows(<Map<String, dynamic>>[
        <String, dynamic>{'track_name': 'Have', 'artist_name': 'A', 'isrc': 'AAA111222333'},
      ]);

      final missing = LibraryLedgerService.missingEntries(
        imported: imported,
        local: local,
      );
      expect(missing.length, 1);
      expect(missing.single.matchKey, 'isrc:BBB111222333');
    });

    test('empty local set yields the full imported list', () {
      final imported = LibraryLedgerService.entriesFromHistoryRows(<Map<String, dynamic>>[
        <String, dynamic>{'track_name': 'Only', 'artist_name': 'A'},
      ]);
      expect(
        LibraryLedgerService.missingEntries(imported: imported, local: const []).length,
        1,
      );
    });
  });

  group('openable url', () {
    test('only well-formed Spotify ids produce a link', () {
      const good = LedgerEntry(
        title: 'T',
        artist: 'A',
        spotifyId: '4cOdK2wGLETKBW3PvgPWqT',
      );
      expect(good.openableUrl, 'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT');
      const bad = LedgerEntry(title: 'T', artist: 'A', spotifyId: 'not a uri!!');
      expect(bad.openableUrl, isNull);
    });
  });
}
