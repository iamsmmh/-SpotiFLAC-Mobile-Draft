/// Similar Artists (Phase 6).
///
/// Shows, for one artist: the similarity percentage, the evidence behind it,
/// that artist's top tracks and the albums worth playing. All of it comes from
/// on-device signals — genre overlap, tag overlap, co-listening, shared
/// playlists and album overlap — and the screen is explicit when a pair has no
/// grounded evidence rather than inventing a percentage.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_service.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/similarity_engine.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/discovery_providers.dart';
import 'package:spotiflac_android/providers/playback_provider.dart';
import 'package:spotiflac_android/screens/discovery/discovery_widgets.dart';
import 'package:spotiflac_android/screens/discovery/radio_screen.dart';
import 'package:spotiflac_android/utils/nav_bar_inset.dart';
import 'package:spotiflac_android/widgets/animation_utils.dart';

class SimilarArtistsScreen extends ConsumerStatefulWidget {
  const SimilarArtistsScreen({
    super.key,
    required this.artistKey,
    required this.artistName,
    this.coverUrl,
    this.providerId,
  });

  final String artistKey;
  final String artistName;
  final String? coverUrl;
  final String? providerId;

  @override
  ConsumerState<SimilarArtistsScreen> createState() =>
      _SimilarArtistsScreenState();
}

class _SimilarArtistsScreenState extends ConsumerState<SimilarArtistsScreen> {
  final Set<String> _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final bottomInset = context.navBarBottomInset;

    final similarAsync = ref.watch(similarArtistsProvider(widget.artistKey));

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () =>
            ref.refresh(similarArtistsProvider(widget.artistKey).future),
        child: CustomScrollView(
          slivers: <Widget>[
            SliverAppBar(
              expandedHeight: 210,
              pinned: true,
              backgroundColor: scheme.surface,
              foregroundColor: scheme.onSurface,
              actions: <Widget>[
                IconButton(
                  tooltip: context.l10n.discoveryRadioArtist,
                  onPressed: _startRadio,
                  icon: const Icon(Icons.podcasts_rounded),
                ),
              ],
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  decoration: BoxDecoration(
                    gradient: discoveryGradient(widget.artistKey, scheme),
                  ),
                  child: SafeArea(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 56, 20, 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Hero(
                            tag: 'discovery-artist-${widget.artistKey}',
                            child: DiscoveryArtwork(
                              seed: widget.artistName,
                              imageUrl: widget.coverUrl,
                              size: 96,
                              round: true,
                              icon: Icons.person_rounded,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.end,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  widget.artistName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    color: scheme.onSurface,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  context.l10n.discoverySectionSimilar,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            ...similarAsync.when<List<Widget>>(
              data: (entries) => entries.isEmpty
                  ? <Widget>[
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: DiscoveryEmptyShelf(
                          title: context.l10n.discoverySimilarNone,
                          hint: context.l10n.discoverySimilarNoneHint,
                          icon: Icons.hub_rounded,
                        ),
                      ),
                    ]
                  : <Widget>[
                      SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) =>
                              _similarTile(entries[index], index),
                          childCount: entries.length,
                        ),
                      ),
                    ],
              loading: () => <Widget>[
                const SliverToBoxAdapter(child: SizedBox(height: 16)),
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: ShimmerLoading(
                      child: SkeletonBox(
                        width: double.infinity,
                        height: 320,
                        borderRadius: 14,
                      ),
                    ),
                  ),
                ),
              ],
              error: (error, _) => <Widget>[
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        context.friendlyError(error),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            SliverToBoxAdapter(child: SizedBox(height: bottomInset + 16)),
          ],
        ),
      ),
    );
  }

  Widget _similarTile(ArtistSimilarity entry, int index) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final expanded = _expanded.contains(entry.artistKey);

    return StaggeredListItem(
      index: index,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Material(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              setState(() {
                if (!_expanded.remove(entry.artistKey)) {
                  _expanded.add(entry.artistKey);
                }
              });
            },
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      DiscoveryArtwork(
                        seed: entry.label,
                        imageUrl: entry.imageUrl,
                        size: 52,
                        round: true,
                        icon: Icons.person_rounded,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              entry.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${(entry.score * 100).round()}% '
                              '${context.l10n.discoverySimilarScore}',
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: context.l10n.discoveryRadioArtist,
                        onPressed: () => _startArtistRadio(
                          artistKey: entry.artistKey,
                          label: entry.label,
                        ),
                        icon: const Icon(Icons.podcasts_rounded),
                      ),
                      Icon(
                        expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                  if (expanded) ...[
                    const SizedBox(height: 8),
                    _EvidenceChips(entry: entry),
                    const SizedBox(height: 8),
                    _ArtistDetailBody(artistKey: entry.artistKey),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _startRadio() {
    _startArtistRadio(
      artistKey: widget.artistKey,
      label: widget.artistName,
    );
  }

  void _startArtistRadio({required String artistKey, required String label}) {
    final controller = ref.read(radioSessionProvider.notifier);
    controller.startArtist(artistKey: artistKey, label: label);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RadioScreen(seedLabel: label),
      ),
    );
  }
}

/// The five similarity signals as chips, so the percentage is explainable.
class _EvidenceChips extends StatelessWidget {
  const _EvidenceChips({required this.entry});

  final ArtistSimilarity entry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final evidence = <String, double>{
      'Genres': entry.genreOverlap,
      'Tags': entry.tagOverlap,
      'Co-listen': entry.coListenOverlap,
      'Playlists': entry.playlistOverlap,
      'Albums': entry.albumOverlap,
    };
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: <Widget>[
        for (final item in evidence.entries)
          if (item.value > 0.001)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${item.key} ${(item.value * 100).round()}%',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
      ],
    );
  }
}

/// Top tracks and recommended albums for one similar artist.
class _ArtistDetailBody extends ConsumerWidget {
  const _ArtistDetailBody({required this.artistKey});

  final String artistKey;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final detailAsync = ref.watch(artistDetailProvider(artistKey));

    return detailAsync.when<Widget>(
      data: (detail) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (detail.topTracks.isNotEmpty) ...[
            Text(
              context.l10n.discoverySimilarTopTracks,
              style: textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            for (var i = 0; i < detail.topTracks.length; i++)
              InkWell(
                onTap: () => _play(context, ref, detail, i),
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    children: [
                      DiscoveryArtwork(
                        seed: detail.topTracks[i].track.key,
                        imageUrl: detail.topTracks[i].track.coverUrl,
                        size: 36,
                        borderRadius: 6,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              detail.topTracks[i].track.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              detail.topTracks[i].track.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.labelSmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.play_arrow_rounded,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  ),
                ),
              ),
          ],
          if (detail.albums.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              context.l10n.discoverySimilarAlbums,
              style: textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final album in detail.albums)
                  Chip(
                    label: Text(album.label),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ],
      ),
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: LinearProgressIndicator(),
      ),
      error: (error, _) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          context.friendlyError(error),
          style: textTheme.bodySmall?.copyWith(color: scheme.error),
        ),
      ),
    );
  }

  void _play(
    BuildContext context,
    WidgetRef ref,
    ArtistDetail detail,
    int startIndex,
  ) {
    final tracks = <Track>[
      for (final entry in detail.topTracks)
        discoveryTrackToTrack(entry.track),
    ];
    if (tracks.isEmpty) return;
    ref
        .read(playbackProvider.notifier)
        .playTrackList(tracks, startIndex: startIndex);
  }
}
