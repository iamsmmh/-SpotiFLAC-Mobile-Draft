import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/engine/playback_session.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/providers/engine_settings_provider.dart';
import 'package:spotiflac_android/providers/library_collections_provider.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/playback_provider.dart';
import 'package:spotiflac_android/providers/playback_statistics_provider.dart';
import 'package:spotiflac_android/providers/streaming_engine_provider.dart';
import 'package:spotiflac_android/services/history_database.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/services/media_browse_tree.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('MediaBrowse');

/// Live [MediaBrowseSource] over the download history, folder library,
/// collections (loved + playlists), listening statistics and the current
/// queue. Every method is defensive: a failing store yields an empty section
/// instead of an exception on the car screen.
class AppMediaBrowseSource implements MediaBrowseSource {
  AppMediaBrowseSource(this._ref);

  final Ref _ref;

  @override
  Future<MediaBrowseCounts> sectionCounts() async {
    final handler = musicPlayerHandler;
    final queue = handler?.queue.value.length ?? 0;
    final stats = _ref.read(playbackStatisticsProvider);
    int loved = 0;
    int playlists = 0;
    try {
      final collections = _ref.read(libraryCollectionsProvider);
      loved = collections.lovedCount;
      playlists = collections.playlistCount;
    } catch (e) {
      _log.w('Collections unavailable for browse root: $e');
    }
    int library = 0;
    int albums = 0;
    try {
      final counts = await LibraryDatabase.instance.getQueueCounts(
        const QueueLibraryDbQuery(limit: 1),
      );
      library = counts.allTrackCount;
      albums = counts.albumCount;
    } catch (e) {
      _log.w('Library counts unavailable for browse root: $e');
    }
    final recentCount =
        stats.trackStats.isEmpty ? 0 : stats.recentTracks.length;
    final topCount =
        stats.trackStats.isEmpty ? 0 : stats.mostPlayedTracks.length;
    return MediaBrowseCounts(
      queue: queue,
      recent: recentCount,
      top: topCount,
      loved: loved,
      playlists: playlists,
      albums: albums,
      library: library,
      home: recentCount > 0 || library > 0 ? 1 : 0,
      continueListening: recentCount,
      artists: albums,
      recommendations: topCount,
    );
  }

  @override
  Future<List<PlayableMedia>> queueMedia() async =>
      musicPlayerHandler?.currentQueueMedia() ?? const [];

  @override
  Future<List<PlayableMedia>> recentMedia({required int limit}) =>
      _fromStats(_ref.read(playbackStatisticsProvider).recentTracks, limit);

  @override
  Future<List<PlayableMedia>> mostPlayedMedia({required int limit}) =>
      _fromStats(
        _ref.read(playbackStatisticsProvider).mostPlayedTracks,
        limit,
      );

  /// Statistics only remember identity; the concrete file is looked up in
  /// the offline stores. Tracks without a local copy fall back to deferred
  /// engine items so the streaming ladder can still play them.
  Future<List<PlayableMedia>> _fromStats(
    List<TrackPlayStat> stats,
    int limit,
  ) async {
    final out = <PlayableMedia>[];
    for (final stat in stats.take(limit)) {
      if (stat.title.trim().isEmpty) continue;
      final track = Track(
        id: stat.trackId,
        name: stat.title,
        artistName: stat.artist,
        albumName: stat.album,
        duration: 0,
        source: 'app',
      );
      out.add(await _playableForTrack(track));
    }
    return out;
  }

  @override
  Future<List<PlayableMedia>> lovedMedia() async {
    try {
      final entries = _ref.read(libraryCollectionsProvider).loved;
      return [
        for (final entry in entries) await _playableForTrack(entry.track),
      ];
    } catch (e) {
      _log.w('Loved tracks unavailable: $e');
      return const [];
    }
  }

  @override
  Future<List<MediaBrowsePlaylist>> playlists() async {
    try {
      final playlists = _ref.read(libraryCollectionsProvider).playlists;
      return [
        for (final playlist in playlists)
          MediaBrowsePlaylist(
            id: playlist.id,
            name: playlist.name,
            trackCount: playlist.tracks.length,
            artUri: _artUri(playlist.coverImagePath ?? playlist.previewCover),
          ),
      ];
    } catch (e) {
      _log.w('Playlists unavailable: $e');
      return const [];
    }
  }

  @override
  Future<List<PlayableMedia>> playlistMedia(String playlistId) async {
    try {
      final notifier = _ref.read(libraryCollectionsProvider.notifier);
      await notifier.ensurePlaylistLoaded(playlistId);
      final playlist = _ref
          .read(libraryCollectionsProvider)
          .playlistById(playlistId);
      if (playlist == null) return const [];
      return [
        for (final entry in playlist.tracks)
          await _playableForTrack(entry.track),
      ];
    } catch (e) {
      _log.w('Playlist $playlistId unavailable: $e');
      return const [];
    }
  }

  @override
  Future<List<MediaBrowseAlbum>> albums({
    required int limit,
    required int offset,
  }) async {
    try {
      final rows = await LibraryDatabase.instance.getQueueAlbumPage(
        QueueLibraryDbQuery(
          limit: limit,
          offset: offset,
          filterMode: 'albums',
          sortMode: 'album',
        ),
      );
      return [
        for (final row in rows)
          if ((row['album_key'] as String? ?? '').isNotEmpty)
            MediaBrowseAlbum(
              source: row['queue_source'] as String? ?? 'downloaded',
              key: row['album_key'] as String,
              name: row['album_name'] as String? ?? '',
              artist: row['artist_name'] as String? ?? '',
              artUri: _artUri(
                (row['cover_url'] as String?) ?? (row['cover_path'] as String?),
              ),
            ),
      ];
    } catch (e) {
      _log.w('Albums unavailable: $e');
      return const [];
    }
  }

  @override
  Future<List<PlayableMedia>> albumMedia({
    required String sourceTag,
    required String key,
  }) async {
    try {
      if (sourceTag == 'local') {
        final rows = await LibraryDatabase.instance
            .getQueueLocalAlbumTracksByKey(key);
        return [
          for (final row in rows)
            playableFromLocal(LocalLibraryItem.fromJson(row)),
        ];
      }
      final rows = await HistoryDatabase.instance.getAlbumTracksByKey(key);
      return [
        for (final row in rows)
          playableFromHistory(DownloadHistoryItem.fromJson(row)),
      ];
    } catch (e) {
      _log.w('Album $sourceTag:$key unavailable: $e');
      return const [];
    }
  }

  @override
  Future<List<PlayableMedia>> libraryMedia({
    required int limit,
    required int offset,
  }) => _queryLibrary(
    QueueLibraryDbQuery(limit: limit, offset: offset, sortMode: 'title'),
  );

  @override
  Future<List<PlayableMedia>> searchMedia(
    String query, {
    required int limit,
  }) => _queryLibrary(
    QueueLibraryDbQuery(limit: limit, searchQuery: query, sortMode: 'title'),
  );

  Future<List<PlayableMedia>> _queryLibrary(QueueLibraryDbQuery query) async {
    try {
      final rows = await LibraryDatabase.instance.getQueueTrackPage(query);
      final out = <PlayableMedia>[];
      for (final row in rows) {
        final source = row['source'] as String? ?? '';
        final itemJson = Map<String, dynamic>.from(row['item'] as Map);
        if (source == 'local') {
          out.add(playableFromLocal(LocalLibraryItem.fromJson(itemJson)));
        } else if (source == 'downloaded') {
          out.add(
            playableFromHistory(DownloadHistoryItem.fromJson(itemJson)),
          );
        }
      }
      return out;
    } catch (e) {
      _log.w('Library query failed: $e');
      return const [];
    }
  }

  /// Local file when one exists, otherwise a deferred engine item (resolved
  /// through the Smart Play ladder at play time) — never a dead entry.
  Future<PlayableMedia> _playableForTrack(Track track) async {
    final engine = _ref.read(streamingEngineControllerProvider);
    final path = await engine.downloadedPathFor(track);
    if (path != null) {
      return PlayableMedia(
        id: track.id,
        source: path,
        title: track.name,
        artist: track.artistName,
        album: track.albumName,
        artUri: track.coverUrl,
        duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
        playbackMode: 'local',
      );
    }
    engine.registerTrackForDeferred(track);
    return PlayableMedia(
      id: track.id,
      source: PlayableMedia.deferredStreamUriFor(track.id),
      title: track.name,
      artist: track.artistName,
      album: track.albumName,
      artUri: track.coverUrl,
      duration: track.duration > 0 ? Duration(seconds: track.duration) : null,
      playbackMode: 'stream',
    );
  }

  static Uri? _artUri(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return null;
    if (value.startsWith('http') ||
        value.startsWith('content://') ||
        value.startsWith('file://')) {
      return Uri.tryParse(value);
    }
    return Uri.file(value);
  }
}

final mediaBrowseTreeProvider = Provider<MediaBrowseTree>(
  (ref) => MediaBrowseTree(AppMediaBrowseSource(ref)),
);

/// Installs the browse tree and the "play from browse" handler on the audio
/// service (idempotent). Called once from app bootstrap, next to the other
/// player observers; the handler may not exist yet, so the binding is
/// re-applied when it becomes ready.
void installMediaBrowsing(WidgetRef ref) {
  final tree = ref.read(mediaBrowseTreeProvider);
  MediaBrowseBinding.install(
    tree: tree,
    playContainer: (media, startIndex) async {
      final settings = ref.read(engineSettingsProvider);
      final hasDeferred = media.any((m) => m.isDeferredStream);
      if (hasDeferred && settings.streamingEnabled) {
        // Deferred items need the engine's queue path so they resolve lazily.
        await ref
            .read(musicPlayerControllerProvider)
            .playAll(media, initialIndex: startIndex);
        return;
      }
      await ref
          .read(playbackProvider.notifier)
          .playMediaQueue(
            media,
            startIndex: startIndex,
            externalPath: media[startIndex].source,
          );
    },
  );
}
