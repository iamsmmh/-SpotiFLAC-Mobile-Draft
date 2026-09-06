import 'dart:io';

import 'package:spotiflac_android/services/ffmpeg_service.dart';
import 'package:spotiflac_android/services/platform_bridge.dart';
import 'package:spotiflac_android/utils/file_access.dart';
import 'package:spotiflac_android/utils/logger.dart';

/// Standalone ReplayGain (re)scanning for existing audio files.
///
/// Computes EBU R128 loudness via FFmpeg and writes REPLAYGAIN_TRACK_* tags
/// back into the file in place:
///   - FLAC / M4A / MP4 / APE / WV / MPC -> native tag writer (PlatformBridge)
///   - MP3 / Opus / OGG / others         -> FFmpeg copy-with-metadata
///
/// Handles SAF content:// URIs transparently by working on a temporary copy
/// and writing it back to the original document.
class ReplayGainService {
  ReplayGainService._();

  static final _log = AppLogger('ReplayGain');

  static const _nativeExtensions = <String>{
    '.flac',
    '.m4a',
    '.mp4',
    '.m4b',
    '.ape',
    '.wv',
    '.mpc',
    '.wav',
    '.aiff',
    '.aif',
    '.aifc',
  };

  static bool _isNativeWritableFormat(String path) {
    final lower = path.toLowerCase();
    return _nativeExtensions.any(lower.endsWith);
  }

  /// Scans [filePath] for loudness and writes track ReplayGain tags in place.
  ///
  /// Returns `true` when tags were successfully written, `false` otherwise
  /// (scan failed, write failed, or SAF write-back failed).
  static Future<bool> applyToFile(String filePath) async {
    if (filePath.isEmpty) return false;

    final isSaf = isContentUri(filePath);
    var workingPath = filePath;
    String? safTempPath;

    try {
      if (isSaf) {
        safTempPath = await PlatformBridge.copyContentUriToTemp(filePath);
        if (safTempPath == null || safTempPath.isEmpty) {
          _log.w('Failed to copy SAF file to temp for ReplayGain scan');
          return false;
        }
        workingPath = safTempPath;
      }

      final rg = await FFmpegService.scanReplayGain(workingPath);
      if (rg == null) {
        _log.w('ReplayGain scan returned no result for $workingPath');
        return false;
      }

      bool written;
      if (_isNativeWritableFormat(workingPath)) {
        final result = await PlatformBridge.editFileMetadata(workingPath, {
          'replaygain_track_gain': rg.trackGain,
          'replaygain_track_peak': rg.trackPeak,
        });
        written = result['error'] == null;
        if (!written) {
          _log.w('Native ReplayGain write failed: ${result['error']}');
        }
      } else {
        written = await FFmpegService.writeTrackReplayGainTags(
          workingPath,
          rg.trackGain,
          rg.trackPeak,
        );
      }

      if (!written) return false;

      if (isSaf) {
        final ok = await PlatformBridge.writeTempToSaf(workingPath, filePath);
        if (!ok) {
          _log.w('Failed to write ReplayGain temp file back to SAF document');
        }
        return ok;
      }

      return true;
    } catch (e) {
      _log.e('Failed to apply ReplayGain', e);
      return false;
    } finally {
      if (safTempPath != null) {
        try {
          await File(safTempPath).delete();
        } catch (e) {
          _log.d('best-effort step failed: $e');
        }
      }
    }
  }
}
