import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:spotiflac_android/utils/lyrics_parser.dart';
import 'package:spotiflac_android/utils/synced_lyrics_scroll.dart';

/// A self-contained, real-time synchronized-lyrics viewer.
///
/// Renders [LyricsParser] output (LRC / enhanced-LRC / TTML) as a scrolling
/// list that
///   * auto-scrolls the active line to the vertical centre as playback
///     advances,
///   * highlights the current line (past/future lines dim progressively), and
///   * lets the user tap any line to seek — the "manual jump-to-timestamp"
///     affordance.
///
/// The widget is deliberately *unaware of Riverpod*: callers feed it the
/// current [position], [playing] and [loading] transport state (typically from
/// `playbackPositionProvider` / `playbackPlayingProvider` / `playbackLoadingProvider`)
/// and receive seeks back through [onSeek]. This keeps the timing/scroll
/// behaviour unit-testable without a provider tree and lets both the classic
/// and Liquid Glass players share one implementation.
class SyncedLyricsViewer extends StatefulWidget {
  final ParsedLyrics lyrics;

  /// Current playback position, in wall-clock terms.
  final Duration position;

  /// Whether audio is currently advancing (drives interpolation and the
  /// line-boundary timer).
  final bool playing;

  /// Whether the player is buffering/loading (pauses the auto-scroll clock).
  final bool loading;

  /// Invoked when the user taps a line; the caller seeks the player.
  final ValueChanged<Duration> onSeek;

  /// Palette used for the highlight/dim colours. Defaults to the ambient
  /// theme's scheme when null.
  final ColorScheme? colorScheme;

  /// Estimated extent of one lyric line, used for the pre-measure scroll
  /// fallback and the symmetric centre padding.
  final double estimatedLineExtent;

  /// Base font size multiplier for the lyric lines.
  final double fontSizeScale;

  /// When false, auto-scroll is suppressed (e.g. the pane is off-screen).
  final bool autoscrollEnabled;

  /// Directionality-aware horizontal padding around the lyric column.
  final EdgeInsetsGeometry padding;

  const SyncedLyricsViewer({
    super.key,
    required this.lyrics,
    required this.position,
    required this.playing,
    required this.loading,
    required this.onSeek,
    this.colorScheme,
    this.estimatedLineExtent = 64,
    this.fontSizeScale = 1.0,
    this.autoscrollEnabled = true,
    this.padding = const EdgeInsets.symmetric(horizontal: 24),
  });

  /// Index of the lyric line currently due at [position] (-1 when none).
  static int activeIndexFor(List<LyricLine> lines, Duration position) =>
      LyricsParser.activeIndex(lines, position);

  @override
  State<SyncedLyricsViewer> createState() => _SyncedLyricsViewerState();
}

class _SyncedLyricsViewerState extends State<SyncedLyricsViewer> {
  final ScrollController _scroll = ScrollController();
  Timer? _lineBoundaryTimer;
  late List<GlobalKey> _lineKeys;
  int _active = -1;
  bool _userScrolling = false;

  @override
  void initState() {
    super.initState();
    _resetLineKeys();
    _active = SyncedLyricsViewer.activeIndexFor(
      widget.lyrics.lines,
      widget.position,
    );
    _scheduleNextLine(widget.position);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybeAutoScroll(_active));
    });
  }

  @override
  void didUpdateWidget(covariant SyncedLyricsViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lyrics != widget.lyrics) {
      _resetLineKeys();
      _active = SyncedLyricsViewer.activeIndexFor(
        widget.lyrics.lines,
        widget.position,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_maybeAutoScroll(_active));
      });
    }
    if (oldWidget.position != widget.position ||
        oldWidget.playing != widget.playing ||
        oldWidget.loading != widget.loading) {
      final active = SyncedLyricsViewer.activeIndexFor(
        widget.lyrics.lines,
        widget.position,
      );
      if (active != _active) {
        _active = active;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_maybeAutoScroll(active));
        });
      }
      _scheduleNextLine(widget.position);
    }
  }

  void _resetLineKeys() {
    _lineKeys = List<GlobalKey>.generate(
      widget.lyrics.lines.length,
      (index) => GlobalKey(debugLabel: 'synced-lyric-line-$index'),
      growable: false,
    );
  }

  void _scheduleNextLine(Duration position) {
    _lineBoundaryTimer?.cancel();
    if (!widget.playing || widget.loading) return;

    final lines = widget.lyrics.lines;
    final dueIndex = syncedLyricsDueLineIndex(
      lineStarts: lines.map((line) => line.time).toList(growable: false),
      currentIndex: _active,
      position: position,
    );
    if (dueIndex != _active && dueIndex >= 0) {
      setState(() => _active = dueIndex);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_maybeAutoScroll(dueIndex));
      });
    }

    final nextIndex = dueIndex + 1;
    if (nextIndex >= lines.length) return;
    final boundary = lines[nextIndex].time;
    _lineBoundaryTimer = Timer(boundary - position, () {
      if (!mounted || !widget.playing || widget.loading) return;
      _scheduleNextLine(boundary);
    });
  }

  @override
  void dispose() {
    _lineBoundaryTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _maybeAutoScroll(int index) async {
    if (!widget.autoscrollEnabled || _userScrolling) return;
    if (index < 0 || !_scroll.hasClients) return;

    if (index < _lineKeys.length) {
      final lineContext = _lineKeys[index].currentContext;
      if (lineContext != null) {
        await Scrollable.ensureVisible(
          lineContext,
          alignment: 0.5,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
        );
        return;
      }
    }

    final position = _scroll.position;
    final target = syncedLyricsEstimatedOffset(
      index: index,
      estimatedLineExtent: widget.estimatedLineExtent,
    );
    final clamped = target.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    await _scroll.animateTo(
      clamped.toDouble(),
      duration: const Duration(milliseconds: 380),
      curve: Curves.easeOutCubic,
    );
    if (!mounted || _userScrolling || index >= _lineKeys.length) return;
    final lineContext = _lineKeys[index].currentContext;
    if (lineContext != null && lineContext.mounted) {
      await Scrollable.ensureVisible(
        lineContext,
        alignment: 0.5,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lyrics.lines;
    if (lines.isEmpty) {
      return const SizedBox.shrink();
    }
    final scheme = widget.colorScheme ?? Theme.of(context).colorScheme;

    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.direction != ScrollDirection.idle) {
          _userScrolling = true;
          // Give the user a few seconds of manual browsing before auto-scroll
          // resumes following the playback position.
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted) _userScrolling = false;
          });
        }
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final centerPadding = syncedLyricsCenterPadding(
            viewportDimension: constraints.maxHeight,
            estimatedLineExtent: widget.estimatedLineExtent,
          );
          return ListView.builder(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(
              widget.padding.horizontal,
              centerPadding,
              widget.padding.horizontal,
              centerPadding,
            ),
            itemCount: lines.length,
            itemBuilder: (context, index) {
              final line = lines[index];
              final isActive = index == _active;
              final isPast = index < _active;

              final color = isActive
                  ? scheme.onSurface
                  : isPast
                  ? scheme.onSurfaceVariant.withValues(alpha: 0.45)
                  : scheme.onSurfaceVariant.withValues(alpha: 0.82);

              final text = line.text.trim().isEmpty
                  ? '\u00b7\u00b7\u00b7'
                  : line.text;

              final baseStyle = isActive
                  ? Theme.of(context).textTheme.headlineSmall
                  : Theme.of(context).textTheme.titleLarge;
              final baseFontSize = baseStyle?.fontSize;
              final style = baseStyle?.copyWith(
                height: 1.4,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                color: color,
                fontSize: baseFontSize == null
                    ? null
                    : baseFontSize * widget.fontSizeScale,
              );

              return Padding(
                key: _lineKeys[index],
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => widget.onSeek(line.time),
                  child: Semantics(
                    button: true,
                    label: text,
                    child: AnimatedScale(
                      scale: isActive ? 1.0 : 0.96,
                      alignment: Alignment.center,
                      duration: const Duration(milliseconds: 280),
                      curve: Curves.easeOutCubic,
                      child: AnimatedOpacity(
                        opacity: isActive ? 1.0 : (isPast ? 0.5 : 0.82),
                        duration: const Duration(milliseconds: 280),
                        child: Text(
                          text,
                          textAlign: TextAlign.center,
                          style: style,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

