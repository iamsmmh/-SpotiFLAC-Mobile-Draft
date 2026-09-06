import 'dart:async';
import 'dart:io';

import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';
import 'package:spotiflac_android/services/ffmpeg_service.dart';

/// [AudioTranscoder] over the app's FFmpegKit service.
///
/// Cancellation model: FFmpegKit sessions owned by the service's static
/// helpers are not exposed as cancellable handles, so this adapter enforces
/// the cancellation *boundary*: the token is checked before and after the
/// native session, and a cancelled run deletes any produced output instead of
/// promoting it — no orphaned conversions surface in the user's library.
/// Native session-level abort hooks land in Stage 3 alongside
/// DownloadService.kt wiring.
class FFmpegAudioTranscoder implements AudioTranscoder {
  const FFmpegAudioTranscoder();

  @override
  Future<TranscodeOutcome> transcode(
    TranscodeRequest request,
    CancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();

    Future<String?> Function() invoke;
    switch (request.targetFormat) {
      case TranscodeTargetFormat.flac:
        invoke = () => FFmpegService.convertM4aToFlac(request.inputPath);
      case TranscodeTargetFormat.mp3:
        invoke = () => FFmpegService.convertM4aToLossy(
          request.inputPath,
          format: 'mp3',
          bitrate: _bitrateArg(request),
          deleteOriginal: request.deleteSourceOnSuccess,
        );
      case TranscodeTargetFormat.opus:
        invoke = () => FFmpegService.convertM4aToLossy(
          request.inputPath,
          format: 'opus',
          bitrate: _bitrateArg(request),
          deleteOriginal: request.deleteSourceOnSuccess,
        );
      case TranscodeTargetFormat.m4a:
        invoke = () => FFmpegService.convertM4aToLossy(
          request.inputPath,
          format: 'aac',
          bitrate: _bitrateArg(request),
          deleteOriginal: request.deleteSourceOnSuccess,
        );
      case TranscodeTargetFormat.ogg:
        return const TranscodeOutcome(
          success: false,
          error: CoreError(
            category: CoreErrorCategory.format,
            message:
                'OGG output is not supported by the FFmpeg adapter; '
                'use opus for ogg-family output',
            retryable: false,
          ),
        );
    }
    // invoke is always assigned here; the ogg arm returned already.
    final output = await invoke();
    if (output == null) {
      return const TranscodeOutcome(
        success: false,
        error: CoreError(
          category: CoreErrorCategory.format,
          message: 'FFmpeg conversion failed',
          retryable: false,
        ),
      );
    }

    if (cancellation.isCancelled) {
      // Boundary rule: cancelled work never promotes its output.
      try {
        final produced = File(output);
        if (await produced.exists()) {
          await produced.delete();
        }
      } catch (_) {
        // Cleanup best-effort; the temp janitor is the second line.
      }
      throw const JobCancelledException(reason: 'cancelled');
    }

    return TranscodeOutcome(success: true, outputPath: output);
  }

  /// The legacy lossy-converter accepts `format_kbps`-style strings like
  /// `mp3_320`; derive one from [TranscodeRequest.bitrateKbps].
  static String? _bitrateArg(TranscodeRequest request) {
    final kbps = request.bitrateKbps;
    if (kbps == null || kbps <= 0) return null;
    return 'core_$kbps';
  }
}
