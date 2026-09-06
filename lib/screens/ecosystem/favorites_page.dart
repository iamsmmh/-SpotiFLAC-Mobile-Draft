import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/ecosystem/ecosystem.dart';
import 'package:spotiflac_android/providers/ecosystem_providers.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';

/// Unified favorites page (Feature Group 3).
///
/// Backed by [favoritesIndexProvider], a read-only projection over the
/// existing collections store plus the ecosystem's favorite-playlists table.
/// Search/sort/filter run against the pre-built index, so typing stays cheap
/// even with thousands of entries.
class FavoritesPage extends ConsumerWidget {
  const FavoritesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final results = ref.watch(favoritesResultsProvider);
    final query = ref.watch(favoritesQueryProvider);
    final controller = ref.read(favoritesQueryProvider.notifier);
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: 'Favorites',
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () {
                  ref.invalidate(favoritesIndexProvider);
                  ref.invalidate(favoritePlaylistsProvider);
                },
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Search favorites',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: controller.setSearch,
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final kind in FavoriteKind.values)
                        FilterChip(
                          label: Text(_kindLabel(kind)),
                          selected: query.kinds.contains(kind),
                          onSelected: (_) => controller.toggleKind(kind),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Sort:'),
                      const SizedBox(width: 12),
                      DropdownButton<FavoriteSortOrder>(
                        value: query.sort,
                        items: [
                          for (final order in FavoriteSortOrder.values)
                            DropdownMenuItem<FavoriteSortOrder>(
                              value: order,
                              child: Text(order.label),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) controller.setSort(value);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          results.when(
            data: (entries) => entries.isEmpty
                ? SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          'No favorites yet. Use the heart on any track, album '
                          'or artist to build this list.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final entry = entries[index];
                      return ListTile(
                        leading: CircleAvatar(
                          child: Icon(_kindIcon(entry.kind)),
                        ),
                        title: Text(
                          entry.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${_kindLabel(entry.kind)}'
                          '${entry.subtitle.isEmpty ? '' : ' · ${entry.subtitle}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.favorite),
                          color: colorScheme.primary,
                          onPressed: () => _remove(ref, entry),
                        ),
                      );
                    }, childCount: entries.length),
                  ),
            loading: () => const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (error, _) => SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('$error')),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  Future<void> _remove(WidgetRef ref, FavoriteEntry entry) async {
    final collections = ref.read(libraryCollectionsProvider.notifier);
    switch (entry.kind) {
      case FavoriteKind.track:
        await collections.removeFromLoved(entry.key);
        break;
      case FavoriteKind.album:
        await collections.removeFavoriteAlbum(entry.key);
        break;
      case FavoriteKind.artist:
        await collections.removeFavoriteArtist(entry.key);
        break;
      case FavoriteKind.playlist:
        final playlistId = entry.playlistId;
        if (playlistId != null) {
          await ref
              .read(favoritePlaylistsRepositoryProvider)
              .remove(playlistId);
        }
        break;
    }
    ref.invalidate(favoritesIndexProvider);
    ref.invalidate(favoritePlaylistsProvider);
  }

  static String _kindLabel(FavoriteKind kind) {
    switch (kind) {
      case FavoriteKind.track:
        return 'Songs';
      case FavoriteKind.album:
        return 'Albums';
      case FavoriteKind.artist:
        return 'Artists';
      case FavoriteKind.playlist:
        return 'Playlists';
    }
  }

  static IconData _kindIcon(FavoriteKind kind) {
    switch (kind) {
      case FavoriteKind.track:
        return Icons.music_note;
      case FavoriteKind.album:
        return Icons.album;
      case FavoriteKind.artist:
        return Icons.person;
      case FavoriteKind.playlist:
        return Icons.queue_music;
    }
  }
}
