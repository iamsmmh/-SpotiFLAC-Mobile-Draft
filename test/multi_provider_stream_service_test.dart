import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/multi_provider_stream_service.dart';

void main() {
  group('StreamProviderInfo', () {
    test('registers all eight ecosystem sources', () {
      expect(StreamProviderInfo.all, hasLength(8));
      expect(
        StreamProviderInfo.all.map((i) => i.id).toSet(),
        StreamProviderId.values.toSet(),
      );
    });

    test('labels are non-empty and lossless flags are consistent', () {
      for (final info in StreamProviderInfo.all) {
        expect(info.displayName, isNotEmpty);
        expect(info.shortName, isNotEmpty);
        expect(info.maxTierLabel, isNotEmpty);
      }
      expect(
        StreamProviderInfo.of(StreamProviderId.qobuz).nativeLossless,
        isTrue,
      );
      expect(
        StreamProviderInfo.of(StreamProviderId.youtube).nativeLossless,
        isFalse,
      );
    });

    test('YouTube and SoundCloud need no credentials; HiFi services do', () {
      expect(
        StreamProviderInfo.of(StreamProviderId.youtube).requiresCredentials,
        isFalse,
      );
      expect(
        StreamProviderInfo.of(StreamProviderId.soundCloud)
            .requiresCredentials,
        isFalse,
      );
      for (final id in [
        StreamProviderId.spotify,
        StreamProviderId.appleMusic,
        StreamProviderId.tidal,
        StreamProviderId.qobuz,
        StreamProviderId.deezer,
        StreamProviderId.amazonMusic,
      ]) {
        expect(
          StreamProviderInfo.of(id).requiresCredentials,
          isTrue,
          reason: '$id should require credentials',
        );
      }
    });
  });

  group('StreamTrackRequest', () {
    test('builds from a Track and forms a title+artist query', () {
      const track = Track(
        id: 't1',
        name: 'Bohemian Rhapsody',
        artistName: 'Queen',
        albumName: 'A Night at the Opera',
        isrc: 'GBUM71029604',
        duration: 354,
      );
      final req = StreamTrackRequest.fromTrack(track);
      expect(req.title, 'Bohemian Rhapsody');
      expect(req.artist, 'Queen');
      expect(req.isrc, 'GBUM71029604');
      expect(req.searchQuery, 'Bohemian Rhapsody Queen');
    });

    test('ResolvedStream annotates the fallback flag and media extras', () {
      final stream = ResolvedStream(
        uri: Uri.parse('https://example.com/audio.opus'),
        provider: StreamProviderId.youtube,
        qualityLabel: 'Opus 160kbps',
        matchedTitle: 'Bohemian Rhapsody',
        viaFallback: true,
      );
      expect(stream.viaFallback, isTrue);
      final media = stream.toMediaItem();
      expect(media.id, 'https://example.com/audio.opus');
      expect(media.extras?['provider'], 'youtube');
      expect(media.extras?['viaFallback'], isTrue);
    });
  });

  group('Universal fallback ordering', () {
    test('credentialed handlers return null without tokens (fall through)',
        () async {
      final apple = AppleMusicStreamHandler();
      final tidal = TidalStreamHandler();
      final qobuz = QobuzStreamHandler();
      final amazon = AmazonMusicStreamHandler();
      const req = StreamTrackRequest(
        title: 'Some Song',
        artist: 'Some Artist',
      );
      expect(await apple.resolve(req), isNull);
      expect(await tidal.resolve(req), isNull);
      expect(await qobuz.resolve(req), isNull);
      expect(await amazon.resolve(req), isNull);
    });

    test('Spotify handler returns the 30s preview when metadata carries it',
        () async {
      final handler = SpotifyStreamHandler();
      const req = StreamTrackRequest(
        title: 'Track',
        artist: 'Artist',
        previewUrl: 'https://p.scdn.co/mp3-preview/abcdef',
      );
      final resolved = await handler.resolve(req);
      expect(resolved, isNotNull);
      expect(resolved!.isPreview, isTrue);
      expect(resolved.provider, StreamProviderId.spotify);
    });

    test('Spotify handler returns null when no preview URL exists',
        () async {
      final handler = SpotifyStreamHandler();
      const req = StreamTrackRequest(title: 'Track', artist: 'Artist');
      expect(await handler.resolve(req), isNull);
    });
  });
}
