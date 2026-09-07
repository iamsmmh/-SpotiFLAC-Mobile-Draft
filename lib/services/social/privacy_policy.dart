/// Social privacy policy (Phase 11).
///
/// Pure gate over [SocialFeatureFlags]. Private session and "hide listening"
/// always win over friend-activity / realtime, even when those flags are on.
library;

import 'package:spotiflac_android/ecosystem/social/social_models.dart';

/// What a remote peer is allowed to see about this device.
class SocialPrivacyDecision {
  const SocialPrivacyDecision({
    required this.publishActivity,
    required this.allowRealtime,
    required this.allowCollaborate,
    required this.reason,
  });

  final bool publishActivity;
  final bool allowRealtime;
  final bool allowCollaborate;
  final String reason;
}

/// Evaluates privacy flags. Default-deny when the master switch is off.
class SocialPrivacyPolicy {
  const SocialPrivacyPolicy({this.flags = SocialFeatureFlags.disabled});

  final SocialFeatureFlags flags;

  SocialPrivacyDecision evaluate() {
    if (!flags.enabled) {
      return const SocialPrivacyDecision(
        publishActivity: false,
        allowRealtime: false,
        allowCollaborate: false,
        reason: 'social disabled',
      );
    }
    if (flags.privateSession) {
      return const SocialPrivacyDecision(
        publishActivity: false,
        allowRealtime: false,
        allowCollaborate: false,
        reason: 'private session',
      );
    }
    return SocialPrivacyDecision(
      publishActivity: flags.canShowFriendActivity,
      allowRealtime: flags.canUseRealtime,
      allowCollaborate: flags.canCollaborate,
      reason: 'ok',
    );
  }
}
