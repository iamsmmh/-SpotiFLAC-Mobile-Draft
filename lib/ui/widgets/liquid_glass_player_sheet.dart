import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:spotiflac_android/constants/app_info.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_queue_provider.dart';
import 'package:spotiflac_android/providers/multi_provider_stream_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/settings_provider.dart';
import 'package:spotiflac_android/services/multi_provider_stream_service.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/ui/widgets/liquid_glass_container.dart';
import 'package:spotiflac_android/widgets/app_bottom_sheet.dart';
import 'package:spotiflac_android/widgets/player_artwork.dart';

/// Liquid Glass full-screen player modal sheet for SpotiFLAC Mobile.
///
/// Dual-mode control surface:
///   * Streaming mode — pick any of the 8 ecosystem providers from the glass
///     chip row; the [MultiProviderStreamService] resolves a stream (with the
///     universal YouTube fallback) and plays it through the app's
///     [audio_service] handler, so background playback and the mini player keep
///     working.
///   * Download mode — one tap queues a lossless FLAC download through the
///     existing native download pipeline (SAF + extensions untouched).
///
/// Present with [show] (modal route over the current route, glass scrim).
class LiquidGlassPlayerSheet extends ConsumerStatefulWidget {
  /// The track being played / previewed. May be null when the sheet is opened
  /// from an already-loaded [MediaItem] without catalog metadata.
  final Track? track;

  /// The current media item (artwork/title) when a track object isn't at hand.
  final MediaItem? mediaItem;

  const LiquidGlassPlayerSheet({super.key, this.track, this.mediaItem});

  /// Shows the sheet as a transparent modal route over the app.
  static Future<void> show(
    BuildContext context, {
    Track? track,
    MediaItem? mediaItem,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black.withValues(alpha: 0.55),
        transitionDuration: const Duration(milliseconds: 380),
        pageBuilder: (context, animation, secondaryAnimation) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.12),
                end: Offset.zero,
              ).animate(curved),
              child: LiquidGlassPlayerSheet(
                track: track,
                mediaItem: mediaItem,
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  ConsumerState<LiquidGlassPlayerSheet> createState() =>
      _LiquidGlassPlayerSheetState();
}

class _LiquidGlassPlayerSheetState
    extends ConsumerState<LiquidGlassPlayerSheet> {
  StreamProviderId? _resolvingProvider;
  String? _statusMessage;
  bool _downloadQueued = false;

  String get _title =>
      widget.track?.name ?? widget.mediaItem?.title ?? AppInfo.appName;
  String get _artist =>
      widget.track?.artistName ?? widget.mediaItem?.artist ?? '';
  String? get _artUri =>
      widget.track?.coverUrl ?? widget.mediaItem?.artUri?.toString();

  StreamTrackRequest get _request {
    final track = widget.track;
    if (track != null) return StreamTrackRequest.fromTrack(track);
    final item = widget.mediaItem;
    return StreamTrackRequest(
      title: item?.title ?? _title,
      artist: item?.artist ?? _artist,
      album: item?.album,
      duration: item?.duration,
      coverUrl: item?.artUri?.toString(),
      previewUrl: item?.extras?['previewUrl'] as String?,
    );
  }

  Future<void> _playWithProvider(StreamProviderId provider) async {
    setState(() {
      _resolvingProvider = provider;
      _statusMessage = null;
    });
    await ref.read(activeStreamProviderProvider.notifier).select(provider);
    try {
      final service = ref.read(multiProviderStreamServiceProvider);
      final resolved = await service.resolveStream(
        _request,
        preferredProvider: provider,
      );
      if (!mounted) return;

      final trackSeconds = widget.track?.duration;
      final duration = trackSeconds != null && trackSeconds > 0
          ? Duration(seconds: trackSeconds)
          : widget.mediaItem?.duration;

      final media = PlayableMedia(
        id: 'stream-${resolved.provider.name}-'
            '${DateTime.now().millisecondsSinceEpoch}',
        source: resolved.uri.toString(),
        title: widget.track?.name ?? resolved.matchedTitle,
        artist: widget.track?.artistName ?? resolved.matchedArtist ?? _artist,
        album: widget.track?.albumName ?? widget.mediaItem?.album ?? '',
        artUri: _artUri,
        duration: duration,
        qualityLabel: resolved.qualityLabel,
        sourceLabel: StreamProviderInfo.of(resolved.provider).displayName,
        providerId: resolved.provider.name,
        playbackMode: 'stream',
      );

      await ref.read(musicPlayerControllerProvider).playSingle(media);
      if (!mounted) return;
      setState(() {
        _resolvingProvider = null;
        _statusMessage = resolved.viaFallback
            ? 'Playing via ${StreamProviderInfo.of(resolved.provider).displayName}'
                  ' (fallback) · ${resolved.qualityLabel}'
            : 'Playing via ${StreamProviderInfo.of(resolved.provider).displayName}'
                  ' · ${resolved.qualityLabel}';
      });
    } on StreamResolutionException catch (e) {
      if (!mounted) return;
      setState(() {
        _resolvingProvider = null;
        _statusMessage = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resolvingProvider = null;
        _statusMessage = 'Could not start stream: $e';
      });
    }
  }

  void _queueFlacDownload() {
    final track = widget.track;
    if (track == null) {
      setState(() => _statusMessage = 'Open this track from the library '
          'to download it losslessly');
      return;
    }
    final settings = ref.read(settingsProvider);
    final service = track.source?.trim().isNotEmpty == true
        ? track.source!
        : settings.defaultService;
    ref
        .read(downloadQueueProvider.notifier)
        .addMultipleToQueue([track], service);
    setState(() {
      _downloadQueued = true;
      _statusMessage = 'Lossless FLAC download queued';
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final activeProvider = ref.watch(activeStreamProviderProvider);

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            16,
            16,
            MediaQuery.viewInsetsOf(context).bottom + 24,
          ),
          child: LiquidGlassContainer(
            borderRadius: 32,
            blurSigma: 22,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Center(
                        child: AppSheetHandle(margin: EdgeInsets.zero),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Center(
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(24),
                        child: SizedBox(
                          width: 168,
                          height: 168,
                          child: PlayerArtwork(
                            artUri: _artUri,
                            colorScheme: scheme,
                            cacheWidth: 360,
                            iconSize: 56,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (_artist.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          _artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                _SectionLabel(text: 'Stream provider'),
                const SizedBox(height: 10),
                _ProviderChipWrap(
                  active: activeProvider,
                  resolving: _resolvingProvider,
                  onSelected: _playWithProvider,
                ),
                if (_resolvingProvider != null) ...[
                  const SizedBox(height: 14),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Resolving ${StreamProviderInfo.of(_resolvingProvider!).displayName}…',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
                if (_statusMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _statusMessage!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                _SectionLabel(text: 'Offline mode'),
                const SizedBox(height: 10),
                _FlacDownloadButton(
                  queued: _downloadQueued,
                  onPressed: _queueFlacDownload,
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        letterSpacing: 1.6,
        fontWeight: FontWeight.w700,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// Horizontal-wrapping row of provider glass chips. Tapping a chip starts
/// streaming immediately with that provider (fallback handled by the service).
class _ProviderChipWrap extends StatelessWidget {
  final StreamProviderId active;
  final StreamProviderId? resolving;
  final ValueChanged<StreamProviderId> onSelected;

  const _ProviderChipWrap({
    required this.active,
    required this.resolving,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final info in StreamProviderInfo.all)
          _ProviderChip(
            info: info,
            selected: info.id == active,
            busy: info.id == resolving,
            onTap: () => onSelected(info.id),
          ),
      ],
    );
  }
}

class _ProviderChip extends StatelessWidget {
  final StreamProviderInfo info;
  final bool selected;
  final bool busy;
  final VoidCallback onTap;

  const _ProviderChip({
    required this.info,
    required this.selected,
    required this.busy,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: busy ? null : onTap,
        child: LiquidGlassContainer(
          borderRadius: 999,
          blurSigma: 10,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          tintOpacity: selected ? 0.22 : 0.08,
          borderOpacity: selected ? 0.32 : 0.18,
          enableShadow: false,
          accentColor: selected ? scheme.primary : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (busy)
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                )
              else
                Icon(
                  _iconFor(info.id),
                  size: 16,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
              const SizedBox(width: 7),
              Text(
                info.shortName,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? scheme.primary : scheme.onSurface,
                ),
              ),
              if (info.requiresCredentials) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.workspace_premium_outlined,
                  size: 12,
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.7),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconFor(StreamProviderId id) => switch (id) {
    StreamProviderId.spotify => Icons.podcasts_rounded,
    StreamProviderId.youtube => Icons.smart_display_outlined,
    StreamProviderId.appleMusic => Icons.apple_rounded,
    StreamProviderId.tidal => Icons.waves_rounded,
    StreamProviderId.qobuz => Icons.high_quality_rounded,
    StreamProviderId.deezer => Icons.library_music_outlined,
    StreamProviderId.amazonMusic => Icons.shopping_bag_outlined,
    StreamProviderId.soundCloud => Icons.graphic_eq_rounded,
  };
}

/// The single-button lossless FLAC download action.
class _FlacDownloadButton extends StatelessWidget {
  final bool queued;
  final VoidCallback onPressed;

  const _FlacDownloadButton({required this.queued, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary.withValues(alpha: 0.92),
          foregroundColor: scheme.onPrimary,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        onPressed: queued ? null : onPressed,
        icon: Icon(queued ? Icons.check_circle_rounded : Icons.download_rounded),
        label: Text(
          queued
              ? 'FLAC download queued'
              : 'Download lossless FLAC for offline',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
