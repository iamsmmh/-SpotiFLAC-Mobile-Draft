import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotiflac_android/engine/audio_characteristics.dart';
import 'package:spotiflac_android/engine/smart_play.dart';
import 'package:spotiflac_android/engine/streaming_engine.dart';
import 'package:spotiflac_android/providers/playback_telemetry_provider.dart';
import 'package:spotiflac_android/providers/streaming_engine_provider.dart';

StreamingDiagnostics _emptyDiagnostics() => StreamingDiagnostics(
  health: ProviderHealthRegistry(),
  log: EngineEventLog(),
  session: StreamSessionState(),
  bandwidth: BandwidthMonitor(),
  integrity: StreamIntegrityLog(),
);

void main() {
  group('PlaybackTelemetry labels', () {
    test('renders measured local characteristics', () {
      final telemetry = PlaybackTelemetry.from(
        context: EnginePlayContext(
          trackId: 't1',
          mode: SmartPlayMode.local,
          quality: AudioQualityLevel.lossless,
          characteristics: const AudioCharacteristics(
            codec: 'FLAC',
            bitDepth: 24,
            sampleRateHz: 96000,
            bitrateKbps: 2500,
            lossless: true,
          ),
          localPath: '/music/song.flac',
        ),
        item: MediaItem(id: 't1', title: 'Song', artist: 'Artist'),
        diagnostics: _emptyDiagnostics(),
      );

      expect(telemetry.codecLabel, 'FLAC');
      expect(telemetry.bitDepthLabel, '24-bit');
      expect(telemetry.sampleRateLabel, '96kHz');
      expect(telemetry.bitrateLabel, '2500 kbps');
      expect(telemetry.sourceDriverLabel, 'Local file');
      expect(telemetry.filePathLabel, '/music/song.flac');
      expect(telemetry.isStreaming, isFalse);
      expect(telemetry.hasLiveTelemetry, isFalse);
    });

    test('falls back to measured media-item extras for local playback', () {
      final telemetry = PlaybackTelemetry.from(
        context: EnginePlayContext(
          trackId: 't2',
          mode: SmartPlayMode.local,
          quality: AudioQualityLevel.high,
          characteristics: const AudioCharacteristics(codec: 'MP3'),
          localPath: '/music/song.mp3',
        ),
        item: MediaItem(
          id: 't2',
          title: 'Song',
          artist: 'Artist',
          extras: const {
            'format': 'MP3',
            'bitrate': 320,
            'sample_rate': 44100,
            'bit_depth': 16,
          },
        ),
        diagnostics: _emptyDiagnostics(),
      );

      expect(telemetry.codecLabel, 'MP3');
      expect(telemetry.bitrateLabel, '320 kbps');
      expect(telemetry.sampleRateLabel, '44.1kHz');
      expect(telemetry.bitDepthLabel, '16-bit');
    });

    test('reports the provider as the source driver while streaming', () {
      final telemetry = PlaybackTelemetry.from(
        context: EnginePlayContext(
          trackId: 't3',
          mode: SmartPlayMode.stream,
          providerId: 'deezer',
          quality: AudioQualityLevel.lossless,
          characteristics: const AudioCharacteristics(
            codec: 'FLAC',
            lossless: true,
          ),
        ),
        item: MediaItem(id: 't3', title: 'Song', artist: 'Artist'),
        diagnostics: _emptyDiagnostics(),
      );

      expect(telemetry.isStreaming, isTrue);
      expect(telemetry.sourceDriverLabel, 'deezer');
      expect(telemetry.filePathLabel, 'Streamed — not stored on device');
    });

    test('unknown fields render a placeholder dash', () {
      final telemetry = PlaybackTelemetry.from(
        context: EnginePlayContext(
          trackId: 't4',
          mode: SmartPlayMode.local,
          quality: AudioQualityLevel.auto,
          characteristics: const AudioCharacteristics(),
          localPath: '/music/x.flac',
        ),
        item: MediaItem(id: 't4', title: 'S', artist: 'A'),
        diagnostics: _emptyDiagnostics(),
      );

      expect(telemetry.codecLabel, '—');
      expect(telemetry.bitrateLabel, '—');
      expect(telemetry.sampleRateLabel, '—');
      expect(telemetry.bitDepthLabel, '—');
    });

    test('exposes live telemetry when a stream is active', () {
      final bandwidth = BandwidthMonitor();
      bandwidth.record(
        BandwidthSample.fromPreflight(
          latencyMs: 40,
          contentLengthBytes: 1024 * 1024,
        ),
      );

      final telemetry = PlaybackTelemetry.from(
        context: EnginePlayContext(
          trackId: 't5',
          mode: SmartPlayMode.stream,
          providerId: 'preview',
          quality: AudioQualityLevel.low,
          characteristics: const AudioCharacteristics(
            codec: 'MP3',
            bitrateKbps: 128,
          ),
        ),
        item: MediaItem(id: 't5', title: 'S', artist: 'A'),
        diagnostics: StreamingDiagnostics(
          health: ProviderHealthRegistry(),
          log: EngineEventLog(),
          session: StreamSessionState(
            phase: StreamPhase.streaming,
            attempt: 1,
          ),
          bandwidth: bandwidth,
          integrity: StreamIntegrityLog(),
        ),
      );

      expect(telemetry.hasLiveTelemetry, isTrue);
      expect(telemetry.session.phase, StreamPhase.streaming);
      expect(telemetry.session.attempt, 1);
      expect(telemetry.bandwidthBytesPerSecond, isNotNull);
    });
  });
}
