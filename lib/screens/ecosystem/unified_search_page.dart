import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/engine/unified_search.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/hybrid_playback_provider.dart';
import 'package:spotiflac_android/providers/playback_provider.dart';
import 'package:spotiflac_android/providers/unified_search_provider.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/app_search_field.dart';
import 'package:spotiflac_android/widgets/cached_cover_image.dart';

/// Unified search (Feature Group: search): one ranked list across the
/// local library, downloads, extensions, self-hosted servers, podcasts
/// and the stream cache.
class UnifiedSearchPage extends ConsumerStatefulWidget {
  const UnifiedSearchPage({super.key});

  @override
  ConsumerState<UnifiedSearchPage> createState() => _UnifiedSearchPageState();
}

class _UnifiedSearchPageState extends ConsumerState<UnifiedSearchPage> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = ref.watch(unifiedSearchQueryProvider);
    final outcome = ref.watch(unifiedSearchResultsProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: 'Search everywhere',
            actions: [
              IconButton(
                icon: const Icon(Icons.search),
                onPressed: () => FocusScope.of(context).unfocus(),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: AppSearchField(
                controller: _controller,
                hintText: 'Library, downloads, servers, podcasts…',
                clearTooltip: 'Clear',
                autofocus: true,
                onChanged: ref.read(unifiedSearchQueryProvider.notifier).set,
                onClear: () =>
                    ref.read(unifiedSearchQueryProvider.notifier).set(''),
              ),
            ),
          ),
          if (query.trim().isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    'Results from every source, ranked on device.\n'
                    'Your queries never leave the phone.',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            )
          else
            outcome.when(
              data: (value) => _results(context, ref, value),
              loading: () => const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              ),
              error: (error, _) => SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('$error'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _results(
    BuildContext context,
    WidgetRef ref,
    UnifiedSearchOutcome outcome,
  ) {
    if (outcome.results.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: Text('No results in any source')),
        ),
      );
    }
    return SliverList.builder(
      itemCount: outcome.results.length,
      itemBuilder: (context, index) {
        final row = outcome.results[index];
        final item = row.item;
        return ListTile(
          leading: _cover(item.imageUrl),
          title: Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            '${item.subtitle.isEmpty ? item.kind.label : item.subtitle} · '
            '${item.kind.label}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: item.playableLocally
              ? const Icon(Icons.offline_pin_outlined, size: 18)
              : null,
          onTap: () => _play(context, ref, item),
        );
      },
    );
  }

  Widget _cover(String? url) {
    if (url == null || url.isEmpty) {
      return const SizedBox(
        width: 44,
        height: 44,
        child: Icon(Icons.music_note_outlined),
      );
    }
    return LocalOrNetworkCoverImage(
      url: url,
      width: 44,
      height: 44,
      borderRadius: BorderRadius.circular(6),
      placeholder: (_) => const SizedBox(
        width: 44,
        height: 44,
        child: Icon(Icons.music_note_outlined),
      ),
    );
  }

  Future<void> _play(
    BuildContext context,
    WidgetRef ref,
    UnifiedSearchItem item,
  ) async {
    final track = item.track;
    if (track == null) return;
    // Hybrid playback (Feature 3): hear it instantly (cache/local/stream)
    // and, when the source allows it, end up with a verified local copy —
    // the live swap happens silently once the fetch verifies.
    final outcome = await ref
        .read(hybridPlaybackManagerProvider)
        .playTrack(track);
    if (!outcome.started && context.mounted) {
      // Fall back to the standard ladder so the user still gets a clear
      // error or a download-&-play path.
      await ref.read(playbackProvider.notifier).playTrackList(<Track>[track]);
    }
  }
}
