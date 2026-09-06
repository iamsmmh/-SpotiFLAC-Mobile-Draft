import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotimusic/providers/ecosystem_providers.dart';
import 'package:spotimusic/screens/ecosystem/account_page.dart';
import 'package:spotimusic/screens/ecosystem/advanced_audio_page.dart';
import 'package:spotimusic/screens/ecosystem/analytics_page.dart';
import 'package:spotimusic/screens/ecosystem/cloud_sync_console_page.dart';
import 'package:spotimusic/screens/ecosystem/favorites_page.dart';
import 'package:spotimusic/screens/ecosystem/history_page.dart';
import 'package:spotimusic/screens/ecosystem/servers_page.dart';
import 'package:spotimusic/screens/ecosystem/smart_playlists_page.dart';
import 'package:spotimusic/screens/ecosystem/unified_search_page.dart';
import 'package:spotimusic/widgets/app_sliver_header.dart';
import 'package:spotimusic/widgets/settings_group.dart';

/// Entry point for the ecosystem features.
///
/// Everything reachable from here is optional and additive: with no cloud
/// backend configured the app behaves exactly as it did before (guest mode,
/// on-device history and recommendations), and no existing download, playback,
/// metadata, lyrics, library or extension flow is touched.
class EcosystemHubPage extends ConsumerWidget {
  const EcosystemHubPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountStateProvider).value;
    final favorites = ref.watch(favoritesIndexProvider).value;
    final insights = ref.watch(insightsProvider(30)).value;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: 'Ecosystem'),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SummaryRow(
                    accountLabel: account == null
                        ? 'Loading…'
                        : account.isAuthenticated
                        ? account.user?.label ?? 'Signed in'
                        : (account.isGuest ? 'Guest' : 'Signed out'),
                    favoritesLabel: '${favorites?.length ?? 0} favorites',
                    hoursLabel:
                        '${(insights?.listeningHours ?? 0).toStringAsFixed(1)} h / 30 d',
                  ),
                  const SizedBox(height: 12),
                  SettingsGroup(
                    children: [
                      for (final destination in _destinations)
                        SettingsItem(
                          icon: destination.icon,
                          title: destination.title,
                          subtitle: destination.subtitle,
                          onTap: () => _open(context, destination.pageBuilder()),
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Cloud accounts and sync activate only when a backend '
                      'adapter is registered. Favorites, history, insights and '
                      'on-device recommendations work with zero configuration.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const List<_EcosystemDestination> _destinations =
      <_EcosystemDestination>[
        _EcosystemDestination(
          icon: Icons.account_circle_outlined,
          title: 'Account',
          subtitle: 'Email, Google, Apple, guest mode, secure tokens',
          pageBuilder: AccountPage.new,
        ),
        _EcosystemDestination(
          icon: Icons.favorite_outline,
          title: 'Favorites',
          subtitle: 'Tracks, albums, artists and playlists in one list',
          pageBuilder: FavoritesPage.new,
        ),
        _EcosystemDestination(
          icon: Icons.history,
          title: 'Listening history',
          subtitle: 'Recently played, most played, skips, completion',
          pageBuilder: HistoryPage.new,
        ),
        _EcosystemDestination(
          icon: Icons.insights_outlined,
          title: 'Analytics',
          subtitle: 'Top artists, albums, trends and yearly recap',
          pageBuilder: AnalyticsPage.new,
        ),
        _EcosystemDestination(
          icon: Icons.cloud_sync_outlined,
          title: 'Cloud sync',
          subtitle: 'Conflict resolution, outbox, background retries',
          pageBuilder: CloudSyncConsolePage.new,
        ),
        _EcosystemDestination(
          icon: Icons.auto_awesome_motion,
          title: 'Smart playlists',
          subtitle: 'Recently played, most played, daily mix, discover',
          pageBuilder: SmartPlaylistsPage.new,
        ),
        _EcosystemDestination(
          icon: Icons.dns_outlined,
          title: 'Music servers',
          subtitle: 'Jellyfin, Navidrome, Subsonic, Airsonic, Plex',
          pageBuilder: ServersPage.new,
        ),
        _EcosystemDestination(
          icon: Icons.manage_search,
          title: 'Search everywhere',
          subtitle: 'One ranked list across every source',
          pageBuilder: UnifiedSearchPage.new,
        ),
        _EcosystemDestination(
          icon: Icons.tune_outlined,
          title: 'Advanced audio',
          subtitle: 'Parametric EQ, profiles, crossfeed, loudness',
          pageBuilder: AdvancedAudioPage.new,
        ),
      ];

  static void _open(BuildContext context, Widget page) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}

class _EcosystemDestination {
  const _EcosystemDestination({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.pageBuilder,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget Function() pageBuilder;
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.accountLabel,
    required this.favoritesLabel,
    required this.hoursLabel,
  });

  final String accountLabel;
  final String favoritesLabel;
  final String hoursLabel;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (final entry in <(IconData, String)>[
          (Icons.person_outline, accountLabel),
          (Icons.favorite_border, favoritesLabel),
          (Icons.schedule, hoursLabel),
        ])
          Expanded(
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 14,
                ),
                child: Column(
                  children: [
                    Icon(entry.$1, color: colorScheme.primary),
                    const SizedBox(height: 8),
                    Text(
                      entry.$2,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
