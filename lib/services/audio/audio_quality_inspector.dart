/// Audio quality inspector + badges (Phase 13).
///
/// Composes [AudioCharacteristics] / [AudioQualityLevel] into a single
/// inspection the UI can render as pills. Does not replace the existing
/// [buildLibraryAudioQualityLabel] helpers.
library;

import 'package:spotiflac_android/engine/audio_characteristics.dart';

/// Badge the now-playing / library row can show.
enum AudioQualityBadge {
  hires,
  lossless,
  high,
  standard,
  preview,
  unknown,
}

/// Result of inspecting one source.
class AudioQualityReport {
  const AudioQualityReport({
    required this.level,
    required this.badge,
    required this.label,
    required this.characteristics,
    this.lossy = false,
  });

  final AudioQualityLevel level;
  final AudioQualityBadge badge;
  final String label;
  final AudioCharacteristics characteristics;
  final bool lossy;
}

/// Maps measured characteristics onto the quality ladder.
class AudioQualityInspector {
  const AudioQualityInspector();

  AudioQualityReport inspect(AudioCharacteristics characteristics) {
    final level = _levelFor(characteristics);
    final badge = _badgeFor(level, characteristics);
    final label = characteristics.compactLabel.isNotEmpty
        ? characteristics.compactLabel
        : level.label;
    return AudioQualityReport(
      level: level,
      badge: badge,
      label: label,
      characteristics: characteristics,
      lossy: !characteristics.isLossless,
    );
  }

  static AudioQualityLevel _levelFor(AudioCharacteristics c) {
    if (c.isLossless) {
      final depth = c.bitDepth ?? 0;
      final rate = c.sampleRateHz ?? 0;
      if (depth >= 24 || rate > 48000) return AudioQualityLevel.hires;
      return AudioQualityLevel.lossless;
    }
    final bitrate = c.bitrateKbps ?? 0;
    if (bitrate >= 320) return AudioQualityLevel.high;
    if (bitrate >= 192) return AudioQualityLevel.normal;
    if (bitrate > 0) return AudioQualityLevel.low;
    return AudioQualityLevel.auto;
  }

  static AudioQualityBadge _badgeFor(
    AudioQualityLevel level,
    AudioCharacteristics c,
  ) {
    switch (level) {
      case AudioQualityLevel.hires:
        return AudioQualityBadge.hires;
      case AudioQualityLevel.lossless:
        return AudioQualityBadge.lossless;
      case AudioQualityLevel.high:
        return AudioQualityBadge.high;
      case AudioQualityLevel.normal:
        return AudioQualityBadge.standard;
      case AudioQualityLevel.low:
        return AudioQualityBadge.preview;
      case AudioQualityLevel.auto:
        return c.codec == null
            ? AudioQualityBadge.unknown
            : AudioQualityBadge.standard;
    }
  }
}
