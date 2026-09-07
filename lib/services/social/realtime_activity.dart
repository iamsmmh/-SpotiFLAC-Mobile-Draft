/// Friend-activity / collaborative-playlist events (Phase 11).
///
/// Transport is the existing Supabase realtime channel when a backend is
/// configured; this file is the local event shape + a privacy filter so a
/// private session never emits.
library;

import 'package:spotiflac_android/ecosystem/social/social_models.dart';
import 'package:spotiflac_android/services/social/privacy_policy.dart';

/// One friend-activity pulse.
class FriendActivityEvent {
  const FriendActivityEvent({
    required this.userId,
    required this.handle,
    required this.trackTitle,
    this.artist = '',
    required this.at,
  });

  final String userId;
  final String handle;
  final String trackTitle;
  final String artist;
  final DateTime at;

  Map<String, Object?> toJson() => <String, Object?>{
        'userId': userId,
        'handle': handle,
        'trackTitle': trackTitle,
        'artist': artist,
        'at': at.toUtc().toIso8601String(),
      };
}

/// Filters outbound events through [SocialPrivacyPolicy].
class FriendActivityPublisher {
  const FriendActivityPublisher({required this.privacy});

  final SocialPrivacyPolicy privacy;

  FriendActivityEvent? publish(FriendActivityEvent event) {
    final decision = privacy.evaluate();
    if (!decision.publishActivity) return null;
    return event;
  }
}

/// Applies a collaborative playlist edit only when the share is collaborative
/// and privacy allows it.
class CollaborativePlaylistGate {
  const CollaborativePlaylistGate({required this.privacy});

  final SocialPrivacyPolicy privacy;

  bool allows(SharedPlaylist playlist) {
    if (!playlist.isCollaborative) return false;
    return privacy.evaluate().allowCollaborate;
  }
}
