/// Detail screen for one generated shelf: Discover Weekly, a Daily Mix or a
/// mood playlist (Phases 3, 4, 5, 14).
///
/// One screen for all three because they are the same shape — a cover, a
/// play/shuffle pair and a track list — and the differences are in the data.
///
/// The list is infinite-scrolling: only [_pageSize] rows are built at a time and
/// the window grows as the user nears the bottom, so a 50-track weekly costs one
/// viewport of widgets on first paint.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/discovery_providers.dart';
import 'package:spotiflac_android/providers/playback_provider.dart';
import 'package:spotiflac_android/screens/discovery/discovery_widgets.dart';
import 'package:spotiflac_android/screens/discovery/radio_screen.dart';
import 'package:spotiflac_android/utils/nav_bar_inset.dart';

/// Rows built per infinite-scroll step.
const int _pageSize = 20;

class DiscoveryShelfScreen extends ConsumerStatefulWidget {
  const DiscoveryShelfScreen({super.key, required this.shelf});

  final GeneratedShelf shelf;

  @override
  ConsumerState<DiscoveryShelfScreen> createState() =>
      _DiscoveryShelfScreenState();
}

class _DiscoveryShelfScreenState extends ConsumerState<DiscoveryShelfScreen> {
  int _visible = _pageSize;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final shelf = widget.shelf;
    final bottomInset = context.navBarBottomInset;
    final cover = shelf.items.isEmpty ? null : shelf.items.first.track.coverUrl;

    return Scaffold(
      body: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification.metrics.pixels <
              notification.metrics.maxScrollExtent - 400) {
            return false;
          }
          if (_visible >= shelf.items.length) return false;
          setState(() {
            _visible = (_visible + _pageSize).clamp(0, shelf.items.length);
          });
          return false;
        },
        child: CustomScrollView(
          slivers: <Widget>[
            SliverAppBar(
              expandedHeight: 268,
              pinned: true,
              backgroundColor: scheme.surface,
              foregroundColor: scheme.onSurface,
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: BoxDecoration(
                    gradient: discoveryGradient(shelf.id, scheme),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 56, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Hero(
                            tag: 'discovery-shelf-${shelf.id}',
                            child: DiscoveryArtwork(
                              seed: shelf.id,
                              imageUrl: cover,
                              size: 132,
                              borderRadius: 14,
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text(
                            shelf.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface,
                            ),
                          ),
                          if (shelf.subtitle.isNotEmpty)
                            Text(
                              shelf.subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          const SizedBox(height: 6),
                          Text(
                            _metaLabel(context, shelf),
                            style: textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    _ShelfActionButton(
                      label: context.l10n.discoveryPlayAll,
                      icon: Icons.play_arrow_rounded,
                      onTap: () => _play(0),
                    ),
                    const SizedBox(width: 10),
                    _ShelfActionButton(
                      label: context.l10n.discoveryShuffle,
                      icon: Icons.shuffle_rounded,
                      filled: false,
                      onTap: _shuffle,
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: context.l10n.discoveryOpenRadio,
                      onPressed: _openRadio,
                      icon: const Icon(Icons.podcasts_rounded),
                    ),
                  ],
                ),
              ),
            ),
            if (shelf.seedLabels.isNotEmpty)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 34,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    children: <Widget>[
                      for (final seed in shelf.seedLabels)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Chip(
                            label: Text(seed),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            if (shelf.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: DiscoveryEmptyShelf(
                  title: context.l10n.discoveryEmptyShelf,
                  hint: context.l10n.discoveryEmptyShelfHint,
                ),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => _row(shelf.items[index], index),
                  childCount: _visible.clamp(0, shelf.items.length),
                ),
              ),
            SliverToBoxAdapter(child: SizedBox(height: bottomInset + 16)),
          ],
        ),
      ),
    );
  }

  Widget _row(ScoredTrack entry, int index) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final track = entry.track;
    final reason = entry.primaryReason;
    return InkWell(
      onTap: () => _play(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Text(
                '${index + 1}',
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            DiscoveryArtwork(
              seed: track.key,
              imageUrl: track.coverUrl,
              size: 44,
              borderRadius: 8,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text(
                    reason != null && reason.isNotEmpty
                        ? reason
                        : track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (track.durationMs > 0)
              Text(
                discoveryFormatDuration(track.durationMs),
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            if (track.isOfflinePlayable)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Icon(
                  Icons.download_done_rounded,
                  size: 16,
                  color: scheme.primary,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _play(int startIndex) {
    final tracks = <Track>[
      for (final entry in widget.shelf.items) discoveryTrackToTrack(entry.track),
    ];
    if (tracks.isEmpty) return;
    ref
        .read(playbackProvider.notifier)
        .playTrackList(tracks, startIndex: startIndex);
  }

  void _shuffle() {
    final order = discoveryShuffleOrder(
      widget.shelf.items.length,
      widget.shelf.id,
    );
    if (order.isEmpty) return;
    final tracks = <Track>[
      for (final index in order)
        discoveryTrackToTrack(widget.shelf.items[index].track),
    ];
    ref.read(playbackProvider.notifier).playTrackList(tracks, startIndex: 0);
  }

  void _openRadio() {
    final first = widget.shelf.items.isEmpty
        ? null
        : widget.shelf.items.first.track;
    if (first == null) return;
    unawaited(
      ref
          .read(radioSessionProvider.notifier)
          .startTrack(trackKey: first.key),
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RadioScreen(seedLabel: widget.shelf.title),
      ),
    );
  }

  String _metaLabel(BuildContext context, GeneratedShelf shelf) {
    final generated = shelf.generatedAt;
    final count = context.l10n.tracksCount(shelf.trackCount);
    if (generated == null) return count;
    final when =
        '${generated.year}-${generated.month.toString().padLeft(2, '0')}-'
        '${generated.day.toString().padLeft(2, '0')}';
    return '$count · $when';
  }
}

class _ShelfActionButton extends StatelessWidget {
  const _ShelfActionButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.filled = true,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: filled ? scheme.primary : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 18,
                color: filled ? scheme.onPrimary : scheme.onSurface,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: filled ? scheme.onPrimary : scheme.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
