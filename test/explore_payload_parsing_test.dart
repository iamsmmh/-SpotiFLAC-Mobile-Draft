import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/providers/explore_provider.dart';

void main() {
  test('home-feed models tolerate malformed optional extension fields', () {
    final section = ExploreSection.fromJson({
      'uri': 123,
      'title': true,
      'items': [
        'not-a-map',
        {
          'id': 42,
          'name': true,
          'artists': ['Artist'],
          'duration_ms': '180000',
          'cover_url': 'not a URL',
          'provider_id': ' extension.example ',
        },
      ],
    });

    expect(section.uri, '123');
    expect(section.title, 'true');
    expect(section.items, hasLength(1));
    expect(section.items.single.id, '42');
    expect(section.items.single.name, 'true');
    expect(section.items.single.durationMs, 180000);
    expect(section.items.single.coverUrl, isNull);
    expect(section.items.single.providerId, 'extension.example');
  });

  test('home-feed model drops a non-list items payload', () {
    final section = ExploreSection.fromJson({
      'uri': 'home',
      'title': 'Home',
      'items': {'unexpected': true},
    });

    expect(section.items, isEmpty);
  });
}
