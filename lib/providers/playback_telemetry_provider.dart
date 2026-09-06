import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/smart_play.dart';
import 'package:spotiflac_android/engine/streaming_engine.dart';
import 'package:spotiflac_android/providers/music_player_provider.dart';
import 'package:spotiflac_android/providers/streaming_engine_provider.dart';
import 'package:spotiflac_android/services/music_player_service.dart';
import 'package:spotiflac_android/utils/string_utils.dart';

/// A single source of truth for the real-time playback/streaming metrics
/// overlay: Codec, Bitrate, Sample Rate, Bit Depth, File Path and Source
/// Driver, plus live stream-session telemetry (phase, attempt, throughput,
/// integrity).
///
/// The model is constructed by a pure [from] factory so the field mapping is
/// unit-testable without the engine/provider wiring.
class PlaybackTelemetry {
  final String? trackId;
  final String title;
  final String artist;

  final AudioCharacteristics characteristics;
  final SmartPlayMode mode;
  final String? providerId;
  final String? localPath;
  final String? streamUri;
  final bool offline;

  /// Live stream session state (phase/attempt/quality), when streaming.
  final StreamSessionState session;

  /// Smoothed effective throughput estimate (bytes/sec), when available.
  final int? bandwidthBytesPerSecond;

  final int integrityFailures;
  final int integritySuccesses;

  const PlaybackTelemetry({
    required this.title,
    required this.artist,
    required this.characteristics,
    required this.mode,
    required this.session,
    this.trackId,
    this.providerId,
    this.localPath,
    this.streamUri,
    this.offline = false,
    this.bandwidthBytesPerSecond,
    this.integrityFailures = 0,
    this.integritySuccesses = 0,
  });

  bool get isStreaming =>
      mode == SmartPlayMode.stream ||
      mode == SmartPlayMode.downloadAndPlay;

  /// Codec / container label, e.g. "FLAC".
  String get codecLabel =>
      characteristics.codec?.trim().isNotEmpty == true
      ? characteristics.codec!.trim().toUpperCase()
      : '—';

  /// Bitrate label, e.g. "1411 kbps".
  String get bitrateLabel {
    final kbps = characteristics.bitrateKbps;
    if (kbps != null && kbps > 0) return '$kbps kbps';
    return '—';
  }

  /// Sample-rate label, e.g. "96 kHz".
  String get sampleRateLabel {
    final hz = characteristics.sampleRateHz;
    if (hz != null && hz > 0) return formatSampleRateKHz(hz);
    return '—';
  }

  /// Bit-depth label, e.g. "24-bit".
  String get bitDepthLabel {
    final bits = characteristics.bitDepth;
    if (bits != null && bits > 0) return '$bits-bit';
    return '—';
  }

  /// Human-readable source driver: provider id for streams, "Local file" for
  /// offline copies, "Download" for Smart Play download-and-play.
  String get sourceDriverLabel => switch (mode) {
    SmartPlayMode.local => 'Local file',
    SmartPlayMode.stream => providerId?.trim().isNotEmpty == true
        ? providerId!.trim()
        : 'Stream',
    SmartPlayMode.download ||
    SmartPlayMode.downloadAndPlay => 'Download',
    SmartPlayMode.unavailable => 'Unavailable',
  };

  /// Where the audio bytes are coming from. A stream URI is abbreviated to its
  /// host to avoid dumping long signed URLs on screen.
  String get filePathLabel {
    if (localPath != null && localPath!.trim().isNotEmpty) {
      return localPath!.trim();
    }
    final uri = streamUri?.trim();
    if (uri != null && uri.isNotEmpty) return uri;
    return 'Streamed — not stored on device';
  }

  /// Compact one-line throughput estimate, e.g. "1.2 Mbps".
  String get bandwidthLabel => formatBandwidth(bandwidthBytesPerSecond);

  bool get hasLiveTelemetry =>
      isStreaming || bandwidthBytesPerSecond != null;

  /// Builds the model from the engine playback context, the audio_service
  /// media item and the engine diagnostics. Local playback enriches the
  /// engine's derived characteristics with measured values carried in the
  /// media-item extras (bit depth / sample rate / bitrate / format).
  static PlaybackTelemetry from({
    required EnginePlayContext? context,
    required MediaItem? item,
    required StreamingDiagnostics diagnostics,
  }) {
    final measured = playbackAudioMetadataFromMediaItem(item ?? _noItem);
    final ctxChars = context?.characteristics ?? const AudioCharacteristics();

    final characteristics = AudioCharacteristics(
      codec: ctxChars.codec ??
          _stringOf(measured['format'] ?? measured['audio_codec']),
      bitrateKbps: ctxChars.bitrateKbps ?? _positive(measured['bitrate']),
      sampleRateHz:
          ctxChars.sampleRateHz ?? _positive(measured['sample_rate']),
      bitDepth: ctxChars.bitDepth ?? _positive(measured['bit_depth']),
      channels: ctxChars.channels,
      lossless: ctxChars.lossless,
      sourceLabel: ctxChars.sourceLabel,
    );

    final streamUri = diagnostics.session.active?.uri;

    return PlaybackTelemetry(
      trackId: context?.trackId,
      title: item?.title ?? '',
      artist: item?.artist ?? '',
      characteristics: characteristics,
      mode: context?.mode ?? SmartPlayMode.unavailable,
      providerId: context?.providerId,
      localPath: context?.localPath,
      streamUri: streamUri,
      offline: context?.offline ?? false,
      session: diagnostics.session,
      bandwidthBytesPerSecond: diagnostics.effectiveBandwidthBytesPerSecond,
      integrityFailures: diagnostics.integrityFailures,
      integritySuccesses: diagnostics.integritySuccesses,
    );
  }

  static final MediaItem _noItem = MediaItem(id: '', title: '');

  static String? _stringOf(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  static int? _positive(Object? value) {
    final num = value is int ? value : int.tryParse(value?.toString() ?? '');
    if (num == null || num <= 0) return null;
    return num;
  }
}

/// Real-time telemetry for the currently-playing item.
final playbackTelemetryProvider = Provider<PlaybackTelemetry>((ref) {
  final context = ref.watch(enginePlayContextProvider);
  final item = ref.watch(currentMediaItemProvider).value;
  final diagnostics = ref.watch(engineDiagnosticsProvider);
  return PlaybackTelemetry.from(
    context: context,
    item: item,
    diagnostics: diagnostics,
  );
});
