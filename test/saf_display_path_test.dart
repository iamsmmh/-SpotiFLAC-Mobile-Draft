import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/saf_display_path.dart';

void main() {
  group('SAF display paths', () {
    test('normalizes an external-storage document URI', () {
      const uri =
          'content://com.android.externalstorage.documents/'
          'document/primary%3AMusic%2FSpotiFLAC%2FSong.flac';

      expect(
        formatSafUriForDisplay(uri),
        '/storage/emulated/0/Music/SpotiFLAC/Song.flac',
      );
    });

    test('rebuilds a friendly path for an opaque SAF document ID', () {
      expect(
        buildSafFileDisplayPath(
          pathOrUri:
              'content://com.android.providers.media.documents/'
              'document/audio%3A1000192991',
          treeUri:
              'content://com.android.externalstorage.documents/'
              'tree/primary%3AMusic%2FSpotiFLAC',
          treeDisplayPath: '/storage/emulated/0/Music/SpotiFLAC',
          relativeDir: 'Falling In Reverse/Popular Monster',
          fileName: '01 - Popular Monster.flac',
        ),
        '/storage/emulated/0/Music/SpotiFLAC/'
        'Falling In Reverse/Popular Monster/01 - Popular Monster.flac',
      );
    });

    test('does not present a MediaStore ID as an SD-card path', () {
      const uri =
          'content://com.android.providers.media.documents/'
          'document/audio%3A12345';
      expect(formatSafUriForDisplay(uri), uri);
    });

    test('keeps ordinary filesystem paths unchanged', () {
      const path = '/storage/emulated/0/Music/Song.flac';
      expect(formatSafUriForDisplay(path), path);
      expect(buildSafFileDisplayPath(pathOrUri: path), path);
    });
  });
}
