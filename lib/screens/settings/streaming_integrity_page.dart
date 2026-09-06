import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/engine/streaming_engine.dart';
import 'package:spotiflac_android/providers/streaming_engine_provider.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// Settings → Streaming & Glass → Streaming integrity.
///
/// Shows a per-URL record of stream attempts (preflight successes, failures,
/// and fallbacks) with a readable reason so the user can see why a particular
/// source failed without reading raw log text.
class StreamingIntegrityPage extends ConsumerWidget {
  const StreamingIntegrityPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final diagnostics = ref.watch(engineDiagnosticsProvider);
    final records = diagnostics.integrity.records;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: 'Streaming integrity'),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.tokens.pagePadding,
                context.tokens.pagePadding * 0.5,
                context.tokens.pagePadding,
                context.tokens.pagePadding * 0.5,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SummaryRow(diagnostics: diagnostics),
                  const SizedBox(height: 16),
                  if (records.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: Text('No stream attempts yet')),
                    )
                  else
                    SettingsGroup(
                      children: records
                          .take(80)
                          .map(
                            (record) => _IntegrityTile(record: record),
                          )
                          .toList(growable: false),
                    ),
                  if (records.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        'Shows the ${records.length.clamp(0, 80)} most recent attempts. '
                        'Tap a row to copy its error reason.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final StreamingDiagnostics diagnostics;

  const _SummaryRow({required this.diagnostics});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _Chip(
          label: '${diagnostics.integritySuccesses} OK',
          color: Colors.green,
        ),
        const SizedBox(width: 8),
        _Chip(
          label: '${diagnostics.integrityFailures} failed',
          color: Theme.of(context).colorScheme.error,
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final Color color;

  const _Chip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _IntegrityTile extends StatelessWidget {
  final StreamIntegrityRecord record;

  const _IntegrityTile({required this.record});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (icon, color) = switch (record.outcome) {
      StreamIntegrityOutcome.success => (Icons.check_circle_outline, Colors.green),
      StreamIntegrityOutcome.failure => (
        Icons.error_outline,
        colorScheme.error,
      ),
      StreamIntegrityOutcome.fallback => (
        Icons.swap_horiz_outlined,
        colorScheme.tertiary,
      ),
    };
    final reason = record.message.isEmpty
        ? switch (record.outcome) {
            StreamIntegrityOutcome.success => 'Preflight succeeded',
            StreamIntegrityOutcome.failure => 'Source unavailable',
            StreamIntegrityOutcome.fallback => 'Fell back to another source',
          }
        : record.message;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: color, size: 20),
      title: Text(
        '${record.providerId} — ${_shortUri(record.uri)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text('${record.category ?? 'stream'} · $reason'),
      onTap: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: SelectableText(reason)),
        );
      },
    );
  }

  String _shortUri(String uri) {
    if (uri.length <= 48) return uri;
    return '${uri.substring(0, 32)}…${uri.substring(uri.length - 12)}';
  }
}
