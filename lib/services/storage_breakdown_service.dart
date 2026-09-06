import 'package:spotiflac_android/providers/download_history_provider.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/utils/file_access.dart';

/// One aggregated storage bucket (by format, artist or album).
class StorageBreakdownBucket {
  final String key;
  final String label;
  final int totalBytes;
  final int fileCount;

  const StorageBreakdownBucket({
    required this.key,
    required this.label,
    required this.totalBytes,
    required this.fileCount,
  });
}

class StorageBreakdown {
  final int totalBytes;
  final int fileCount;
  final List<StorageBreakdownBucket> byFormat;
  final List<StorageBreakdownBucket> byArtist;
  final List<StorageBreakdownBucket> byAlbum;

  const StorageBreakdown({
    required this.totalBytes,
    required this.fileCount,
    required this.byFormat,
    required this.byArtist,
    required this.byAlbum,
  });
}

/// Computes per-format / per-artist / per-album disk usage for downloaded and
/// local-library files. File stats are read on demand; files that no longer
/// exist are skipped silently.
Future<StorageBreakdown> computeStorageBreakdown({
  required List<DownloadHistoryItem> historyItems,
  required List<LocalLibraryItem> localItems,
}) async {
  final formatSizes = <String, _BucketAccumulator>{};
  final artistSizes = <String, _BucketAccumulator>{};
  final albumSizes = <String, _BucketAccumulator>{};
  var total = 0;
  var count = 0;

  Future<void> addEntry({
    required String path,
    required String format,
    required String artist,
    required String album,
  }) async {
    final stat = await fileStat(path);
    final size = stat?.size;
    if (size == null || size <= 0) return;
    total += size;
    count++;
    _addBucket(formatSizes, _bucketKey('format', format), format, size);
    _addBucket(
      artistSizes,
      _bucketKey('artist', artist),
      artist.isEmpty ? 'Unknown artist' : artist,
      size,
    );
    _addBucket(
      albumSizes,
      _bucketKey('album', '$artist::$album'),
      album.isEmpty ? 'Unknown album' : album,
      size,
    );
  }

  for (final item in historyItems) {
    await addEntry(
      path: item.filePath,
      format: item.format ?? _extFormat(item.filePath),
      artist: item.artistName,
      album: item.albumName,
    );
  }
  for (final item in localItems) {
    await addEntry(
      path: item.filePath,
      format: item.format ?? _extFormat(item.filePath),
      artist: item.artistName,
      album: item.albumName,
    );
  }

  return StorageBreakdown(
    totalBytes: total,
    fileCount: count,
    byFormat: _toBuckets(formatSizes),
    byArtist: _toBuckets(artistSizes),
    byAlbum: _toBuckets(albumSizes),
  );
}

void _addBucket(
  Map<String, _BucketAccumulator> buckets,
  String key,
  String label,
  int size,
) {
  final current = buckets[key] ??
      _BucketAccumulator(label.isEmpty ? 'Unknown' : label);
  current.totalBytes += size;
  current.fileCount++;
  buckets[key] = current;
}

String _bucketKey(String kind, String label) {
  final normalized = label.trim().toLowerCase();
  return '$kind::${normalized.isEmpty ? 'unknown' : normalized}';
}

List<StorageBreakdownBucket> _toBuckets(
  Map<String, _BucketAccumulator> buckets,
) {
  final list = <StorageBreakdownBucket>[
    for (final entry in buckets.entries)
      StorageBreakdownBucket(
        key: entry.key,
        label: entry.value.label,
        totalBytes: entry.value.totalBytes,
        fileCount: entry.value.fileCount,
      ),
  ];
  list.sort((a, b) => b.totalBytes.compareTo(a.totalBytes));
  return list;
}

class _BucketAccumulator {
  final String label;
  int totalBytes = 0;
  int fileCount = 0;

  _BucketAccumulator(this.label);
}

String _extFormat(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0 || dot == path.length - 1) return 'Unknown';
  return path.substring(dot + 1).toUpperCase();
}

/// Human format for bytes (e.g. "1.2 GB").
String formatStorageBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const kb = 1024;
  const mb = kb * 1024;
  const gb = mb * 1024;
  if (bytes >= gb) return '${(bytes / gb).toStringAsFixed(2)} GB';
  if (bytes >= mb) return '${(bytes / mb).toStringAsFixed(1)} MB';
  if (bytes >= kb) return '${(bytes / kb).toStringAsFixed(1)} KB';
  return '$bytes B';
}
