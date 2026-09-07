/// Optional social layer — domain values (Feature Group 11).
///
/// The whole module is gated by [SocialFeatureFlags]: when disabled (the
/// default) no profile is created, no request is made and the UI hides every
/// entry point. Nothing else in the app may depend on this module.
library;

import 'dart:convert';

/// Master switches for the social layer.
///
/// Disabled by default: an offline-first downloader must never phone home
/// because a module happens to be compiled in.
class SocialFeatureFlags {
  const SocialFeatureFlags({
    this.enabled = false,
    this.publicProfile = false,
    this.playlistSharing = false,
    this.following = false,
    this.activityFeed = false,
    this.collaborativePlaylists = false,
    this.friendActivity = false,
    this.realtimeSync = false,
    this.hideListeningActivity = false,
    this.privateSession = false,
  });

  final bool enabled;
  final bool publicProfile;
  final bool playlistSharing;
  final bool following;
  final bool activityFeed;

  /// Extra social / privacy switches (Phase 11). Default off so existing
  /// installs stay private until the user opts in.
  final bool collaborativePlaylists;
  final bool friendActivity;
  final bool realtimeSync;
  final bool hideListeningActivity;
  final bool privateSession;

  /// Everything off — the shipping default.
  static const SocialFeatureFlags disabled = SocialFeatureFlags();

  /// A sub-feature is live only when the master switch is also on.
  bool get canPublishProfile => enabled && publicProfile;
  bool get canSharePlaylists => enabled && playlistSharing;
  bool get canFollow => enabled && following;
  bool get canShowFeed => enabled && activityFeed;
  bool get canCollaborate => enabled && collaborativePlaylists;
  bool get canShowFriendActivity =>
      enabled && friendActivity && !privateSession && !hideListeningActivity;
  bool get canUseRealtime => enabled && realtimeSync && !privateSession;

  SocialFeatureFlags copyWith({
    bool? enabled,
    bool? publicProfile,
    bool? playlistSharing,
    bool? following,
    bool? activityFeed,
    bool? collaborativePlaylists,
    bool? friendActivity,
    bool? realtimeSync,
    bool? hideListeningActivity,
    bool? privateSession,
  }) {
    return SocialFeatureFlags(
      enabled: enabled ?? this.enabled,
      publicProfile: publicProfile ?? this.publicProfile,
      playlistSharing: playlistSharing ?? this.playlistSharing,
      following: following ?? this.following,
      activityFeed: activityFeed ?? this.activityFeed,
      collaborativePlaylists:
          collaborativePlaylists ?? this.collaborativePlaylists,
      friendActivity: friendActivity ?? this.friendActivity,
      realtimeSync: realtimeSync ?? this.realtimeSync,
      hideListeningActivity:
          hideListeningActivity ?? this.hideListeningActivity,
      privateSession: privateSession ?? this.privateSession,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'publicProfile': publicProfile,
    'playlistSharing': playlistSharing,
    'following': following,
    'activityFeed': activityFeed,
    'collaborativePlaylists': collaborativePlaylists,
    'friendActivity': friendActivity,
    'realtimeSync': realtimeSync,
    'hideListeningActivity': hideListeningActivity,
    'privateSession': privateSession,
  };

  static SocialFeatureFlags fromJson(Map<String, Object?> json) {
    return SocialFeatureFlags(
      enabled: json['enabled'] == true,
      publicProfile: json['publicProfile'] == true,
      playlistSharing: json['playlistSharing'] == true,
      following: json['following'] == true,
      activityFeed: json['activityFeed'] == true,
      collaborativePlaylists: json['collaborativePlaylists'] == true,
      friendActivity: json['friendActivity'] == true,
      realtimeSync: json['realtimeSync'] == true,
      hideListeningActivity: json['hideListeningActivity'] == true,
      privateSession: json['privateSession'] == true,
    );
  }

  static SocialFeatureFlags? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return fromJson(Map<String, Object?>.from(decoded));
      }
    } on FormatException {
      // Fall through to null: a corrupt flag blob means "use defaults".
    }
    return null;
  }
}

/// A user profile as seen by others.
class SocialProfile {
  const SocialProfile({
    required this.userId,
    required this.handle,
    this.displayName = '',
    this.bio = '',
    this.avatarUrl,
    this.isPublic = false,
    this.followerCount = 0,
    this.followingCount = 0,
    this.playlistCount = 0,
  });

  final String userId;

  /// Unique, URL-safe handle.
  final String handle;

  final String displayName;
  final String bio;
  final String? avatarUrl;
  final bool isPublic;
  final int followerCount;
  final int followingCount;
  final int playlistCount;

  String get label => displayName.isEmpty ? '@$handle' : displayName;

  Map<String, Object?> toJson() => <String, Object?>{
    'userId': userId,
    'handle': handle,
    'displayName': displayName,
    'bio': bio,
    if (avatarUrl != null) 'avatarUrl': avatarUrl,
    'isPublic': isPublic,
    'followerCount': followerCount,
    'followingCount': followingCount,
    'playlistCount': playlistCount,
  };

  static SocialProfile? tryParse(Map<String, Object?> json) {
    final userId = json['userId']?.toString();
    final handle = json['handle']?.toString();
    if (userId == null || userId.isEmpty) return null;
    if (handle == null || handle.isEmpty) return null;
    return SocialProfile(
      userId: userId,
      handle: handle,
      displayName: json['displayName']?.toString() ?? '',
      bio: json['bio']?.toString() ?? '',
      avatarUrl: json['avatarUrl']?.toString(),
      isPublic: json['isPublic'] == true,
      followerCount: _int(json['followerCount']),
      followingCount: _int(json['followingCount']),
      playlistCount: _int(json['playlistCount']),
    );
  }
}

/// How a shared playlist may be used by its recipients.
enum PlaylistShareMode {
  /// Anyone with the link can view.
  view,

  /// Anyone with the link can add and remove tracks.
  collaborate;

  static PlaylistShareMode parse(Object? raw) {
    final value = raw?.toString();
    for (final mode in PlaylistShareMode.values) {
      if (mode.name == value) return mode;
    }
    return PlaylistShareMode.view;
  }
}

/// A playlist published to a share link.
class SharedPlaylist {
  const SharedPlaylist({
    required this.shareId,
    required this.playlistId,
    required this.ownerId,
    required this.title,
    this.description = '',
    this.coverUrl,
    this.trackCount = 0,
    this.mode = PlaylistShareMode.view,
    required this.sharedAt,
    this.collaborators = const <String>[],
  });

  final String shareId;
  final String playlistId;
  final String ownerId;
  final String title;
  final String description;
  final String? coverUrl;
  final int trackCount;
  final PlaylistShareMode mode;
  final DateTime sharedAt;

  /// User ids allowed to edit when [mode] is collaborative.
  final List<String> collaborators;

  bool get isCollaborative => mode == PlaylistShareMode.collaborate;

  /// Canonical deep link, reusing the app's existing `spotiflac://` scheme so
  /// links open in-app on both platforms with no new intent filters.
  Uri get link => Uri(
    scheme: 'spotiflac',
    host: 'playlist',
    pathSegments: <String>['shared', shareId],
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'shareId': shareId,
    'playlistId': playlistId,
    'ownerId': ownerId,
    'title': title,
    'description': description,
    if (coverUrl != null) 'coverUrl': coverUrl,
    'trackCount': trackCount,
    'mode': mode.name,
    'sharedAt': sharedAt.toUtc().toIso8601String(),
    'collaborators': collaborators,
  };

  static SharedPlaylist? tryParse(Map<String, Object?> json) {
    final shareId = json['shareId']?.toString();
    if (shareId == null || shareId.isEmpty) return null;
    final rawCollaborators = json['collaborators'];
    return SharedPlaylist(
      shareId: shareId,
      playlistId: json['playlistId']?.toString() ?? '',
      ownerId: json['ownerId']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString(),
      trackCount: _int(json['trackCount']),
      mode: PlaylistShareMode.parse(json['mode']),
      sharedAt:
          DateTime.tryParse(json['sharedAt']?.toString() ?? '')?.toUtc() ??
              DateTime.now().toUtc(),
      collaborators: rawCollaborators is List
          ? rawCollaborators
                .map((entry) => entry.toString())
                .where((entry) => entry.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
    );
  }

  /// Extracts a share id from a `spotiflac://playlist/shared/<id>` link
  /// (the legacy `spotimusic://` scheme is accepted too).
  static String? shareIdFromLink(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    if ((scheme != 'spotiflac' && scheme != 'spotimusic') ||
        uri.host != 'playlist') {
      return null;
    }
    final segments = uri.pathSegments;
    if (segments.length < 2 || segments[0] != 'shared') return null;
    final id = segments[1];
    return id.isEmpty ? null : id;
  }
}

/// Kinds of activity that can appear in a feed.
enum ActivityKind {
  playedTrack,
  likedTrack,
  sharedPlaylist,
  followedUser,
  addedToPlaylist;

  static ActivityKind parse(Object? raw) {
    final value = raw?.toString();
    for (final kind in ActivityKind.values) {
      if (kind.name == value) return kind;
    }
    return ActivityKind.playedTrack;
  }
}

/// One entry in the activity feed.
class ActivityEntry {
  const ActivityEntry({
    required this.entryId,
    required this.actorId,
    this.actorHandle = '',
    required this.kind,
    this.subject = '',
    this.subtitle = '',
    this.artworkUrl,
    this.targetId,
    required this.occurredAt,
  });

  final String entryId;
  final String actorId;
  final String actorHandle;
  final ActivityKind kind;

  /// What the activity is about (track title, playlist name, user handle).
  final String subject;

  final String subtitle;
  final String? artworkUrl;

  /// Id to open when the entry is tapped.
  final String? targetId;

  final DateTime occurredAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'entryId': entryId,
    'actorId': actorId,
    'actorHandle': actorHandle,
    'kind': kind.name,
    'subject': subject,
    'subtitle': subtitle,
    if (artworkUrl != null) 'artworkUrl': artworkUrl,
    if (targetId != null) 'targetId': targetId,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
  };

  static ActivityEntry? tryParse(Map<String, Object?> json) {
    final entryId = json['entryId']?.toString();
    if (entryId == null || entryId.isEmpty) return null;
    return ActivityEntry(
      entryId: entryId,
      actorId: json['actorId']?.toString() ?? '',
      actorHandle: json['actorHandle']?.toString() ?? '',
      kind: ActivityKind.parse(json['kind']),
      subject: json['subject']?.toString() ?? '',
      subtitle: json['subtitle']?.toString() ?? '',
      artworkUrl: json['artworkUrl']?.toString(),
      targetId: json['targetId']?.toString(),
      occurredAt:
          DateTime.tryParse(json['occurredAt']?.toString() ?? '')?.toUtc() ??
              DateTime.now().toUtc(),
    );
  }
}

int _int(Object? value) => value is num ? value.toInt() : 0;
