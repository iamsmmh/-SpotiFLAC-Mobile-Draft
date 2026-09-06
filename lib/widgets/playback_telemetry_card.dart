import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:spotiflac_android/engine/streaming_engine.dart';
import 'package:spotiflac_android/providers/playback_telemetry_provider.dart';

/// Real-time streaming/playback metrics overlay.
///
/// Shows the fixed technical characteristics — Codec, Bitrate, Sample Rate,
/// Bit Depth — alongside the source driver and the concrete file/stream path,
/// and appends live stream-session telemetry (phase, attempt, throughput,
/// integrity) whenever the engine is actively streaming.
class PlaybackTelemetryCard extends StatelessWidget {
  final PlaybackTelemetry telemetry;

  /// Set false to suppress the "copy path" action (e.g. inside a sheet that
  /// already owns clipboard affordances).
  final bool allowCopyPath;

  const PlaybackTelemetryCard({
    super.key,
    required this.telemetry,
    this.allowCopyPath = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: _MetricTile(
                icon: Icons.audiotrack_outlined,
                label: 'Codec',
                value: telemetry.codecLabel,
              ),
            ),
            Expanded(
              child: _MetricTile(
                icon: Icons.speed_outlined,
                label: 'Bitrate',
                value: telemetry.bitrateLabel,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _MetricTile(
                icon: Icons.graphic_eq_outlined,
                label: 'Sample rate',
                value: telemetry.sampleRateLabel,
              ),
            ),
            Expanded(
              child: _MetricTile(
                icon: Icons.stacked_bar_chart_outlined,
                label: 'Bit depth',
                value: telemetry.bitDepthLabel,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _DetailRow(
          icon: telemetry.offline
              ? Icons.cloud_off_outlined
              : Icons.router_outlined,
          label: 'Source driver',
          value: telemetry.sourceDriverLabel,
          emphasis: true,
        ),
        _DetailRow(
          icon: Icons.folder_open_outlined,
          label: 'File path',
          value: telemetry.filePathLabel,
          monospace: true,
          trailing: allowCopyPath
              ? IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy path',
                  onPressed: () => _copyPath(context),
                )
              : null,
        ),
        if (telemetry.hasLiveTelemetry) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: scheme.primaryContainer.withValues(alpha: 0.32),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.sensors_outlined,
                      size: 18,
                      color: scheme.onPrimaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Live stream',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.onPrimaryContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _LiveRow(
                  label: 'Session phase',
                  value: _phaseLabel(telemetry.session.phase),
                ),
                _LiveRow(
                  label: 'Attempt',
                  value: '${telemetry.session.attempt}',
                ),
                _LiveRow(
                  label: 'Throughput',
                  value: telemetry.bandwidthLabel.isEmpty
                      ? '—'
                      : '~${telemetry.bandwidthLabel}',
                ),
                _LiveRow(
                  label: 'Integrity',
                  value:
                      '${telemetry.integritySuccesses} ok · '
                      '${telemetry.integrityFailures} failed',
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _copyPath(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: telemetry.filePathLabel));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Path copied')),
      );
    }
  }

  static String _phaseLabel(StreamPhase phase) => switch (phase) {
    StreamPhase.idle => 'Idle',
    StreamPhase.resolving => 'Resolving',
    StreamPhase.preflighting => 'Preflighting',
    StreamPhase.streaming => 'Streaming',
    StreamPhase.refreshingUrl => 'Refreshing URL',
    StreamPhase.fallingBack => 'Falling back',
    StreamPhase.waitingRetry => 'Waiting to retry',
    StreamPhase.succeeded => 'Succeeded',
    StreamPhase.failed => 'Failed',
    StreamPhase.cancelled => 'Cancelled',
  };
}

class _MetricTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(
                label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool emphasis;
  final bool monospace;
  final Widget? trailing;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.emphasis = false,
    this.monospace = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: emphasis ? scheme.primary : scheme.onSurface,
                    fontWeight: emphasis ? FontWeight.w600 : null,
                    fontFamily: monospace ? 'monospace' : null,
                  ),
                ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

class _LiveRow extends StatelessWidget {
  final String label;
  final String value;

  const _LiveRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onPrimaryContainer.withValues(alpha: 0.8),
            ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
