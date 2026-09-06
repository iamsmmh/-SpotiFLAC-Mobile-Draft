import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/core/data/bridge_extension_driver.dart';
import 'package:spotiflac_android/core/data/ffmpeg_audio_transcoder.dart';
import 'package:spotiflac_android/core/data/platform_metadata_pipeline.dart';
import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';

void main() {
  group('GomobileExtensionDriver', () {
    final request = ExtensionRequest(
      kind: ExtensionRequestKind.search,
      track: const TrackRef(id: 't', name: 'Song', artistName: 'Artist'),
    );

    test('returns a defensive copy of the provider payload', () async {
      final mutable = <String, Object?>{'url': 'https://x'};
      final driver = GomobileExtensionDriver(
        providerId: 'deezer',
        invoker: (req) async => mutable,
      );
      final payload = await driver.resolve(
        request,
        CancellationTokenSource().token,
      );
      expect(payload['url'], 'https://x');
      mutable['url'] = 'tampered';
      expect(
        payload['url'],
        'https://x',
        reason: 'payload must be isolated from provider-side mutation',
      );
    });

    test('attributes CoreError failures to the provider', () async {
      final driver = GomobileExtensionDriver(
        providerId: 'qobuz',
        invoker: (req) async => throw const CoreError(
          category: CoreErrorCategory.rateLimited,
          message: 'slow down',
        ),
      );
      await expectLater(
        driver.resolve(request, CancellationTokenSource().token),
        throwsA(
          isA<CoreError>()
              .having((e) => e.category, 'category',
                  CoreErrorCategory.rateLimited)
              .having((e) => e.providerId, 'providerId', 'qobuz'),
        ),
      );
    });

    test('normalizes PlatformException and unknown throws', () async {
      final channelDriver = GomobileExtensionDriver(
        providerId: 'tidal',
        invoker: (req) async => throw PlatformException(
          code: 'permission_denied',
          message: 'SAF grant revoked',
        ),
      );
      await expectLater(
        channelDriver.resolve(request, CancellationTokenSource().token),
        throwsA(
          isA<CoreError>().having((e) => e.category, 'category',
              CoreErrorCategory.permission),
        ),
      );

      final explodingDriver = GomobileExtensionDriver(
        providerId: 'js',
        invoker: (req) async => throw StateError('goja runtime'),
      );
      await expectLater(
        explodingDriver.resolve(request, CancellationTokenSource().token),
        throwsA(
          isA<CoreError>()
              .having(
                (e) => e.category,
                'category',
                CoreErrorCategory.provider,
              )
              .having((e) => e.providerId, 'providerId', 'js'),
        ),
      );
    });

    test('aborts before invocation when the token is already cancelled',
        () async {
      var invoked = false;
      final driver = GomobileExtensionDriver(
        providerId: 'noop',
        invoker: (req) async {
          invoked = true;
          return const <String, Object?>{};
        },
      );
      final source = CancellationTokenSource()..cancel('user');
      await expectLater(
        driver.resolve(request, source.token),
        throwsA(isA<JobCancelledException>()),
      );
      expect(invoked, isFalse);
    });

    test('decoderFor keeps the provider attribution on format errors', () {
      final driver = GomobileExtensionDriver(
        providerId: 'deezer',
        invoker: (req) async => const <String, Object?>{},
      );
      final decoder = driver.decoderFor(
        const ExtensionPayload(<String, Object?>{'n': 42}),
      );
      expect(decoder.providerId, 'deezer');
    });
  });

  group('PlatformMetadataPipeline', () {
    test('identity enrich maps the track into an envelope', () async {
      const pipeline = PlatformMetadataPipeline();
      final envelope = await pipeline.enrich(
        const TrackRef(
          id: 'id',
          name: 'Title',
          artistName: 'Artist',
          albumName: 'Album',
          trackNumber: 3,
          isrc: 'US123',
        ),
        CancellationTokenSource().token,
      );
      expect(envelope.title, 'Title');
      expect(envelope.artist, 'Artist');
      expect(envelope.album, 'Album');
      expect(envelope.trackNumber, 3);
      expect(envelope.isrc, 'US123');
    });

    test('respects cancellation before doing any work', () async {
      const pipeline = PlatformMetadataPipeline();
      final source = CancellationTokenSource()..cancel('user');
      await expectLater(
        pipeline.enrich(
          const TrackRef(id: 'i', name: 'n', artistName: 'a'),
          source.token,
        ),
        throwsA(isA<JobCancelledException>()),
      );
    });
  });

  group('metadataEnvelopeToTagMap', () {
    test('emits only present, non-empty tags', () {
      final tags = metadataEnvelopeToTagMap(
        const MetadataEnvelope(
          title: 'T',
          artist: 'A',
          album: 'Al',
          trackNumber: 2,
          discNumber: 0, // invalid → omitted
          isrc: 'ISRC',
          releaseDate: '2024-01-01',
        ),
      );
      expect(tags, <String, String>{
        'title': 'T',
        'artist': 'A',
        'album': 'Al',
        'track_number': '2',
        'isrc': 'ISRC',
        'release_date': '2024-01-01',
      });
      expect(tags.containsKey('album_artist'), isFalse);
      expect(tags.containsKey('disc_number'), isFalse);
    });
  });

  group('fileExtensionOf', () {
    test('extracts lowercase extensions', () {
      expect(fileExtensionOf('/music/Song.FLAC'), 'flac');
      expect(fileExtensionOf('nested.dir/file.mp3'), 'mp3');
      expect(fileExtensionOf('/no/extension'), '');
      expect(fileExtensionOf('trailing.'), '');
    });
  });

  group('FFmpegAudioTranscoder', () {
    test('rejects the unsupported OGG target without invoking FFmpeg',
        () async {
      const transcoder = FFmpegAudioTranscoder();
      final outcome = await transcoder.transcode(
        const TranscodeRequest(
          inputPath: '/tmp/in.m4a',
          targetFormat: TranscodeTargetFormat.ogg,
        ),
        CancellationTokenSource().token,
      );
      expect(outcome.success, isFalse);
      expect(outcome.error?.category, CoreErrorCategory.format);
      expect(outcome.error?.isRetryable, isFalse);
    });

    test('honours cancellation before any work', () async {
      const transcoder = FFmpegAudioTranscoder();
      final source = CancellationTokenSource()..cancel('user');
      await expectLater(
        transcoder.transcode(
          const TranscodeRequest(
            inputPath: '/tmp/in.m4a',
            targetFormat: TranscodeTargetFormat.flac,
          ),
          source.token,
        ),
        throwsA(isA<JobCancelledException>()),
      );
    });
  });
}
