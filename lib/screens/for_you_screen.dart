import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/engine/recommendations.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/playback_provider.dart';
import 'package:spotiflac_android/providers/recommendation_provider.dart';
import 'package:spotiflac_android/screens/artist_screen.dart';
import 'package:spotiflac_android/services/cover_cache_manager.dart';
import 'package:spotiflac_android/utils/adaptive_layout.dart';
import 'package:spotiflac_android/utils/nav_bar_inset.dart';
import 'package:spotiflac_android/widgets/animation_utils.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';

/// For You (Phase 7): personalized shelves driven by the recommendation
/// engine — recently played, discovery mix, frequently played, artists.
/// Data is fully on-device (listening stats + favorites); richer remote
/// sections blend in automatically when a recommendation provider registers.
class ForYouScreen extends ConsumerWidget {
  const ForYouScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sectionsAsync = ref.watch(forYouSectionsProvider);
    final colorScheme = Theme.of(context).colorScheme;
    final bottomInset = context.navBarBottomInset;

    final bodySlivers = sectionsAsync.when<List<Widget>>(
      data: (sections) => sections.isEmpty
          ? [
              SliverFillRemaining(
                hasScrollBody: false,
                child: _ForYouEmptyState(colorScheme: colorScheme),
              ),
            ]
          : [
              for (final section in sections)
                ..._sectionSlivers(context, ref, section, colorScheme),
            ],
      loading: () => [
        const SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ],
      error: (error, _) => [
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
    );

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: context.l10n.forYouTitle),
          ...bodySlivers,
          SliverToBoxAdapter(child: SizedBox(height: bottomInset)),
        ],
      ),
    );
  }

  List<Widget> _sectionSlivers(
    BuildContext context,
    WidgetRef ref,
    RecommendationSection section,
    ColorScheme colorScheme,
  ) {
    final title = section.title.isNotEmpty
        ? section.title
        : _sectionTitle(context, section.kind);
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding:
              const EdgeInsets.fromLTRB(16, 20, 16, 4) +
              EdgeInsets.symmetric(horizontal: wideListInset(context)),
          child: Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8) +
                EdgeInsets.symmetric(horizontal: wideListInset(context)),
            itemCount: section.items.length,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = section.items[index];
              return _RecommendationCard(
                item: item,
                onTap: () => _openItem(context, ref, section, index),
              );
            },
          ),
        ),
      ),
    ];
  }

  String _sectionTitle(BuildContext context, RecommendationSectionKind kind) {
    switch (kind) {
      case RecommendationSectionKind.recentlyPlayed:
        return context.l10n.forYouSectionRecentlyPlayed;
      case RecommendationSectionKind.frequentlyPlayed:
        return context.l10n.forYouSectionFrequentlyPlayed;
      case RecommendationSectionKind.similarArtists:
      case RecommendationSectionKind.similarTracks:
        return context.l10n.forYouSectionArtists;
      case RecommendationSectionKind.discoveryMix:
        return context.l10n.forYouSectionDiscoveryMix;
      case RecommendationSectionKind.becauseYouListened:
        // The engine supplies a producer title naming the seed artist;
        // this generic fallback covers remote providers that do not.
        return context.l10n.forYouSectionBecauseYouListened;
      case RecommendationSectionKind.trending:
        // Remote providers may supply their own title; this is the fallback.
        return context.l10n.forYouTitle;
    }
  }

  void _openItem(
    BuildContext context,
    WidgetRef ref,
    RecommendationSection section,
    int index,
  ) {
    final item = section.items[index];
    switch (item.kind) {
      case RecommendedItemKind.artist:
        Navigator.of(context).push(
          slidePageRoute<void>(
            page: ArtistScreen(
              artistId: item.id,
              artistName: item.title,
              coverUrl: item.imageUrl,
              extensionId:
                  item.providerId != null &&
                      item.providerId!.isNotEmpty &&
                      item.providerId != LocalRecommendationEngine.providerId
                  ? item.providerId
                  : null,
            ),
          ),
        );
      case RecommendedItemKind.track:
      case RecommendedItemKind.album:
        // Queue the whole shelf from the tapped position (Smart Play decides
        // local → stream per track).
        final tracks = <Track>[];
        var startIndex = 0;
        for (var i = 0; i < section.items.length; i++) {
          final entry = section.items[i];
          if (entry.kind != RecommendedItemKind.track) continue;
          if (i <= index) {
            startIndex = tracks.length;
          }
          tracks.add(
            Track(
              id: entry.id,
              name: entry.title,
              artistName: entry.subtitle,
              albumName: '',
              coverUrl: entry.imageUrl,
              duration: 0,
            ),
          );
        }
        if (tracks.isEmpty) return;
        ref
            .read(playbackProvider.notifier)
            .playTrackList(tracks, startIndex: startIndex);
    }
  }
}

class _ForYouEmptyState extends StatelessWidget {
  const _ForYouEmptyState({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 60,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              context.l10n.forYouEmptyTitle,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.forYouEmptySubtitle,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecommendationCard extends StatelessWidget {
  const _RecommendationCard({required this.item, required this.onTap});

  final RecommendedItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isArtist = item.kind == RecommendedItemKind.artist;
    final imageUrl = item.imageUrl;

    final artwork = imageUrl != null && imageUrl.isNotEmpty
        ? CachedNetworkImage(
            imageUrl: imageUrl,
            width: 128,
            height: 128,
            fit: BoxFit.cover,
            memCacheWidth: 256,
            memCacheHeight: 256,
            cacheManager: CoverCacheManager.instance,
            errorWidget: (_, _, _) => _artworkFallback(colorScheme, isArtist),
          )
        : _artworkFallback(colorScheme, isArtist);

    return SizedBox(
      width: 128,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (isArtist)
              ClipOval(child: artwork)
            else
              ClipRRect(borderRadius: BorderRadius.circular(12), child: artwork),
            const SizedBox(height: 8),
            Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
            ),
            if (item.subtitle.isNotEmpty)
              Text(
                item.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _artworkFallback(ColorScheme colorScheme, bool isArtist) {
    return Container(
      width: 128,
      height: 128,
      color: colorScheme.surfaceContainerHighest,
      child: Icon(
        isArtist ? Icons.person : Icons.music_note,
        size: 40,
        color: colorScheme.onSurfaceVariant,
      ),
    );
  }
}
