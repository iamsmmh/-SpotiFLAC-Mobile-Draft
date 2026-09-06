import 'package:spotiflac_android/core/domain/cancellation_token.dart';
import 'package:spotiflac_android/core/domain/core_errors.dart';
import 'package:spotiflac_android/core/domain/entities.dart';
import 'package:spotiflac_android/core/domain/ports.dart';
import 'package:spotiflac_android/services/ffmpeg_service.dart';

/// Pluggable lookup used by [PlatformMetadataPipeline.enrich]. Returns the
/// enriched envelope for [track]; the default implementation is the identity
/// (no enrichment), keeping the pipeline usable before provider wiring.
typedef MetadataLookupFn =
    Future<MetadataEnvelope> Function(
      TrackRef track,
      CancellationToken cancellation,
    );

/// [MetadataPipeline] over the platform services.
///
///  - `enrich` delegates to the injected lookup function (provider-backed at
///    the composition root; identity by default)
///  - `embed` routes container-aware FFmpeg embedding: the container decides
///    the writer — Vorbis comments for FLAC/Opus, ID3v2.3-style tags for MP3,
///    MP4 atoms for M4A — so a pipeline caller never hand-picks FFmpeg
///    invocations per format
///
/// Every failure crossing this adapter is a normalized [CoreError].
class PlatformMetadataPipeline implements MetadataPipeline {
  const PlatformMetadataPipeline({MetadataLookupFn? lookup})
    : _lookup = lookup;

  final MetadataLookupFn? _lookup;

  @override
  Future<MetadataEnvelope> enrich(
    TrackRef track,
    CancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final lookup = _lookup;
    if (lookup == null) {
      return MetadataEnvelope(
        title: track.name,
        artist: track.artistName,
        album: track.albumName.isEmpty ? null : track.albumName,
        albumArtist: track.albumArtistName,
        trackNumber: track.trackNumber,
        discNumber: track.discNumber,
        isrc: track.isrc,
        coverUrl: track.coverUrl,
        releaseDate: track.releaseDate,
      );
    }
    try {
      final envelope = await lookup(track, cancellation);
      cancellation.throwIfCancelled();
      return envelope;
    } on JobCancelledException {
      rethrow;
    } on CoreError {
      rethrow;
    } catch (error) {
      throw normalizeCoreError(
        error,
        fallback: CoreErrorCategory.provider,
        fallbackMessage: 'Metadata enrichment failed: $error',
      );
    }
  }

  @override
  Future<String?> embed(
    String filePath,
    MetadataEnvelope envelope,
    CancellationToken cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final metadata = metadataEnvelopeToTagMap(envelope);
    if (metadata.isEmpty) return null;

    final ext = fileExtensionOf(filePath).toLowerCase();
    try {
      final String? result = switch (ext) {
        'flac' => await FFmpegService.embedMetadata(
          flacPath: filePath,
          metadata: metadata,
        ),
        'mp3' => await FFmpegService.embedMetadataToMp3(
          mp3Path: filePath,
          metadata: metadata,
        ),
        'opus' => await FFmpegService.embedMetadataToOpus(
          opusPath: filePath,
          metadata: metadata,
        ),
        'm4a' => await FFmpegService.embedMetadataToM4a(
          m4aPath: filePath,
          metadata: metadata,
        ),
        _ => throw const CoreError(
          category: CoreErrorCategory.format,
          message: 'No metadata embedder for container type',
          retryable: false,
        ),
      };
      cancellation.throwIfCancelled();
      return result;
    } on JobCancelledException {
      rethrow;
    } on CoreError {
      rethrow;
    } catch (error) {
      throw normalizeCoreError(
        error,
        fallback: CoreErrorCategory.format,
        fallbackMessage: 'Metadata embedding failed: $error',
      );
    }
  }
}

/// Pure conversion from [MetadataEnvelope] to a tag map; shared by the embed
/// router and unit tests. Empty/absent fields are omitted.
Map<String, String> metadataEnvelopeToTagMap(MetadataEnvelope envelope) {
  final tags = <String, String>{
    'title': envelope.title,
    'artist': envelope.artist,
  };
  final album = envelope.album;
  if (album != null && album.isNotEmpty) tags['album'] = album;
  final albumArtist = envelope.albumArtist;
  if (albumArtist != null && albumArtist.isNotEmpty) {
    tags['album_artist'] = albumArtist;
  }
  final trackNumber = envelope.trackNumber;
  if (trackNumber != null && trackNumber > 0) {
    tags['track_number'] = '$trackNumber';
  }
  final discNumber = envelope.discNumber;
  if (discNumber != null && discNumber > 0) {
    tags['disc_number'] = '$discNumber';
  }
  final isrc = envelope.isrc;
  if (isrc != null && isrc.isNotEmpty) tags['isrc'] = isrc;
  final releaseDate = envelope.releaseDate;
  if (releaseDate != null && releaseDate.isNotEmpty) {
    tags['release_date'] = releaseDate;
  }
  return tags;
}

/// Lowercase extension without the dot (`/a/b.flac` → `flac`).
String fileExtensionOf(String path) {
  final base = path.split('/').last;
  final dot = base.lastIndexOf('.');
  if (dot < 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}
