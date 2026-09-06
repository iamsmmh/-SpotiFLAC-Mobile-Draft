import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/data/extension_payload.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';

void main() {
  group('ExtensionPayloadDecoder', () {
    const payload = <String, Object?>{
      'url': 'https://cdn.example.com/track.flac',
      'bitrate': 320,
      'bitrate_text': '320',
      'premium': true,
      'premium_text': 'false',
      'empty': '',
      'tags': <Object?>['a', 'b', 3],
      'meta': <Object?, Object?>{'k': 'v'},
    };

    test('extracts typed values with strictness where required', () {
      const decoder = ExtensionPayloadDecoder(payload);
      expect(decoder.requireString('url'), 'https://cdn.example.com/track.flac');
      expect(decoder.optString('empty'), isNull);
      expect(decoder.optString('missing'), isNull);
      expect(decoder.optInt('bitrate'), 320);
      expect(decoder.optInt('bitrate_text'), 320);
      expect(decoder.optBool('premium'), isTrue);
      expect(decoder.optBool('premium_text'), isFalse);
      expect(decoder.optStringList('tags'), <String>['a', 'b']);
      expect(decoder.optMap('meta'), <String, Object?>{'k': 'v'});
    });

    test('malformed payloads become attributed format errors', () {
      const decoder = ExtensionPayloadDecoder(payload, providerId: 'deezer');
      expect(
        () => decoder.requireString('bitrate'),
        throwsA(
          isA<CoreError>()
              .having((e) => e.category, 'category', CoreErrorCategory.format)
              .having((e) => e.providerId, 'providerId', 'deezer'),
        ),
      );
      expect(() => decoder.requireString('missing'), throwsA(isA<CoreError>()));
      expect(() => decoder.optInt('url'), throwsA(isA<CoreError>()));
      expect(() => decoder.optBool('bitrate'), throwsA(isA<CoreError>()));
    });
  });

  group('normalizePlatformException', () {
    test('passes CoreError through', () {
      const original = CoreError(
        category: CoreErrorCategory.storage,
        message: 'x',
      );
      expect(
        identical(normalizePlatformException(original), original),
        isTrue,
      );
    });

    test('maps channel codes to the taxonomy', () {
      CoreError coreErrorFor(String code, [String? message]) =>
          normalizePlatformException(
            PlatformException(code: code, message: message),
          );

      expect(
        coreErrorFor('permission_denied').category,
        CoreErrorCategory.permission,
      );
      expect(
        coreErrorFor('cancelled').category,
        CoreErrorCategory.cancelled,
      );
      expect(
        coreErrorFor('not_found').category,
        CoreErrorCategory.notFound,
      );
      expect(
        coreErrorFor('unavailable', 'network unreachable').category,
        CoreErrorCategory.network,
      );
      expect(
        coreErrorFor('unknown_code_xyz').category,
        CoreErrorCategory.unknown,
      );
    });

    test('cancellation wins over other keywords', () {
      final error = normalizePlatformException(
        PlatformException(code: 'cancelled', message: 'user cancelled'),
      );
      expect(error.category, CoreErrorCategory.cancelled);
    });

    test('wraps non-platform errors via normalizeCoreError', () {
      final error = normalizePlatformException(StateError('boom'));
      expect(error.category, CoreErrorCategory.unknown);
      expect(error.cause, isA<StateError>());
    });
  });
}
