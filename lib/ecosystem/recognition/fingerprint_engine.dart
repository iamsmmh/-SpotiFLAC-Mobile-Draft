/// Acoustic fingerprinting (Feature Group 10).
///
/// The app already ships the full FFmpeg build (`ffmpeg_kit_flutter_new_full`),
/// which includes the **Chromaprint** muxer — the same algorithm AcoustID uses.
/// That means fingerprints are produced on-device with no extra native
/// dependency and no audio ever leaving the phone: only the compact fingerprint
/// string is sent to a provider.
///
/// Pipeline: microphone/file → FFmpeg (`-f chromaprint`) → base64 fingerprint →
/// [RecognitionProvider].
library;

import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_full/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_full/return_code.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:spotiflac_android/ecosystem/recognition/recognition_models.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('Fingerprint');

/// Thrown when audio cannot be fingerprinted.
class FingerprintException implements Exception {
  const FingerprintException(this.message);

  final String message;

  @override
  String toString() => 'FingerprintException: $message';
}

/// Produces [AudioFingerprint]s from audio.
abstract interface class FingerprintEngine {
  /// Fingerprints [sample]. Throws [FingerprintException] on failure.
  Future<AudioFingerprint> fingerprint(RecognitionSample sample);
}

/// Chromaprint via FFmpeg.
class ChromaprintFingerprintEngine implements FingerprintEngine {
  const ChromaprintFingerprintEngine();

  /// Chromaprint is tuned for ~12s excerpts; longer input costs time without
  /// improving the match rate.
  static const Duration analysisWindow = Duration(seconds: 12);

  @override
  Future<AudioFingerprint> fingerprint(RecognitionSample sample) async {
    final input = File(sample.filePath);
    if (!await input.exists()) {
      throw FingerprintException('sample not found: ${sample.filePath}');
    }

    final temporary = await getTemporaryDirectory();
    final outputPath = p.join(
      temporary.path,
      'fp_${DateTime.now().microsecondsSinceEpoch}.txt',
    );

    // Chromaprint requires mono 16-bit PCM at a fixed rate; -t bounds the work.
    final seconds = _windowSeconds(sample.duration);
    final command = <String>[
      '-hide_banner',
      '-nostdin',
      '-i',
      _quote(sample.filePath),
      '-t',
      '$seconds',
      '-ac',
      '1',
      '-ar',
      '44100',
      '-f',
      'chromaprint',
      '-fp_format',
      'base64',
      '-y',
      _quote(outputPath),
    ].join(' ');

    try {
      final session = await FFmpegKit.execute(command);
      final returnCode = await session.getReturnCode();
      if (!ReturnCode.isSuccess(returnCode)) {
        final logs = await session.getOutput();
        throw FingerprintException(
          'ffmpeg chromaprint failed (${returnCode?.getValue()}): '
          '${_tail(logs)}',
        );
      }

      final output = File(outputPath);
      if (!await output.exists()) {
        throw const FingerprintException('chromaprint produced no output');
      }
      final value = (await output.readAsString()).trim();
      if (value.isEmpty) {
        throw const FingerprintException('chromaprint output was empty');
      }

      return AudioFingerprint(
        fingerprint: value,
        duration: Duration(seconds: seconds),
        sampleRate: 44100,
        channels: 1,
      );
    } finally {
      // Never leave scratch files behind, success or failure.
      try {
        final output = File(outputPath);
        if (await output.exists()) await output.delete();
      } catch (error) {
        _log.w('Could not clean fingerprint scratch file: $error');
      }
    }
  }

  /// Clamps the analysis window to something both useful and bounded.
  static int _windowSeconds(Duration duration) {
    if (duration <= Duration.zero) return analysisWindow.inSeconds;
    final seconds = duration.inSeconds;
    if (seconds < 3) return 3;
    return seconds > analysisWindow.inSeconds
        ? analysisWindow.inSeconds
        : seconds;
  }

  /// FFmpeg's command parser splits on spaces, so paths must be quoted.
  static String _quote(String path) => "'${path.replaceAll("'", r"\'")}'";

  static String _tail(String? logs) {
    if (logs == null || logs.isEmpty) return 'no output';
    const limit = 300;
    return logs.length <= limit
        ? logs.trim()
        : logs.substring(logs.length - limit).trim();
  }
}
