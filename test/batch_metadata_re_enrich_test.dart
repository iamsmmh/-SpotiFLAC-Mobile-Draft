import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/services/batch_metadata_re_enrich.dart';
import 'package:spotiflac_android/services/library_database.dart';

LocalLibraryItem _item({
  String? albumArtist,
  String? isrc,
  String? genre,
  String? coverPath = '/music/cover.jpg',
}) {
  return LocalLibraryItem(
    id: 'track-1',
    trackName: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    albumArtist: albumArtist,
    filePath: '/music/song.flac',
    coverPath: coverPath,
    scannedAt: DateTime(2026),
    isrc: isrc,
    trackNumber: 1,
    totalTracks: 10,
    discNumber: 1,
    totalDiscs: 1,
    duration: 180,
    releaseDate: '2026-01-02',
    genre: genre,
  );
}

void main() {
  test(
    'missing mode returns granular keys and preserves populated neighbors',
    () {
      final fields = missingReEnrichFields(_item());

      expect(fields, containsAll(<String>['album_artist', 'isrc', 'genre']));
      expect(fields, isNot(contains('basic_tags')));
      expect(fields, isNot(contains('track_name')));
      expect(fields, isNot(contains('release_date')));
      expect(fields, isNot(contains('cover')));
    },
  );

  test('ISRC-only mode never selects the full release-info group', () {
    final fields = const ReEnrichFieldSelection(
      mode: ReEnrichBatchMode.isrcOnly,
    ).updateFieldsFor(_item());

    expect(fields, const ['isrc']);
  });

  test('resolved preview metadata is reused without another online search', () {
    final request = buildBatchReEnrichRequest(
      item: _item(),
      settings: const AppSettings(),
      updateFields: const ['isrc'],
      resolvedMetadata: const {
        'isrc': 'USRC17607839',
        'spotify_id': 'resolved-id',
      },
    );

    expect(request['search_online'], isFalse);
    expect(request['update_fields'], const ['isrc']);
    expect(request['isrc'], 'USRC17607839');
    expect(request['spotify_id'], 'resolved-id');
  });

  test('review only includes values that would actually change', () {
    final changes = buildReEnrichMetadataChanges(
      _item(isrc: 'OLD'),
      const {'track_name': 'Song', 'artist_name': 'Artist', 'isrc': 'NEW'},
      const ['isrc'],
    );

    expect(changes, hasLength(1));
    expect(changes.single.field, 'isrc');
    expect(changes.single.oldValue, 'OLD');
    expect(changes.single.newValue, 'NEW');
  });
}
