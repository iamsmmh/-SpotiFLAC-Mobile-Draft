import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/l10n/l10n.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/widgets/cached_cover_image.dart';

Future<void> showAddTrackToPlaylistSheet(
  BuildContext context,
  WidgetRef ref,
  Track track,
) async {
  return showAddTracksToPlaylistSheet(context, ref, [track]);
}

Future<void> showAddTracksToPlaylistSheet(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  String? playlistNamePrefill,
}) async {
  if (tracks.isEmpty) return;

  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      return _PlaylistPickerSheetContent(
        tracks: tracks,
        playlistNamePrefill: playlistNamePrefill,
      );
    },
  );
}

class _PlaylistPickerSheetContent extends ConsumerStatefulWidget {
  final List<Track> tracks;
  final String? playlistNamePrefill;

  const _PlaylistPickerSheetContent({
    required this.tracks,
    this.playlistNamePrefill,
  });

  @override
  ConsumerState<_PlaylistPickerSheetContent> createState() =>
      _PlaylistPickerSheetContentState();
}

class _PlaylistPickerSheetContentState
    extends ConsumerState<_PlaylistPickerSheetContent> {
  late final PlaylistPickerSummaryRequest _summaryRequest;
  final Set<String> _selectedPlaylistIds = {};
  final Set<String> _committedPlaylistIds = {};

  @override
  void initState() {
    super.initState();
    _summaryRequest = PlaylistPickerSummaryRequest.fromTracks(widget.tracks);
  }

  void _handleDone(List<PlaylistPickerSummary> playlists) async {
    final notifier = ref.read(libraryCollectionsProvider.notifier);
    final effectiveDisabledIds = <String>{
      ..._committedPlaylistIds,
      for (final playlist in playlists)
        if (playlist.containsAllRequestedTracks) playlist.id,
    };
    final idsToAdd = _selectedPlaylistIds.difference(effectiveDisabledIds);
    final playlistNamesById = {
      for (final playlist in playlists) playlist.id: playlist.name,
    };
    final addedNames = <String>[];

    for (final playlistId in idsToAdd) {
      final playlistName = playlistNamesById[playlistId];
      if (playlistName != null && playlistName.isNotEmpty) {
        addedNames.add(playlistName);
      }
      await notifier.addTracksToPlaylist(playlistId, widget.tracks);
    }

    if (!mounted) return;
    Navigator.of(context).pop();

    if (addedNames.isNotEmpty) {
      final name = addedNames.length == 1
          ? addedNames.first
          : addedNames.join(', ');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.collectionAddedToPlaylist(name))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final playlistSummariesValue = ref.watch(
      libraryPlaylistPickerSummariesProvider(_summaryRequest),
    );
    final notifier = ref.read(libraryCollectionsProvider.notifier);

    final String subtitle;
    if (widget.tracks.length == 1) {
      final track = widget.tracks.first;
      subtitle = '${track.name} • ${track.artistName}';
    } else {
      subtitle =
          '${widget.tracks.length} ${widget.tracks.length == 1 ? 'track' : 'tracks'}';
    }

    final resolvedPlaylists = playlistSummariesValue.asData?.value ?? const [];
    final effectiveDisabledIds = <String>{
      ..._committedPlaylistIds,
      for (final playlist in resolvedPlaylists)
        if (playlist.containsAllRequestedTracks) playlist.id,
    };
    final idsToAdd = _selectedPlaylistIds.difference(effectiveDisabledIds);
    final hasNewSelections = idsToAdd.isNotEmpty;

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.playlist_add),
            title: Text(context.l10n.collectionAddToPlaylist),
            subtitle: Text(subtitle),
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.add_circle_outline),
            title: Text(context.l10n.collectionCreatePlaylist),
            onTap: () async {
              final name = await _promptPlaylistName(
                context,
                widget.playlistNamePrefill,
              );
              if (name == null || name.trim().isEmpty || !context.mounted) {
                return;
              }
              final playlistId = await notifier.createPlaylist(name.trim());
              await notifier.addTracksToPlaylist(playlistId, widget.tracks);
              setState(() {
                _committedPlaylistIds.add(playlistId);
                _selectedPlaylistIds.remove(playlistId);
              });
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    context.l10n.collectionAddedToPlaylist(name.trim()),
                  ),
                ),
              );
            },
          ),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: playlistSummariesValue.when(
                data: (playlists) {
                  if (playlists.isEmpty) {
                    return Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      child: Text(
                        context.l10n.collectionNoPlaylistsYet,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: playlists.length,
                    itemBuilder: (context, index) {
                      final playlist = playlists[index];
                      final isAlreadyIn = effectiveDisabledIds.contains(
                        playlist.id,
                      );
                      final isSelected =
                          _selectedPlaylistIds.contains(playlist.id) ||
                          isAlreadyIn;

                      return ListTile(
                        leading: _PlaylistPickerThumbnail(
                          playlist: playlist,
                          isSelected: isSelected,
                        ),
                        title: Text(playlist.name),
                        subtitle: Text(
                          context.l10n.collectionPlaylistTracks(
                            playlist.trackCount,
                          ),
                        ),
                        enabled: !isAlreadyIn,
                        onTap: !isAlreadyIn
                            ? () {
                                setState(() {
                                  if (_selectedPlaylistIds.contains(
                                    playlist.id,
                                  )) {
                                    _selectedPlaylistIds.remove(playlist.id);
                                  } else {
                                    _selectedPlaylistIds.add(playlist.id);
                                  }
                                });
                              }
                            : null,
                      );
                    },
                  );
                },
                loading: () => const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                error: (_, _) => Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                  child: Text(
                    context.l10n.collectionNoPlaylistsYet,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () {
                  if (hasNewSelections) {
                    _handleDone(resolvedPlaylists);
                  } else {
                    Navigator.of(context).pop();
                  }
                },
                child: Text(context.l10n.dialogDone),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<String?> _promptPlaylistName(
  BuildContext context,
  String? playlistNamePrefill,
) async {
  final controller = TextEditingController(text: playlistNamePrefill);
  final formKey = GlobalKey<FormState>();

  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(dialogContext.l10n.collectionCreatePlaylist),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: dialogContext.l10n.collectionPlaylistNameHint,
            ),
            validator: (value) {
              final trimmed = value?.trim() ?? '';
              if (trimmed.isEmpty) {
                return dialogContext.l10n.collectionPlaylistNameRequired;
              }
              return null;
            },
            onFieldSubmitted: (_) {
              if (formKey.currentState?.validate() != true) return;
              Navigator.of(dialogContext).pop(controller.text.trim());
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(dialogContext.l10n.dialogCancel),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.of(dialogContext).pop(controller.text.trim());
            },
            child: Text(dialogContext.l10n.actionCreate),
          ),
        ],
      );
    },
  );

  return result;
}

class _PlaylistPickerThumbnail extends StatelessWidget {
  final PlaylistPickerSummary playlist;
  final bool isSelected;

  const _PlaylistPickerThumbnail({
    required this.playlist,
    required this.isSelected,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    const double size = 48;
    final borderRadius = BorderRadius.circular(8);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: borderRadius,
            child: _buildCoverImage(context, colorScheme, size),
          ),
          if (isSelected) ...[
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.primary.withValues(alpha: 0.3),
                  borderRadius: borderRadius,
                ),
              ),
            ),
            Positioned(
              right: 2,
              top: 2,
              child: Container(
                decoration: BoxDecoration(
                  color: colorScheme.primary,
                  shape: BoxShape.circle,
                  border: Border.all(color: colorScheme.primary, width: 1.5),
                ),
                child: Icon(
                  Icons.check,
                  color: colorScheme.onPrimary,
                  size: 14,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCoverImage(
    BuildContext context,
    ColorScheme colorScheme,
    double size,
  ) {
    final customCoverPath = playlist.coverImagePath;
    if (customCoverPath != null && customCoverPath.isNotEmpty) {
      return Image.file(
        File(customCoverPath),
        width: size,
        height: size,
        fit: BoxFit.cover,
        cacheWidth: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        cacheHeight: (size * MediaQuery.devicePixelRatioOf(context)).round(),
        filterQuality: FilterQuality.low,
        errorBuilder: (_, _, _) => _iconFallback(colorScheme, size),
      );
    }

    final firstCoverUrl = playlist.previewCover;
    if (firstCoverUrl != null) {
      return LocalOrNetworkCoverImage(
        url: firstCoverUrl,
        width: size,
        height: size,
        networkCacheWidth: (size * 2).toInt(),
        placeholder: (_) => _iconFallback(colorScheme, size),
      );
    }

    return _iconFallback(colorScheme, size);
  }

  Widget _iconFallback(ColorScheme colorScheme, double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(Icons.queue_music, color: colorScheme.onSurfaceVariant),
    );
  }
}
