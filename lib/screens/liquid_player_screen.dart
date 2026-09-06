import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/constants/app_info.dart';
import 'package:spotiflac_android/engine/smart_play.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/audio_effects_provider.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/now_playing_lyrics_provider.dart';
import 'package:spotiflac_android/providers/playback_telemetry_provider.dart';
import 'package:spotiflac_android/providers/streaming_engine_provider.dart';
import 'package:spotiflac_android/screens/settings/equalizer_page.dart';
import 'package:spotiflac_android/screens/track_metadata_screen.dart';
import 'package:spotiflac_android/services/cover_cache_manager.dart';
import 'package:spotiflac_android/services/history_database.dart';
import 'package:spotiflac_android/ui/widgets/liquid_glass_player_sheet.dart';
import 'package:spotiflac_android/utils/lyrics_parser.dart';
import 'package:spotiflac_android/utils/string_utils.dart';
import 'package:spotiflac_android/widgets/liquid/liquid_glass.dart';
import 'package:spotiflac_android/widgets/liquid/liquid_visualizer.dart';
import 'package:spotiflac_android/widgets/playback_telemetry_card.dart';
import 'package:spotiflac_android/widgets/player_artwork.dart';
import 'package:spotiflac_android/widgets/synced_lyrics_viewer.dart';

/// Hero tag for the Liquid player artwork (kept separate from the classic
/// player's tag so both routes can coexist).
const String kLiquidNowPlayingArtworkHeroTag = 'liquid-now-playing-artwork';

/// Glass full-player route — same drag-to-dismiss mechanics as the classic
/// Now Playing route, rendered as a frosted layer.
class LiquidNowPlayingRoute extends PageRoute<void> {
  LiquidNowPlayingRoute() : super(fullscreenDialog: true);

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 400);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      const LiquidPlayerScreen();

  /// Exposes the (protected) [PageRoute] transition controller to the screen,
  /// which drives the drag-to-dismiss gesture.
  Animation<double>? get transitionAnimation => controller;

  void startDrag() {
    controller?.stop();
    changedInternalState();
  }

  void updateDrag(DragUpdateDetails details, double pageHeight) {
    controller?.value -= (details.primaryDelta ?? 0) / pageHeight;
  }

  void endDrag(DragEndDetails details, double pageHeight) {
    changedInternalState();
    final velocity = (details.primaryVelocity ?? 0) / pageHeight;
    final value = controller?.value ?? 1.0;
    if (velocity > 1.0 || (velocity >= 0 && value < 0.7)) {
      navigator?.pop();
    } else {
      controller?.fling();
    }
  }

  void cancelDrag() {
    changedInternalState();
    controller?.fling();
  }
}

class LiquidPlayerScreen extends ConsumerStatefulWidget {
  const LiquidPlayerScreen({super.key});

  @override
  ConsumerState<LiquidPlayerScreen> createState() => _LiquidPlayerScreenState();
}

class _LiquidPlayerScreenState extends ConsumerState<LiquidPlayerScreen>
    with SingleTickerProviderStateMixin {
  double? _dragPositionMs;
  LiquidNowPlayingRoute? get _route =>
      ModalRoute.of(context) as LiquidNowPlayingRoute?;

  @override
  Widget build(BuildContext context) {
    final mediaItem = ref.watch(currentMediaItemProvider).value;
    if (mediaItem == null) {
      return const Scaffold(
        body: GlassScrim(child: Center(child: CircularProgressIndicator())),
      );
    }

    final isPlaying = ref.watch(playbackPlayingProvider);
    final isLoading = ref.watch(playbackLoadingProvider);
    final playbackState = ref.watch(playbackStateProvider).value;
    final position = ref.watch(playbackPositionProvider);
    final engineContext = ref.watch(enginePlayContextProvider);
    final settings = ref.watch(engineSettingsProvider);
    final duration = mediaItem.duration ?? Duration.zero;
    final durationMs = duration.inMilliseconds;
    final effectivePosition = _dragPositionMs ??
        (durationMs > 0
            ? position.inMilliseconds.clamp(0, durationMs)
            : 0);
    final progress = durationMs > 0 ? effectivePosition / durationMs : 0.0;
    final isAmoled = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final l10n = context.l10n;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onVerticalDragStart: (_) => _route?.startDrag(),
        onVerticalDragUpdate: (details) {
          _route?.updateDrag(details, MediaQuery.sizeOf(context).height);
          // Also drive a subtle visual parallax via the route controller.
          setState(() {});
        },
        onVerticalDragEnd: (details) =>
            _route?.endDrag(details, MediaQuery.sizeOf(context).height),
        onVerticalDragCancel: _route?.cancelDrag,
        child: AnimatedBuilder(
          animation:
              _route?.transitionAnimation ?? const AlwaysStoppedAnimation(1.0),
          builder: (context, child) {
            final value = _route?.transitionAnimation?.value ?? 1.0;
            return Opacity(
              opacity: value.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, (1 - value) * 80),
                child: child,
              ),
            );
          },
          child: GlassScrim(
            backgroundImage: _artworkProvider(mediaItem),
            tintColor: isAmoled ? Colors.black : scheme.surface,
            blurSigma: settings.glassBlurSigma,
            child: SafeArea(
              child: Column(
                children: [
                  _buildTopBar(),
                  const Spacer(),
                  _buildArtwork(mediaItem, settings),
                  const Spacer(),
                  _buildTrackInfo(mediaItem, engineContext),
                  _buildVisualizer(settings),
                  _buildSeekBar(duration, progress),
                  _buildTransport(isPlaying, isLoading, playbackState, l10n),
                  _buildSecondaryRow(),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  ImageProvider? _artworkProvider(MediaItem mediaItem) {
    final artUri = mediaItem.artUri?.toString() ?? '';
    if (artUri.isEmpty) return null;
    if (artUri.startsWith('http')) {
      // Cached via the shared cover cache manager network provider.
      return CachedNetworkImageProvider(
        artUri,
        cacheManager: CoverCacheManager.instance,
      );
    }
    if (artUri.startsWith('file://')) {
      return FileImage(File(Uri.parse(artUri).toFilePath()));
    }
    return null;
  }

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          GlassIconButton(
            icon: Icons.keyboard_arrow_down,
            tooltip: 'Close player',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          const Spacer(),
          Column(
            children: [
              Text(
                'NOW PLAYING',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  letterSpacing: 2,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              Text(
                AppInfo.appName,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const Spacer(),
          GlassIconButton(
            icon: Icons.more_horiz,
            tooltip: 'More audio controls',
            onPressed: () => _openMoreSheet(),
          ),
        ],
      ),
    );
  }

  Widget _buildArtwork(MediaItem mediaItem, EngineSettings engineSettings) {
    return Hero(
      tag: kLiquidNowPlayingArtworkHeroTag,
      child: Container(
        width: engineSettings.largeArtworkMode ? 340 : 280,
        height: engineSettings.largeArtworkMode ? 340 : 280,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 48,
              offset: const Offset(0, 22),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: PlayerArtwork(
            artUri: mediaItem.artUri?.toString(),
            colorScheme: Theme.of(context).colorScheme,
            cacheWidth: 720,
            iconSize: 64,
          ),
        ),
      ),
    );
  }

  Widget _buildTrackInfo(MediaItem mediaItem, EnginePlayContext? contextInfo) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
      child: Column(
        children: [
          Text(
            mediaItem.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            [mediaItem.artist, mediaItem.album]
                .where((part) => part != null && part.isNotEmpty)
                .join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (contextInfo != null && contextInfo.mode != SmartPlayMode.unavailable)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Tooltip(
                message: 'Stream info',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _openTelemetrySheet,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      GlassChip(
                        icon: _modeIcon(contextInfo.mode),
                        label: _modeLabel(contextInfo),
                        selected: true,
                      ),
                      const SizedBox(width: 8),
                      if (contextInfo.characteristics.compactLabel.isNotEmpty)
                        GlassChip(
                          label: contextInfo.characteristics.compactLabel,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (ref.watch(engineOfflineModeProvider))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: GlassChip(
                icon: Icons.cloud_off_outlined,
                label: 'Offline mode',
                selected: true,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVisualizer(EngineSettings settings) {
    final isPlaying = ref.watch(playbackPlayingProvider);
    return SizedBox(
      height: 64,
      child: LiquidVisualizer(
        style: settings.visualizerStyle,
        playing: isPlaying,
        performanceMode: settings.visualizerPerformanceMode,
        colorScheme: Theme.of(context).colorScheme,
        height: 64,
      ),
    );
  }

  Widget _buildSeekBar(Duration duration, double progress) {
    final controller = ref.read(musicPlayerControllerProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          GlassSlider(
            value: progress,
            onChanged: (value) {
              setState(() {
                _dragPositionMs = value * duration.inMilliseconds;
              });
            },
            onChangeEnd: (value) {
              final target = value * duration.inMilliseconds;
              setState(() {
                _dragPositionMs = null;
              });
              controller.seek(Duration(milliseconds: target.round()));
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  formatClock(effectiveSeconds(_dragPositionMs)),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
                Text(
                  formatClock(duration.inSeconds),
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  int effectiveSeconds(double? positionMs) =>
      ((positionMs ?? 0) / 1000).round();

  Widget _buildTransport(
    bool isPlaying,
    bool isLoading,
    PlaybackState? playbackState,
    AppLocalizations l10n,
  ) {
    final controller = ref.read(musicPlayerControllerProvider);
    final shuffle = playbackState?.shuffleMode == AudioServiceShuffleMode.all;
    final repeat = playbackState?.repeatMode ?? AudioServiceRepeatMode.none;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GlassIconButton(
            icon: shuffle ? Icons.shuffle : Icons.shuffle_outlined,
            tooltip: shuffle ? l10n.nowPlayingShuffleOn : 'Shuffle off',
            onPressed: () => controller.setShuffle(!shuffle),
          ),
          const SizedBox(width: 18),
          GlassIconButton(
            icon: Icons.skip_previous,
            tooltip: l10n.nowPlayingPreviousTrack,
            size: 58,
            onPressed: controller.previous,
          ),
          const SizedBox(width: 18),
          GlassIconButton(
            icon: isLoading
                ? Icons.hourglass_top
                : isPlaying
                ? Icons.pause
                : Icons.play_arrow,
            tooltip: isPlaying ? l10n.actionPause : l10n.tooltipPlay,
            size: 78,
            prominent: true,
            onPressed: isLoading
                ? null
                : () => controller.togglePlayPause(isPlaying),
          ),
          const SizedBox(width: 18),
          GlassIconButton(
            icon: Icons.skip_next,
            tooltip: l10n.nowPlayingNextTrack,
            size: 58,
            onPressed: controller.next,
          ),
          const SizedBox(width: 18),
          GlassIconButton(
            icon: _repeatIcon(repeat),
            tooltip: _repeatLabel(repeat, l10n),
            onPressed: () => controller.setRepeatMode(_nextRepeat(repeat)),
          ),
        ],
      ),
    );
  }

  static IconData _repeatIcon(AudioServiceRepeatMode repeat) =>
      switch (repeat) {
        AudioServiceRepeatMode.one => Icons.repeat_one,
        AudioServiceRepeatMode.all => Icons.repeat,
        _ => Icons.repeat_outlined,
      };

  static AudioServiceRepeatMode _nextRepeat(AudioServiceRepeatMode repeat) =>
      switch (repeat) {
        AudioServiceRepeatMode.one => AudioServiceRepeatMode.all,
        AudioServiceRepeatMode.all => AudioServiceRepeatMode.none,
        _ => AudioServiceRepeatMode.one,
      };

  static String _repeatLabel(
    AudioServiceRepeatMode repeat,
    AppLocalizations l10n,
  ) => switch (repeat) {
    AudioServiceRepeatMode.one => l10n.nowPlayingRepeatOne,
    AudioServiceRepeatMode.all => l10n.nowPlayingRepeatAll,
    _ => l10n.nowPlayingRepeatOff,
  };

  Widget _buildSecondaryRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GlassIconButton(
          icon: Icons.travel_explore_rounded,
          tooltip: 'Streaming providers',
          onPressed: _openProvidersSheet,
        ),
        const SizedBox(width: 16),
        GlassIconButton(
          icon: Icons.queue_music,
          tooltip: 'Queue',
          onPressed: _openQueueSheet,
        ),
        const SizedBox(width: 16),
        GlassIconButton(
          icon: Icons.bedtime_outlined,
          tooltip: 'Sleep timer',
          onPressed: _openSleepTimerSheet,
        ),
        const SizedBox(width: 16),
        GlassIconButton(
          icon: Icons.lyrics_outlined,
          tooltip: 'Lyrics',
          onPressed: _openLyricsSheet,
        ),
        const SizedBox(width: 16),
        GlassIconButton(
          icon: Icons.info_outline,
          tooltip: 'Track details',
          onPressed: _openTrackDetails,
        ),
      ],
    );
  }

  /// Opens the dual-mode sheet: pick a streaming provider (with
  /// universal fallback) or queue a lossless FLAC download.
  Future<void> _openProvidersSheet() async {
    final mediaItem = ref.read(currentMediaItemProvider).value;
    Track? track;
    if (mediaItem != null) {
      track = ref
          .read(streamingEngineControllerProvider)
          .trackFor(mediaItem.id);
    }
    await LiquidGlassPlayerSheet.show(
      context,
      track: track,
      mediaItem: mediaItem,
    );
  }

  Future<void> _openQueueSheet() async {
    final queue = ref.read(playQueueProvider).value ?? const <MediaItem>[];
    if (queue.isEmpty) return;
    final controller = ref.read(musicPlayerControllerProvider);
    await showLiquidBottomSheet<void>(
      context: context,
      title: 'Queue',
      subtitle: Text('${queue.length} tracks'),
      builder: (sheetContext) => ListView.separated(
        shrinkWrap: true,
        itemCount: queue.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, index) {
          final item = queue[index];
          final current = ref.read(currentMediaItemProvider).value;
          final isCurrent = item.id == current?.id;
          return ListTile(
            leading: SizedBox(
              width: 40,
              height: 40,
              child: PlayerArtwork(
                artUri: item.artUri?.toString(),
                colorScheme: Theme.of(sheetContext).colorScheme,
                iconSize: 18,
              ),
            ),
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontWeight: isCurrent ? FontWeight.w700 : null),
            ),
            subtitle: Text(
              item.artist ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () {
              Navigator.of(sheetContext).pop();
              controller.jumpTo(index);
            },
          );
        },
      ),
    );
  }

  Future<void> _openSleepTimerSheet() async {
    final sleepTimer = ref.read(sleepTimerProvider.notifier);
    await showLiquidBottomSheet<void>(
      context: context,
      title: 'Sleep timer',
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final minutes in const [15, 30, 45, 60])
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text('$minutes minutes'),
              onTap: () {
                sleepTimer.start(Duration(minutes: minutes));
                Navigator.of(sheetContext).pop();
              },
            ),
          ListTile(
            leading: const Icon(Icons.trending_flat),
            title: const Text('End of track'),
            onTap: () {
              sleepTimer.endOfTrack();
              Navigator.of(sheetContext).pop();
            },
          ),
          ListTile(
            leading: const Icon(Icons.timer_off_outlined),
            title: const Text('Stop timer'),
            onTap: () {
              sleepTimer.stop();
              Navigator.of(sheetContext).pop();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _openLyricsSheet() async {
    await showLiquidBottomSheet<void>(
      context: context,
      title: 'Lyrics',
      subtitle: const Text('Tap a line to jump to that moment'),
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.62,
        child: const _LyricsSheetContent(),
      ),
    );
  }

  Future<void> _openTelemetrySheet() async {
    await showLiquidBottomSheet<void>(
      context: context,
      title: 'Stream info',
      subtitle: const Text('Codec · bitrate · sample rate · source'),
      builder: (sheetContext) => const _TelemetrySheetContent(),
    );
  }

  Future<void> _openTrackDetails() async {
    final mediaItem = ref.read(currentMediaItemProvider).value;
    if (mediaItem == null) return;
    final engine = ref.read(streamingEngineControllerProvider);
    final track = engine.trackFor(mediaItem.id);
    if (track == null) return;
    final item = await ref
        .read(downloadHistoryProvider.notifier)
        .findExistingTrackAsync(
          HistoryLookupRequest(
            spotifyId: track.id,
            isrc: track.isrc,
            trackName: track.name,
            artistName: track.artistName,
          ),
        );
    if (!mounted) return;
    if (item == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TrackMetadataScreen(item: item),
      ),
    );
  }

  Future<void> _openMoreSheet() async {
    final controller = ref.read(musicPlayerControllerProvider);
    await showLiquidBottomSheet<void>(
      context: context,
      title: 'Audio controls',
      builder: (sheetContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _AudioAdjustmentRow(
            icon: Icons.volume_up_outlined,
            label: 'Volume',
            value: 1.0,
            onChanged: (v) => controller.setVolume(v),
          ),
          _AudioAdjustmentRow(
            icon: Icons.speed,
            label: 'Playback speed',
            value: 1.0,
            min: 0.5,
            max: 2.0,
            onChanged: (v) => controller.setPlaybackRate(v),
          ),
          _AudioAdjustmentRow(
            icon: Icons.surround_sound_outlined,
            label: 'Balance',
            value: 0.5,
            min: 0,
            max: 1,
            onChanged: (v) => controller.setBalance((v * 2) - 1),
          ),
          ListTile(
            leading: const Icon(Icons.graphic_eq_rounded),
            title: const Text('Equalizer & effects'),
            subtitle: Consumer(
              builder: (context, ref, _) {
                final effects = ref.watch(audioEffectsProvider);
                final settings = effects.settings;
                final label = !effects.capabilities.any
                    ? 'Not available on this device'
                    : !settings.enabled
                    ? 'Off'
                    : settings.presetName ?? 'Custom curve';
                return Text(label);
              },
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(sheetContext).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: EqualizerPage()),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  static IconData? _modeIcon(SmartPlayMode mode) => switch (mode) {
    SmartPlayMode.local => Icons.offline_pin_outlined,
    SmartPlayMode.stream => Icons.stream_outlined,
    SmartPlayMode.download => Icons.downloading_outlined,
    SmartPlayMode.downloadAndPlay => Icons.south_outlined,
    SmartPlayMode.unavailable => Icons.cloud_off_outlined,
  };

  static String _modeLabel(EnginePlayContext contextInfo) =>
      contextInfo.mode.label;
}

class _AudioAdjustmentRow extends StatefulWidget {
  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _AudioAdjustmentRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
  });

  @override
  State<_AudioAdjustmentRow> createState() => _AudioAdjustmentRowState();
}

class _AudioAdjustmentRowState extends State<_AudioAdjustmentRow> {
  late double _value = widget.value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(widget.icon),
        const SizedBox(width: 12),
        Expanded(child: Text(widget.label)),
        SizedBox(
          width: 160,
          child: GlassSlider(
            value: (_value - widget.min) / (widget.max - widget.min),
            onChanged: (v) {
              setState(() => _value = widget.min + v * (widget.max - widget.min));
              widget.onChanged(_value);
            },
          ),
        ),
      ],
    );
  }
}

/// Sheet content that renders the synchronized lyrics viewer for the current
/// track, fed by the live playback providers.
class _LyricsSheetContent extends ConsumerWidget {
  const _LyricsSheetContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyricsAsync = ref.watch(nowPlayingLyricsProvider);
    final position = ref.watch(playbackPositionProvider);
    final playing = ref.watch(playbackPlayingProvider);
    final loading = ref.watch(playbackLoadingProvider);
    final controller = ref.read(musicPlayerControllerProvider);

    final lyrics = lyricsAsync.value ?? ParsedLyrics.empty;
    if (lyricsAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (lyrics.isEmpty || lyrics.lines.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lyrics_outlined, size: 48),
            SizedBox(height: 12),
            Text('No lyrics for this track'),
          ],
        ),
      );
    }

    return SyncedLyricsViewer(
      lyrics: lyrics,
      position: position,
      playing: playing,
      loading: loading,
      onSeek: (time) => controller.seek(time),
    );
  }
}

/// Sheet content that renders the real-time stream/playback metrics overlay
/// plus the offline-mode quick toggle.
class _TelemetrySheetContent extends ConsumerWidget {
  const _TelemetrySheetContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final telemetry = ref.watch(playbackTelemetryProvider);
    final offline = ref.watch(engineOfflineModeProvider);
    final notifier = ref.read(engineSettingsProvider.notifier);

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PlaybackTelemetryCard(telemetry: telemetry),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.cloud_off_outlined, size: 20),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Offline mode',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      'Local files only — no network resolves',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              Switch(value: offline, onChanged: notifier.setOfflineMode),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
