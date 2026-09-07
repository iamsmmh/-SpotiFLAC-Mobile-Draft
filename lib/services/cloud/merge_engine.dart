/// Last-write-wins plus structured merge (Phase 3).
///
/// Record-level conflicts stay LWW (the existing [SyncOrchestrator] rule).
/// Playlist *contents* additionally union-merge so two devices adding
/// different tracks in the same second do not clobber each other.
library;

import 'package:spotiflac_android/core/sync/sync_entities.dart';
import 'package:spotiflac_android/core/sync/sync_orchestrator.dart';

/// One merged playlist payload.
class MergedPlaylistPayload {
  const MergedPlaylistPayload({
    required this.title,
    required this.trackIds,
    required this.updatedAt,
    this.description = '',
  });

  final String title;
  final List<String> trackIds;
  final DateTime updatedAt;
  final String description;

  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        'description': description,
        'trackIds': trackIds,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
      };
}

/// Structured merge on top of LWW.
class SyncMergeEngine {
  const SyncMergeEngine();

  /// Record-level winner — delegates to the orchestrator's deterministic
  /// rule so cloud sync and the local outbox never disagree.
  SyncConflictWinner recordWinner(SyncRecord local, SyncRecord remote) {
    return SyncOrchestrator().resolve(local, remote);
  }

  /// Union-merge of two playlist payloads. Title/description follow LWW on
  /// [updatedAt]; track ids are the stable union (local order, then remote
  /// additions appended). Tombstones (ids listed in either side's
  /// `removedTrackIds`) stay removed.
  MergedPlaylistPayload mergePlaylists({
    required Map<String, Object?> local,
    required Map<String, Object?> remote,
    required DateTime localUpdatedAt,
    required DateTime remoteUpdatedAt,
  }) {
    final localNewer = !remoteUpdatedAt.isAfter(localUpdatedAt);
    final title = (localNewer ? local['title'] : remote['title'])?.toString() ??
        '';
    final description =
        (localNewer ? local['description'] : remote['description'])
                ?.toString() ??
            '';
    final localIds = _stringList(local['trackIds']);
    final remoteIds = _stringList(remote['trackIds']);
    final removed = <String>{
      ..._stringList(local['removedTrackIds']),
      ..._stringList(remote['removedTrackIds']),
    };
    final seen = <String>{};
    final merged = <String>[];
    for (final id in [...localIds, ...remoteIds]) {
      if (id.isEmpty || removed.contains(id) || !seen.add(id)) continue;
      merged.add(id);
    }
    return MergedPlaylistPayload(
      title: title,
      description: description,
      trackIds: List<String>.unmodifiable(merged),
      updatedAt: localNewer ? localUpdatedAt : remoteUpdatedAt,
    );
  }

  /// Settings merge: per-key LWW. Keys present on only one side are kept.
  Map<String, Object?> mergeSettings({
    required Map<String, Object?> local,
    required Map<String, Object?> remote,
    required DateTime localUpdatedAt,
    required DateTime remoteUpdatedAt,
  }) {
    final localNewer = !remoteUpdatedAt.isAfter(localUpdatedAt);
    final winner = localNewer ? local : remote;
    final loser = localNewer ? remote : local;
    return <String, Object?>{
      ...loser,
      ...winner,
    };
  }

  static List<String> _stringList(Object? raw) {
    if (raw is List<String>) {
      return <String>[for (final entry in raw) if (entry.isNotEmpty) entry];
    }
    if (raw is! List<Object?>) return const <String>[];
    return <String>[
      for (final entry in raw)
        if (entry != null && entry.toString().isNotEmpty) entry.toString(),
    ];
  }
}
