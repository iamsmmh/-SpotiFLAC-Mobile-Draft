/// The personalised discovery home (Phase 10).
///
/// Spotify-style: one scrollable column of horizontal rails, each backed by a
/// lazily-built `ListView`, with the whole payload produced by
/// [DiscoveryService] in the background and cached on device.
///
/// Section order is fixed so the page never jumps between refreshes:
///   Continue Listening → Recently Played → Daily Mixes → Discover Weekly →
///   New Releases → Recommended For You → Trending Now → Moods →
///   Favorite Artists → Favorite Albums → Radio Stations → (legacy For You
///   shelves from registered recommendation providers).
///
/// The last group is deliberate: the pre-existing `forYouSectionsProvider`
/// chain (cloud → similarity → daily-mix → local) keeps rendering exactly as
/// before, so a user with a self-hosted recommender configured loses nothing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/ecosystem/discovery/continue_listening_repository.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_service.dart';
import 'package:spotiflac_android/ecosystem/discovery/radio_service.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/mood_engine.dart';
import 'package:spotiflac_android/engine/discovery/trending_engine.dart';
import 'package:spotiflac_android/engine/recommendations.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/discovery_providers.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/playback_provider.dart';
import 'package:spotiflac_android/providers/recommendation_provider.dart';
import 'package:spotiflac_android/screens/album_screen.dart';
import 'package:spotiflac_android/screens/artist_screen.dart';
import 'package:spotiflac_android/screens/discovery/discovery_shelf_screen.dart';
import 'package:spotiflac_android/screens/discovery/discovery_widgets.dart';
import 'package:spotiflac_android/screens/discovery/radio_screen.dart';
import 'package:spotiflac_android/screens/discovery/similar_artists_screen.dart';
import 'package:spotiflac_android/utils/adaptive_layout.dart';
import 'package:spotiflac_android/utils/nav_bar_inset.dart';
import 'package:spotiflac_android/widgets/animation_utils.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';

/// The discovery home.
///
/// `ForYouScreen` (the pre-existing entry point) delegates here, so every
/// navigation path that used to open For You now opens the full personalised
/// home.
class DiscoveryHomeScreen extends ConsumerStatefulWidget {
  const DiscoveryHomeScreen({super.key, this.title});

  /// Page heading. `ForYouScreen` passes its existing localized `forYouTitle`
  /// so the tab heading users already know does not change.
  final String? title;

  @override
  ConsumerState<DiscoveryHomeScreen> createState() =>
      _DiscoveryHomeScreenState();
}

class _DiscoveryHomeScreenState extends ConsumerState<DiscoveryHomeScreen> {
  TrendingPeriod _trendingPeriod = TrendingPeriod.week;

  @override
  Widget build(BuildContext context) {
    final homeAsync = ref.watch(discoveryHomeProvider);
    final bottomInset = context.navBarBottomInset;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () => refreshDiscovery(ref).then((_) {}),
        child: CustomScrollView(
          slivers: <Widget>[
            AppSliverHeader.page(
              title: widget.title ?? context.l10n.discoveryTitle,
            ),
            ...homeAsync.when<List<Widget>>(
              data: (home) => _sections(context, home),
              loading: () => _loadingSections(context),
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
            ..._legacyForYouSections(context),
            SliverToBoxAdapter(child: SizedBox(height: bottomInset + 16)),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Sections
  // -------------------------------------------------------------------------

  List<Widget> _sections(BuildContext context, DiscoveryHome home) {
    if (home.isColdStart && !home.hasAnyContent) {
      return <Widget>[
        SliverFillRemaining(
          hasScrollBody: false,
          child: _ColdStartState(colorScheme: Theme.of(context).colorScheme),
        ),
      ];
    }

    final sections = <Widget>[];

    final resume = home.continueListening;
    if (resume != null) {
      sections.add(
        SliverToBoxAdapter(
          child: Padding(
            padding: _edgePadding(context) + const EdgeInsets.only(top: 8),
            child: ContinueListeningCard(
              title: resume.track.title,
              artist: resume.track.artist,
              album: resume.track.album,
              coverUrl: resume.track.coverUrl,
              progress: resume.progress,
              remainingLabel: resume.remainingLabel,
              contextLabel: resume.contextLabel,
              onTap: () => _resume(resume),
            ),
          ),
        ),
      );
    }

    if (home.discoverWeekly != null && !home.discoverWeekly!.isEmpty) {
      sections.addAll(
        _featured(
          context,
          shelf: home.discoverWeekly!,
          caption: context.l10n.discoveryWeeklyMonday,
          onRadio: () => _startRadio(
            context,
            seedLabel: home.discoverWeekly!.title,
            start: (controller) => controller.startTrack(
              trackKey: home.discoverWeekly!.items.first.track.key,
            ),
          ),
        ),
      );
    }

    if (home.dailyMixes.isNotEmpty) {
      sections.addAll(
        _rail(
          context,
          title: context.l10n.discoverySectionDailyMixes,
          height: 214,
          itemCount: home.dailyMixes.length,
          itemBuilder: (context, index) {
            final shelf = home.dailyMixes[index];
            return DiscoveryMixTile(
              shelf: shelf,
              index: index,
              onTap: () => _openShelf(context, shelf),
            );
          },
        ),
      );
    }

    if (home.recentlyPlayed.isNotEmpty) {
      sections.addAll(
        _rail(
          context,
          title: context.l10n.discoverySectionRecent,
          height: 196,
          itemCount: home.recentlyPlayed.length,
          itemBuilder: (context, index) => DiscoveryTrackCard(
            track: home.recentlyPlayed[index].track,
            index: index,
            onTap: () => _playScored(context, home.recentlyPlayed, index),
          ),
        ),
      );
    }

    if (home.recommendedForYou.isNotEmpty) {
      sections.addAll(
        _rail(
          context,
          title: context.l10n.discoverySectionForYou,
          height: 196,
          itemCount: home.recommendedForYou.length,
          itemBuilder: (context, index) => DiscoveryTrackCard(
            track: home.recommendedForYou[index].track,
            index: index,
            onTap: () => _playScored(context, home.recommendedForYou, index),
          ),
        ),
      );
    }

    if (home.newReleases.isNotEmpty) {
      sections.addAll(
        _rail(
          context,
          title: context.l10n.discoverySectionNewReleases,
          height: 196,
          itemCount: home.newReleases.length,
          itemBuilder: (context, index) => DiscoveryTrackCard(
            track: home.newReleases[index].track,
            index: index,
            subtitle: _releaseLabel(home.newReleases[index].track),
            onTap: () => _playScored(context, home.newReleases, index),
          ),
        ),
      );
    }

    final trending = _trendingEntries(home);
    if (trending.isNotEmpty) {
      sections.addAll(_trendingSection(context, trending));
    }

    if (home.moods.isNotEmpty) {
      final moods = home.moods.entries.toList()
        ..sort((a, b) => a.key.index.compareTo(b.key.index));
      sections.addAll(
        _rail(
          context,
          title: context.l10n.discoverySectionMoods,
          height: 92,
          spacing: 10,
          itemCount: moods.length,
          itemBuilder: (context, index) {
            final entry = moods[index];
            return DiscoveryMoodTile(
              label: moodProfiles[entry.key]!.label,
              iconName: moodProfiles[entry.key]!.icon,
              index: index,
              onTap: () => _openShelf(context, entry.value),
            );
          },
        ),
      );
    }

    if (home.similarArtists.isNotEmpty) {
      sections.addAll(
        _rail(
          context,
          title: context.l10n.discoverySectionSimilar,
          height: 182,
          itemCount: home.similarArtists.length,
          actionLabel: context.l10n.forYouSectionArtists,
          onAction: () => _openSimilarArtists(context, home),
          itemBuilder: (context, index) {
            final entry = home.similarArtists[index];
            return DiscoveryArtistCard(
              name: entry.label,
              imageUrl: entry.imageUrl,
              caption: '${(entry.score * 100).round()}%',
              index: index,
              onTap: () => _openArtist(
                context,
                artistKey: entry.artistKey,
                name: entry.label,
                imageUrl: entry.imageUrl,
                providerId: entry.providerId,
              ),
            );
          },
        ),
      );
    }

    // "Favorite Artists" reads the collections store: those rows carry a real
    // provider artist id, so tapping one opens the full artist page.
    final favoriteArtists =
        ref.watch(libraryCollectionsProvider).favoriteArtists;
    if (favoriteArtists.isNotEmpty) {
      sections.addAll(
        _rail(
          context,
          title: context.l10n.discoverySectionArtists,
          height: 182,
          itemCount: favoriteArtists.length,
          itemBuilder: (context, index) {
            final entry = favoriteArtists[index];
            return DiscoveryArtistCard(
              name: entry.name,
              imageUrl: entry.imageUrl,
              index: index,
              onTap: () => _openCollectionArtist(context, entry),
            );
          },
        ),
      );
    }

    // "Albums you love" is sourced from the collections store, not from the
    // taste profile: those rows carry a real album id, so tapping one opens the
    // actual album screen instead of a search.
    final favoriteAlbums =
        ref.watch(libraryCollectionsProvider).favoriteAlbums;
    if (favoriteAlbums.isNotEmpty) {
      sections.addAll(
        _rail(
          context,
          title: context.l10n.discoverySectionAlbums,
          height: 196,
          itemCount: favoriteAlbums.length,
          itemBuilder: (context, index) {
            final entry = favoriteAlbums[index];
            return DiscoveryTrackCard(
              track: DiscoveryTrack(
                key: entry.key,
                title: entry.name,
                artist: entry.artistName ?? '',
                albumKey: entry.albumId,
                coverUrl: entry.imageUrl,
                providerId: entry.providerId,
                externalId: entry.albumId,
              ),
              index: index,
              onTap: () => _openAlbum(context, entry),
            );
          },
        ),
      );
    }

    if (home.radioStations.isNotEmpty) {
      sections.addAll(
        _rail(
          context,
          title: context.l10n.discoverySectionRadio,
          height: 132,
          itemCount: home.radioStations.length,
          itemBuilder: (context, index) {
            final station = home.radioStations[index];
            return _RadioStationTile(
              station: station,
              index: index,
              onTap: () => _resumeRadio(context, station.sessionId),
            );
          },
        ),
      );
    }

    return sections;
  }

  List<Widget> _featured(
    BuildContext context, {
    required GeneratedShelf shelf,
    required String caption,
    required VoidCallback onRadio,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return <Widget>[
      SliverToBoxAdapter(
        child: Padding(
          padding: _edgePadding(context) + const EdgeInsets.only(top: 12),
          child: Material(
            borderRadius: BorderRadius.circular(18),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _openShelf(context, shelf),
              child: Ink(
                decoration: BoxDecoration(
                  gradient: discoveryGradient(shelf.id, scheme),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      DiscoveryArtwork(
                        seed: shelf.id,
                        imageUrl: shelf.items.isEmpty
                            ? null
                            : shelf.items.first.track.coverUrl,
                        size: 88,
                        borderRadius: 12,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              shelf.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w800,
                                color: scheme.onSurface,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              shelf.subtitle.isEmpty
                                  ? caption
                                  : shelf.subtitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: 10),
                            Row(
                              children: [
                                _PillButton(
                                  label: context.l10n.discoveryPlayAll,
                                  icon: Icons.play_arrow_rounded,
                                  onTap: () => _playShelf(context, shelf, 0),
                                ),
                                const SizedBox(width: 8),
                                _PillButton(
                                  label: context.l10n.discoveryShuffle,
                                  icon: Icons.shuffle_rounded,
                                  filled: false,
                                  onTap: () => _shuffleShelf(context, shelf),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: context.l10n.discoveryOpenRadio,
                        onPressed: onRadio,
                        icon: const Icon(Icons.podcasts_rounded),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _trendingSection(
    BuildContext context,
    List<TrendingEntry> entries,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return <Widget>[
      SliverToBoxAdapter(
        child: DiscoverySectionHeader(
          title: context.l10n.discoverySectionTrending,
          subtitle: context.l10n.discoveryTrendingNote,
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: <Widget>[
              for (final period in TrendingPeriod.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(_trendingLabel(context, period)),
                    selected: _trendingPeriod == period,
                    onSelected: (_) {
                      setState(() => _trendingPeriod = period);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final entry = entries[index];
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: DiscoveryTrendingRow(
                rank: entry.rank,
                label: entry.label,
                subtitle: entry.subtitle,
                coverUrl: entry.coverUrl,
                badge: entry.period == TrendingPeriod.velocity
                    ? entry.deltaLabel
                    : '${entry.playCount}',
                isArtist: entry.isArtist,
                onTap: () => _openTrending(context, entries, entry),
              ),
            );
          },
          childCount: entries.length,
        ),
      ),
      SliverToBoxAdapter(
        child: SizedBox(
          height: 8,
          child: ColoredBox(color: scheme.surface.withValues(alpha: 0)),
        ),
      ),
    ];
  }

  /// The pre-existing For You shelves, rendered below the new sections so a
  /// configured cloud/similarity provider still surfaces exactly as before.
  List<Widget> _legacyForYouSections(BuildContext context) {
    final sections = ref.watch(forYouSectionsProvider).value ?? const [];
    if (sections.isEmpty) return const <Widget>[];
    final widgets = <Widget>[];
    for (final section in sections) {
      if (section.isEmpty) continue;
      widgets.addAll(
        _rail(
          context,
          title: section.title.isNotEmpty
              ? section.title
              : _legacySectionTitle(context, section.kind),
          height: 196,
          itemCount: section.items.length,
          itemBuilder: (context, index) {
            final item = section.items[index];
            if (item.kind == RecommendedItemKind.artist) {
              return DiscoveryArtistCard(
                name: item.title,
                imageUrl: item.imageUrl,
                index: index,
                onTap: () => _openLegacyArtist(context, item),
              );
            }
            return DiscoveryTrackCard(
              track: DiscoveryTrack(
                key: item.id,
                title: item.title,
                artist: item.subtitle,
                coverUrl: item.imageUrl,
                providerId: item.providerId,
                externalId: item.id,
              ),
              index: index,
              onTap: () => _playLegacy(context, section, index),
            );
          },
        ),
      );
    }
    return widgets;
  }

  String _legacySectionTitle(BuildContext context, RecommendationSectionKind kind) {
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
        return context.l10n.forYouSectionBecauseYouListened;
      case RecommendationSectionKind.trending:
        return context.l10n.discoverySectionTrending;
    }
  }

  List<Widget> _loadingSections(BuildContext context) {
    return <Widget>[
      const SliverToBoxAdapter(child: SizedBox(height: 12)),
      const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: ShimmerLoading(
            child: SkeletonBox(width: double.infinity, height: 104, borderRadius: 16),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 20)),
      const SliverToBoxAdapter(child: DiscoveryRailSkeleton()),
      const SliverToBoxAdapter(child: SizedBox(height: 20)),
      const SliverToBoxAdapter(child: DiscoveryRailSkeleton(height: 214, size: 148)),
    ];
  }

  List<Widget> _rail(
    BuildContext context, {
    required String title,
    required double height,
    required int itemCount,
    required Widget Function(BuildContext context, int index) itemBuilder,
    double spacing = 12,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    if (itemCount <= 0) return const <Widget>[];
    return <Widget>[
      SliverToBoxAdapter(
        child: DiscoverySectionHeader(
          title: title,
          actionLabel: actionLabel,
          onAction: onAction,
        ),
      ),
      SliverToBoxAdapter(
        child: DiscoveryRail(
          height: height,
          spacing: spacing,
          itemCount: itemCount,
          itemBuilder: itemBuilder,
        ),
      ),
    ];
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  EdgeInsets get _edge => const EdgeInsets.symmetric(horizontal: 16);

  EdgeInsets _edgePadding(BuildContext context) =>
      _edge + EdgeInsets.symmetric(horizontal: wideListInset(context));

  void _playScored(
    BuildContext context,
    List<ScoredTrack> items,
    int startIndex,
  ) {
    final tracks = <Track>[
      for (final entry in items) discoveryTrackToTrack(entry.track),
    ];
    if (tracks.isEmpty) return;
    ref
        .read(playbackProvider.notifier)
        .playTrackList(tracks, startIndex: startIndex);
  }

  void _playShelf(BuildContext context, GeneratedShelf shelf, int startIndex) {
    _playScored(context, shelf.items, startIndex);
  }

  void _shuffleShelf(BuildContext context, GeneratedShelf shelf) {
    final order = discoveryShuffleOrder(shelf.items.length, shelf.id);
    final shuffled = <ScoredTrack>[
      for (final index in order) shelf.items[index],
    ];
    if (shuffled.isEmpty) return;
    ref.read(playbackProvider.notifier).playTrackList(
      <Track>[for (final entry in shuffled) discoveryTrackToTrack(entry.track)],
      startIndex: 0,
    );
  }

  void _playLegacy(
    BuildContext context,
    RecommendationSection section,
    int tappedIndex,
  ) {
    final tracks = <Track>[];
    var startIndex = 0;
    for (var i = 0; i < section.items.length; i++) {
      final entry = section.items[i];
      if (entry.kind == RecommendedItemKind.artist) continue;
      if (i <= tappedIndex) startIndex = tracks.length;
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

  void _openShelf(BuildContext context, GeneratedShelf shelf) {
    Navigator.of(context).push(
      slidePageRoute<void>(page: DiscoveryShelfScreen(shelf: shelf)),
    );
  }

  void _openArtist(
    BuildContext context, {
    required String artistKey,
    required String name,
    String? imageUrl,
    String? providerId,
  }) {
    Navigator.of(context).push(
      slidePageRoute<void>(
        page: SimilarArtistsScreen(
          artistKey: artistKey,
          artistName: name,
          coverUrl: imageUrl,
          providerId: providerId,
        ),
      ),
    );
  }

  void _openSimilarArtists(BuildContext context, DiscoveryHome home) {
    if (home.similarArtists.isEmpty) return;
    final top = home.similarArtists.first;
    _openArtist(
      context,
      artistKey: top.artistKey,
      name: top.label,
      imageUrl: top.imageUrl,
      providerId: top.providerId,
    );
  }

  /// A favourited artist has a real provider id, so it opens the full artist
  /// page rather than the similarity view.
  void _openCollectionArtist(
    BuildContext context,
    CollectionArtistEntry entry,
  ) {
    Navigator.of(context).push(
      slidePageRoute<void>(
        page: ArtistScreen(
          artistId: entry.artistId,
          artistName: entry.name,
          coverUrl: entry.imageUrl,
          extensionId: entry.providerId,
        ),
      ),
    );
  }

  /// Exactly the routing the previous For You screen used for items produced
  /// by `forYouSectionsProvider`, including the rule that the bundled local
  /// engine's synthetic provider id must not be forwarded as an extension id.
  void _openLegacyArtist(BuildContext context, RecommendedItem item) {
    final providerId = item.providerId;
    Navigator.of(context).push(
      slidePageRoute<void>(
        page: ArtistScreen(
          artistId: item.id,
          artistName: item.title,
          coverUrl: item.imageUrl,
          extensionId: providerId != null &&
                  providerId.isNotEmpty &&
                  providerId != LocalRecommendationEngine.providerId
              ? providerId
              : null,
        ),
      ),
    );
  }

  void _openAlbum(BuildContext context, CollectionAlbumEntry entry) {
    Navigator.of(context).push(
      slidePageRoute<void>(
        page: AlbumScreen(
          albumId: entry.albumId,
          albumName: entry.name,
          coverUrl: entry.imageUrl,
          artistName: entry.artistName,
          artistId: entry.artistId,
          extensionId: entry.providerId,
        ),
      ),
    );
  }

  /// Tapping a trending row queues the visible trending list from that row, so
  /// the user hears the chart they are looking at rather than an unrelated mix.
  void _openTrending(
    BuildContext context,
    List<TrendingEntry> entries,
    TrendingEntry entry,
  ) {
    if (entry.isArtist) {
      _openArtist(context, artistKey: entry.key, name: entry.label);
      return;
    }
    final tracks = <ScoredTrack>[];
    var startIndex = 0;
    var found = false;
    for (final candidate in entries) {
      if (candidate.isArtist) continue;
      if (!found && candidate.key == entry.key) {
        startIndex = tracks.length;
        found = true;
      }
      tracks.add(_trendingToScored(candidate));
    }
    if (tracks.isEmpty) return;
    _playScored(context, tracks, startIndex);
  }

  ScoredTrack _trendingToScored(TrendingEntry entry) {
    return ScoredTrack(
      track: DiscoveryTrack(
        key: entry.key,
        title: entry.label,
        artist: entry.subtitle,
        coverUrl: entry.coverUrl,
      ),
      score: entry.score,
    );
  }

  void _resume(ContinueListeningEntry resume) {
    final queue = resume.hasQueue
        ? <Track>[for (final track in resume.queue) discoveryTrackToTrack(track)]
        : <Track>[discoveryTrackToTrack(resume.track)];
    if (queue.isEmpty) return;
    ref
        .read(playbackProvider.notifier)
        .playTrackList(queue, startIndex: resume.queueIndex.clamp(0, queue.length - 1));
  }

  void _startRadio(
    BuildContext context, {
    required String seedLabel,
    required void Function(RadioSessionController controller) start,
  }) {
    final controller = ref.read(radioSessionProvider.notifier);
    start(controller);
    Navigator.of(context).push(
      slidePageRoute<void>(page: RadioScreen(seedLabel: seedLabel)),
    );
  }

  void _resumeRadio(BuildContext context, String sessionId) {
    unawaitedResume(ref.read(radioSessionProvider.notifier), sessionId);
    Navigator.of(context).push(
      slidePageRoute<void>(page: const RadioScreen()),
    );
  }

  void unawaitedResume(RadioSessionController controller, String sessionId) {
    // Fire-and-forget: the radio screen shows its own loading state while the
    // session and its queue are restored.
    controller.resume(sessionId);
  }

  List<TrendingEntry> _trendingEntries(DiscoveryHome home) {
    switch (_trendingPeriod) {
      case TrendingPeriod.week:
        return home.trendingWeek;
      case TrendingPeriod.month:
        return home.trendingMonth;
      case TrendingPeriod.velocity:
        return home.fastestGrowing;
      case TrendingPeriod.emerging:
        return home.emergingArtists;
    }
  }

  String _trendingLabel(BuildContext context, TrendingPeriod period) {
    switch (period) {
      case TrendingPeriod.week:
        return context.l10n.discoveryTrendingWeek;
      case TrendingPeriod.month:
        return context.l10n.discoveryTrendingMonth;
      case TrendingPeriod.velocity:
        return context.l10n.discoveryTrendingVelocity;
      case TrendingPeriod.emerging:
        return context.l10n.discoveryTrendingEmerging;
    }
  }

  String? _releaseLabel(DiscoveryTrack track) {
    final released = track.releaseDate;
    if (released == null) return track.artist;
    return '${track.artist} · ${released.year}';
  }
}

// ---------------------------------------------------------------------------
// Small pieces
// ---------------------------------------------------------------------------

class _PillButton extends StatelessWidget {
  const _PillButton({
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
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
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

class _RadioStationTile extends StatelessWidget {
  const _RadioStationTile({
    required this.station,
    required this.onTap,
    this.index = 0,
  });

  final RadioStationSummary station;
  final VoidCallback onTap;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return StaggeredListItem(
      index: index,
      child: SizedBox(
        width: 132,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 132,
                height: 76,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: discoveryGradient(station.label, scheme),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.podcasts_rounded,
                  color: scheme.onSurface,
                  size: 26,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                station.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                context.l10n.discoveryPlayCount(station.playCount),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColdStartState extends StatelessWidget {
  const _ColdStartState({required this.colorScheme});

  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome_rounded,
              size: 56,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 14),
            Text(
              context.l10n.discoveryColdTitle,
              textAlign: TextAlign.center,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.discoveryColdSubtitle,
              textAlign: TextAlign.center,
              style: textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
