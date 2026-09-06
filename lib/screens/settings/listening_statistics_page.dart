import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/engine/playback_session.dart';
import 'package:spotiflac_android/providers/playback_statistics_provider.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// Settings → Streaming & Glass → Listening Statistics.
///
/// Everything shown here is computed on-device; no telemetry is sent.
class ListeningStatisticsPage extends ConsumerWidget {
  const ListeningStatisticsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(playbackStatisticsProvider);
    final notifier = ref.read(playbackStatisticsProvider.notifier);

    return CustomScrollView(
      slivers: [
        AppSliverHeader.page(title: 'Listening Statistics'),
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              context.tokens.pagePadding,
              context.tokens.pagePadding * 0.5,
              context.tokens.pagePadding,
              context.tokens.pagePadding * 0.5,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SummaryGrid(
                  stats: stats,
                ),
                const SizedBox(height: 16),
                SettingsGroup(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: context.tokens.pagePadding,
                      ),
                      leading: const Icon(Icons.delete_sweep_outlined),
                      title: const Text('Reset statistics'),
                      subtitle: const Text(
                        'Clears plays, skips, listening time and per-track history',
                      ),
                      onTap: () => _confirmReset(context, notifier),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                _SectionHeader(title: 'Recently played'),
                _TrackStatList(
                  items: stats.recentTracks.take(20).toList(growable: false),
                  empty: 'No tracks have been played yet.',
                ),
                const SizedBox(height: 20),
                _SectionHeader(title: 'Most played'),
                _TrackStatList(
                  items: stats.mostPlayedTracks.take(20).toList(growable: false),
                  empty: 'Play some tracks to build a most-played list.',
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmReset(
    BuildContext context,
    PlaybackStatisticsNotifier notifier,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset listening statistics?'),
        content: const Text(
          'This permanently clears all locally stored playback statistics. '
          'It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await notifier.resetAll();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Listening statistics cleared')),
        );
      }
    }
  }
}

class _SummaryGrid extends StatelessWidget {
  final ListeningStats stats;

  const _SummaryGrid({required this.stats});

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 2.2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        _SummaryCard(label: 'Plays', value: '${stats.plays}'),
        _SummaryCard(label: 'Skips', value: '${stats.skips}'),
        _SummaryCard(
          label: 'Listened',
          value: formatListenedMs(stats.listenedMs),
        ),
        _SummaryCard(label: 'Day streak', value: '${stats.streakDays}d'),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;

  const _SummaryCard({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _TrackStatList extends StatelessWidget {
  final List<TrackPlayStat> items;
  final String empty;

  const _TrackStatList({required this.items, required this.empty});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(empty, style: Theme.of(context).textTheme.bodyMedium),
      );
    }
    return SettingsGroup(
      children: items
          .map(
            (stat) => ListTile(
              contentPadding: EdgeInsets.symmetric(
                horizontal: context.tokens.pagePadding,
              ),
              leading: CircleAvatar(
                child: Text(
                  stat.playCount > 99 ? '99+' : '${stat.playCount}',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              title: Text(
                stat.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                stat.artist,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text(
                _playedAtLabel(stat.lastPlayedAt),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  String _playedAtLabel(DateTime? at) {
    if (at == null) return '';
    final now = DateTime.now();
    final diff = now.difference(at);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${at.year}-${at.month.toString().padLeft(2, '0')}-'
        '${at.day.toString().padLeft(2, '0')}';
  }
}
