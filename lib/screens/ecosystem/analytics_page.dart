import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotimusic/ecosystem/ecosystem.dart';
import 'package:spotimusic/providers/ecosystem_providers.dart';
import 'package:spotimusic/widgets/app_sliver_header.dart';
import 'package:spotimusic/widgets/settings_group.dart';

/// Personal analytics dashboard (Feature Group 12).
///
/// Everything is derived on-device from the listening-history tables by
/// [InsightsCalculator]; no third-party analytics SDK is involved.
class AnalyticsPage extends ConsumerWidget {
  const AnalyticsPage({super.key});

  static const List<int> _windows = <int>[7, 30, 365];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window = ref.watch(_analyticsWindowProvider);
    final insightsAsync = ref.watch(insightsProvider(window));
    final recapAsync = ref.watch(recapProvider(DateTime.now().year));
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: 'Analytics',
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  ref.invalidate(insightsProvider(window));
                  ref.invalidate(recapProvider(DateTime.now().year));
                },
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  for (final days in _windows)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(_windowLabel(days)),
                        selected: window == days,
                        onSelected: (_) => ref
                            .read(_analyticsWindowProvider.notifier)
                            .set(days),
                      ),
                    ),
                ],
              ),
            ),
          ),
          insightsAsync.when(
            data: (insights) {
              if (insights.isEmpty) {
                return SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No listening data in this window yet.',
                        style: TextStyle(color: colorScheme.onSurfaceVariant),
                      ),
                    ),
                  ),
                );
              }
              return SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SummaryGrid(insights: insights),
                      const SizedBox(height: 16),
                      _TrendCard(insights: insights),
                      const SizedBox(height: 16),
                      _RankingCard(
                        title: 'Top artists',
                        rankings: insights.topArtists,
                      ),
                      _RankingCard(
                        title: 'Top albums',
                        rankings: insights.topAlbums,
                      ),
                      _RankingCard(
                        title: 'Top tracks',
                        rankings: insights.topTracks,
                      ),
                      const SizedBox(height: 16),
                      SettingsGroup(
                        children: [
                          SettingsItem(
                            icon: Icons.emoji_events_outlined,
                            title: 'Longest streak',
                            subtitle: '${insights.longestStreakDays} days',
                          ),
                          SettingsItem(
                            icon: Icons.local_fire_department_outlined,
                            title: 'Current streak',
                            subtitle: '${insights.currentStreakDays} days',
                          ),
                          if (insights.busiestDay != null)
                            SettingsItem(
                              icon: Icons.trending_up,
                              title: 'Busiest day',
                              subtitle: insights.busiestDay!,
                            ),
                          SettingsItem(
                            icon: Icons.done_all_outlined,
                            title: 'Completion',
                            subtitle:
                                '${(insights.averageCompletion * 100).round()}% '
                                'average · skip rate '
                                '${(insights.skipRate * 100).round()}%',
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '${DateTime.now().year} recap',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      recapAsync.when(
                        data: (recap) => _RecapCard(recap: recap),
                        loading: () => const SizedBox.shrink(),
                        error: (error, _) => Text('$error'),
                      ),
                    ],
                  ),
                ),
              );
            },
            loading: () => const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('$error')),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  static String _windowLabel(int days) {
    switch (days) {
      case 7:
        return '7 days';
      case 30:
        return '30 days';
      default:
        return 'Year';
    }
  }
}

/// Selection of the analytics window (days); Riverpod 3 removed
/// StateProvider, so this follows the repo's NotifierProvider convention.
class _AnalyticsWindowNotifier extends Notifier<int> {
  @override
  int build() => 30;

  void set(int days) => state = days;
}

final _analyticsWindowProvider =
    NotifierProvider<_AnalyticsWindowNotifier, int>(
      _AnalyticsWindowNotifier.new,
    );

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({required this.insights});

  final ListeningInsights insights;

  @override
  Widget build(BuildContext context) {
    final cards = <(String, String)>[
      (
        insights.listeningHours.toStringAsFixed(1),
        'hours listened',
      ),
      ('${insights.playCount}', 'plays'),
      ('${insights.uniqueTracks}', 'unique tracks'),
      (
        insights.minutesPerActiveDay.toStringAsFixed(0),
        'min / active day',
      ),
    ];
    return Row(
      children: [
        for (final card in cards)
          Expanded(
            child: Card(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 16,
                  horizontal: 8,
                ),
                child: Column(
                  children: [
                    Text(
                      card.$1,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      card.$2,
                      textAlign: TextAlign.center,
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

/// Day-by-day minutes for the selected window.
class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.insights});

  final ListeningInsights insights;

  @override
  Widget build(BuildContext context) {
    final days = insights.minutesByDay.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final maxMinutes = days.isEmpty
        ? 0.0
        : days
            .map((entry) => entry.value)
            .reduce((a, b) => a > b ? a : b);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Daily minutes', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 12),
            if (days.isEmpty)
              const Text('No activity in this window.')
            else
              Column(
                children: [
                  for (final entry in days.take(30))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 62,
                            child: Text(
                              entry.key.substring(5),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: maxMinutes <= 0
                                  ? 0
                                  : entry.value / maxMinutes,
                              minHeight: 8,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            entry.value.toStringAsFixed(0),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _RankingCard extends StatelessWidget {
  const _RankingCard({required this.title, required this.rankings});

  final String title;
  final List<ListeningRanking> rankings;

  @override
  Widget build(BuildContext context) {
    if (rankings.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SettingsGroup(
        children: [
          for (var i = 0; i < rankings.length && i < 10; i++)
            SettingsItem(
              icon: Icons.star_outline,
              title: '${i + 1}. ${rankings[i].title}',
              subtitle: rankings[i].subtitle.isEmpty
                  ? '${rankings[i].playCount} plays'
                  : '${rankings[i].subtitle} · ${rankings[i].playCount} plays',
            ),
        ],
      ),
    );
  }
}

class _RecapCard extends StatelessWidget {
  const _RecapCard({required this.recap});

  final RecapReport recap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${recap.year} in review',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (recap.milestones.isEmpty)
              const Text('Not enough data for a recap yet.')
            else
              for (final milestone in recap.milestones)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• $milestone'),
                ),
          ],
        ),
      ),
    );
  }
}
