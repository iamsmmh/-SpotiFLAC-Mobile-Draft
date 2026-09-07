import 'package:audio_service/audio_service.dart';
import 'package:spotiflac_android/services/music_player_service.dart';

/// Browse tree exposed to Android Auto / Automotive OS, Bluetooth AVRCP
/// browsers and (through audio_service) CarPlay-style clients over
/// `MediaBrowserService.onLoadChildren`.
///
/// The tree is entirely local-first: it lists what the device can play right
/// now — the live queue, recently played, most played, downloaded albums,
/// the folder library, loved tracks and user playlists. It never triggers a
/// network resolution while the user browses; only tapping a track starts
/// playback (where the streaming engine applies its usual local → stream
/// ladder if the file is missing).
///
/// Media ids are namespaced strings so a car head unit that caches ids across
/// sessions can always be routed back to the right subtree:
///
/// ```
/// __ROOT__                     (audio_service browsable root)
/// ├─ browse:queue              Now playing queue      (playable children)
/// ├─ browse:recent             Recently played        (playable children)
/// ├─ browse:top                Most played            (playable children)
/// ├─ browse:loved              Loved tracks           (playable children)
/// ├─ browse:playlists          Playlists              (browsable children)
/// │   └─ playlist:<id>                                (playable children)
/// ├─ browse:albums             Albums (downloads + local)
/// │   └─ album:<source>:<key>                          (playable children)
/// └─ browse:library            All songs (paged)      (playable children)
/// ```
///
/// Playable ids are the queue-item ids the handler already understands; when
/// the tapped track is not in the queue the handler asks [MediaBrowseSource]
/// for the media list of the enclosing container and starts it there, so
/// "tap a song in an album" plays the whole album from that song.
class MediaBrowseTree {
  MediaBrowseTree(this.source);

  final MediaBrowseSource source;

  static const String queueId = 'browse:queue';
  static const String recentId = 'browse:recent';
  static const String topId = 'browse:top';
  static const String lovedId = 'browse:loved';
  static const String playlistsId = 'browse:playlists';
  static const String albumsId = 'browse:albums';
  static const String libraryId = 'browse:library';

  /// Extra Android Auto / CarPlay sections. Appended *after* the original
  /// root so existing tests that expect `[queue, albums, library]` stay
  /// green when the extra counts are zero (the default).
  static const String homeId = 'browse:home';
  static const String continueId = 'browse:continue';
  static const String artistsId = 'browse:artists';
  static const String recommendationsId = 'browse:recommendations';

  static const String playlistPrefix = 'playlist:';
  static const String albumPrefix = 'album:';
  static const String artistPrefix = 'artist:';

  /// Maximum children returned per container. Head units render lists of
  /// this size comfortably; larger libraries page through `browse:library`.
  static const int pageSize = 200;

  /// Hint keys understood by Android Auto (`androidx.media.utils`).
  static const String _contentStyleSupported =
      'android.media.browse.CONTENT_STYLE_SUPPORTED';
  static const String _contentStyleBrowsable =
      'android.media.browse.CONTENT_STYLE_BROWSABLE_HINT';
  static const String _contentStylePlayable =
      'android.media.browse.CONTENT_STYLE_PLAYABLE_HINT';
  static const int _contentStyleList = 1;
  static const int _contentStyleGrid = 2;

  /// Root children. Empty sections are hidden so a fresh install shows only
  /// what has content (the queue is always shown when non-empty).
  Future<List<MediaItem>> rootChildren() async {
    final counts = await source.sectionCounts();
    final items = <MediaItem>[];
    if (counts.queue > 0) {
      items.add(
        _folder(queueId, 'Now playing', subtitle: _countLabel(counts.queue)),
      );
    }
    if (counts.recent > 0) {
      items.add(_folder(recentId, 'Recently played'));
    }
    if (counts.top > 0) {
      items.add(_folder(topId, 'Most played'));
    }
    if (counts.loved > 0) {
      items.add(
        _folder(lovedId, 'Loved', subtitle: _countLabel(counts.loved)),
      );
    }
    if (counts.playlists > 0) {
      items.add(
        _folder(
          playlistsId,
          'Playlists',
          subtitle: '${counts.playlists} '
              '${counts.playlists == 1 ? 'playlist' : 'playlists'}',
        ),
      );
    }
    if (counts.albums > 0) {
      items.add(
        _folder(
          albumsId,
          'Albums',
          subtitle: '${counts.albums} ${counts.albums == 1 ? 'album' : 'albums'}',
          grid: true,
        ),
      );
    }
    if (counts.library > 0) {
      items.add(
        _folder(libraryId, 'Songs', subtitle: _countLabel(counts.library)),
      );
    }
    if (counts.home > 0) {
      items.add(_folder(homeId, 'Home'));
    }
    if (counts.continueListening > 0) {
      items.add(_folder(continueId, 'Continue listening'));
    }
    if (counts.artists > 0) {
      items.add(
        _folder(
          artistsId,
          'Artists',
          subtitle: '${counts.artists} '
              '${counts.artists == 1 ? 'artist' : 'artists'}',
          grid: true,
        ),
      );
    }
    if (counts.recommendations > 0) {
      items.add(_folder(recommendationsId, 'For you'));
    }
    return List<MediaItem>.unmodifiable(items);
  }

  /// Children of any browsable id. Unknown ids return an empty list (never
  /// throw: the platform surfaces an exception as a dead "loading" spinner).
  Future<List<MediaItem>> children(
    String parentId, {
    int page = 0,
    int pageSize = pageSize,
  }) async {
    if (parentId == AudioService.browsableRootId) return rootChildren();
    if (parentId == AudioService.recentRootId || parentId == queueId) {
      return _playable(await source.queueMedia(), containerId: queueId);
    }
    switch (parentId) {
      case recentId:
        return _playable(await source.recentMedia(limit: pageSize),
            containerId: recentId);
      case topId:
        return _playable(await source.mostPlayedMedia(limit: pageSize),
            containerId: topId);
      case lovedId:
        return _playable(await source.lovedMedia(), containerId: lovedId);
      case playlistsId:
        final playlists = await source.playlists();
        return List<MediaItem>.unmodifiable([
          for (final playlist in playlists)
            _folder(
              '$playlistPrefix${playlist.id}',
              playlist.name,
              subtitle: _countLabel(playlist.trackCount),
              artUri: playlist.artUri,
            ),
        ]);
      case albumsId:
        final albums = await source.albums(limit: pageSize, offset: page * pageSize);
        return List<MediaItem>.unmodifiable([
          for (final album in albums)
            _folder(
              '$albumPrefix${album.source}:${album.key}',
              album.name,
              subtitle: album.artist,
              artUri: album.artUri,
            ),
        ]);
      case libraryId:
        return _playable(
          await source.libraryMedia(limit: pageSize, offset: page * pageSize),
          containerId: libraryId,
        );
      case homeId:
        return _playable(
          await source.recentMedia(limit: pageSize),
          containerId: homeId,
        );
      case continueId:
        return _playable(
          await source.recentMedia(limit: pageSize),
          containerId: continueId,
        );
      case recommendationsId:
        return _playable(
          await source.mostPlayedMedia(limit: pageSize),
          containerId: recommendationsId,
        );
      case artistsId:
        return _artistFolders(
          await source.albums(limit: pageSize, offset: page * pageSize),
        );
    }
    if (parentId.startsWith(playlistPrefix)) {
      final id = parentId.substring(playlistPrefix.length);
      return _playable(await source.playlistMedia(id), containerId: parentId);
    }
    if (parentId.startsWith(albumPrefix)) {
      final ref = _AlbumRef.parse(parentId);
      if (ref == null) return const [];
      return _playable(
        await source.albumMedia(sourceTag: ref.source, key: ref.key),
        containerId: parentId,
      );
    }
    if (parentId.startsWith(artistPrefix)) {
      final artist = _decodeArtistId(parentId);
      if (artist == null) return const [];
      final albums = await source.albums(limit: pageSize, offset: 0);
      return List<MediaItem>.unmodifiable([
        for (final album in albums)
          if (album.artist == artist)
            _folder(
              '$albumPrefix${album.source}:${album.key}',
              album.name,
              subtitle: album.artist,
              artUri: album.artUri,
            ),
      ]);
    }
    return const [];
  }

  /// The media list a playable child belongs to (for "play this container
  /// from that track"). Null when the container is unknown.
  Future<List<PlayableMedia>?> containerMedia(String containerId) async {
    switch (containerId) {
      case queueId:
        return source.queueMedia();
      case recentId:
        return source.recentMedia(limit: pageSize);
      case topId:
        return source.mostPlayedMedia(limit: pageSize);
      case lovedId:
        return source.lovedMedia();
      case libraryId:
        return source.libraryMedia(limit: pageSize, offset: 0);
      case homeId:
      case continueId:
        return source.recentMedia(limit: pageSize);
      case recommendationsId:
        return source.mostPlayedMedia(limit: pageSize);
    }
    if (containerId.startsWith(playlistPrefix)) {
      return source.playlistMedia(containerId.substring(playlistPrefix.length));
    }
    if (containerId.startsWith(albumPrefix)) {
      final ref = _AlbumRef.parse(containerId);
      if (ref == null) return null;
      return source.albumMedia(sourceTag: ref.source, key: ref.key);
    }
    return null;
  }

  /// Full-text search over the offline library for voice requests
  /// ("play Daft Punk"). Ranks exact title/artist hits first.
  Future<List<MediaItem>> search(String query, {int limit = 50}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return const [];
    final media = await source.searchMedia(trimmed, limit: limit);
    return _playable(media, containerId: 'search:$trimmed');
  }

  /// Extras every playable child carries so the handler can recover its
  /// container without a second lookup.
  static const String containerExtraKey = 'browse_container';

  List<MediaItem> _playable(
    List<PlayableMedia> media, {
    required String containerId,
  }) {
    return List<MediaItem>.unmodifiable([
      for (final item in media)
        item.toMediaItem().copyWith(
          playable: true,
          extras: {
            ...?item.toMediaItem().extras,
            containerExtraKey: containerId,
          },
        ),
    ]);
  }

  List<MediaItem> _artistFolders(List<MediaBrowseAlbum> albums) {
    final seen = <String>{};
    final items = <MediaItem>[];
    for (final album in albums) {
      final artist = album.artist.trim();
      if (artist.isEmpty || !seen.add(artist)) continue;
      items.add(
        _folder(
          '$artistPrefix${Uri.encodeComponent(artist)}',
          artist,
          artUri: album.artUri,
          grid: true,
        ),
      );
    }
    return List<MediaItem>.unmodifiable(items);
  }

  static String? _decodeArtistId(String id) {
    if (!id.startsWith(artistPrefix)) return null;
    final rest = id.substring(artistPrefix.length);
    if (rest.isEmpty) return null;
    return Uri.decodeComponent(rest);
  }

  MediaItem _folder(
    String id,
    String title, {
    String? subtitle,
    Uri? artUri,
    bool grid = false,
  }) => MediaItem(
    id: id,
    title: title,
    artist: subtitle,
    artUri: artUri,
    playable: false,
    extras: {
      _contentStyleSupported: true,
      _contentStyleBrowsable: grid ? _contentStyleGrid : _contentStyleList,
      _contentStylePlayable: _contentStyleList,
    },
  );

  static String _countLabel(int count) =>
      '$count ${count == 1 ? 'song' : 'songs'}';
}

class _AlbumRef {
  final String source;
  final String key;
  const _AlbumRef(this.source, this.key);

  static _AlbumRef? parse(String id) {
    if (!id.startsWith(MediaBrowseTree.albumPrefix)) return null;
    final rest = id.substring(MediaBrowseTree.albumPrefix.length);
    final split = rest.indexOf(':');
    if (split <= 0 || split == rest.length - 1) return null;
    return _AlbumRef(rest.substring(0, split), rest.substring(split + 1));
  }
}

/// Counts used to decide which root sections to show.
class MediaBrowseCounts {
  final int queue;
  final int recent;
  final int top;
  final int loved;
  final int playlists;
  final int albums;
  final int library;

  /// Extra sections (Phase 4). Default 0 so existing fakes / tests compile
  /// and keep hiding empty folders.
  final int home;
  final int continueListening;
  final int artists;
  final int recommendations;

  const MediaBrowseCounts({
    this.queue = 0,
    this.recent = 0,
    this.top = 0,
    this.loved = 0,
    this.playlists = 0,
    this.albums = 0,
    this.library = 0,
    this.home = 0,
    this.continueListening = 0,
    this.artists = 0,
    this.recommendations = 0,
  });
}

class MediaBrowsePlaylist {
  final String id;
  final String name;
  final int trackCount;
  final Uri? artUri;

  const MediaBrowsePlaylist({
    required this.id,
    required this.name,
    required this.trackCount,
    this.artUri,
  });
}

class MediaBrowseAlbum {
  /// `downloaded` or `local`.
  final String source;

  /// Stable album key inside [source] (history/library `album_key`).
  final String key;
  final String name;
  final String artist;
  final Uri? artUri;

  const MediaBrowseAlbum({
    required this.source,
    required this.key,
    required this.name,
    required this.artist,
    this.artUri,
  });
}

/// Data access the tree needs. Implemented against the live providers by
/// the app and by in-memory fakes in tests.
abstract class MediaBrowseSource {
  Future<MediaBrowseCounts> sectionCounts();
  Future<List<PlayableMedia>> queueMedia();
  Future<List<PlayableMedia>> recentMedia({required int limit});
  Future<List<PlayableMedia>> mostPlayedMedia({required int limit});
  Future<List<PlayableMedia>> lovedMedia();
  Future<List<MediaBrowsePlaylist>> playlists();
  Future<List<PlayableMedia>> playlistMedia(String playlistId);
  Future<List<MediaBrowseAlbum>> albums({
    required int limit,
    required int offset,
  });
  Future<List<PlayableMedia>> albumMedia({
    required String sourceTag,
    required String key,
  });
  Future<List<PlayableMedia>> libraryMedia({
    required int limit,
    required int offset,
  });
  Future<List<PlayableMedia>> searchMedia(String query, {required int limit});
}
