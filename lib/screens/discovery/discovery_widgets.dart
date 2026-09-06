/// Shared widgets for the discovery surfaces (Phase 14).
///
/// Design notes:
///   * artwork is always sized and `memCacheWidth`-bounded, so a rail of forty
///     covers cannot blow the image cache;
///   * gradients are derived from a hash of the shelf/track identity rather
///     than sampled from the bitmap — deterministic, free, and no decode on the
///     UI thread (Phase 12: no jank);
///   * every rail is a lazily-built `ListView`, and every long list a
///     `SliverList`, so a 500-item shelf costs one viewport of widgets;
///   * skeletons mirror the real layout so the swap on load has no reflow.
library;

import 'package:flutter/material.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/widgets/animation_utils.dart';
import 'package:spotiflac_android/widgets/cached_cover_image.dart';

// ---------------------------------------------------------------------------
// Track mapping
// ---------------------------------------------------------------------------

/// Maps a [DiscoveryTrack] back to the app-wide [Track] so a shelf can be
/// handed to the existing playback path unchanged (Smart Play decides
/// local → stream per track).
Track discoveryTrackToTrack(DiscoveryTrack source) {
  return Track(
    id: source.externalId?.isNotEmpty == true ? source.externalId! : source.key,
    name: source.title,
    artistName: source.artist,
    albumName: source.album,
    coverUrl: source.coverUrl,
    isrc: source.isrc,
    duration: (source.durationMs / 1000).round(),
    source: source.providerId,
  );
}

/// Maps a whole shelf.
List<Track> discoveryShelfToTracks(List<DiscoveryTrack> tracks) {
  return tracks.map(discoveryTrackToTrack).toList(growable: false);
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

/// Deterministic accent for a shelf or track, derived from its identity.
Color discoveryAccentFor(String seed, ColorScheme scheme) {
  var hash = 0x811c9dc5;
  for (final unit in seed.codeUnits) {
    hash = (hash ^ unit) * 0x01000193;
    hash &= 0x7fffffff;
  }
  final hue = (hash % 360).toDouble();
  final color = HSLColor.fromAHSL(1, hue, 0.55, 0.45).toColor();
  return Color.alphaBlend(color.withValues(alpha: 0.55), scheme.primary);
}

/// Two-stop gradient used behind artwork-less tiles.
LinearGradient discoveryGradient(String seed, ColorScheme scheme) {
  final base = discoveryAccentFor(seed, scheme);
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: <Color>[
      Color.alphaBlend(base.withValues(alpha: 0.85), scheme.surfaceContainerHighest),
      Color.alphaBlend(base.withValues(alpha: 0.35), scheme.surfaceContainerHighest),
    ],
  );
}

// ---------------------------------------------------------------------------
// Artwork
// ---------------------------------------------------------------------------

/// Square artwork with a deterministic gradient fallback.
class DiscoveryArtwork extends StatelessWidget {
  const DiscoveryArtwork({
    super.key,
    required this.seed,
    this.imageUrl,
    this.size = 128,
    this.round = false,
    this.borderRadius = 10,
    this.icon,
  });

  final String seed;
  final String? imageUrl;
  final double size;
  final bool round;
  final double borderRadius;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = imageUrl;
    final hasImage = url != null && url.isNotEmpty;

    // Local library covers are file paths; stream covers are URLs.
    // LocalOrNetworkCoverImage handles both and falls back to the gradient on
    // any error, so a missing file never leaves a hole in a rail.
    Widget fallback(BuildContext context) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(gradient: discoveryGradient(seed, scheme)),
      alignment: Alignment.center,
      child: Icon(
        icon ?? Icons.music_note_rounded,
        size: size * 0.32,
        color: scheme.onSurfaceVariant.withValues(alpha: 0.75),
      ),
    );

    final radius = BorderRadius.circular(round ? size / 2 : borderRadius);
    final child = hasImage
        ? LocalOrNetworkCoverImage(
            url: url,
            width: size,
            height: size,
            borderRadius: radius,
            localCacheWidth: (size * 2).round(),
            networkCacheWidth: (size * 2).round(),
            placeholder: fallback,
          )
        : fallback(context);

    if (round) return ClipOval(child: child);
    return ClipRRect(borderRadius: radius, child: child);
  }
}

// ---------------------------------------------------------------------------
// Cards
// ---------------------------------------------------------------------------

/// Track card for a horizontal rail.
class DiscoveryTrackCard extends StatelessWidget {
  const DiscoveryTrackCard({
    super.key,
    required this.track,
    required this.onTap,
    this.subtitle,
    this.width = 132,
    this.index = 0,
  });

  final DiscoveryTrack track;
  final VoidCallback onTap;
  final String? subtitle;
  final double width;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final label = subtitle ?? track.artist;
    return StaggeredListItem(
      index: index,
      child: SizedBox(
        width: width,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              DiscoveryArtwork(
                seed: track.key,
                imageUrl: track.coverUrl,
                size: width,
              ),
              const SizedBox(height: 8),
              Text(
                track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (label.isNotEmpty)
                Text(
                  label,
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

/// Circular artist card.
class DiscoveryArtistCard extends StatelessWidget {
  const DiscoveryArtistCard({
    super.key,
    required this.name,
    this.imageUrl,
    this.caption,
    required this.onTap,
    this.size = 116,
    this.index = 0,
  });

  final String name;
  final String? imageUrl;
  final String? caption;
  final VoidCallback onTap;
  final double size;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return StaggeredListItem(
      index: index,
      child: SizedBox(
        width: size,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(size / 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DiscoveryArtwork(
                seed: name,
                imageUrl: imageUrl,
                size: size,
                round: true,
                icon: Icons.person_rounded,
              ),
              const SizedBox(height: 8),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (caption != null && caption!.isNotEmpty)
                Text(
                  caption!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
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

/// Daily Mix tile: artwork collage over a seeded gradient.
class DiscoveryMixTile extends StatelessWidget {
  const DiscoveryMixTile({
    super.key,
    required this.shelf,
    required this.onTap,
    this.index = 0,
  });

  final GeneratedShelf shelf;
  final VoidCallback onTap;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final covers = shelf.items
        .map((entry) => entry.track.coverUrl)
        .where((url) => url != null && url!.isNotEmpty)
        .take(4)
        .cast<String>()
        .toList(growable: false);

    return StaggeredListItem(
      index: index,
      child: SizedBox(
        width: 148,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 148,
                height: 148,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: discoveryGradient(shelf.id, scheme),
                ),
                clipBehavior: Clip.antiAlias,
                child: covers.isEmpty
                    ? Center(
                        child: Icon(
                          Icons.queue_music_rounded,
                          size: 44,
                          color: scheme.onSurface.withValues(alpha: 0.7),
                        ),
                      )
                    : GridView.count(
                        crossAxisCount: 2,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        children: <Widget>[
                          for (final url in covers)
                            LocalOrNetworkCoverImage(
                              url: url,
                              width: 74,
                              height: 74,
                              localCacheWidth: 148,
                              networkCacheWidth: 148,
                              placeholder: (_) => const SizedBox.shrink(),
                            ),
                        ],
                      ),
              ),
              const SizedBox(height: 8),
              Text(
                shelf.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (shelf.subtitle.isNotEmpty)
                Text(
                  shelf.subtitle,
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

/// Continue Listening: the resume card at the top of the home.
class ContinueListeningCard extends StatelessWidget {
  const ContinueListeningCard({
    super.key,
    required this.title,
    required this.artist,
    this.album = '',
    this.coverUrl,
    required this.progress,
    this.remainingLabel = '',
    this.contextLabel = '',
    required this.onTap,
  });

  final String title;
  final String artist;
  final String album;
  final String? coverUrl;
  final double progress;
  final String remainingLabel;
  final String contextLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              DiscoveryArtwork(
                seed: title,
                imageUrl: coverUrl,
                size: 64,
                borderRadius: 10,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      <String>[
                        artist,
                        if (contextLabel.isNotEmpty) contextLabel,
                      ].where((part) => part.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        minHeight: 4,
                        backgroundColor: scheme.surfaceContainerHighest,
                      ),
                    ),
                    if (remainingLabel.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        remainingLabel,
                        style: textTheme.labelSmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: scheme.primary,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: scheme.onPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Numbered trending row.
class DiscoveryTrendingRow extends StatelessWidget {
  const DiscoveryTrendingRow({
    super.key,
    required this.rank,
    required this.label,
    required this.subtitle,
    this.coverUrl,
    this.badge,
    required this.onTap,
    this.isArtist = false,
  });

  final int rank;
  final String label;
  final String subtitle;
  final String? coverUrl;
  final String? badge;
  final VoidCallback onTap;
  final bool isArtist;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                '$rank',
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            DiscoveryArtwork(
              seed: label,
              imageUrl: coverUrl,
              size: 44,
              round: isArtist,
              borderRadius: 8,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle.isNotEmpty)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (badge != null && badge!.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  badge!,
                  style: textTheme.labelSmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

/// Section title row with an optional trailing action.
class DiscoverySectionHeader extends StatelessWidget {
  const DiscoverySectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (subtitle != null && subtitle!.isNotEmpty)
                  Text(
                    subtitle!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

/// Horizontal rail of fixed-height children.
class DiscoveryRail extends StatelessWidget {
  const DiscoveryRail({
    super.key,
    required this.height,
    required this.itemCount,
    required this.itemBuilder,
    this.spacing = 12,
  });

  final double height;
  final int itemCount;
  final Widget Function(BuildContext context, int index) itemBuilder;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: itemCount,
        separatorBuilder: (_, _) => SizedBox(width: spacing),
        itemBuilder: itemBuilder,
      ),
    );
  }
}

/// Skeleton rail shown while a shelf loads.
class DiscoveryRailSkeleton extends StatelessWidget {
  const DiscoveryRailSkeleton({
    super.key,
    this.itemCount = 5,
    this.size = 132,
    this.height = 196,
  });

  final int itemCount;
  final double size;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ShimmerLoading(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          itemCount: itemCount,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (_, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonBox(width: size, height: size, borderRadius: 12),
              const SizedBox(height: 8),
              SkeletonBox(width: size * 0.8, height: 12),
              const SizedBox(height: 6),
              SkeletonBox(width: size * 0.55, height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

/// Empty-shelf placeholder that explains itself.
class DiscoveryEmptyShelf extends StatelessWidget {
  const DiscoveryEmptyShelf({
    super.key,
    required this.title,
    required this.hint,
    this.icon = Icons.auto_awesome_rounded,
  });

  final String title;
  final String hint;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 44, color: scheme.onSurfaceVariant),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// Mood tile: gradient chip with the mood icon and name.
class DiscoveryMoodTile extends StatelessWidget {
  const DiscoveryMoodTile({
    super.key,
    required this.label,
    required this.iconName,
    required this.onTap,
    this.width = 124,
    this.index = 0,
  });

  final String label;
  final String iconName;
  final VoidCallback onTap;
  final double width;
  final int index;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StaggeredListItem(
      index: index,
      child: SizedBox(
        width: width,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            height: 76,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: discoveryGradient('mood-$label', scheme),
            ),
            child: Row(
              children: [
                Icon(
                  moodIconFor(iconName),
                  color: scheme.onSurface,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Maps the mood catalogue's icon *names* to [IconData].
///
/// Names (not `IconData`) are stored in the engine layer precisely so the pure
/// Dart module never has to import Flutter.
IconData moodIconFor(String name) {
  switch (name) {
    case 'self_improvement':
      return Icons.self_improvement_rounded;
    case 'psychology':
      return Icons.psychology_rounded;
    case 'fitness_center':
      return Icons.fitness_center_rounded;
    case 'spa':
      return Icons.spa_rounded;
    case 'nightlight':
      return Icons.nightlight_round_rounded;
    case 'celebration':
      return Icons.celebration_rounded;
    case 'flight':
      return Icons.flight_rounded;
    case 'code':
      return Icons.code_rounded;
    case 'directions_car':
      return Icons.directions_car_rounded;
    default:
      return Icons.graphic_eq_rounded;
  }
}

/// Deterministic shuffle of track keys for the "Shuffle" action, so the same
/// shelf shuffles the same way within a day.
List<int> discoveryShuffleOrder(int count, String seed) {
  if (count <= 0) return const <int>[];
  var hash = 0x811c9dc5;
  for (final unit in seed.codeUnits) {
    hash = (hash ^ unit) * 0x01000193;
    hash &= 0x7fffffff;
  }
  final order = List<int>.generate(count, (index) => index);
  for (var i = order.length - 1; i > 0; i--) {
    hash = (hash * 0x01000193) & 0x7fffffff;
    final j = hash % (i + 1);
    final tmp = order[i];
    order[i] = order[j];
    order[j] = tmp;
  }
  return order;
}

/// Formats milliseconds as `m:ss`.
String discoveryFormatDuration(int milliseconds) {
  if (milliseconds <= 0) return '';
  final totalSeconds = milliseconds ~/ 1000;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Clamps a value into 0..1 for progress bars.
double discoveryClampProgress(double value) =>
    value.isNaN ? 0 : value.clamp(0.0, 1.0);
