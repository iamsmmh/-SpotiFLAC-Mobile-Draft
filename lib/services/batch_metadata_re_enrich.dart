import 'package:spotiflac_android/models/settings.dart';
import 'package:spotiflac_android/services/library_database.dart';

/// Field group keys understood by the Go re-enrich backend.
class ReEnrichFields {
  static const String cover = 'cover';
  static const String lyrics = 'lyrics';
  static const String basicTags = 'basic_tags';
  static const String trackInfo = 'track_info';
  static const String releaseInfo = 'release_info';
  static const String extra = 'extra';

  static const List<String> all = [
    cover,
    lyrics,
    basicTags,
    trackInfo,
    releaseInfo,
    extra,
  ];
}

enum ReEnrichBatchMode { isrcOnly, missingOnly, selectedFields }

class ReEnrichFieldSelection {
  final ReEnrichBatchMode mode;
  final List<String> fields;

  const ReEnrichFieldSelection({required this.mode, this.fields = const []});

  List<String> updateFieldsFor(LocalLibraryItem item) {
    switch (mode) {
      case ReEnrichBatchMode.isrcOnly:
        return const ['isrc'];
      case ReEnrichBatchMode.selectedFields:
        return fields;
      case ReEnrichBatchMode.missingOnly:
        return missingReEnrichFields(item);
    }
  }
}

bool _missingText(String? value) {
  final normalized = value?.trim().toLowerCase() ?? '';
  return normalized.isEmpty ||
      normalized == 'unknown' ||
      normalized == 'unknown title' ||
      normalized == 'unknown artist' ||
      normalized == 'unknown album';
}

/// Returns granular tag keys, preventing a missing value from causing its
/// already-populated neighbors in the same backend group to be overwritten.
List<String> missingReEnrichFields(LocalLibraryItem item) {
  final fields = <String>[];
  if (_missingText(item.trackName)) fields.add('track_name');
  if (_missingText(item.artistName)) fields.add('artist_name');
  if (_missingText(item.albumName)) fields.add('album_name');
  if (_missingText(item.albumArtist)) fields.add('album_artist');
  if ((item.trackNumber ?? 0) <= 0) fields.add('track_number');
  if ((item.totalTracks ?? 0) <= 0) fields.add('total_tracks');
  if ((item.discNumber ?? 0) <= 0) fields.add('disc_number');
  if ((item.totalDiscs ?? 0) <= 0) fields.add('total_discs');
  if (_missingText(item.releaseDate)) fields.add('release_date');
  if (_missingText(item.isrc)) fields.add('isrc');
  if (_missingText(item.genre)) fields.add('genre');
  if (_missingText(item.composer)) fields.add('composer');
  if (_missingText(item.label)) fields.add('label');
  if (_missingText(item.copyright)) fields.add('copyright');
  if (_missingText(item.coverPath)) fields.add('cover');
  return fields;
}

Map<String, dynamic> buildBatchReEnrichRequest({
  required LocalLibraryItem item,
  required AppSettings settings,
  required List<String> updateFields,
  bool previewOnly = false,
  Map<String, dynamic>? resolvedMetadata,
}) {
  final request = <String, dynamic>{
    'file_path': item.filePath,
    'cover_url': '',
    'embed_lyrics': settings.embedLyrics,
    'lyrics_mode': settings.lyricsMode,
    'artist_tag_mode': settings.artistTagMode,
    'spotify_id': '',
    'track_name': item.trackName,
    'artist_name': item.artistName,
    'album_name': item.albumName,
    'album_artist': item.albumArtist ?? '',
    'track_number': item.trackNumber ?? 0,
    'total_tracks': item.totalTracks ?? 0,
    'disc_number': item.discNumber ?? 0,
    'total_discs': item.totalDiscs ?? 0,
    'release_date': item.releaseDate ?? '',
    'isrc': item.isrc ?? '',
    'genre': item.genre ?? '',
    'composer': item.composer ?? '',
    'label': item.label ?? '',
    'copyright': item.copyright ?? '',
    'duration_ms': (item.duration ?? 0) * 1000,
    'search_online': resolvedMetadata == null,
    'replace_release_metadata': false,
    'update_fields': updateFields,
    if (previewOnly) 'preview_only': true,
  };
  if (resolvedMetadata != null) {
    request.addAll(resolvedMetadata);
  }
  return request;
}

class ReEnrichMetadataChange {
  final String field;
  final String oldValue;
  final String newValue;

  const ReEnrichMetadataChange({
    required this.field,
    required this.oldValue,
    required this.newValue,
  });
}

class BatchReEnrichPreview {
  final LocalLibraryItem item;
  final List<String> updateFields;
  final Map<String, dynamic> enrichedMetadata;
  final List<ReEnrichMetadataChange> changes;

  const BatchReEnrichPreview({
    required this.item,
    required this.updateFields,
    required this.enrichedMetadata,
    required this.changes,
  });
}

String _displayValue(Object? value) {
  if (value == null) return '';
  if (value is num && value == 0) return '';
  return value.toString().trim();
}

List<ReEnrichMetadataChange> buildReEnrichMetadataChanges(
  LocalLibraryItem item,
  Map<String, dynamic> enrichedMetadata,
  List<String> updateFields,
) {
  final current = <String, Object?>{
    'track_name': item.trackName,
    'artist_name': item.artistName,
    'album_name': item.albumName,
    'album_artist': item.albumArtist,
    'track_number': item.trackNumber,
    'total_tracks': item.totalTracks,
    'disc_number': item.discNumber,
    'total_discs': item.totalDiscs,
    'release_date': item.releaseDate,
    'isrc': item.isrc,
    'genre': item.genre,
    'composer': item.composer,
    'label': item.label,
    'copyright': item.copyright,
    'cover_url': item.coverPath,
  };
  final changes = <ReEnrichMetadataChange>[];
  for (final field in current.keys) {
    if (!enrichedMetadata.containsKey(field)) continue;
    final oldValue = _displayValue(current[field]);
    final newValue = _displayValue(enrichedMetadata[field]);
    if (newValue.isEmpty || oldValue == newValue) continue;
    changes.add(
      ReEnrichMetadataChange(
        field: field,
        oldValue: oldValue,
        newValue: newValue,
      ),
    );
  }
  if (updateFields.contains(ReEnrichFields.lyrics) ||
      updateFields.contains('lyrics')) {
    changes.add(
      const ReEnrichMetadataChange(
        field: 'lyrics',
        oldValue: '',
        newValue: '__refresh_online__',
      ),
    );
  }
  return changes;
}
