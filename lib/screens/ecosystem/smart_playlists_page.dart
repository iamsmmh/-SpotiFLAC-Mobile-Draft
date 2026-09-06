import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/ecosystem/ecosystem.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/playback_provider.dart';
import 'package:spotiflac_android/providers/smart_playlists_provider.dart';
import 'package:spotiflac_android/widgets/app_sliver_header.dart';
import 'package:spotiflac_android/widgets/cached_cover_image.dart';
import 'package:spotiflac_android/widgets/settings_group.dart';

/// Smart playlists (Feature Group 6): auto-updating views over history,
/// favorites, the library and the recommendation engine.
class SmartPlaylistsPage extends ConsumerWidget {
  const SmartPlaylistsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(smartPlaylistsProvider);

    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: 'Smart playlists',
            actions: [
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: () => ref.invalidate(smartPlaylistsProvider),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'These playlists rebuild themselves as you listen. Play '
                'them like any list — every row goes through the normal '
                'Smart Play ladder (local copy → stream → download & play).',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          playlists.when(
            data: (list) => SliverList.builder(
              itemCount: list.length,
              itemBuilder: (context, index) {
                final playlist = list[index];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: SettingsGroup(
                    children: [
                      SettingsItem(
                        icon: _iconFor(playlist.definition.kind),
                        title: playlist.definition.kind.title,
                        subtitle:
                            '${playlist.tracks.length} tracks · '
                            '${playlist.definition.kind.description}',
                        onTap: () => _openTracks(context, playlist),
                      ),
                    ],
                  ),
                );
              },
            ),
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

  static void _openTracks(BuildContext context, SmartPlaylist playlist) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SmartPlaylistTracksPage(playlist: playlist),
      ),
    );
  }

  static IconData _iconFor(SmartPlaylistKind kind) => switch (kind) {
    SmartPlaylistKind.recentlyPlayed => Icons.history,
    SmartPlaylistKind.mostPlayed => Icons.trending_up,
    SmartPlaylistKind.favorites => Icons.favorite_border,
    SmartPlaylistKind.recentlyAdded => Icons.library_add_check_outlined,
    SmartPlaylistKind.discoverMix => Icons.explore_outlined,
    SmartPlaylistKind.dailyMix => Icons.shuffle,
  };
}

class _SmartPlaylistTracksPage extends ConsumerWidget {
  const _SmartPlaylistTracksPage({required this.playlist});

  final SmartPlaylist playlist;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tracks = <Track>[for (final row in playlist.tracks) row.track];
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          AppSliverHeader.page(
            title: playlist.definition.kind.title,
            actions: [
              IconButton(
                icon: const Icon(Icons.play_arrow),
                tooltip: 'Play all',
                onPressed: tracks.isEmpty
                    ? null
                    : () async {
                        await ref
                            .read(playbackProvider.notifier)
                            .playTrackList(tracks);
                        if (context.mounted) {
                          Navigator.of(context).maybePop();
                        }
                      },
              ),
            ],
          ),
          if (tracks.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('Nothing here yet — listen more!')),
              ),
            )
          else
            SliverList.builder(
              itemCount: playlist.tracks.length,
              itemBuilder: (context, index) {
                final row = playlist.tracks[index];
                return ListTile(
                  leading: row.track.coverUrl == null ||
                          row.track.coverUrl!.isEmpty
                      ? const SizedBox(
                          width: 44,
                          height: 44,
                          child: Icon(Icons.music_note_outlined),
                        )
                      : LocalOrNetworkCoverImage(
                          url: row.track.coverUrl!,
                          width: 44,
                          height: 44,
                          borderRadius: BorderRadius.circular(6),
                          placeholder: (_) => const SizedBox(
                            width: 44,
                            height: 44,
                            child: Icon(Icons.music_note_outlined),
                          ),
                        ),
                  title: Text(
                    row.track.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    row.reason.isEmpty
                        ? row.track.artistName
                        : '${row.track.artistName} · ${row.reason}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => ref
                      .read(playbackProvider.notifier)
                      .playTrackList(tracks, startIndex: index),
                );
              },
            ),
        ],
      ),
    );
  }
}
