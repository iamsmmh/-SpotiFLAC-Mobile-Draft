/// Radio mode screen (Phase 7).
///
/// The station itself lives in [RadioService] / `ds_radio_sessions`; this screen
/// is a thin view over [radioSessionProvider] plus one behaviour the engine
/// cannot own: detecting that the player moved on and asking the service to
/// consume the track that just ended and top the queue back up.
///
/// That detection reads the same `currentMediaItemProvider` stream the rest of
/// the app uses — nothing here reaches into the audio handler, so playback,
/// gapless and crossfade behaviour are untouched.
library;

import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/radio_engine.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/discovery_providers.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/playback_provider.dart';
import 'package:spotiflac_android/screens/discovery/discovery_widgets.dart';
import 'package:spotiflac_android/utils/nav_bar_inset.dart';

class RadioScreen extends ConsumerStatefulWidget {
  const RadioScreen({super.key, this.seedLabel});

  /// Optional display name while the session is still being created.
  final String? seedLabel;

  @override
  ConsumerState<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends ConsumerState<RadioScreen> {
  String? _lastMediaId;
  ProviderSubscription<AsyncValue<MediaItem?>>? _mediaSub;
  bool _starting = true;

  @override
  void initState() {
    super.initState();
    // Start playing as soon as the session exists. `_starting` guards against
    // re-triggering when the widget rebuilds after a queue refill.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startPlayback();
    });
  }

  @override
  void dispose() {
    _mediaSub?.close();
    super.dispose();
  }

  Future<void> _startPlayback() async {
    if (!_starting) return;
    final session = ref.read(radioSessionProvider);
    if (session == null || session.queue.isEmpty) return;
    _starting = false;
    _playFrom(session, 0);
    _watchMediaChanges();
  }

  void _watchMediaChanges() {
    if (_mediaSub != null) return;
    _lastMediaId = ref.read(currentMediaItemProvider).value?.id;
    _mediaSub = ref.listenManual<AsyncValue<MediaItem?>>(
      currentMediaItemProvider,
      (_, next) {
        final id = next.value?.id;
        if (id == null || id == _lastMediaId) return;
        final previous = _lastMediaId;
        _lastMediaId = id;
        if (previous == null) return;
        unawaited(_advance());
      },
    );
  }

  Future<void> _advance() async {
    final controller = ref.read(radioSessionProvider.notifier);
    await controller.advance(skipped: false);
    final session = ref.read(radioSessionProvider);
    if (session == null || session.queue.isEmpty) return;
    await controller.refill();
  }

  void _playFrom(RadioState session, int index) {
    final tracks = <Track>[
      for (final entry in session.queue) discoveryTrackToTrack(entry.track),
    ];
    if (tracks.isEmpty) return;
    ref
        .read(playbackProvider.notifier)
        .playTrackList(tracks, startIndex: index);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final session = ref.watch(radioSessionProvider);
    final isPlaying = ref.watch(playbackPlayingProvider);
    final bottomInset = context.navBarBottomInset;

    final seedLabel =
        session?.seed.label ?? widget.seedLabel ?? context.l10n.discoveryRadioTitle;

    return Scaffold(
      body: CustomScrollView(
        slivers: <Widget>[
          SliverAppBar(
            expandedHeight: 240,
            pinned: true,
            backgroundColor: scheme.surface,
            foregroundColor: scheme.onSurface,
            actions: <Widget>[
              IconButton(
                tooltip: context.l10n.discoveryRadioStop,
                onPressed: () async {
                  await ref.read(radioSessionProvider.notifier).stop();
                  if (mounted) Navigator.of(context).maybePop();
                },
                icon: const Icon(Icons.stop_circle_outlined),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              background: Container(
                decoration: BoxDecoration(
                  gradient: discoveryGradient('radio-$seedLabel', scheme),
                ),
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 56, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.podcasts_rounded,
                              color: scheme.onSurface,
                              size: 28,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              context.l10n.discoveryRadioPlaying,
                              style: textTheme.labelLarge?.copyWith(
                                color: scheme.onSurface,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          seedLabel,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _kindLabel(context, session?.seed.kind),
                          style: textTheme.bodySmall?.copyWith(
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
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: isPlaying
                          ? () => ref.read(musicPlayerControllerProvider).pause()
                          : () => _resumeOrStart(session),
                      icon: Icon(
                        isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
                      label: Text(
                        isPlaying
                            ? context.l10n.actionPause
                            : context.l10n.discoveryPlayAll,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filledTonal(
                    tooltip: context.l10n.discoveryRadioSkip,
                    onPressed: () => _skip(),
                    icon: const Icon(Icons.skip_next_rounded),
                  ),
                ],
              ),
            ),
          ),
          if (session == null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.discoveryRadioQueueEmpty,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (session.queue.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.discoveryRadioQueueEmpty,
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _queueRow(session.queue[index], index),
                childCount: session.queue.length,
              ),
            ),
          SliverToBoxAdapter(child: SizedBox(height: bottomInset + 16)),
        ],
      ),
    );
  }

  Widget _queueRow(ScoredTrack entry, int index) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final track = entry.track;
    final isCurrent = index == 0;
    return InkWell(
      onTap: () => _jumpTo(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
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
                      color: isCurrent ? scheme.primary : null,
                    ),
                  ),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (isCurrent)
              Icon(Icons.graphic_eq_rounded, size: 18, color: scheme.primary)
            else
              Text(
                '${index + 1}',
                style: textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _resumeOrStart(RadioState? session) {
    if (session == null || session.queue.isEmpty) return;
    _playFrom(session, 0);
    _watchMediaChanges();
  }

  void _jumpTo(int index) {
    final session = ref.read(radioSessionProvider);
    if (session == null) return;
    _playFrom(session, index);
  }

  Future<void> _skip() async {
    final controller = ref.read(radioSessionProvider.notifier);
    await controller.advance(skipped: true);
    final session = ref.read(radioSessionProvider);
    if (session == null || session.queue.isEmpty) return;
    await controller.refill();
    if (mounted) _playFrom(session, 0);
  }

  String _kindLabel(BuildContext context, RadioKind? kind) {
    switch (kind) {
      case RadioKind.artist:
        return context.l10n.discoveryRadioArtist;
      case RadioKind.track:
        return context.l10n.discoveryRadioTrack;
      case RadioKind.genre:
        return context.l10n.discoveryRadioGenre;
      case RadioKind.mood:
        return context.l10n.discoveryRadioMood;
      case null:
        return context.l10n.discoveryRadioTitle;
    }
  }
}
