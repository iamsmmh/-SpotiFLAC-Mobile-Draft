import 'package:spotiflac_android/engine/audio_characteristics.dart';

/// Adaptive buffering: turns network conditions + policy into concrete
/// progressive-playback buffer decisions.
///
/// The engine preflights a stream before playing it and pre-buffers the next
/// track while the current one plays. This planner decides *how much* to pull
/// ahead: low-bandwidth environments get a deeper lookahead (a longer buffer
/// window) and every profile is capped so a single track never saturates the
/// device's memory or the user's data plan.
class AdaptiveBufferDecision {
  /// Bytes of the next source to pull ahead (0 = no head pre-buffer).
  final int headBytes;

  /// How far ahead the lookahead window reaches (used by the preloader).
  final Duration lookahead;

  /// Whether the next track should be prepared while the current one plays.
  final bool prebufferNextTrack;

  final String? reason;

  const AdaptiveBufferDecision({
    required this.headBytes,
    required this.lookahead,
    required this.prebufferNextTrack,
    this.reason,
  });

  static const AdaptiveBufferDecision none = AdaptiveBufferDecision(
    headBytes: 0,
    lookahead: Duration.zero,
    prebufferNextTrack: false,
    reason: 'offline',
  );
}

class AdaptiveBufferPlanner {
  const AdaptiveBufferPlanner();

  static const int _minimumHeadBytes = 16 * 1024; // 16 KiB
  static const int _maximumHeadBytes = 4 * 1024 * 1024; // 4 MiB absolute cap

  /// Effective throughput to assume when there is no live sample, derived from
  /// the source bitrate (bytes/second).
  static int bytesPerSecondForBitrate(int? bitrateKbps) {
    if (bitrateKbps == null || bitrateKbps <= 0) return 0;
    return (bitrateKbps * 1000) ~/ 8;
  }

  AdaptiveBufferDecision plan({
    required NetworkProfile profile,
    required StreamBufferPolicy policy,
    int? bitrateKbps,
    int? measuredBytesPerSecond,
    bool preloadEnabled = true,
    int lowBandwidthBufferSeconds = 30,
    int prebufferHeadBytes = 512 * 1024,
  }) {
    if (profile.isOffline) return AdaptiveBufferDecision.none;

    final measured = measuredBytesPerSecond;
    final estimated = bytesPerSecondForBitrate(bitrateKbps);
    final throughput = (measured != null && measured > 0) ? measured : estimated;

    // Low-bandwidth environments buffer deeper (longer window) so a brief
    // stall never interrupts playback; healthy links buffer just enough to
    // absorb jitter.
    final isPoor =
        profile == NetworkProfile.poor ||
        (measured != null && measured < estimated && measured < 250000);
    final bufferSeconds = isPoor
        ? lowBandwidthBufferSeconds.clamp(1, 120)
        : policy.targetSeconds.inSeconds.clamp(1, 90);

    final cappedHead = prebufferHeadBytes.clamp(
      _minimumHeadBytes,
      _maximumHeadBytes,
    );
    final headBytes = throughput <= 0
        ? 0
        : (throughput * bufferSeconds).clamp(_minimumHeadBytes, cappedHead);

    return AdaptiveBufferDecision(
      headBytes: headBytes,
      lookahead: policy.preloadSeconds,
      prebufferNextTrack: preloadEnabled,
      reason: isPoor
          ? 'low-bandwidth: ${bufferSeconds}s lookahead'
          : 'standard: ${policy.targetSeconds.inSeconds}s buffer',
    );
  }
}
