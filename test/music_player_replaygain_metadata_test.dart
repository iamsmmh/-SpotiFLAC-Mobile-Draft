import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/services/music_player_service.dart';

void main() {
  test('stream ReplayGain metadata survives persistence round-trip', () {
    const media = PlayableMedia(
      id: 't1',
      source: 'https://example.test/stream.flac',
      title: 'Track',
      artist: 'Artist',
      format: 'FLAC',
      bitDepth: 24,
      sampleRate: 96000,
      trackGainDb: -8.5,
      albumGainDb: -7.2,
      trackPeak: 0.988,
    );
    final restored = PlayableMedia.fromJson(media.toJson());
    expect(restored, isNotNull);
    expect(restored!.trackGainDb, closeTo(-8.5, 1e-9));
    expect(restored.albumGainDb, closeTo(-7.2, 1e-9));
    expect(restored.trackPeak, closeTo(0.988, 1e-9));
  });

  test('queue metadata carries gain for remote streams', () {
    const media = PlayableMedia(
      id: 't1',
      source: 'https://example.test/stream.flac',
      title: 'Track',
      artist: 'Artist',
      trackGainDb: -8.5,
      trackPeak: 0.988,
    );
    final extras = media.toMediaItem().extras ?? const {};
    expect(extras['track_gain_db'], closeTo(-8.5, 1e-9));
    expect(extras['track_peak'], closeTo(0.988, 1e-9));
  });
}
