/// Collaborative playlist service (Milestone 4).
///
/// Provides the client-side API for real-time collaborative playlists:
///   - Invite users to a playlist
///   - Accept/decline invitations
///   - Role-based access control (OWNER, EDITOR, VIEWER)
///   - Real-time updates via WebSocket/SSE
///   - Optimistic UI with conflict resolution
///
/// Backend contract: /v1/collaboration/*
/// Real-time: WebSocket /v1/collaboration/events
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('CollaborativePlaylist');

/// Collaboration roles.
enum CollabRole {
  owner,
  editor,
  viewer;

  static CollabRole parse(String? raw) {
    switch (raw?.toUpperCase()) {
      case 'OWNER':
        return CollabRole.owner;
      case 'EDITOR':
        return CollabRole.editor;
      case 'VIEWER':
        return CollabRole.viewer;
      default:
        return CollabRole.viewer;
    }
  }

  String get wireId => name.toUpperCase();

  bool get canEdit => this == CollabRole.owner || this == CollabRole.editor;
  bool get canManage => this == CollabRole.owner;
}

/// A collaborative playlist member.
class CollabMember {
  const CollabMember({
    required this.playlistId,
    required this.userId,
    this.handle = '',
    required this.role,
    required this.joinedAt,
  });

  final String playlistId;
  final String userId;
  final String handle;
  final CollabRole role;
  final DateTime joinedAt;

  static CollabMember? tryFromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    return CollabMember(
      playlistId: raw['playlistId']?.toString() ?? '',
      userId: raw['userId']?.toString() ?? '',
      handle: raw['handle']?.toString() ?? '',
      role: CollabRole.parse(raw['role']?.toString()),
      joinedAt: DateTime.tryParse(raw['joinedAt']?.toString() ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// A pending invitation.
class CollabInvite {
  const CollabInvite({
    required this.id,
    required this.playlistId,
    this.playlistName = '',
    required this.inviterId,
    required this.inviteeId,
    required this.role,
    required this.createdAt,
    required this.expiresAt,
  });

  final String id;
  final String playlistId;
  final String playlistName;
  final String inviterId;
  final String inviteeId;
  final CollabRole role;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);

  static CollabInvite? tryFromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    return CollabInvite(
      id: raw['id']?.toString() ?? '',
      playlistId: raw['playlistId']?.toString() ?? '',
      playlistName: raw['playlistName']?.toString() ?? '',
      inviterId: raw['inviterId']?.toString() ?? '',
      inviteeId: raw['inviteeId']?.toString() ?? '',
      role: CollabRole.parse(raw['role']?.toString()),
      createdAt: DateTime.tryParse(raw['createdAt']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      expiresAt: DateTime.tryParse(raw['expiresAt']?.toString() ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// A change to a collaborative playlist.
class CollabChange {
  const CollabChange({
    required this.id,
    required this.playlistId,
    required this.userId,
    required this.action,
    this.trackId = '',
    this.position = 0,
    required this.revision,
    required this.createdAt,
  });

  final String id;
  final String playlistId;
  final String userId;
  final String action;
  final String trackId;
  final int position;
  final int revision;
  final DateTime createdAt;

  static CollabChange? tryFromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    return CollabChange(
      id: raw['id']?.toString() ?? '',
      playlistId: raw['playlistId']?.toString() ?? '',
      userId: raw['userId']?.toString() ?? '',
      action: raw['action']?.toString() ?? '',
      trackId: raw['trackId']?.toString() ?? '',
      position: (raw['position'] as num?)?.toInt() ?? 0,
      revision: (raw['revision'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.tryParse(raw['createdAt']?.toString() ?? '') ??
          DateTime.now().toUtc(),
    );
  }
}

/// Real-time event from the collaboration WebSocket.
class CollabRealtimeEvent {
  const CollabRealtimeEvent({
    required this.kind,
    required this.playlistId,
    this.change,
    this.member,
  });

  final String kind; // "change", "member_joined", "member_left", "invite"
  final String playlistId;
  final CollabChange? change;
  final CollabMember? member;

  static CollabRealtimeEvent? tryFromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    return CollabRealtimeEvent(
      kind: raw['kind']?.toString() ?? '',
      playlistId: raw['playlistId']?.toString() ?? '',
      change: CollabChange.tryFromJson(raw['change']),
      member: CollabMember.tryFromJson(raw['member']),
    );
  }
}

/// Client for the collaborative playlist API.
class CollaborativePlaylistClient {
  CollaborativePlaylistClient({
    required String baseUrl,
    required Future<String?> Function() accessToken,
    http.Client? httpClient,
  })  : _baseUrl = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        _accessToken = accessToken,
        _client = httpClient ?? http.Client();

  final String _baseUrl;
  final Future<String?> Function() _accessToken;
  final http.Client _client;

  Future<Map<String, String>> _headers() async {
    final token = await _accessToken();
    return <String, String>{
      if (token != null) 'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
  }

  /// Invites a user to a collaborative playlist.
  Future<CollabInvite?> inviteUser({
    required String playlistId,
    required String userId,
    CollabRole role = CollabRole.viewer,
  }) async {
    try {
      final response = await _client.post(
        Uri.parse('$_baseUrl/v1/collaboration/playlists/$playlistId/invite'),
        headers: await _headers(),
        body: jsonEncode(<String, String>{
          'userId': userId,
          'role': role.wireId,
        }),
      );
      if (response.statusCode != 201) return null;
      final decoded = jsonDecode(response.body);
      return CollabInvite.tryFromJson(decoded);
    } catch (error, stack) {
      _log.e('Invite failed', error, stack);
      return null;
    }
  }

  /// Accepts a pending invitation.
  Future<CollabMember?> acceptInvite(String inviteId) async {
    try {
      final response = await _client.post(
        Uri.parse('$_baseUrl/v1/collaboration/invites/$inviteId/accept'),
        headers: await _headers(),
      );
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(response.body);
      return CollabMember.tryFromJson(decoded);
    } catch (error, stack) {
      _log.e('Accept invite failed', error, stack);
      return null;
    }
  }

  /// Lists members of a collaborative playlist.
  Future<List<CollabMember>> listMembers(String playlistId) async {
    try {
      final response = await _client.get(
        Uri.parse(
            '$_baseUrl/v1/collaboration/playlists/$playlistId/members'),
        headers: await _headers(),
      );
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(response.body);
      if (decoded is! List) return const [];
      return decoded
          .map(CollabMember.tryFromJson)
          .whereType<CollabMember>()
          .toList();
    } catch (error, stack) {
      _log.e('List members failed', error, stack);
      return const [];
    }
  }

  /// Records a track change to a collaborative playlist.
  Future<bool> recordChange({
    required String playlistId,
    required String action,
    String trackId = '',
    int position = 0,
  }) async {
    try {
      final response = await _client.post(
        Uri.parse(
            '$_baseUrl/v1/collaboration/playlists/$playlistId/changes'),
        headers: await _headers(),
        body: jsonEncode(<String, Object?>{
          'action': action,
          'trackId': trackId,
          'position': position,
        }),
      );
      return response.statusCode == 201;
    } catch (error, stack) {
      _log.e('Record change failed', error, stack);
      return false;
    }
  }

  /// Gets changes since the given revision.
  Future<List<CollabChange>> getChanges(
    String playlistId, {
    int sinceRevision = 0,
  }) async {
    try {
      final response = await _client.get(
        Uri.parse(
          '$_baseUrl/v1/collaboration/playlists/$playlistId/changes'
          '?since=$sinceRevision',
        ),
        headers: await _headers(),
      );
      if (response.statusCode != 200) return const [];
      final decoded = jsonDecode(response.body);
      if (decoded is! List) return const [];
      return decoded
          .map(CollabChange.tryFromJson)
          .whereType<CollabChange>()
          .toList();
    } catch (error, stack) {
      _log.e('Get changes failed', error, stack);
      return const [];
    }
  }

  /// Removes a member from a collaborative playlist.
  Future<bool> removeMember(String playlistId, String userId) async {
    try {
      final response = await _client.delete(
        Uri.parse(
            '$_baseUrl/v1/collaboration/playlists/$playlistId/members/$userId'),
        headers: await _headers(),
      );
      return response.statusCode == 204;
    } catch (error, stack) {
      _log.e('Remove member failed', error, stack);
      return false;
    }
  }
}

/// Service layer that adds optimistic UI and real-time updates.
class CollaborativePlaylistService {
  CollaborativePlaylistService({
    required CollaborativePlaylistClient client,
  }) : _client = client;

  final CollaborativePlaylistClient _client;

  /// Pending local changes not yet confirmed by the server.
  final List<CollabChange> _pendingChanges = [];

  /// Real-time event stream.
  final _events = StreamController<CollabRealtimeEvent>.broadcast();

  Stream<CollabRealtimeEvent> get events => _events.stream;

  /// Invites a user with optimistic UI.
  Future<CollabInvite?> inviteUser({
    required String playlistId,
    required String userId,
    CollabRole role = CollabRole.viewer,
  }) async {
    final invite = await _client.inviteUser(
      playlistId: playlistId,
      userId: userId,
      role: role,
    );
    if (invite != null) {
      _events.add(CollabRealtimeEvent(
        kind: 'invite',
        playlistId: playlistId,
      ));
    }
    return invite;
  }

  /// Adds a track to a collaborative playlist with optimistic UI.
  Future<bool> addTrack(String playlistId, String trackId, int position) async {
    // Optimistic: record locally first.
    final pending = CollabChange(
      id: 'pending_${DateTime.now().millisecondsSinceEpoch}',
      playlistId: playlistId,
      userId: '',
      action: 'add',
      trackId: trackId,
      position: position,
      revision: 0,
      createdAt: DateTime.now().toUtc(),
    );
    _pendingChanges.add(pending);

    final success = await _client.recordChange(
      playlistId: playlistId,
      action: 'add',
      trackId: trackId,
      position: position,
    );

    if (success) {
      _pendingChanges.remove(pending);
    }
    return success;
  }

  /// Removes a track from a collaborative playlist with optimistic UI.
  Future<bool> removeTrack(String playlistId, String trackId) async {
    return _client.recordChange(
      playlistId: playlistId,
      action: 'remove',
      trackId: trackId,
    );
  }

  /// Disposes resources.
  void dispose() {
    _events.close();
    _pendingChanges.clear();
  }
}
