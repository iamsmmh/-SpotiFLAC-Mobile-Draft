/// Wire payloads + per-scope metadata for cloud synchronization
/// (Feature Group 2).
///
/// The orchestrator treats records as opaque; the *scope owners* own
/// encode/decode. This file is the shared codec registry so a scope is defined
/// exactly once and both sides (local store ↔ backend) agree on the shape.
library;

import 'package:spotiflac_android/core/sync/sync_entities.dart';

/// Human/UI metadata for a scope: what the toggle on the sync page says and
/// whether it is on by default.
class SyncScopeDescriptor {
  const SyncScopeDescriptor({
    required this.scope,
    required this.title,
    required this.description,
    this.enabledByDefault = true,
  });

  final SyncScope scope;
  final String title;
  final String description;
  final bool enabledByDefault;

  static SyncScopeDescriptor of(SyncScope scope) => descriptors[scope]!;

  /// Every scope in the order the sync page lists them.
  static const List<SyncScopeDescriptor> all = <SyncScopeDescriptor>[
    SyncScopeDescriptor(
      scope: SyncScope.favorites,
      title: 'Favorites',
      description: 'Loved tracks, favorite albums, artists and playlists',
    ),
    SyncScopeDescriptor(
      scope: SyncScope.playlists,
      title: 'Playlists',
      description: 'User playlists, their tracks and covers',
    ),
    SyncScopeDescriptor(
      scope: SyncScope.settings,
      title: 'Settings',
      description: 'App and engine preferences that are safe to mirror',
    ),
    SyncScopeDescriptor(
      scope: SyncScope.history,
      title: 'Listening history',
      description: 'Play counts, skips and completion per track',
    ),
    SyncScopeDescriptor(
      scope: SyncScope.queueState,
      title: 'Queue state',
      description: 'Current queue and playback position for hand-off',
    ),
    SyncScopeDescriptor(
      scope: SyncScope.downloadPreferences,
      title: 'Download preferences',
      description: 'Quality, format, folder layout and network rules',
    ),
    SyncScopeDescriptor(
      scope: SyncScope.podcasts,
      title: 'Podcasts',
      description: 'Subscriptions, episode progress and downloads',
    ),
    SyncScopeDescriptor(
      scope: SyncScope.social,
      title: 'Social',
      description: 'Public profile, follows and shared playlists (optional)',
      enabledByDefault: false,
    ),
  ];

  static final Map<SyncScope, SyncScopeDescriptor> descriptors =
      <SyncScope, SyncScopeDescriptor>{
        for (final descriptor in all) descriptor.scope: descriptor,
      };

  /// Scopes enabled on a fresh install.
  static Set<SyncScope> defaultEnabledScopes() => all
      .where((descriptor) => descriptor.enabledByDefault)
      .map((descriptor) => descriptor.scope)
      .toSet();
}

/// Encodes/decodes the payload of one scope.
abstract interface class SyncPayloadCodec<T> {
  SyncScope get scope;

  Map<String, Object?> encode(T value);

  T? decode(Map<String, Object?> payload);
}

/// Favorites record (`isrc:…` / `provider:albumId` keys).
class FavoriteSyncPayload {
  const FavoriteSyncPayload({
    required this.key,
    required this.kind,
    required this.title,
    this.subtitle = '',
    this.coverUrl,
    this.addedAt,
  });

  final String key;
  final String kind; // track | album | artist | playlist
  final String title;
  final String subtitle;
  final String? coverUrl;
  final DateTime? addedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'kind': kind,
    'title': title,
    'subtitle': subtitle,
    if (coverUrl != null) 'coverUrl': coverUrl,
    if (addedAt != null) 'addedAt': addedAt!.toUtc().toIso8601String(),
  };

  static FavoriteSyncPayload? tryParse(Map<String, Object?> json) {
    final key = json['key']?.toString();
    if (key == null || key.isEmpty) return null;
    DateTime? addedAt;
    final raw = json['addedAt']?.toString();
    if (raw != null) addedAt = DateTime.tryParse(raw);
    return FavoriteSyncPayload(
      key: key,
      kind: json['kind']?.toString() ?? 'track',
      title: json['title']?.toString() ?? '',
      subtitle: json['subtitle']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString(),
      addedAt: addedAt,
    );
  }
}

/// Per-track listening aggregate (history scope).
class HistorySyncPayload {
  const HistorySyncPayload({
    required this.trackKey,
    required this.title,
    this.artist = '',
    this.album = '',
    this.playCount = 0,
    this.skipCount = 0,
    this.totalPlayedMs = 0,
    this.averageCompletion = 0,
    this.lastPlayedAt,
  });

  final String trackKey;
  final String title;
  final String artist;
  final String album;
  final int playCount;
  final int skipCount;
  final int totalPlayedMs;
  final double averageCompletion;
  final DateTime? lastPlayedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'trackKey': trackKey,
    'title': title,
    'artist': artist,
    'album': album,
    'playCount': playCount,
    'skipCount': skipCount,
    'totalPlayedMs': totalPlayedMs,
    'averageCompletion': averageCompletion,
    if (lastPlayedAt != null)
      'lastPlayedAt': lastPlayedAt!.toUtc().toIso8601String(),
  };

  static HistorySyncPayload? tryParse(Map<String, Object?> json) {
    final trackKey = json['trackKey']?.toString();
    if (trackKey == null || trackKey.isEmpty) return null;
    int asInt(Object? value) => value is num ? value.toInt() : 0;
    double asDouble(Object? value) => value is num ? value.toDouble() : 0;
    final raw = json['lastPlayedAt']?.toString();
    return HistorySyncPayload(
      trackKey: trackKey,
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      album: json['album']?.toString() ?? '',
      playCount: asInt(json['playCount']),
      skipCount: asInt(json['skipCount']),
      totalPlayedMs: asInt(json['totalPlayedMs']),
      averageCompletion: asDouble(json['averageCompletion']),
      lastPlayedAt: raw == null ? null : DateTime.tryParse(raw),
    );
  }
}

/// Queue snapshot for cross-device hand-off.
class QueueStateSyncPayload {
  const QueueStateSyncPayload({
    required this.deviceId,
    required this.trackKeys,
    this.currentIndex = 0,
    this.positionMs = 0,
    this.repeatMode = 'off',
    this.shuffle = false,
    this.savedAt,
  });

  final String deviceId;
  final List<String> trackKeys;
  final int currentIndex;
  final int positionMs;
  final String repeatMode;
  final bool shuffle;
  final DateTime? savedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'deviceId': deviceId,
    'trackKeys': trackKeys,
    'currentIndex': currentIndex,
    'positionMs': positionMs,
    'repeatMode': repeatMode,
    'shuffle': shuffle,
    if (savedAt != null) 'savedAt': savedAt!.toUtc().toIso8601String(),
  };

  static QueueStateSyncPayload? tryParse(Map<String, Object?> json) {
    final deviceId = json['deviceId']?.toString();
    final rawKeys = json['trackKeys'];
    if (deviceId == null || rawKeys is! List) return null;
    final raw = json['savedAt']?.toString();
    return QueueStateSyncPayload(
      deviceId: deviceId,
      trackKeys: rawKeys.map((key) => key.toString()).toList(growable: false),
      currentIndex: json['currentIndex'] is num
          ? (json['currentIndex']! as num).toInt()
          : 0,
      positionMs: json['positionMs'] is num
          ? (json['positionMs']! as num).toInt()
          : 0,
      repeatMode: json['repeatMode']?.toString() ?? 'off',
      shuffle: json['shuffle'] == true,
      savedAt: raw == null ? null : DateTime.tryParse(raw),
    );
  }
}

/// Podcast subscription + progress (podcasts scope).
class PodcastSyncPayload {
  const PodcastSyncPayload({
    required this.feedUrl,
    required this.title,
    this.author = '',
    this.imageUrl,
    this.autoDownload = false,
    this.keepEpisodes = 3,
    this.episodeProgress = const <String, int>{},
  });

  final String feedUrl;
  final String title;
  final String author;
  final String? imageUrl;
  final bool autoDownload;
  final int keepEpisodes;

  /// episode guid → played seconds.
  final Map<String, int> episodeProgress;

  Map<String, Object?> toJson() => <String, Object?>{
    'feedUrl': feedUrl,
    'title': title,
    'author': author,
    if (imageUrl != null) 'imageUrl': imageUrl,
    'autoDownload': autoDownload,
    'keepEpisodes': keepEpisodes,
    'episodeProgress': episodeProgress,
  };

  static PodcastSyncPayload? tryParse(Map<String, Object?> json) {
    final feedUrl = json['feedUrl']?.toString();
    if (feedUrl == null || feedUrl.isEmpty) return null;
    final rawProgress = json['episodeProgress'];
    final progress = <String, int>{};
    if (rawProgress is Map) {
      for (final entry in rawProgress.entries) {
        final value = entry.value;
        if (value is num) progress[entry.key.toString()] = value.toInt();
      }
    }
    return PodcastSyncPayload(
      feedUrl: feedUrl,
      title: json['title']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      imageUrl: json['imageUrl']?.toString(),
      autoDownload: json['autoDownload'] == true,
      keepEpisodes: json['keepEpisodes'] is num
          ? (json['keepEpisodes']! as num).toInt()
          : 3,
      episodeProgress: progress,
    );
  }
}

/// Shared playlist published to the optional social layer.
class SharedPlaylistSyncPayload {
  const SharedPlaylistSyncPayload({
    required this.playlistId,
    required this.title,
    required this.trackKeys,
    this.description = '',
    this.coverUrl,
    this.isPublic = false,
    this.publishedAt,
  });

  final String playlistId;
  final String title;
  final List<String> trackKeys;
  final String description;
  final String? coverUrl;
  final bool isPublic;
  final DateTime? publishedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'playlistId': playlistId,
    'title': title,
    'trackKeys': trackKeys,
    'description': description,
    if (coverUrl != null) 'coverUrl': coverUrl,
    'isPublic': isPublic,
    if (publishedAt != null)
      'publishedAt': publishedAt!.toUtc().toIso8601String(),
  };

  static SharedPlaylistSyncPayload? tryParse(Map<String, Object?> json) {
    final playlistId = json['playlistId']?.toString();
    final rawKeys = json['trackKeys'];
    if (playlistId == null || playlistId.isEmpty || rawKeys is! List) {
      return null;
    }
    final raw = json['publishedAt']?.toString();
    return SharedPlaylistSyncPayload(
      playlistId: playlistId,
      title: json['title']?.toString() ?? '',
      trackKeys: rawKeys.map((key) => key.toString()).toList(growable: false),
      description: json['description']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString(),
      isPublic: json['isPublic'] == true,
      publishedAt: raw == null ? null : DateTime.tryParse(raw),
    );
  }
}
