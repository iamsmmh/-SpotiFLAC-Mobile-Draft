import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:spotiflac_android/models/download_item.dart';
import 'package:spotiflac_android/models/track.dart';

/// Cross-device queue transfer.
///
/// Exports the active download queue (and optionally the failed downloads) as a
/// portable JSON file that can be shared, then re-imported on another device.
/// The file only carries track identity/metadata; it never carries extension
/// credentials or downloaded audio.
class QueueTransferService {
  static const int _formatVersion = 1;

  /// Serializes [items] into a shareable JSON payload.
  static String encode(List<DownloadItem> items) {
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'spotiflac-queue',
      'version': _formatVersion,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'items': items.map((item) => item.toJson()).toList(growable: false),
    });
  }

  /// Parses the queue JSON payload. Returns an empty list when the payload is
  /// not a supported SpotiFLAC queue export.
  static List<DownloadItem> decode(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, dynamic>) return const [];
    if (decoded['format'] != 'spotiflac-queue') return const [];
    final rawItems = decoded['items'];
    if (rawItems is! List) return const [];
    return <DownloadItem>[
      for (final raw in rawItems)
        if (raw is Map<String, dynamic>) DownloadItem.fromJson(raw),
    ];
  }

  static List<Track> tracksFromItems(List<DownloadItem> items) =>
      items.map((item) => item.track).toList(growable: false);

  /// Writes the queue to a temp file and opens the system share sheet.
  static Future<String?> exportAndShare(
    List<DownloadItem> items, {
    String exportName = 'spotiflac-queue',
  }) async {
    if (items.isEmpty) return null;
    final dir = await getTemporaryDirectory();
    final safeName = exportName
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final now = DateTime.now();
    final datePart =
        '${now.year}${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}';
    final file = File(
      p.join(dir.path, '${safeName.isEmpty ? 'queue' : safeName}_$datePart.json'),
    );
    await file.writeAsString(encode(items), flush: true);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], subject: 'SpotiFLAC queue'),
    );
    return file.path;
  }

  /// Picks a `.json` queue export and returns the parsed items (or null when
  /// the user cancels or the file is invalid).
  static Future<List<DownloadItem>?> pickAndImport() async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['json'],
    );
    if (file == null) return null;
    try {
      final source = utf8.decode(await file.readAsBytes());
      return decode(source);
    } catch (_) {
      return const <DownloadItem>[];
    }
  }
}
