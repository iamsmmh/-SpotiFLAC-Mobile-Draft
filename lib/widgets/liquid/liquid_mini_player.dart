import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/engine/smart_play.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/streaming_engine_provider.dart';
import 'package:spotiflac_android/screens/liquid_player_screen.dart';
import 'package:spotiflac_android/widgets/liquid/liquid_glass.dart';
import 'package:spotiflac_android/widgets/player_artwork.dart';

/// Liquid Glass mini player.
///
/// Keeps the exact same semantics as the classic [MiniPlayer] (dismiss = stop,
/// tap = full player, hero artwork) while rendering as a floating frosted bar
/// with source/quality badges from the streaming engine.
class LiquidMiniPlayer extends ConsumerStatefulWidget {
  const LiquidMiniPlayer({super.key});

  @override
  ConsumerState<LiquidMiniPlayer> createState() => _LiquidMiniPlayerState();
}

class _LiquidMiniPlayerState extends ConsumerState<LiquidMiniPlayer> {
  String? _dismissedItemId;

  @override
  Widget build(BuildContext context) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    if (mediaItem == null) return const SizedBox.shrink();

    final isPlaying = ref.watch(playbackPlayingProvider);
    final isLoading = ref.watch(playbackLoadingProvider);
    if (mediaItem.id == _dismissedItemId && !isPlaying) {
      return const SizedBox.shrink();
    }

    final controller = ref.read(musicPlayerControllerProvider);
    final contextInfo = ref.watch(enginePlayContextProvider);
    final position = ref.watch(playbackPositionProvider);
    final duration = mediaItem.duration ?? Duration.zero;
    final progress = duration.inMilliseconds <= 0
        ? 0.0
        : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      child: Dismissible(
        key: ValueKey('liquid-mini-player-${mediaItem.id}'),
        direction: DismissDirection.horizontal,
        onDismissed: (_) {
          setState(() => _dismissedItemId = mediaItem.id);
          controller.stop();
        },
        child: GlassSurface(
          borderRadius: BorderRadius.circular(18),
          style: LiquidGlassStyle(
            blurSigma: 22,
            tintAlpha: 0.30,
            borderAlpha: 0.26,
            shadowAlpha: 0.35,
          ),
          padding: EdgeInsets.zero,
          child: Stack(
            children: [
              Positioned(
                top: 0,
                left: 14,
                right: 14,
                child: _MiniPlayerProgress(progress: progress),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: () {
                        Navigator.of(
                          context,
                          rootNavigator: true,
                        ).push(LiquidNowPlayingRoute());
                      },
                      child: Row(
                        children: [
                          Hero(
                            tag: kLiquidNowPlayingArtworkHeroTag,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: 44,
                                height: 44,
                                child: PlayerArtwork(
                                  artUri: mediaItem.artUri?.toString(),
                                  colorScheme: scheme,
                                  cacheWidth: 132,
                                  iconSize: 22,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 190),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  mediaItem.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Flexible(
                                      child: Text(
                                        mediaItem.artist ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: scheme.onSurfaceVariant,
                                            ),
                                      ),
                                    ),
                                    if (contextInfo != null) ...[
                                      const SizedBox(width: 6),
                                      _SourceBadge(contextInfo: contextInfo),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    if (isLoading)
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.primary,
                        ),
                      )
                    else
                      GlassIconButton(
                        icon: isPlaying ? Icons.pause : Icons.play_arrow,
                        tooltip: isPlaying
                            ? l10n.actionPause
                            : l10n.tooltipPlay,
                        size: 44,
                        prominent: true,
                        onPressed: () =>
                            controller.togglePlayPause(isPlaying),
                      ),
                    GlassIconButton(
                      icon: Icons.skip_previous,
                      tooltip: l10n.nowPlayingPreviousTrack,
                      size: 44,
                      onPressed: controller.previous,
                    ),
                    GlassIconButton(
                      icon: Icons.skip_next,
                      tooltip: l10n.nowPlayingNextTrack,
                      size: 44,
                      onPressed: controller.next,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  final EnginePlayContext contextInfo;

  const _SourceBadge({required this.contextInfo});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isStream = contextInfo.mode == SmartPlayMode.stream;
    final label = contextInfo.sourceLabel;
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: (isStream ? scheme.primary : scheme.tertiary).withValues(
          alpha: 0.16,
        ),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          color: isStream
              ? scheme.onPrimaryContainer
              : scheme.onTertiaryContainer,
        ),
      ),
    );
  }
}

/// Tiny progress sliver pinned to the top edge of the glass card.
class _MiniPlayerProgress extends StatelessWidget {
  final double progress;

  const _MiniPlayerProgress({required this.progress});

  @override
  Widget build(BuildContext context) {
    return GlassProgressBar(value: progress, height: 2.5);
  }
}
