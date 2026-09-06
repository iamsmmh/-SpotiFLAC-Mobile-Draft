import 'package:spotiflac_android/engine/audio_characteristics.dart';

/// Plans transitions between consecutive queue items for gapless playback.
///
/// True sample-accurate gapless needs a decoder that splices without silence;
/// on the built-in player that is possible only when two consecutive items
/// share the same transport (both local, or both progressive streams) and the
/// same codec/sample rate/bit depth/channel layout. This policy tells the
/// audio service whether it may skip tearing down the source between tracks,
/// and whether the engine should pre-buffer the next source head instead.
enum GaplessTransitionKind {
  /// Identical characteristics and a gapless-capable lossless codec: the
  /// player can splice the sources directly.
  seamless,

  /// The transition cannot be spliced (lossy codec or mismatched stream
  /// characteristics); pre-buffering the next head still minimizes the gap.
  prebuffer,

  /// Gapless handling is disabled.
  disabled,
}

class GaplessDecision {
  final GaplessTransitionKind kind;
  final String? reason;

  const GaplessDecision({required this.kind, this.reason});

  bool get canSkipSourceTeardown => kind == GaplessTransitionKind.seamless;

  bool get shouldPrebuffer =>
      kind == GaplessTransitionKind.seamless ||
      kind == GaplessTransitionKind.prebuffer;

  static const GaplessDecision disabled = GaplessDecision(
    kind: GaplessTransitionKind.disabled,
    reason: 'gapless playback disabled',
  );
}

class GaplessPolicy {
  const GaplessPolicy();

  /// Lossless formats whose decoders splice sample-accurately.
  static bool isGaplessCapableCodec(String? codec) {
    switch (codec?.toUpperCase()) {
      case 'FLAC':
      case 'ALAC':
      case 'WAV':
      case 'AIFF':
      case 'APE':
      case 'WV': // WavPack
        return true;
      default:
        return false;
    }
  }

  static String _codecFamily(String? codec) {
    switch (codec?.toUpperCase()) {
      case 'FLAC':
      case 'ALAC':
      case 'WAV':
      case 'AIFF':
      case 'APE':
      case 'WV':
        return 'lossless';
      case 'MP3':
      case 'AAC':
      case 'M4A':
      case 'OGG':
      case 'OPUS':
      case 'VORBIS':
        return 'lossy';
      default:
        return 'unknown';
    }
  }

  /// Whether two characteristics describe the same PCM stream parameters.
  static bool sameStreamParameters(
    AudioCharacteristics a,
    AudioCharacteristics b,
  ) {
    return a.sampleRateHz == b.sampleRateHz &&
        a.bitDepth == b.bitDepth &&
        a.channels == b.channels;
  }

  GaplessDecision decide({
    required bool enabled,
    required AudioCharacteristics current,
    required AudioCharacteristics next,
    required bool sameTransport,
  }) {
    if (!enabled) return GaplessDecision.disabled;
    if (!sameTransport) {
      return const GaplessDecision(
        kind: GaplessTransitionKind.prebuffer,
        reason: 'transport differs (local ↔ stream)',
      );
    }
    final currentFamily = _codecFamily(current.codec);
    final nextFamily = _codecFamily(next.codec);
    final sameFamily = currentFamily != 'unknown' && currentFamily == nextFamily;
    final parametersMatch = sameStreamParameters(current, next);

    if (sameFamily &&
        currentFamily == 'lossless' &&
        parametersMatch &&
        isGaplessCapableCodec(current.codec) &&
        isGaplessCapableCodec(next.codec)) {
      return const GaplessDecision(
        kind: GaplessTransitionKind.seamless,
        reason: 'lossless gapless splice',
      );
    }
    return GaplessDecision(
      kind: GaplessTransitionKind.prebuffer,
      reason: !sameFamily
          ? 'codec family differs'
          : !parametersMatch
          ? 'stream parameters differ'
          : 'codec is not gapless-capable',
    );
  }
}
