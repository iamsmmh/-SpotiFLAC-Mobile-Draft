import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/ecosystem/ecosystem.dart';
import 'package:spotiflac_android/providers/ecosystem_providers.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// Listening history (Feature Group 4).
///
/// Recently played comes from the append-only event log; most played comes
/// from the per-track aggregate (play count, skips, completion). Both are
/// computed on-device and only leave the phone if the user enables the history
/// sync scope.
class HistoryPage extends ConsumerWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(recentHistoryProvider);
    final mostPlayed = ref.watch(mostPlayedHistoryProvider);
    final repository = ref.watch(listeningHistoryRepositoryProvider);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: 'History',
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  ref.invalidate(recentHistoryProvider);
                  ref.invalidate(mostPlayedHistoryProvider);
                },
              ),
              IconButton(
                icon: const Icon(Icons.delete_sweep_outlined),
                onPressed: () => _confirmClear(context, ref, repository),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
              child: Text(
                'Plays, skips and completion are recorded locally while '
                '"track listening stats" is enabled in Streaming & Glass.',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          _sectionTitle(context, 'Recently played'),
          recent.when(
            data: (events) => _eventsList(events),
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
            error: (error, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('$error'),
              ),
            ),
          ),
          _sectionTitle(context, 'Most played'),
          mostPlayed.when(
            data: (tracks) => _aggregatesList(tracks),
            loading: () => const SliverToBoxAdapter(child: SizedBox.shrink()),
            error: (error, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('$error'),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String title) =>
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      );

  static Widget _eventsList(List<PlayEvent> events) {
    if (events.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text('Nothing played yet.'),
        ),
      );
    }
    return SliverToBoxAdapter(
      child: SettingsGroup(
        children: [
          for (final event in events.take(50))
            SettingsItem(
              icon: Icons.play_arrow_outlined,
              title: event.title,
              subtitle:
                  '${event.artist} · ${_formatDuration(event.listened)}'
                  ' · ${(event.completion * 100).round()}%'
                  '${event.skipped ? ' · skipped' : ''}',
            ),
        ],
      ),
    );
  }

  static Widget _aggregatesList(List<TrackHistory> tracks) {
    if (tracks.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text('No plays recorded yet.'),
        ),
      );
    }
    return SliverToBoxAdapter(
      child: SettingsGroup(
        children: [
          for (final track in tracks.take(50))
            SettingsItem(
              icon: Icons.repeat,
              title: track.title,
              subtitle:
                  '${track.artist} · ${track.playCount} plays'
                  ' · ${track.skipCount} skips'
                  ' · ${(track.averageCompletion * 100).round()}% avg',
            ),
        ],
      ),
    );
  }

  static String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds % 60;
    return '${minutes}m ${seconds}s';
  }

  static Future<void> _confirmClear(
    BuildContext context,
    WidgetRef ref,
    ListeningHistoryRepository repository,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear listening history?'),
        content: const Text(
          'Removes every play event and per-track aggregate stored on this '
          'device. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await repository.clear();
    ref.invalidate(recentHistoryProvider);
    ref.invalidate(mostPlayedHistoryProvider);
    ref.invalidate(trackPlayCountsProvider);
  }
}
