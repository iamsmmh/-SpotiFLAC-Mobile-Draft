/// New-episode notification policy (Phase 9).
///
/// Decides *whether* to notify; the existing [NotificationService] delivers.
/// Honours [PodcastSubscription.notifyNew] so a muted feed stays silent.
library;

import 'package:spotiflac_android/ecosystem/podcasts/podcast_models.dart';

/// One notification the UI / OS layer should post.
class PodcastEpisodeAlert {
  const PodcastEpisodeAlert({
    required this.feedUrl,
    required this.showTitle,
    required this.episodeTitle,
    required this.episodeKey,
  });

  final String feedUrl;
  final String showTitle;
  final String episodeTitle;
  final String episodeKey;
}

/// Filters a refresh result down to notifiable episodes.
class PodcastNotificationPolicy {
  const PodcastNotificationPolicy();

  List<PodcastEpisodeAlert> alertsFor({
    required PodcastSubscription subscription,
    required PodcastRefreshResult refresh,
  }) {
    if (!subscription.notifyNew) return const <PodcastEpisodeAlert>[];
    if (refresh.failed || !refresh.hasNewEpisodes) {
      return const <PodcastEpisodeAlert>[];
    }
    return <PodcastEpisodeAlert>[
      for (final episode in refresh.newEpisodes)
        PodcastEpisodeAlert(
          feedUrl: subscription.feedUrl,
          showTitle: subscription.title,
          episodeTitle: episode.title,
          episodeKey: episode.episodeKey,
        ),
    ];
  }
}
