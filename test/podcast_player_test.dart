import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';
import 'package:spotiflac_android/ecosystem/podcasts/podcast_player.dart';

void main() {
  group('speed handling', () {
    test('clamps to the supported range', () {
      expect(clampPodcastSpeed(0.1), 0.5);
      expect(clampPodcastSpeed(9.0), 3.0);
      expect(clampPodcastSpeed(1.25), 1.25);
      expect(clampPodcastSpeed(double.nan), 1.0);
    });

    test('cycling advances through presets and wraps around', () {
      expect(nextPodcastSpeed(1.0), 1.1);
      expect(nextPodcastSpeed(1.1), 1.25);
      expect(nextPodcastSpeed(3.0), 0.5);
    });

    test('cycling from an off-preset value snaps to the next preset up', () {
      expect(nextPodcastSpeed(1.3), 1.5);
    });
  });

  group('PodcastPlaybackSettings', () {
    test('round-trips through JSON', () {
      const original = PodcastPlaybackSettings(
        speed: 1.5,
        skipBack: Duration(seconds: 10),
        skipForward: Duration(seconds: 45),
        skipSilence: true,
      );
      final restored = PodcastPlaybackSettings.fromJson(original.toJson());

      expect(restored.speed, 1.5);
      expect(restored.skipBack, const Duration(seconds: 10));
      expect(restored.skipForward, const Duration(seconds: 45));
      expect(restored.skipSilence, isTrue);
    });

    test('uses podcast-conventional defaults when fields are absent', () {
      final settings = PodcastPlaybackSettings.fromJson(
        const <String, Object?>{},
      );
      expect(settings.speed, 1.0);
      expect(settings.skipBack, const Duration(seconds: 15));
      expect(settings.skipForward, const Duration(seconds: 30));
      expect(settings.skipSilence, isFalse);
    });

    test('an out-of-range persisted speed is clamped on read', () {
      final settings = PodcastPlaybackSettings.fromJson(
        const <String, Object?>{'speed': 99},
      );
      expect(settings.speed, 3.0);
    });
  });

  group('SilenceSkipPolicy', () {
    const ranges = <SilentRange>[
      SilentRange(
        start: Duration(seconds: 10),
        end: Duration(seconds: 20),
      ),
      SilentRange(
        start: Duration(seconds: 60),
        end: Duration(seconds: 61),
      ),
    ];

    test('returns nothing while disabled', () {
      const policy = SilenceSkipPolicy(silentRanges: ranges);
      expect(policy.skipTargetFor(const Duration(seconds: 12)), isNull);
    });

    test('jumps to the end of the silent range it is inside', () {
      const policy = SilenceSkipPolicy(enabled: true, silentRanges: ranges);
      expect(
        policy.skipTargetFor(const Duration(seconds: 12)),
        const Duration(seconds: 20),
      );
    });

    test('leaves audible positions alone', () {
      const policy = SilenceSkipPolicy(enabled: true, silentRanges: ranges);
      expect(policy.skipTargetFor(const Duration(seconds: 5)), isNull);
      expect(policy.skipTargetFor(const Duration(seconds: 30)), isNull);
    });

    test('ignores gaps shorter than the minimum skip', () {
      const policy = SilenceSkipPolicy(enabled: true, silentRanges: ranges);
      // The 60..61s range is only 1s, below the 2s default.
      expect(policy.skipTargetFor(const Duration(seconds: 60)), isNull);
    });

    test('the range end is exclusive', () {
      const policy = SilenceSkipPolicy(enabled: true, silentRanges: ranges);
      expect(policy.skipTargetFor(const Duration(seconds: 20)), isNull);
    });
  });

  group('playableFromEpisode', () {
    final episode = PodcastEpisode(
      episodeKey: 'key',
      feedUrl: 'https://a/f.xml',
      guid: 'g',
      title: 'Episode title',
      audioUrl: 'https://a/e.mp3',
      imageUrl: 'https://a/e.jpg',
      duration: const Duration(minutes: 42),
      addedAt: DateTime.utc(2026),
    );

    test('maps an episode onto the shared engine media value', () {
      final media = playableFromEpisode(episode, showTitle: 'Signal & Noise');

      expect(media.id, 'key');
      expect(media.source, 'https://a/e.mp3');
      expect(media.title, 'Episode title');
      expect(media.artist, 'Signal & Noise');
      expect(media.artUri, 'https://a/e.jpg');
      expect(media.duration, const Duration(minutes: 42));
    });

    test('tags the item as a podcast so the UI shows podcast controls', () {
      final media = playableFromEpisode(episode);
      expect(media.playbackMode, 'podcast');
      expect(media.providerId, 'podcast');
    });

    test('prefers the downloaded file so offline playback works', () {
      final downloaded = episode.copyWith(
        filePath: '/data/e.mp3',
        downloadState: EpisodeDownloadState.downloaded,
      );
      expect(playableFromEpisode(downloaded).source, '/data/e.mp3');
    });

    test('an unknown duration is left null rather than sent as zero', () {
      final unknown = episode.copyWith(duration: Duration.zero);
      expect(playableFromEpisode(unknown).duration, isNull);
    });
  });
}
