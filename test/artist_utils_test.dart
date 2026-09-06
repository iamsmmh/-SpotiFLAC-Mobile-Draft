import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/utils/artist_utils.dart';

void main() {
  test('primary artist prefers the first album artist', () {
    expect(
      primaryArtistName(
        'Track Artist, Guest Artist',
        albumArtist: 'Album Artist & Collaborator',
      ),
      'Album Artist',
    );
  });

  test('primary artist handles provider separator variants', () {
    expect(primaryArtistName('One; Two & Three'), 'One');
    expect(primaryArtistName('One feat. Two'), 'One');
    expect(primaryArtistName('AC/DC'), 'AC/DC');
    expect(
      primaryArtistName('Actual Artist, Guest', albumArtist: 'Various Artists'),
      'Actual Artist',
    );
  });
}
