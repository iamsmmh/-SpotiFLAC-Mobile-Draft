import 'package:json_annotation/json_annotation.dart';
import 'package:spotiflac_android/models/track.dart';

part 'download_item.g.dart';

enum DownloadStatus {
  queued,
  downloading,
  finalizing,
  completed,
  failed,
  skipped,
}

enum DownloadErrorType {
  unknown,
  notFound,
  rateLimit,
  network,
  permission,
  verificationRequired,
}

@JsonSerializable()
class DownloadItem {
  final String id;
  final Track track;
  final String service;
  final DownloadStatus status;
  final double progress;
  final double speedMBps;
  final int bytesReceived;
  final int bytesTotal; // Total bytes when the server provides content length
  final String? filePath;
  final String? error;
  final DownloadErrorType? errorType;
  final String preparationStage;
  final DateTime createdAt;
  final String? qualityOverride;
  final String? playlistName;
  final int? playlistPosition; // 1-based position in the source playlist
  final bool fromBatch;
  final bool preserveQualityVariant;

  const DownloadItem({
    required this.id,
    required this.track,
    required this.service,
    this.status = DownloadStatus.queued,
    this.progress = 0.0,
    this.speedMBps = 0.0,
    this.bytesReceived = 0,
    this.bytesTotal = 0,
    this.filePath,
    this.error,
    this.errorType,
    this.preparationStage = '',
    required this.createdAt,
    this.qualityOverride,
    this.playlistName,
    this.playlistPosition,
    this.fromBatch = false,
    this.preserveQualityVariant = false,
  });

  DownloadItem copyWith({
    String? id,
    Track? track,
    String? service,
    DownloadStatus? status,
    double? progress,
    double? speedMBps,
    int? bytesReceived,
    int? bytesTotal,
    String? filePath,
    String? error,
    DownloadErrorType? errorType,
    String? preparationStage,
    DateTime? createdAt,
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
    bool? fromBatch,
    bool? preserveQualityVariant,
    // `error ?? this.error` cannot distinguish "not provided" from
    // "clear it", so retries use this explicit flag to drop the previous
    // failure message instead of carrying it into the fresh attempt.
    bool clearError = false,
  }) {
    return DownloadItem(
      id: id ?? this.id,
      track: track ?? this.track,
      service: service ?? this.service,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      speedMBps: speedMBps ?? this.speedMBps,
      bytesReceived: bytesReceived ?? this.bytesReceived,
      bytesTotal: bytesTotal ?? this.bytesTotal,
      filePath: filePath ?? this.filePath,
      error: clearError ? null : (error ?? this.error),
      errorType: clearError ? null : (errorType ?? this.errorType),
      preparationStage: preparationStage ?? this.preparationStage,
      createdAt: createdAt ?? this.createdAt,
      qualityOverride: qualityOverride ?? this.qualityOverride,
      playlistName: playlistName ?? this.playlistName,
      playlistPosition: playlistPosition ?? this.playlistPosition,
      fromBatch: fromBatch ?? this.fromBatch,
      preserveQualityVariant:
          preserveQualityVariant ?? this.preserveQualityVariant,
    );
  }

  String get errorMessage {
    if (error == null) return '';

    switch (errorType) {
      case DownloadErrorType.notFound:
        return 'Song not found on any service';
      case DownloadErrorType.rateLimit:
        return 'Service rate limit reached. Wait before retrying.';
      case DownloadErrorType.network:
        return 'Connection failed, check your internet';
      case DownloadErrorType.permission:
        return 'Cannot write to folder, check storage permission';
      case DownloadErrorType.verificationRequired:
        return 'Verification required. Open the extension and complete the security check.';
      default:
        return error ?? 'An error occurred';
    }
  }

  factory DownloadItem.fromJson(Map<String, dynamic> json) =>
      _$DownloadItemFromJson(json);
  Map<String, dynamic> toJson() => _$DownloadItemToJson(this);
}
