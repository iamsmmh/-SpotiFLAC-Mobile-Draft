import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/services/storage_breakdown_service.dart';
import 'package:spotiflac_android/theme/app_tokens.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// Settings → Files → Storage breakdown.
///
/// Shows on-device disk usage aggregated by file format, artist and album for
/// downloaded + local-library tracks. All sizing is computed locally.
class StorageBreakdownPage extends ConsumerStatefulWidget {
  const StorageBreakdownPage({super.key});

  @override
  ConsumerState<StorageBreakdownPage> createState() =>
      _StorageBreakdownPageState();
}

class _StorageBreakdownPageState extends ConsumerState<StorageBreakdownPage> {
  StorageBreakdown? _breakdown;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final history = ref.read(downloadHistoryProvider).items;
      final localRows = await LibraryDatabase.instance.getAll();
      final local = localRows.map(LocalLibraryItem.fromJson).toList();
      final breakdown = await computeStorageBreakdown(
        historyItems: history,
        localItems: local,
      );
      if (!mounted) return;
      setState(() {
        _breakdown = breakdown;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(title: 'Storage breakdown'),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                context.tokens.pagePadding,
                context.tokens.pagePadding * 0.5,
                context.tokens.pagePadding,
                context.tokens.pagePadding * 0.5,
              ),
              child: _buildBody(context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 40),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Column(
        children: [
          Text('Could not read storage data: $_error'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _load, child: const Text('Retry')),
        ],
      );
    }
    final breakdown = _breakdown;
    if (breakdown == null || breakdown.fileCount == 0) {
      return const Text(
        'No downloaded or local-library files found yet.',
        style: TextStyle(fontSize: 15),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SummaryCard(breakdown: breakdown),
        const SizedBox(height: 20),
        _Section('By format', breakdown.byFormat),
        const SizedBox(height: 16),
        _Section('By artist', breakdown.byArtist),
        const SizedBox(height: 16),
        _Section('By album', breakdown.byAlbum),
        const SizedBox(height: 24),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final StorageBreakdown breakdown;

  const _SummaryCard({required this.breakdown});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Expanded(
            child: _Metric(
              label: 'Total size',
              value: formatStorageBytes(breakdown.totalBytes),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _Metric(label: 'Files', value: '${breakdown.fileCount}'),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  final String label;
  final String value;

  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final List<StorageBreakdownBucket> buckets;

  const _Section(this.title, this.buckets);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 4),
          child: Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SettingsGroup(
          children: buckets
              .take(30)
              .map(
                (bucket) => ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: const Icon(Icons.folder_outlined, size: 20),
                  title: Text(
                    bucket.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text('${bucket.fileCount} file(s)'),
                  trailing: Text(
                    formatStorageBytes(bucket.totalBytes),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              )
              .toList(growable: false),
        ),
      ],
    );
  }
}
