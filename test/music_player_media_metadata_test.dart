import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/music_player_service.dart';

void main() {
  const media = PlayableMedia(
    id: 'track-1',
    source: '/music/track.flac',
    title: 'Track',
    artist: 'Artist',
    bitDepth: 24,
    sampleRate: 96000,
    bitrate: 2860,
    format: 'flac',
    explicit: true,
  );

  test('queue media exposes technical quality to Now Playing immediately', () {
    final metadata = playbackAudioMetadataFromMediaItem(media.toMediaItem());

    expect(metadata, {
      'bit_depth': 24,
      'sample_rate': 96000,
      'bitrate': 2860,
      'format': 'flac',
      'explicit': true,
    });
  });

  test('persisted playback keeps technical quality across app restarts', () {
    final restored = PlayableMedia.fromJson(media.toJson());

    expect(restored, isNotNull);
    expect(restored!.bitDepth, 24);
    expect(restored.sampleRate, 96000);
    expect(restored.bitrate, 2860);
    expect(restored.format, 'flac');
    expect(restored.explicit, isTrue);
  });

  test('stream URL expiry survives persistence and reaches the media item', () {
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(1_900_000_000_000);
    final streamed = PlayableMedia(
      id: 'track-2',
      source: 'https://cdn.example/signed.m4a',
      title: 'Stream',
      artist: 'Artist',
      providerId: 'soundcloud',
      expiresAt: expiresAt,
    );

    final restored = PlayableMedia.fromJson(streamed.toJson());
    expect(restored, isNotNull);
    expect(restored!.expiresAt, expiresAt);
    expect(restored.providerId, 'soundcloud');
    expect(restored.isRemoteHttp, isTrue);

    final item = streamed.toMediaItem();
    expect(item.extras?['expires_at_ms'], expiresAt.millisecondsSinceEpoch);
    expect(item.extras?['provider_id'], 'soundcloud');

    // Local files never carry an expiry.
    expect(media.toJson().containsKey('expiresAtMs'), isFalse);
    expect(PlayableMedia.fromJson(media.toJson())!.expiresAt, isNull);
  });

  test('malformed optional persisted metadata falls back without throwing', () {
    final restored = PlayableMedia.fromJson({
      'id': 7,
      'source': '/music/track.flac',
      'title': true,
      'artist': ['Artist'],
      'durationMs': '180000',
      'bitDepth': '24',
      'artUri': 'not a URL',
    });

    expect(restored, isNotNull);
    expect(restored!.id, '7');
    expect(restored.title, 'true');
    expect(restored.duration, const Duration(minutes: 3));
    expect(restored.bitDepth, 24);
    expect(restored.artUri, isNull);
  });

  test('file probe cannot erase valid queue quality with empty values', () {
    final merged = mergePlaybackFileMetadata(
      playbackAudioMetadataFromMediaItem(media.toMediaItem()),
      {'title': 'Track', 'bit_depth': 0, 'sample_rate': null, 'format': ''},
    );

    expect(merged['bit_depth'], 24);
    expect(merged['sample_rate'], 96000);
    expect(merged['format'], 'flac');
    expect(merged['title'], 'Track');
  });

  test('restored playback starts at its persisted position', () {
    const savedPosition = Duration(minutes: 1, seconds: 23);

    expect(
      normalizedPlaybackResumePosition(
        savedPosition,
        duration: const Duration(minutes: 4),
      ),
      savedPosition,
    );
  });

  test('a completed persisted position restarts safely from zero', () {
    expect(
      normalizedPlaybackResumePosition(
        const Duration(minutes: 4),
        duration: const Duration(minutes: 4),
      ),
      Duration.zero,
    );
  });

  test('cold-start metadata read retries thrown and reported errors', () async {
    var calls = 0;

    final metadata = await readPlaybackFileMetadataWithRetry(
      '/music/track.flac',
      retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
      reader: (path) async {
        calls++;
        if (calls == 1) throw StateError('backend not ready');
        if (calls == 2) return {'error': 'file temporarily unavailable'};
        return {'lyrics': '[00:01.00]Ready'};
      },
    );

    expect(calls, 3);
    expect(metadata['lyrics'], '[00:01.00]Ready');
  });

  test('successful metadata without lyrics is not retried', () async {
    var calls = 0;

    final metadata = await readPlaybackFileMetadataWithRetry(
      '/music/instrumental.flac',
      retryDelays: const [Duration.zero, Duration.zero, Duration.zero],
      reader: (path) async {
        calls++;
        return {'title': 'Instrumental'};
      },
    );

    expect(calls, 1);
    expect(metadata['title'], 'Instrumental');
  });
}
