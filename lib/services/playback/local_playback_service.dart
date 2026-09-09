/// Local-file playback source for the unified playback layer.
///
/// [LocalPlaybackSource] plays downloaded (or locally imported) tracks on
/// the shared player. File discovery reuses the exact stores the rest of the
/// app reads — the local library database and the download history database —
/// behind the injectable [LocalTrackPathResolver] port, so tests never touch
/// SQLite and production never maintains a second library index.
library;

import 'dart:async';

import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/services/cache/playback_source_ladder.dart'
    show PlaybackSourceKind;
import 'package:spotiflac_android/services/history_database.dart'
    show HistoryDatabase, HistoryLookupRequest;
import 'package:spotiflac_android/services/library_database.dart'
    show LibraryDatabase;
import 'package:spotiflac_android/services/music_player_service.dart'
    show PlayableMedia;
import 'package:spotiflac_android/services/playback/playback_source.dart';
import 'package:spotiflac_android/utils/file_access.dart'
    show fileExists, isCueVirtualPath;

/// Resolves the playable on-disk path for [track], or null when no
/// downloaded/imported copy exists (or it no longer exists on storage).
typedef LocalTrackPathResolver = Future<String?> Function(Track track);

/// Batch variant of [LocalTrackPathResolver], aligned with the input order.
typedef LocalTrackPathBatchResolver =
    Future<List<String?>> Function(List<Track> tracks);

/// Production resolver: local library first, then download history, with an
/// existence check on every candidate.
///
/// CUE virtual tracks (`album.cue#trackNN`) are never playable directly and
/// resolve to null, matching the queue builders elsewhere in the app. A
/// broken store resolves to null rather than throwing so one corrupt index
/// can never block playback from the other.
Future<String?> defaultLocalTrackPathResolver(Track track) async {
  try {
    final library = await LibraryDatabase.instance.findExisting(
      isrc: track.isrc,
      trackName: track.name,
      artistName: track.artistName,
    );
    final libraryPath = library?['filePath']?.toString().trim() ?? '';
    if (libraryPath.isNotEmpty &&
        !isCueVirtualPath(libraryPath) &&
        await fileExists(libraryPath)) {
      return libraryPath;
    }
  } catch (_) {
    // A broken library store must not block the history lookup below.
  }
  try {
    final row = await HistoryDatabase.instance.findExistingTrack(
      HistoryLookupRequest(
        spotifyId: track.id,
        isrc: track.isrc,
        trackName: track.name,
        artistName: track.artistName,
      ),
    );
    final historyPath = row?['filePath']?.toString().trim() ?? '';
    if (historyPath.isEmpty || isCueVirtualPath(historyPath)) return null;
    return await fileExists(historyPath) ? historyPath : null;
  } catch (_) {
    return null;
  }
}

/// Production batch resolver: fans out over [defaultLocalTrackPathResolver].
Future<List<String?>> defaultLocalTrackPathBatchResolver(
  List<Track> tracks,
) {
  return Future.wait(
    tracks.map(defaultLocalTrackPathResolver),
    eagerError: false,
  );
}

/// Plays downloaded/local tracks on the shared player.
///
/// Transport ([PlaybackSource.pause]/[PlaybackSource.resume]/…) is inherited
/// from [SharedBackendPlaybackSource] and therefore identical for every
/// origin; only resolution ([play]/[preload]) is local-specific.
class LocalPlaybackSource extends SharedBackendPlaybackSource {
  LocalPlaybackSource({required super.backend, LocalTrackPathResolver? resolvePath})
    : _resolvePath = resolvePath ?? defaultLocalTrackPathResolver;

  final LocalTrackPathResolver _resolvePath;

  /// Queue media id for a local item: the file path itself (engine parity).
  static String mediaIdForPath(String path) => path;

  /// Resolves [track] to its on-disk path (null when not downloaded).
  Future<String?> resolvePath(Track track) => _resolvePath(track);

  @override
  PlaybackSourceKind get kind => PlaybackSourceKind.localLibrary;

  @override
  Future<void> initialize() => backend.ensureReady();

  @override
  Future<void> play(Track track) async {
    final path = await _resolvePath(track);
    if (path == null || path.trim().isEmpty) {
      throw PlaybackSourceException.unavailable(
        track.id,
        'No downloaded file for "${track.name}"',
      );
    }
    await backend.playMedia(_mediaFor(track, path));
  }

  @override
  Future<void> preload(Track track) async {
    final path = await _resolvePath(track);
    if (path == null || path.isEmpty) {
      throw PlaybackSourceException.unavailable(
        track.id,
        'No downloaded file for "${track.name}"',
      );
    }
    // Local files need no warming beyond the existence check above: the
    // shared player opens them synchronously at play time.
  }

  PlayableMedia mediaFor(Track track, String path) => _mediaFor(track, path);

  PlayableMedia _mediaFor(Track track, String path) {
    return playableMediaForTrack(
      track,
      mediaId: mediaIdForPath(path),
      source: path,
      playbackMode: 'local',
    );
  }
}
