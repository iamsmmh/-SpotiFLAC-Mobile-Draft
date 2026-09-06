/// iOS 17+ (and Android media-session) background playback durability.
///
/// The OS audio session, not a Dart timer, keeps lossless playback alive
/// after the UI is suspended. This policy encodes the decisions the audio
/// handler must make on interruption, route loss, and process resume so a
/// 2-hour background session neither dies nor auto-resumes against the
/// user's intent.
library;

enum AudioInterruptionKind { duck, pause, unknown }

enum BackgroundPlaybackAction {
  /// Transient duck — leave the player running, the mixer attenuates us.
  ignore,

  /// Pause now and remember that *we* paused so a matching end event can
  /// resume. Used for pause-type interruptions (Siri, another music app).
  pauseAndMarkResumable,

  /// Pause now and do **not** auto-resume. Used for unknown interruptions
  /// and for becoming-noisy (headphones unplugged) — auto-resume would
  /// blast audio over the speaker.
  pauseSticky,

  /// Focus returned after a pause-type interruption we marked resumable.
  resume,

  /// Focus returned but we did not pause for this interruption (user pause,
  /// sticky pause, or duck). Stay paused.
  stayPaused,
}

class BackgroundPlaybackDecision {
  const BackgroundPlaybackDecision(this.action, {this.reason});

  final BackgroundPlaybackAction action;
  final String? reason;
}

abstract final class BackgroundPlaybackPolicy {
  /// `UIBackgroundModes` value required in Info.plist for iOS 17+ durability.
  static const String iosBackgroundMode = 'audio';

  /// Android audio_service channel that must stay as a `mediaPlayback` FGS.
  static const String androidPlaybackChannelId = 'com.zarz.spotiflac.playback';

  /// How the handler should react when an interruption *begins*.
  static BackgroundPlaybackDecision onInterruptionBegan(
    AudioInterruptionKind kind,
  ) {
    return switch (kind) {
      AudioInterruptionKind.duck => const BackgroundPlaybackDecision(
        BackgroundPlaybackAction.ignore,
        reason: 'transient duck',
      ),
      AudioInterruptionKind.pause => const BackgroundPlaybackDecision(
        BackgroundPlaybackAction.pauseAndMarkResumable,
        reason: 'pause-type interruption',
      ),
      AudioInterruptionKind.unknown => const BackgroundPlaybackDecision(
        BackgroundPlaybackAction.pauseSticky,
        reason: 'unknown interruption',
      ),
    };
  }

  /// How the handler should react when an interruption *ends*.
  static BackgroundPlaybackDecision onInterruptionEnded({
    required AudioInterruptionKind kind,
    required bool pausedByInterruption,
    required bool userPaused,
  }) {
    if (kind == AudioInterruptionKind.duck) {
      return const BackgroundPlaybackDecision(
        BackgroundPlaybackAction.ignore,
        reason: 'duck ended',
      );
    }
    if (userPaused) {
      return const BackgroundPlaybackDecision(
        BackgroundPlaybackAction.stayPaused,
        reason: 'user paused',
      );
    }
    if (pausedByInterruption && kind == AudioInterruptionKind.pause) {
      return const BackgroundPlaybackDecision(
        BackgroundPlaybackAction.resume,
        reason: 'pause-type interruption ended',
      );
    }
    return const BackgroundPlaybackDecision(
      BackgroundPlaybackAction.stayPaused,
      reason: 'sticky pause',
    );
  }

  /// Headphones unplugged / output route lost. Never auto-resume.
  static const BackgroundPlaybackDecision becomingNoisy =
      BackgroundPlaybackDecision(
        BackgroundPlaybackAction.pauseSticky,
        reason: 'becoming noisy',
      );

  /// Cold start of a restored session: always paused. The user (or a
  /// media-button event) has to press play; iOS 17 will otherwise kill an
  /// app that starts audio from the background without an active session.
  static bool restoreSessionPaused() => true;
}
