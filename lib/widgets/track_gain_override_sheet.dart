import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/audio/replaygain_processor.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/audio_engine_provider.dart';
import 'package:spotiflac_android/utils/gain_format.dart';
import 'package:spotiflac_android/widgets/app_bottom_sheet.dart';

/// Per-track manual ReplayGain override — the user-facing end of
/// `AudioEngineSettingsNotifier.setTrackOverride`.
///
/// The engine resolves a manual track gain ahead of any tag
/// ([ManualGainOverrides.lookup]: a track override beats an album override,
/// which beats the tag), so this sheet is the "manual override" control of
/// the ReplayGain feature.
///
/// The value is held locally while the slider is dragged and only committed
/// on release, so one adjustment writes one preference blob instead of one
/// per drag tick.
///
/// NOTE(l10n): English-first, the same rationale as the streaming settings
/// page — the staged-strings budget is full, so these strings join the ARB
/// tree in the Crowdin catch-up pass.
class TrackGainOverrideSheet extends ConsumerStatefulWidget {
  const TrackGainOverrideSheet({super.key, required this.track});

  final Track track;

  /// Opens the sheet for [track]. [ref] is accepted for symmetry with the
  /// other track sheets; the widget reads the provider itself.
  static void show(BuildContext context, WidgetRef ref, Track track) {
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHigh,
      builder: (sheetContext) => TrackGainOverrideSheet(track: track),
    );
  }

  @override
  ConsumerState<TrackGainOverrideSheet> createState() =>
      _TrackGainOverrideSheetState();
}

class _TrackGainOverrideSheetState extends ConsumerState<TrackGainOverrideSheet> {
  static const double _step = 0.5;

  /// `double.round()` is not const-evaluable, so this stays `final`.
  static final int _divisions =
      ((ManualGainOverrides.maxDb - ManualGainOverrides.minDb) / _step)
          .round();

  /// Live value while dragging; null until the user touches the slider.
  double? _draft;

  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(audioEngineSettingsProvider);
    final notifier = ref.read(audioEngineSettingsProvider.notifier);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final key = ManualGainOverrides.trackKey(widget.track.id);
    final stored = settings.gainOverrides[key];
    // `double.clamp(double, double)` is statically a `double`, so no cast.
    final value = (_draft ?? stored ?? 0.0).clamp(
      ManualGainOverrides.minDb,
      ManualGainOverrides.maxDb,
    );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppSheetHandle(),
            Text('Track gain', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${widget.track.artistName} · ${widget.track.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  stored == null && _draft == null
                      ? 'No override — the tag decides'
                      : 'Override',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  '${formatGainDb(value)} dB',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            Slider(
              value: value,
              min: ManualGainOverrides.minDb,
              max: ManualGainOverrides.maxDb,
              divisions: _divisions,
              label: '${formatGainDb(value)} dB',
              onChanged: (next) => setState(() => _draft = next),
              onChangeEnd: (next) => notifier.setTrackOverride(
                widget.track.id,
                next,
              ),
            ),
            Text(
              'Applies to this track only, ahead of its ReplayGain tag. '
              'ReplayGain and Normalize loudness must both be on in '
              'Settings → Streaming & Glass.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: stored == null
                      ? null
                      : () {
                          notifier.clearTrackOverride(widget.track.id);
                          setState(() => _draft = null);
                        },
                  child: const Text('Reset'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
