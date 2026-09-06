import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('ApkDownloader');

typedef ProgressCallback = void Function(int received, int total);

class ApkDownloader {
  /// Bound on the initial connect/headers exchange. An update must never hold
  /// the dialog in "starting download…" indefinitely because the server
  /// stopped answering before the first byte arrived.
  static const Duration _connectTimeout = Duration(seconds: 30);

  /// Inactivity timeout for the body stream: large APKs legitimately take
  /// minutes, so only a *stalled* connection (no bytes for this long) aborts.
  static const Duration _streamIdleTimeout = Duration(seconds: 60);

  static Future<String?> downloadApk({
    required String url,
    required String version,
    ProgressCallback? onProgress,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      _log.e('Refusing to download from invalid or non-HTTPS URL');
      return null;
    }

    final dir = await getExternalStorageDirectory();
    if (dir == null) {
      _log.e('Could not get storage directory');
      return null;
    }

    // Stream into a `.part` file and atomically rename it only after the
    // whole body arrived. A failed/interrupted update therefore never leaves
    // a truncated APK at the final path, and never destroys the previously
    // downloaded (installable) APK before the new one is complete.
    final filePath = '${dir.path}/SpotiFLAC-$version.apk';
    final partPath = '$filePath.part';

    final client = http.Client();
    IOSink? sink;
    var completed = false;

    try {
      final request = http.Request('GET', uri);
      final response = await client.send(request).timeout(_connectTimeout);

      if (response.statusCode != 200) {
        _log.e('Failed to download: ${response.statusCode}');
        return null;
      }

      final contentLength = response.contentLength ?? 0;

      final partFile = File(partPath);
      if (await partFile.exists()) {
        await partFile.delete();
      }

      sink = partFile.openWrite();
      int received = 0;

      await for (final chunk in response.stream.timeout(_streamIdleTimeout)) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, contentLength);
      }

      await sink.flush();
      completed = true;
      _log.i('Downloaded to: $filePath');
      return filePath;
    } catch (e) {
      _log.e('Error: $e');
      return null;
    } finally {
      await sink?.close();
      client.close();
      if (completed) {
        // Promote the complete artifact over any previous copy. rename() is
        // atomic on the filesystems Android uses, so an old APK is replaced
        // only once the new one is fully on disk.
        try {
          final partFile = File(partPath);
          if (await partFile.exists()) {
            await partFile.rename(filePath);
          }
        } catch (e) {
          _log.e('Failed to promote downloaded APK: $e');
        }
      } else {
        // Never leave a partial artifact behind on failure/interruption.
        try {
          final partFile = File(partPath);
          if (await partFile.exists()) {
            await partFile.delete();
          }
        } catch (e) {
          _log.w('Failed to clean up partial APK: $e');
        }
      }
    }
  }

  static Future<void> installApk(String filePath) async {
    try {
      final result = await OpenFilex.open(filePath);
      _log.i('Open result: ${result.type} - ${result.message}');
    } catch (e) {
      _log.e('Install error: $e');
    }
  }
}
