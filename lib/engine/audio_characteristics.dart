import 'package:spotiflac_android/models/track.dart';
import 'package:spotiflac_android/utils/string_utils.dart';

/// Audio quality ladder shared by the streaming and download engines.
///
/// The ladder intentionally mirrors the app's existing download quality
/// vocabulary ("Original", "FLAC", ...) but adds the intermediate streaming
/// steps so the adaptive engine can step down gracefully on a poor network
/// instead of failing.
enum AudioQualityLevel {
  auto('Auto', 0, -1),
  low('Low', 1, 128),
  normal('Normal', 2, 192),
  high('High', 3, 320),
  lossless('Lossless', 4, 1411),
  hires('Hi-Res', 5, 4608);

  const AudioQualityLevel(this.label, this.rank, this.referenceBitrateKbps);

  final String label;
  final int rank;
  final int referenceBitrateKbps;

  /// Whether this level *requires* a lossless stream.
  bool get requiresLossless => this == AudioQualityLevel.lossless ||
      this == AudioQualityLevel.hires;

  bool get isLossless => this == AudioQualityLevel.lossless ||
      this == AudioQualityLevel.hires;

  /// Highest level of `values` (falls back to [auto]).
  static AudioQualityLevel maxOf(Iterable<AudioQualityLevel> values) {
    var best = AudioQualityLevel.auto;
    for (final value in values) {
      if (value.rank > best.rank) best = value;
    }
    return best;
  }

  /// Lowest level of `values` (falls back to [auto]).
  static AudioQualityLevel minOf(Iterable<AudioQualityLevel> values) {
    var best = AudioQualityLevel.hires;
    for (final value in values) {
      if (value.rank < best.rank) best = value;
    }
    return best;
  }

  static AudioQualityLevel fromLabel(Object? label) {
    final text = label?.toString().trim().toLowerCase() ?? '';
    for (final level in AudioQualityLevel.values) {
      if (level.name == text || level.label.toLowerCase() == text) {
        return level;
      }
    }
    switch (text) {
      case 'original':
      case 'flac':
      case 'alac':
        return AudioQualityLevel.lossless;
      case 'hires':
      case 'hi-res':
      case 'hd':
        return AudioQualityLevel.hires;
      default:
        return AudioQualityLevel.auto;
    }
  }
}

/// Network conditions that drive the adaptive quality policies.
enum NetworkProfile {
  wifi('Wi-Fi'),
  mobile('Mobile'),
  roaming('Roaming'),
  poor('Poor network'),
  offline('Offline');

  const NetworkProfile(this.label);

  final String label;

  /// Maps connectivity_plus / platform connectivity strings to a profile.
  /// Unknown values become [mobile] (the conservative default for a phone).
  static NetworkProfile fromConnectivity(Object? connectivity) {
    switch (connectivity?.toString().toLowerCase()) {
      case 'wifi':
        return NetworkProfile.wifi;
      case 'mobile':
      case 'cellular':
      case '4g':
      case '5g':
      case 'lte':
        return NetworkProfile.mobile;
      case 'none':
      case 'off':
        return NetworkProfile.offline;
      default:
        return NetworkProfile.mobile;
    }
  }

  bool get isOffline => this == NetworkProfile.offline;
  bool get isWifi => this == NetworkProfile.wifi;
}

/// Technical characteristics of one source, whether it is a local FLAC, a
/// downloaded file, or a live stream.
///
/// This is the model behind the "FLAC · 24-bit · 96 kHz · Lossless" pills:
/// the UI never invents quality labels from a file extension; it reads the
/// measured characteristics and composes them.
class AudioCharacteristics {
  final String? codec;
  final int? bitrateKbps;
  final int? sampleRateHz;
  final int? bitDepth;
  final int? channels;
  final int? fileSizeBytes;
  final bool lossless;
  final String? sourceLabel;

  /// ReplayGain loudness metadata, when a provider/extension supplies it for a
  /// stream (local files are probed by the audio service instead). Gains are in
  /// dB; peaks are linear full-scale values.
  final double? trackGainDb;
  final double? albumGainDb;
  final double? trackPeak;
  final double? albumPeak;

  const AudioCharacteristics({
    this.codec,
    this.bitrateKbps,
    this.sampleRateHz,
    this.bitDepth,
    this.channels,
    this.fileSizeBytes,
    this.lossless = false,
    this.sourceLabel,
    this.trackGainDb,
    this.albumGainDb,
    this.trackPeak,
    this.albumPeak,
  });

  factory AudioCharacteristics.fromTrack(Track track) {
    final level = AudioQualityLevel.fromLabel(track.audioQuality);
    return AudioCharacteristics(
      codec: _codecFromQuality(track.audioQuality, track.audioModes),
      bitrateKbps: level.referenceBitrateKbps > 0 ? level.referenceBitrateKbps : null,
      lossless: level.isLossless,
      sourceLabel: track.source,
    );
  }

  static String? _codecFromQuality(String? quality, String? modes) {
    final qualityText = quality?.toLowerCase() ?? '';
    if (qualityText.contains('flac')) return 'FLAC';
    if (qualityText.contains('alac')) return 'ALAC';
    if (qualityText.contains('aac')) return 'AAC';
    if (qualityText.contains('mp3') || qualityText.contains('320')) return 'MP3';
    final modesText = modes?.toUpperCase() ?? '';
    if (modesText.contains('FLAC')) return 'FLAC';
    if (modesText.contains('LOSSLESS')) return 'Lossless';
    return null;
  }

  bool get isLossless => lossless;

  /// Compact single-line description used in list rows and the mini player.
  String get compactLabel {
    if (codec != null) {
      final codecText = codec!.toUpperCase();
      if (bitDepth != null && sampleRateHz != null && bitDepth! > 0) {
        return '$codecText $bitDepth-bit/${formatSampleRateKHz(sampleRateHz!)}';
      }
      if (bitrateKbps != null && bitrateKbps! > 0) return '$codecText ${bitrateKbps}kbps';
      if (lossless) return '$codecText Lossless';
      return codecText;
    }
    if (lossless) return 'Lossless';
    if (bitrateKbps != null && bitrateKbps! > 0) return '${bitrateKbps}kbps';
    return '';
  }

  /// Multi-line technical card text: "FLAC\n24-bit\n96 kHz\nStereo · Lossless".
  List<String> get detailLines {
    final lines = <String>[
      if (codec != null && codec!.trim().isNotEmpty) codec!.toUpperCase(),
      if (bitDepth != null && bitDepth! > 0) '$bitDepth-bit',
      if (sampleRateHz != null && sampleRateHz! > 0)
        formatSampleRateKHz(sampleRateHz!),
      if (bitrateKbps != null && bitrateKbps! > 0) '$bitrateKbps kbps',
      if (channels != null && channels! > 0) _channelsLabel(channels!),
      if (fileSizeBytes != null && fileSizeBytes! > 0)
        formatBytes(fileSizeBytes!),
      if (lossless) 'Lossless' else if (codec != null) 'Lossy',
      if (sourceLabel != null && sourceLabel!.trim().isNotEmpty)
        sourceLabel!.trim(),
    ];
    return lines;
  }

  static String _channelsLabel(int channels) => switch (channels) {
    1 => 'Mono',
    2 => 'Stereo',
    3 => '2.1',
    4 => 'Quad',
    6 => '5.1',
    8 => '7.1',
    _ => '$channels channels',
  };

  Map<String, dynamic> toJson() => {
    if (codec != null) 'codec': codec,
    if (bitrateKbps != null) 'bitrate_kbps': bitrateKbps,
    if (sampleRateHz != null) 'sample_rate_hz': sampleRateHz,
    if (bitDepth != null) 'bit_depth': bitDepth,
    if (channels != null) 'channels': channels,
    if (fileSizeBytes != null) 'file_size_bytes': fileSizeBytes,
    'lossless': lossless,
    if (sourceLabel != null) 'source': sourceLabel,
    if (trackGainDb != null) 'track_gain_db': trackGainDb,
    if (albumGainDb != null) 'album_gain_db': albumGainDb,
    if (trackPeak != null) 'track_peak': trackPeak,
    if (albumPeak != null) 'album_peak': albumPeak,
  };

  factory AudioCharacteristics.fromJson(Map<String, dynamic> json) =>
      AudioCharacteristics(
        codec: json['codec']?.toString(),
        bitrateKbps: _positiveInt(json['bitrate_kbps']),
        sampleRateHz: _positiveInt(json['sample_rate_hz']),
        bitDepth: _positiveInt(json['bit_depth']),
        channels: _positiveInt(json['channels']),
        fileSizeBytes: _positiveInt(json['file_size_bytes']),
        lossless: json['lossless'] == true,
        sourceLabel: json['source']?.toString(),
        trackGainDb: _finiteDouble(json['track_gain_db']),
        albumGainDb: _finiteDouble(json['album_gain_db']),
        trackPeak: _finiteDouble(json['track_peak']),
        albumPeak: _finiteDouble(json['album_peak']),
      );

  static int? _positiveInt(Object? value) {
    final parsed = value is num ? value.toInt() : int.tryParse('$value');
    return parsed != null && parsed > 0 ? parsed : null;
  }

  static double? _finiteDouble(Object? value) {
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }
}

/// Maps network conditions + user policy to the quality level actually used.
class QualityPolicy {
  final AudioQualityLevel wifiProfile;
  final AudioQualityLevel mobileProfile;
  final AudioQualityLevel poorProfile;
  final AudioQualityLevel roamingProfile;
  final bool autoProfile;

  const QualityPolicy({
    this.wifiProfile = AudioQualityLevel.lossless,
    this.mobileProfile = AudioQualityLevel.high,
    this.poorProfile = AudioQualityLevel.normal,
    this.roamingProfile = AudioQualityLevel.high,
    this.autoProfile = true,
  });

  AudioQualityLevel levelFor(NetworkProfile profile) {
    if (autoProfile) {
      switch (profile) {
        case NetworkProfile.wifi:
          return AudioQualityLevel.lossless;
        case NetworkProfile.mobile:
          return AudioQualityLevel.high;
        case NetworkProfile.roaming:
          return AudioQualityLevel.high;
        case NetworkProfile.poor:
          return AudioQualityLevel.normal;
        case NetworkProfile.offline:
          return AudioQualityLevel.auto;
      }
    }
    switch (profile) {
      case NetworkProfile.wifi:
        return wifiProfile;
      case NetworkProfile.mobile:
        return mobileProfile;
      case NetworkProfile.roaming:
        return roamingProfile;
      case NetworkProfile.poor:
        return poorProfile;
      case NetworkProfile.offline:
        return AudioQualityLevel.auto;
    }
  }

  /// Steps one level down from [current] (never below [low]).
  static AudioQualityLevel stepDown(AudioQualityLevel current) {
    if (current.rank <= AudioQualityLevel.low.rank) return current;
    return AudioQualityLevel.values[current.rank - 1];
  }

  /// Steps one level up from [current] (never above [hires]).
  static AudioQualityLevel stepUp(AudioQualityLevel current) {
    if (current.rank >= AudioQualityLevel.hires.rank) return current;
    return AudioQualityLevel.values[current.rank + 1];
  }
}

/// Buffer sizing for progressive playback.
class StreamBufferPolicy {
  final Duration targetSeconds;
  final Duration maxSeconds;
  final Duration preloadSeconds;

  const StreamBufferPolicy({
    this.targetSeconds = const Duration(seconds: 12),
    this.maxSeconds = const Duration(seconds: 60),
    this.preloadSeconds = const Duration(seconds: 20),
  });

  static const StreamBufferPolicy auto = StreamBufferPolicy();

  StreamBufferPolicy forProfile(NetworkProfile profile) {
    switch (profile) {
      case NetworkProfile.wifi:
        return const StreamBufferPolicy(
          targetSeconds: Duration(seconds: 20),
          maxSeconds: Duration(seconds: 90),
          preloadSeconds: Duration(seconds: 30),
        );
      case NetworkProfile.mobile:
        return const StreamBufferPolicy(
          targetSeconds: Duration(seconds: 12),
          maxSeconds: Duration(seconds: 60),
          preloadSeconds: Duration(seconds: 20),
        );
      case NetworkProfile.poor:
        return const StreamBufferPolicy(
          targetSeconds: Duration(seconds: 30),
          maxSeconds: Duration(seconds: 120),
          preloadSeconds: Duration(seconds: 45),
        );
      case NetworkProfile.roaming:
        return const StreamBufferPolicy(
          targetSeconds: Duration(seconds: 8),
          maxSeconds: Duration(seconds: 30),
          preloadSeconds: Duration(seconds: 12),
        );
      case NetworkProfile.offline:
        return const StreamBufferPolicy(
          targetSeconds: Duration.zero,
          maxSeconds: Duration.zero,
          preloadSeconds: Duration.zero,
        );
    }
  }
}
