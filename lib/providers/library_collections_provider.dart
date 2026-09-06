import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/core/sync/sync_entities.dart';
import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/providers/sync_provider.dart';
import 'package:spotiflac_android/services/ffmpeg_service.dart';
import 'package:spotiflac_android/services/library_collections_database.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('LibraryCollections');

const _playlistCoverMaxDimension = 1024;
const _playlistCoverMaxStoredBytes = 2 * 1024 * 1024;

String trackCollectionKey(Track track) {
  final isrc = track.isrc?.trim();
  if (isrc != null && isrc.isNotEmpty) {
    return 'isrc:${isrc.toUpperCase()}';
  }
  final source = (track.source?.trim().isNotEmpty ?? false)
      ? track.source!.trim()
      : 'builtin';
  return '$source:${track.id}';
}

String _stripCollectionResourcePrefix(String value) {
  final colonIndex = value.indexOf(':');
  if (colonIndex <= 0 || colonIndex == value.length - 1) {
    return value.trim();
  }
  return value.substring(colonIndex + 1).trim();
}

String artistCollectionKey({
  required String artistId,
  required String? providerId,
}) {
  final trimmedArtistId = artistId.trim();
  final trimmedProviderId = providerId?.trim();
  final source = trimmedProviderId != null && trimmedProviderId.isNotEmpty
      ? trimmedProviderId.toLowerCase()
      : (trimmedArtistId.contains(':')
            ? trimmedArtistId.split(':').first.toLowerCase()
            : 'builtin');
  return '$source:${_stripCollectionResourcePrefix(trimmedArtistId)}';
}

/// Stable identity for a favorited album, mirroring [artistCollectionKey]:
/// the provider namespace owns the prefix so the same album browsed through
/// two extensions stays two entries, while re-visits through one extension
/// dedupe exactly.
String albumCollectionKey({
  required String albumId,
  required String? providerId,
}) {
  final trimmedAlbumId = albumId.trim();
  final trimmedProviderId = providerId?.trim();
  final source = trimmedProviderId != null && trimmedProviderId.isNotEmpty
      ? trimmedProviderId.toLowerCase()
      : (trimmedAlbumId.contains(':')
            ? trimmedAlbumId.split(':').first.toLowerCase()
            : 'builtin');
  return '$source:${_stripCollectionResourcePrefix(trimmedAlbumId)}';
}

class CollectionTrackEntry {
  final String key;
  final Track track;
  final DateTime addedAt;

  const CollectionTrackEntry({
    required this.key,
    required this.track,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'track': track.toJson(),
    'addedAt': addedAt.toIso8601String(),
  };

  factory CollectionTrackEntry.fromJson(Map<String, dynamic> json) {
    final addedAtRaw = json['addedAt'] as String?;
    return CollectionTrackEntry(
      key: json['key'] as String,
      track: Track.fromJson(Map<String, dynamic>.from(json['track'] as Map)),
      addedAt: DateTime.tryParse(addedAtRaw ?? '') ?? DateTime.now(),
    );
  }
}

class CollectionArtistEntry {
  final String key;
  final String artistId;
  final String? providerId;
  final String name;
  final String? imageUrl;
  final DateTime addedAt;

  const CollectionArtistEntry({
    required this.key,
    required this.artistId,
    required this.providerId,
    required this.name,
    this.imageUrl,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'artistId': artistId,
    'providerId': providerId,
    'name': name,
    'imageUrl': imageUrl,
    'addedAt': addedAt.toIso8601String(),
  };

  factory CollectionArtistEntry.fromJson(Map<String, dynamic> json) {
    final artistId = json['artistId'] as String;
    final providerId = json['providerId'] as String?;
    final addedAtRaw = json['addedAt'] as String?;
    return CollectionArtistEntry(
      key:
          json['key'] as String? ??
          artistCollectionKey(artistId: artistId, providerId: providerId),
      artistId: artistId,
      providerId: providerId,
      name: json['name'] as String? ?? '',
      imageUrl: json['imageUrl'] as String?,
      addedAt: DateTime.tryParse(addedAtRaw ?? '') ?? DateTime.now(),
    );
  }
}

class CollectionAlbumEntry {
  final String key;
  final String albumId;
  final String? providerId;
  final String name;
  final String? artistName;
  final String? artistId;
  final String? imageUrl;
  final DateTime addedAt;

  const CollectionAlbumEntry({
    required this.key,
    required this.albumId,
    required this.providerId,
    required this.name,
    this.artistName,
    this.artistId,
    this.imageUrl,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'key': key,
    'albumId': albumId,
    'providerId': providerId,
    'name': name,
    if (artistName != null) 'artistName': artistName,
    if (artistId != null) 'artistId': artistId,
    'imageUrl': imageUrl,
    'addedAt': addedAt.toIso8601String(),
  };

  factory CollectionAlbumEntry.fromJson(Map<String, dynamic> json) {
    final albumId = json['albumId'] as String;
    final providerId = json['providerId'] as String?;
    final addedAtRaw = json['addedAt'] as String?;
    return CollectionAlbumEntry(
      key:
          json['key'] as String? ??
          albumCollectionKey(albumId: albumId, providerId: providerId),
      albumId: albumId,
      providerId: providerId,
      name: json['name'] as String? ?? '',
      artistName: json['artistName'] as String?,
      artistId: json['artistId'] as String?,
      imageUrl: json['imageUrl'] as String?,
      addedAt: DateTime.tryParse(addedAtRaw ?? '') ?? DateTime.now(),
    );
  }
}

class UserPlaylistCollection {
  final String id;
  final String name;
  final String? coverImagePath;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<CollectionTrackEntry> tracks;
  final String? previewCover;
  final bool tracksLoaded;
  final Set<String> _trackKeys;

  UserPlaylistCollection({
    required this.id,
    required this.name,
    this.coverImagePath,
    required this.createdAt,
    required this.updatedAt,
    required this.tracks,
    this.previewCover,
    this.tracksLoaded = true,
    Set<String>? trackKeys,
  }) : _trackKeys = trackKeys ?? tracks.map((entry) => entry.key).toSet();

  UserPlaylistCollection copyWith({
    String? id,
    String? name,
    String? Function()? coverImagePath,
    DateTime? createdAt,
    DateTime? updatedAt,
    List<CollectionTrackEntry>? tracks,
    String? previewCover,
    bool? tracksLoaded,
  }) {
    final nextTracks = tracks ?? this.tracks;
    final keepTrackIndex = identical(nextTracks, this.tracks);
    return UserPlaylistCollection(
      id: id ?? this.id,
      name: name ?? this.name,
      coverImagePath: coverImagePath != null
          ? coverImagePath()
          : this.coverImagePath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      tracks: nextTracks,
      previewCover: previewCover ?? this.previewCover,
      tracksLoaded:
          tracksLoaded ??
          (identical(nextTracks, this.tracks) ? this.tracksLoaded : true),
      trackKeys: keepTrackIndex ? _trackKeys : null,
    );
  }

  bool containsTrack(Track track) {
    final key = trackCollectionKey(track);
    return _trackKeys.contains(key);
  }

  bool containsTrackKey(String trackKey) {
    return _trackKeys.contains(trackKey);
  }

  int get trackCount => _trackKeys.length;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    if (coverImagePath != null) 'coverImagePath': coverImagePath,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'tracks': tracks.map((e) => e.toJson()).toList(),
  };

  factory UserPlaylistCollection.fromJson(Map<String, dynamic> json) {
    final createdAtRaw = json['createdAt'] as String?;
    final updatedAtRaw = json['updatedAt'] as String?;
    final createdAt = DateTime.tryParse(createdAtRaw ?? '') ?? DateTime.now();
    final updatedAt = DateTime.tryParse(updatedAtRaw ?? '') ?? createdAt;
    final tracksRaw = (json['tracks'] as List?) ?? const [];
    return UserPlaylistCollection(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      coverImagePath: json['coverImagePath'] as String?,
      createdAt: createdAt,
      updatedAt: updatedAt,
      tracks: tracksRaw
          .whereType<Map<Object?, Object?>>()
          .map(
            (e) => CollectionTrackEntry.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
    );
  }
}

class PlaylistPickerSummary {
  final String id;
  final String name;
  final String? coverImagePath;
  final String? previewCover;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int trackCount;
  final bool containsAllRequestedTracks;

  const PlaylistPickerSummary({
    required this.id,
    required this.name,
    this.coverImagePath,
    this.previewCover,
    required this.createdAt,
    required this.updatedAt,
    required this.trackCount,
    required this.containsAllRequestedTracks,
  });
}

class PlaylistPickerSummaryRequest {
  final List<String> trackKeys;

  PlaylistPickerSummaryRequest._(this.trackKeys);

  factory PlaylistPickerSummaryRequest.fromTracks(Iterable<Track> tracks) {
    final keys =
        tracks
            .map(trackCollectionKey)
            .where((key) => key.trim().isNotEmpty)
            .toSet()
            .toList(growable: false)
          ..sort();
    return PlaylistPickerSummaryRequest._(keys);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PlaylistPickerSummaryRequest &&
          listEquals(trackKeys, other.trackKeys);

  @override
  int get hashCode => Object.hashAll(trackKeys);
}

class LibraryCollectionsState {
  final List<CollectionTrackEntry> wishlist;
  final List<CollectionTrackEntry> loved;
  final List<UserPlaylistCollection> playlists;
  final List<CollectionArtistEntry> favoriteArtists;
  final List<CollectionAlbumEntry> favoriteAlbums;
  final bool isLoaded;
  final Set<String> _wishlistKeys;
  final Set<String> _lovedKeys;
  final Set<String> _favoriteArtistKeys;
  final Set<String> _favoriteAlbumKeys;
  final Map<String, UserPlaylistCollection> _playlistsById;
  final Set<String> _allPlaylistTrackKeys;

  LibraryCollectionsState({
    this.wishlist = const [],
    this.loved = const [],
    this.playlists = const [],
    this.favoriteArtists = const [],
    this.favoriteAlbums = const [],
    this.isLoaded = false,
    Set<String>? wishlistKeys,
    Set<String>? lovedKeys,
    Set<String>? favoriteArtistKeys,
    Set<String>? favoriteAlbumKeys,
    Map<String, UserPlaylistCollection>? playlistsById,
    Set<String>? allPlaylistTrackKeys,
  }) : _wishlistKeys =
           wishlistKeys ?? wishlist.map((entry) => entry.key).toSet(),
       _lovedKeys = lovedKeys ?? loved.map((entry) => entry.key).toSet(),
       _favoriteArtistKeys =
           favoriteArtistKeys ??
           favoriteArtists.map((entry) => entry.key).toSet(),
       _favoriteAlbumKeys =
           favoriteAlbumKeys ?? favoriteAlbums.map((entry) => entry.key).toSet(),
       _playlistsById =
           playlistsById ??
           Map.fromEntries(
             playlists.map((playlist) => MapEntry(playlist.id, playlist)),
           ),
       _allPlaylistTrackKeys =
           allPlaylistTrackKeys ?? _buildPlaylistTrackKeys(playlists);

  int get wishlistCount => wishlist.length;
  int get lovedCount => loved.length;
  int get playlistCount => playlists.length;
  int get favoriteArtistCount => favoriteArtists.length;
  int get favoriteAlbumCount => favoriteAlbums.length;

  bool isInWishlist(Track track) {
    final key = trackCollectionKey(track);
    return _wishlistKeys.contains(key);
  }

  bool isLoved(Track track) {
    final key = trackCollectionKey(track);
    return _lovedKeys.contains(key);
  }

  bool containsWishlistKey(String trackKey) {
    return _wishlistKeys.contains(trackKey);
  }

  bool containsLovedKey(String trackKey) {
    return _lovedKeys.contains(trackKey);
  }

  bool isFavoriteArtist({
    required String artistId,
    required String? providerId,
  }) {
    final key = artistCollectionKey(artistId: artistId, providerId: providerId);
    return _favoriteArtistKeys.contains(key);
  }

  bool containsFavoriteArtistKey(String artistKey) {
    return _favoriteArtistKeys.contains(artistKey);
  }

  bool isFavoriteAlbum({required String albumId, required String? providerId}) {
    final key = albumCollectionKey(albumId: albumId, providerId: providerId);
    return _favoriteAlbumKeys.contains(key);
  }

  bool containsFavoriteAlbumKey(String albumKey) {
    return _favoriteAlbumKeys.contains(albumKey);
  }

  UserPlaylistCollection? playlistById(String playlistId) {
    return _playlistsById[playlistId];
  }

  bool playlistContainsTrack(String playlistId, String trackKey) {
    final playlist = _playlistsById[playlistId];
    if (playlist == null) return false;
    return playlist.containsTrackKey(trackKey);
  }

  bool isTrackInAnyPlaylist(String trackKey) {
    return _allPlaylistTrackKeys.contains(trackKey);
  }

  bool get hasPlaylistTracks => _allPlaylistTrackKeys.isNotEmpty;

  LibraryCollectionsState copyWith({
    List<CollectionTrackEntry>? wishlist,
    List<CollectionTrackEntry>? loved,
    List<UserPlaylistCollection>? playlists,
    List<CollectionArtistEntry>? favoriteArtists,
    List<CollectionAlbumEntry>? favoriteAlbums,
    bool? isLoaded,
  }) {
    final nextWishlist = wishlist ?? this.wishlist;
    final nextLoved = loved ?? this.loved;
    final nextPlaylists = playlists ?? this.playlists;
    final nextFavoriteArtists = favoriteArtists ?? this.favoriteArtists;
    final nextFavoriteAlbums = favoriteAlbums ?? this.favoriteAlbums;
    final keepWishlistIndex = identical(nextWishlist, this.wishlist);
    final keepLovedIndex = identical(nextLoved, this.loved);
    final keepPlaylistIndex = identical(nextPlaylists, this.playlists);
    final keepFavoriteArtistIndex = identical(
      nextFavoriteArtists,
      this.favoriteArtists,
    );
    final keepFavoriteAlbumIndex = identical(
      nextFavoriteAlbums,
      this.favoriteAlbums,
    );

    return LibraryCollectionsState(
      wishlist: nextWishlist,
      loved: nextLoved,
      playlists: nextPlaylists,
      favoriteArtists: nextFavoriteArtists,
      favoriteAlbums: nextFavoriteAlbums,
      isLoaded: isLoaded ?? this.isLoaded,
      wishlistKeys: keepWishlistIndex ? _wishlistKeys : null,
      lovedKeys: keepLovedIndex ? _lovedKeys : null,
      favoriteArtistKeys: keepFavoriteArtistIndex ? _favoriteArtistKeys : null,
      favoriteAlbumKeys: keepFavoriteAlbumIndex ? _favoriteAlbumKeys : null,
      playlistsById: keepPlaylistIndex ? _playlistsById : null,
      allPlaylistTrackKeys: keepPlaylistIndex ? _allPlaylistTrackKeys : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'wishlist': wishlist.map((e) => e.toJson()).toList(),
    'loved': loved.map((e) => e.toJson()).toList(),
    'playlists': playlists.map((e) => e.toJson()).toList(),
    'favoriteArtists': favoriteArtists.map((e) => e.toJson()).toList(),
    'favoriteAlbums': favoriteAlbums.map((e) => e.toJson()).toList(),
  };

  factory LibraryCollectionsState.fromJson(Map<String, dynamic> json) {
    final wishlistRaw = (json['wishlist'] as List?) ?? const [];
    final lovedRaw = (json['loved'] as List?) ?? const [];
    final playlistsRaw = (json['playlists'] as List?) ?? const [];
    final favoriteArtistsRaw = (json['favoriteArtists'] as List?) ?? const [];
    final favoriteAlbumsRaw = (json['favoriteAlbums'] as List?) ?? const [];

    return LibraryCollectionsState(
      wishlist: wishlistRaw
          .whereType<Map<Object?, Object?>>()
          .map(
            (e) => CollectionTrackEntry.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
      loved: lovedRaw
          .whereType<Map<Object?, Object?>>()
          .map(
            (e) => CollectionTrackEntry.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
      playlists: playlistsRaw
          .whereType<Map<Object?, Object?>>()
          .map(
            (e) =>
                UserPlaylistCollection.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
      favoriteArtists: favoriteArtistsRaw
          .whereType<Map<Object?, Object?>>()
          .map(
            (e) => CollectionArtistEntry.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
      favoriteAlbums: favoriteAlbumsRaw
          .whereType<Map<Object?, Object?>>()
          .map(
            (e) => CollectionAlbumEntry.fromJson(Map<String, dynamic>.from(e)),
          )
          .toList(growable: false),
      isLoaded: true,
    );
  }
}

Set<String> _buildPlaylistTrackKeys(List<UserPlaylistCollection> playlists) {
  final keys = <String>{};
  for (final playlist in playlists) {
    keys.addAll(playlist._trackKeys);
  }
  return keys;
}

class PlaylistAddBatchResult {
  final int addedCount;
  final int alreadyInPlaylistCount;

  const PlaylistAddBatchResult({
    required this.addedCount,
    required this.alreadyInPlaylistCount,
  });
}

class LibraryCollectionsNotifier extends Notifier<LibraryCollectionsState> {
  final LibraryCollectionsDatabase _db = LibraryCollectionsDatabase.instance;
  Future<void>? _loadFuture;
  final Map<String, Future<void>> _playlistLoadFutures = {};

  void _invalidatePlaylistPickerSummaries() {
    ref.invalidate(libraryPlaylistPickerSummariesProvider);
  }

  @override
  LibraryCollectionsState build() {
    _loadFuture = _load();
    return LibraryCollectionsState();
  }

  Future<void> _load() async {
    try {
      await _db.migrateFromSharedPreferences();
      final snapshot = await _db.loadSnapshot();

      final wishlist = <CollectionTrackEntry>[];
      for (final row in snapshot.wishlistRows) {
        final parsed = _parseTrackEntryRow(row);
        if (parsed != null) {
          wishlist.add(parsed);
        }
      }

      final loved = <CollectionTrackEntry>[];
      for (final row in snapshot.lovedRows) {
        final parsed = _parseTrackEntryRow(row);
        if (parsed != null) {
          loved.add(parsed);
        }
      }

      final favoriteArtists = <CollectionArtistEntry>[];
      for (final row in snapshot.favoriteArtistRows) {
        final parsed = _parseArtistEntryRow(row);
        if (parsed != null) {
          favoriteArtists.add(parsed);
        }
      }

      final favoriteAlbums = <CollectionAlbumEntry>[];
      for (final row in snapshot.favoriteAlbumRows) {
        final parsed = _parseAlbumEntryRow(row);
        if (parsed != null) {
          favoriteAlbums.add(parsed);
        }
      }

      final trackKeysByPlaylist = <String, Set<String>>{};
      for (final row in snapshot.playlistTrackRows) {
        final playlistId = row['playlist_id'] as String?;
        if (playlistId == null || playlistId.isEmpty) continue;
        final trackKey = row['track_key'] as String?;
        if (trackKey == null || trackKey.isEmpty) continue;
        trackKeysByPlaylist.putIfAbsent(playlistId, () => {}).add(trackKey);
      }

      final playlists = <UserPlaylistCollection>[];
      for (final row in snapshot.playlistRows) {
        final id = row['id'] as String?;
        if (id == null || id.isEmpty) continue;

        final createdAtRaw = row['created_at'] as String?;
        final updatedAtRaw = row['updated_at'] as String?;
        final createdAt =
            DateTime.tryParse(createdAtRaw ?? '') ?? DateTime.now();
        final updatedAt = DateTime.tryParse(updatedAtRaw ?? '') ?? createdAt;
        String? previewCover;
        final previewTrackJson = row['preview_track_json'] as String?;
        if (previewTrackJson != null && previewTrackJson.isNotEmpty) {
          try {
            final decoded = jsonDecode(previewTrackJson);
            if (decoded is Map) {
              previewCover = decoded['coverUrl']?.toString();
            }
          } catch (e) {
            _log.d('best-effort step failed: $e');
          }
        }

        playlists.add(
          UserPlaylistCollection(
            id: id,
            name: row['name'] as String? ?? '',
            coverImagePath: row['cover_image_path'] as String?,
            createdAt: createdAt,
            updatedAt: updatedAt,
            tracks: const <CollectionTrackEntry>[],
            previewCover: previewCover,
            tracksLoaded: false,
            trackKeys: trackKeysByPlaylist[id],
          ),
        );
      }

      state = LibraryCollectionsState(
        wishlist: wishlist,
        loved: loved,
        playlists: playlists,
        favoriteArtists: favoriteArtists,
        favoriteAlbums: favoriteAlbums,
        isLoaded: true,
      );
    } catch (_) {
      state = state.copyWith(isLoaded: true);
    }
  }

  Future<void> _ensureLoaded() async {
    if (state.isLoaded) return;
    await (_loadFuture ?? _load());
  }

  Future<void> ensurePlaylistLoaded(String playlistId) async {
    await _ensureLoaded();
    final playlist = state.playlistById(playlistId);
    if (playlist == null || playlist.tracksLoaded) return;

    final pending = _playlistLoadFutures[playlistId];
    if (pending != null) return pending;
    final load = () async {
      final rows = await _db.loadPlaylistTracks(playlistId);
      final tracks = rows
          .map(_parseTrackEntryRow)
          .whereType<CollectionTrackEntry>()
          .toList(growable: false);
      _replacePlaylistById(
        playlistId,
        (current) => current.copyWith(tracks: tracks, tracksLoaded: true),
      );
    }();
    _playlistLoadFutures[playlistId] = load;
    try {
      await load;
    } finally {
      if (identical(_playlistLoadFutures[playlistId], load)) {
        _playlistLoadFutures.remove(playlistId);
      }
    }
  }

  Future<void> ensurePlaylistsLoaded(Iterable<String> playlistIds) async {
    await Future.wait(playlistIds.toSet().map(ensurePlaylistLoaded));
  }

  CollectionTrackEntry? _parseTrackEntryRow(Map<String, dynamic> row) {
    final key = row['track_key'] as String?;
    final trackJson = row['track_json'] as String?;
    if (key == null || key.isEmpty || trackJson == null || trackJson.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(trackJson);
      if (decoded is! Map) return null;
      final track = Track.fromJson(Map<String, dynamic>.from(decoded));
      final addedAtRaw = row['added_at'] as String?;
      return CollectionTrackEntry(
        key: key,
        track: track,
        addedAt: DateTime.tryParse(addedAtRaw ?? '') ?? DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }

  CollectionArtistEntry? _parseArtistEntryRow(Map<String, dynamic> row) {
    final key = row['artist_key'] as String?;
    final artistJson = row['artist_json'] as String?;
    if (key == null ||
        key.isEmpty ||
        artistJson == null ||
        artistJson.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(artistJson);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final addedAtRaw = row['added_at'] as String?;
      return CollectionArtistEntry.fromJson({
        ...map,
        'key': key,
        'addedAt': map['addedAt'] ?? addedAtRaw,
      });
    } catch (_) {
      return null;
    }
  }

  CollectionAlbumEntry? _parseAlbumEntryRow(Map<String, dynamic> row) {
    final key = row['album_key'] as String?;
    final albumJson = row['album_json'] as String?;
    if (key == null || key.isEmpty || albumJson == null || albumJson.isEmpty) {
      return null;
    }

    try {
      final decoded = jsonDecode(albumJson);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final addedAtRaw = row['added_at'] as String?;
      return CollectionAlbumEntry.fromJson({
        ...map,
        'key': key,
        'addedAt': map['addedAt'] ?? addedAtRaw,
      });
    } catch (_) {
      return null;
    }
  }

  bool _replacePlaylistById(
    String playlistId,
    UserPlaylistCollection Function(UserPlaylistCollection playlist) update,
  ) {
    final playlist = state.playlistById(playlistId);
    if (playlist == null) return false;

    final playlistIndex = state.playlists.indexWhere((p) => p.id == playlistId);
    if (playlistIndex < 0) return false;

    final nextPlaylist = update(playlist);
    if (identical(nextPlaylist, playlist)) return false;

    final updatedPlaylists = [...state.playlists];
    updatedPlaylists[playlistIndex] = nextPlaylist;
    state = state.copyWith(playlists: updatedPlaylists);
    return true;
  }

  Future<bool> _toggleTrackEntry(
    Track track, {
    required bool Function(String key) contains,
    required List<CollectionTrackEntry> Function(LibraryCollectionsState state)
    select,
    required LibraryCollectionsState Function(List<CollectionTrackEntry> list)
    withList,
    required Future<void> Function(String key) dbDelete,
    required Future<void> Function({
      required String trackKey,
      required String trackJson,
      required String addedAt,
    })
    dbUpsert,
  }) async {
    await _ensureLoaded();
    final key = trackCollectionKey(track);
    if (contains(key)) {
      await dbDelete(key);
      state = withList(
        select(
          state,
        ).where((entry) => entry.key != key).toList(growable: false),
      );
      _recordFavoritesSyncDelete(key);
      return false;
    }

    final entry = CollectionTrackEntry(
      key: key,
      track: track,
      addedAt: DateTime.now(),
    );
    await dbUpsert(
      trackKey: key,
      trackJson: jsonEncode(track.toJson()),
      addedAt: entry.addedAt.toIso8601String(),
    );
    state = withList([entry, ...select(state)]);
    _recordFavoritesSyncWrite(key, <String, Object?>{
      'kind': 'track',
      'entry': entry.toJson(),
    });
    return true;
  }

  /// Cloud-sync outbox hooks (Phase 6). Fire-and-forget and fail-safe: when
  /// no sync backend is configured these no-op, and a sync failure must never
  /// break the favorites UX.
  void _recordFavoritesSyncWrite(String key, Map<String, Object?> payload) {
    try {
      ref
          .read(syncStateProvider.notifier)
          .recordLocalWrite(SyncScope.favorites, key, payload);
    } catch (e) {
      _log.d('best-effort step failed: $e');
    }
  }

  void _recordFavoritesSyncDelete(String key) {
    try {
      ref
          .read(syncStateProvider.notifier)
          .recordLocalDelete(SyncScope.favorites, key);
    } catch (e) {
      _log.d('best-effort step failed: $e');
    }
  }

  Future<bool> toggleWishlist(Track track) => _toggleTrackEntry(
    track,
    contains: (key) => state.containsWishlistKey(key),
    select: (state) => state.wishlist,
    withList: (list) => state.copyWith(wishlist: list),
    dbDelete: _db.deleteWishlistEntry,
    dbUpsert: _db.upsertWishlistEntry,
  );

  Future<bool> toggleLoved(Track track) => _toggleTrackEntry(
    track,
    contains: (key) => state.containsLovedKey(key),
    select: (state) => state.loved,
    withList: (list) => state.copyWith(loved: list),
    dbDelete: _db.deleteLovedEntry,
    dbUpsert: _db.upsertLovedEntry,
  );

  Future<bool> toggleFavoriteArtist({
    required String artistId,
    required String? providerId,
    required String name,
    String? imageUrl,
  }) async {
    await _ensureLoaded();
    final key = artistCollectionKey(artistId: artistId, providerId: providerId);
    final sourceSeparator = key.indexOf(':');
    final source = sourceSeparator > 0 ? key.substring(0, sourceSeparator) : '';
    final trimmedProviderId = providerId?.trim();
    final effectiveProviderId =
        trimmedProviderId != null && trimmedProviderId.isNotEmpty
        ? trimmedProviderId
        : (source.isNotEmpty && source != 'builtin' ? source : null);
    if (state.containsFavoriteArtistKey(key)) {
      await removeFavoriteArtist(key);
      return false;
    }

    final entry = CollectionArtistEntry(
      key: key,
      artistId: _stripCollectionResourcePrefix(artistId),
      providerId: effectiveProviderId,
      name: name,
      imageUrl: imageUrl,
      addedAt: DateTime.now(),
    );
    await _db.upsertFavoriteArtistEntry(
      artistKey: key,
      artistJson: jsonEncode(entry.toJson()),
      addedAt: entry.addedAt.toIso8601String(),
    );
    final updated = [entry, ...state.favoriteArtists];
    state = state.copyWith(favoriteArtists: updated);
    _recordFavoritesSyncWrite(key, <String, Object?>{
      'kind': 'artist',
      'entry': entry.toJson(),
    });
    return true;
  }

  /// Toggles an album favorite. Returns `true` when the album is now
  /// favorited, `false` when it was removed. Behavior intentionally mirrors
  /// [toggleFavoriteArtist] (identity upstream of [_stripCollectionResourcePrefix],
  /// newest-first state, SQLite write-through).
  Future<bool> toggleFavoriteAlbum({
    required String albumId,
    required String? providerId,
    required String name,
    String? artistName,
    String? artistId,
    String? imageUrl,
  }) async {
    await _ensureLoaded();
    final key = albumCollectionKey(albumId: albumId, providerId: providerId);
    final sourceSeparator = key.indexOf(':');
    final source = sourceSeparator > 0 ? key.substring(0, sourceSeparator) : '';
    final trimmedProviderId = providerId?.trim();
    final effectiveProviderId =
        trimmedProviderId != null && trimmedProviderId.isNotEmpty
        ? trimmedProviderId
        : (source.isNotEmpty && source != 'builtin' ? source : null);
    if (state.containsFavoriteAlbumKey(key)) {
      await removeFavoriteAlbum(key);
      return false;
    }

    final entry = CollectionAlbumEntry(
      key: key,
      albumId: _stripCollectionResourcePrefix(albumId),
      providerId: effectiveProviderId,
      name: name,
      artistName: artistName,
      artistId: artistId,
      imageUrl: imageUrl,
      addedAt: DateTime.now(),
    );
    await _db.upsertFavoriteAlbumEntry(
      albumKey: key,
      albumJson: jsonEncode(entry.toJson()),
      addedAt: entry.addedAt.toIso8601String(),
    );
    final updated = [entry, ...state.favoriteAlbums];
    state = state.copyWith(favoriteAlbums: updated);
    _recordFavoritesSyncWrite(key, <String, Object?>{
      'kind': 'album',
      'entry': entry.toJson(),
    });
    return true;
  }

  Future<void> removeFavoriteAlbum(String albumKey) => _removeEntry(
    albumKey,
    contains: (key) => state.containsFavoriteAlbumKey(key),
    select: (state) => state.favoriteAlbums,
    keyOf: (entry) => entry.key,
    withList: (list) => state.copyWith(favoriteAlbums: list),
    dbDelete: _db.deleteFavoriteAlbumEntry,
  );

  Future<void> _removeEntry<T>(
    String key, {
    required bool Function(String key) contains,
    required List<T> Function(LibraryCollectionsState state) select,
    required String Function(T entry) keyOf,
    required LibraryCollectionsState Function(List<T> list) withList,
    required Future<void> Function(String key) dbDelete,
  }) async {
    await _ensureLoaded();
    if (!contains(key)) return;

    await dbDelete(key);
    state = withList(
      select(
        state,
      ).where((entry) => keyOf(entry) != key).toList(growable: false),
    );
    _recordFavoritesSyncDelete(key);
  }

  Future<void> removeFavoriteArtist(String artistKey) => _removeEntry(
    artistKey,
    contains: (key) => state.containsFavoriteArtistKey(key),
    select: (state) => state.favoriteArtists,
    keyOf: (entry) => entry.key,
    withList: (list) => state.copyWith(favoriteArtists: list),
    dbDelete: _db.deleteFavoriteArtistEntry,
  );

  Future<void> removeFromWishlist(String trackKey) => _removeEntry(
    trackKey,
    contains: (key) => state.containsWishlistKey(key),
    select: (state) => state.wishlist,
    keyOf: (entry) => entry.key,
    withList: (list) => state.copyWith(wishlist: list),
    dbDelete: _db.deleteWishlistEntry,
  );

  Future<void> removeFromLoved(String trackKey) => _removeEntry(
    trackKey,
    contains: (key) => state.containsLovedKey(key),
    select: (state) => state.loved,
    keyOf: (entry) => entry.key,
    withList: (list) => state.copyWith(loved: list),
    dbDelete: _db.deleteLovedEntry,
  );

  Future<String> createPlaylist(String name) async {
    await _ensureLoaded();
    final now = DateTime.now();
    final id = 'pl_${now.microsecondsSinceEpoch}';
    final trimmedName = name.trim();

    final playlist = UserPlaylistCollection(
      id: id,
      name: trimmedName,
      createdAt: now,
      updatedAt: now,
      tracks: const [],
    );

    await _db.upsertPlaylist(
      id: id,
      name: trimmedName,
      coverImagePath: null,
      createdAt: now.toIso8601String(),
      updatedAt: now.toIso8601String(),
    );
    state = state.copyWith(playlists: [playlist, ...state.playlists]);
    _invalidatePlaylistPickerSummaries();
    return id;
  }

  Future<void> renamePlaylist(String playlistId, String newName) async {
    await _ensureLoaded();
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return;
    final playlist = state.playlistById(playlistId);
    if (playlist == null || playlist.name == trimmed) return;

    final now = DateTime.now();
    await _db.renamePlaylist(
      playlistId: playlistId,
      name: trimmed,
      updatedAt: now.toIso8601String(),
    );
    _replacePlaylistById(playlistId, (playlist) {
      return playlist.copyWith(name: trimmed, updatedAt: now);
    });
    _invalidatePlaylistPickerSummaries();
  }

  Future<void> deletePlaylist(String playlistId) async {
    await _ensureLoaded();
    final playlistIndex = state.playlists.indexWhere((p) => p.id == playlistId);
    if (playlistIndex < 0) return;

    await _db.deletePlaylist(playlistId);
    final updatedPlaylists = [...state.playlists]..removeAt(playlistIndex);
    state = state.copyWith(playlists: updatedPlaylists);
    _invalidatePlaylistPickerSummaries();
  }

  Future<bool> addTrackToPlaylist(String playlistId, Track track) async {
    await _ensureLoaded();
    var playlist = state.playlistById(playlistId);
    if (playlist == null) return false;

    final key = trackCollectionKey(track);
    if (playlist.containsTrackKey(key)) return false;
    await ensurePlaylistLoaded(playlistId);
    playlist = state.playlistById(playlistId);
    if (playlist == null) return false;

    final now = DateTime.now();
    final entry = CollectionTrackEntry(key: key, track: track, addedAt: now);
    await _db.upsertPlaylistTrack(
      playlistId: playlistId,
      trackKey: key,
      trackJson: jsonEncode(track.toJson()),
      addedAt: entry.addedAt.toIso8601String(),
      playlistUpdatedAt: now.toIso8601String(),
    );
    final changed = _replacePlaylistById(playlistId, (playlist) {
      if (playlist.containsTrackKey(key)) return playlist;
      return playlist.copyWith(
        tracks: [...playlist.tracks, entry],
        updatedAt: now,
      );
    });
    if (!changed) return false;
    _invalidatePlaylistPickerSummaries();
    return true;
  }

  Future<PlaylistAddBatchResult> addTracksToPlaylist(
    String playlistId,
    Iterable<Track> tracks,
  ) async {
    await _ensureLoaded();
    await ensurePlaylistLoaded(playlistId);
    final playlist = state.playlistById(playlistId);
    if (playlist == null) {
      return const PlaylistAddBatchResult(
        addedCount: 0,
        alreadyInPlaylistCount: 0,
      );
    }

    final now = DateTime.now();
    final knownKeys = <String>{...playlist._trackKeys};
    final entriesToAdd = <CollectionTrackEntry>[];
    var alreadyInPlaylistCount = 0;

    for (final track in tracks) {
      final key = trackCollectionKey(track);
      if (!knownKeys.add(key)) {
        alreadyInPlaylistCount++;
        continue;
      }

      entriesToAdd.add(
        CollectionTrackEntry(key: key, track: track, addedAt: now),
      );
    }

    if (entriesToAdd.isEmpty) {
      return PlaylistAddBatchResult(
        addedCount: 0,
        alreadyInPlaylistCount: alreadyInPlaylistCount,
      );
    }

    await _db.upsertPlaylistTracksBatch(
      playlistId: playlistId,
      playlistUpdatedAt: now.toIso8601String(),
      tracks: entriesToAdd
          .map(
            (entry) => <String, String>{
              'track_key': entry.key,
              'track_json': jsonEncode(entry.track.toJson()),
              'added_at': entry.addedAt.toIso8601String(),
            },
          )
          .toList(growable: false),
    );
    final changed = _replacePlaylistById(playlistId, (current) {
      return current.copyWith(
        // Append in playlist order, matching the ASC snapshot ordering.
        tracks: [...current.tracks, ...entriesToAdd],
        updatedAt: now,
      );
    });
    if (!changed) {
      return PlaylistAddBatchResult(
        addedCount: 0,
        alreadyInPlaylistCount: alreadyInPlaylistCount,
      );
    }
    _invalidatePlaylistPickerSummaries();
    return PlaylistAddBatchResult(
      addedCount: entriesToAdd.length,
      alreadyInPlaylistCount: alreadyInPlaylistCount,
    );
  }

  Future<void> removeTrackFromPlaylist(
    String playlistId,
    String trackKey,
  ) async {
    await _ensureLoaded();
    var playlist = state.playlistById(playlistId);
    if (playlist == null || !playlist.containsTrackKey(trackKey)) return;
    await ensurePlaylistLoaded(playlistId);
    playlist = state.playlistById(playlistId);
    if (playlist == null) return;

    final now = DateTime.now();
    await _db.deletePlaylistTrack(
      playlistId: playlistId,
      trackKey: trackKey,
      playlistUpdatedAt: now.toIso8601String(),
    );
    _replacePlaylistById(playlistId, (playlist) {
      final nextTracks = playlist.tracks
          .where((entry) => entry.key != trackKey)
          .toList(growable: false);
      if (nextTracks.length == playlist.tracks.length) return playlist;
      return playlist.copyWith(tracks: nextTracks, updatedAt: now);
    });
    _invalidatePlaylistPickerSummaries();
  }

  Future<Directory> _playlistCoversDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'playlist_covers'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<void> setPlaylistCover(
    String playlistId,
    String sourceFilePath,
  ) async {
    await _ensureLoaded();
    final playlist = state.playlistById(playlistId);
    if (playlist == null) return;

    final previousCoverPath = playlist.coverImagePath;
    final destPath = await _normalizePlaylistCoverFile(
      playlistId,
      sourceFilePath,
    );

    final now = DateTime.now();
    await _db.updatePlaylistCover(
      playlistId: playlistId,
      coverImagePath: destPath,
      updatedAt: now.toIso8601String(),
    );
    _replacePlaylistById(playlistId, (playlist) {
      if (playlist.coverImagePath == destPath) return playlist;
      return playlist.copyWith(coverImagePath: () => destPath, updatedAt: now);
    });
    _invalidatePlaylistPickerSummaries();
    if (previousCoverPath != null && previousCoverPath != destPath) {
      try {
        final previous = File(previousCoverPath);
        if (await previous.exists()) await previous.delete();
      } catch (e) {
        _log.d('best-effort step failed: $e');
      }
    }
  }

  Future<String> _normalizePlaylistCoverFile(
    String playlistId,
    String sourceFilePath,
  ) async {
    final coversDir = await _playlistCoversDir();
    final destPath = p.join(coversDir.path, '$playlistId.jpg');
    final tempPath = p.join(
      coversDir.path,
      '.$playlistId.${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    try {
      final dimensions = await FFmpegService.probeImageDimensions(
        sourceFilePath,
      );
      final longestEdge = dimensions == null
          ? _playlistCoverMaxDimension
          : (dimensions.width > dimensions.height
                ? dimensions.width
                : dimensions.height);
      var targetDimension = longestEdge
          .clamp(64, _playlistCoverMaxDimension)
          .toInt();
      while (true) {
        final resized = await FFmpegService.resizeCoverArt(
          inputPath: sourceFilePath,
          outputPath: tempPath,
          maxDimension: targetDimension,
        );
        if (!resized) {
          throw StateError('Unable to normalize playlist cover');
        }
        if (await File(tempPath).length() <= _playlistCoverMaxStoredBytes) {
          break;
        }
        if (targetDimension <= 64) {
          throw StateError('Normalized playlist cover exceeds the size limit');
        }
        targetDimension = (targetDimension * 3 ~/ 4)
            .clamp(64, targetDimension)
            .toInt();
      }
      final destination = File(destPath);
      if (await destination.exists()) await destination.delete();
      await File(tempPath).rename(destPath);
      return destPath;
    } finally {
      try {
        final temp = File(tempPath);
        if (await temp.exists()) await temp.delete();
      } catch (e) {
        _log.d('best-effort step failed: $e');
      }
    }
  }

  Future<bool> _playlistCoverNeedsNormalization(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    if (p.extension(path).toLowerCase() != '.jpg' ||
        await file.length() > _playlistCoverMaxStoredBytes) {
      return true;
    }
    final dimensions = await FFmpegService.probeImageDimensions(path);
    return dimensions == null ||
        dimensions.width > _playlistCoverMaxDimension ||
        dimensions.height > _playlistCoverMaxDimension;
  }

  Future<void> removePlaylistCover(String playlistId) async {
    await _ensureLoaded();
    final playlist = state.playlistById(playlistId);
    if (playlist == null || playlist.coverImagePath == null) return;

    final path = playlist.coverImagePath;
    if (path != null) {
      final file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    }

    final now = DateTime.now();
    await _db.updatePlaylistCover(
      playlistId: playlistId,
      coverImagePath: null,
      updatedAt: now.toIso8601String(),
    );
    _replacePlaylistById(playlistId, (playlist) {
      if (playlist.coverImagePath == null) return playlist;
      return playlist.copyWith(coverImagePath: () => null, updatedAt: now);
    });
    _invalidatePlaylistPickerSummaries();
  }

  /// Returns the full collections snapshot (wishlist, loved, playlists,
  /// favorite artists) for a backup, ensuring data is loaded first.
  Future<Map<String, dynamic>> exportCollections() async {
    await _ensureLoaded();
    await ensurePlaylistsLoaded(state.playlists.map((playlist) => playlist.id));
    return state.toJson();
  }

  /// Exports custom playlist cover images as base64, keyed by playlist id.
  /// Each value contains the original file extension and the encoded bytes so a
  /// restore on another device can recreate the cover files.
  Future<Map<String, Map<String, String>>> exportPlaylistCovers() async {
    await _ensureLoaded();
    final covers = <String, Map<String, String>>{};
    final playlists = List<UserPlaylistCollection>.of(state.playlists);
    for (final playlist in playlists) {
      var path = playlist.coverImagePath;
      if (path == null || path.isEmpty) continue;
      try {
        if (await _playlistCoverNeedsNormalization(path)) {
          await setPlaylistCover(playlist.id, path);
          path = state.playlistById(playlist.id)?.coverImagePath ?? path;
        }
        final file = File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        covers[playlist.id] = {
          'ext': p.extension(path).toLowerCase(),
          'data': base64Encode(bytes),
        };
      } catch (_) {
        // Skip unreadable cover; the rest of the backup still succeeds.
      }
    }
    return covers;
  }

  /// Replaces all collections (wishlist, loved, playlists, favorite artists)
  /// with the contents of a backup. [collectionsJson] uses the
  /// [LibraryCollectionsState.toJson] shape; [coverImages] is the map produced
  /// by [exportPlaylistCovers]. Cover images are rewritten into this device's
  /// covers directory and their paths fixed up before persisting.
  Future<void> restoreFromBackup(
    Map<String, dynamic> collectionsJson, {
    Map<String, dynamic>? coverImages,
  }) async {
    final normalized = Map<String, dynamic>.from(collectionsJson);
    final coversDir = await _playlistCoversDir();

    final playlistsRaw = normalized['playlists'];
    if (playlistsRaw is List) {
      final rewritten = <Map<String, dynamic>>[];
      for (final entry in playlistsRaw.whereType<Map<Object?, Object?>>()) {
        final playlist = Map<String, dynamic>.from(entry);
        final id = playlist['id'] as String?;
        String? newCoverPath;
        final coverEntry = (id != null && coverImages != null)
            ? coverImages[id]
            : null;
        if (id != null && coverEntry is Map) {
          final data = coverEntry['data'] as String?;
          final ext = (coverEntry['ext'] as String?) ?? '.jpg';
          if (data != null && data.isNotEmpty) {
            try {
              final sourcePath = p.join(
                coversDir.path,
                '.$id.restore${ext.startsWith('.') ? ext : '.$ext'}',
              );
              final source = File(sourcePath);
              await source.writeAsBytes(base64Decode(data), flush: true);
              try {
                newCoverPath = await _normalizePlaylistCoverFile(
                  id,
                  sourcePath,
                );
              } finally {
                try {
                  if (await source.exists()) await source.delete();
                } catch (e) {
                  _log.d('best-effort step failed: $e');
                }
              }
            } catch (_) {
              newCoverPath = null;
            }
          }
        }
        // Always replace the backup's device-specific path: either with the
        // freshly written local cover, or drop it so a stale path is not kept.
        if (newCoverPath != null) {
          playlist['coverImagePath'] = newCoverPath;
        } else {
          playlist.remove('coverImagePath');
        }
        rewritten.add(playlist);
      }
      normalized['playlists'] = rewritten;
    }

    await _db.replaceAllFromBackup(normalized);
    await _load();
    _invalidatePlaylistPickerSummaries();
  }
}

final libraryCollectionsProvider =
    NotifierProvider<LibraryCollectionsNotifier, LibraryCollectionsState>(
      LibraryCollectionsNotifier.new,
    );

final libraryPlaylistPickerSummariesProvider = FutureProvider.autoDispose
    .family<List<PlaylistPickerSummary>, PlaylistPickerSummaryRequest>((
      ref,
      request,
    ) async {
      final db = LibraryCollectionsDatabase.instance;
      await db.migrateFromSharedPreferences();
      final rows = await db.loadPlaylistPickerSummaries(request.trackKeys);
      return rows
          .map(
            (row) => PlaylistPickerSummary(
              id: row.id,
              name: row.name,
              coverImagePath: row.coverImagePath,
              previewCover: row.previewCover,
              createdAt: row.createdAt,
              updatedAt: row.updatedAt,
              trackCount: row.trackCount,
              containsAllRequestedTracks: row.containsAllRequestedTracks,
            ),
          )
          .toList(growable: false);
    });
