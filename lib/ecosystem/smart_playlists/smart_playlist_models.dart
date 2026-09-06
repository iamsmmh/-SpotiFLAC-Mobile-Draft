/// Smart playlist models (Feature Group 6).
///
/// A smart playlist is a *definition*, not a stored track list: every view
/// is materialized on demand from listening history, favorites, the
/// library and the recommendation engine, then cached into
/// `ec_smart_playlist_state` (timestamps + counts) so the UI can show
/// freshness without re-running the engine.
library;

import 'package:spotiflac_android/models/track.dart';

/// The built-in smart playlists.
enum SmartPlaylistKind {
  recentlyPlayed('Recently Played', 'What you played, newest first'),
  mostPlayed('Most Played', 'All-time favourites by play count'),
  favorites('Favorites', 'Your loved tracks and albums'),
  recentlyAdded('Recently Added', 'Newest files in your library'),
  discoverMix('Discover Mix', 'Fresh picks from your recommendation engine'),
  dailyMix('Daily Mix', 'Your top tracks, reshuffled every day');

  const SmartPlaylistKind(this.title, this.description);

  final String title;
  final String description;

  static SmartPlaylistKind fromName(Object? name) {
    final text = name?.toString().trim().toLowerCase() ?? '';
    for (final kind in SmartPlaylistKind.values) {
      if (kind.name == text) return kind;
    }
    return SmartPlaylistKind.recentlyPlayed;
  }
}

/// Tunables for one smart playlist.
class SmartPlaylistDefinition {
  const SmartPlaylistDefinition({
    required this.kind,
    this.limit = 30,
    this.daysWindow = 0,
    this.minPlayCount = 1,
    this.maxSkipRate = 0.6,
    this.enabled = true,
  });

  final SmartPlaylistKind kind;

  /// Maximum materialized tracks.
  final int limit;

  /// History window in days (0 = all time).
  final int daysWindow;

  /// Minimum plays to qualify (most played only).
  final int minPlayCount;

  /// Tracks skipped more often than this are excluded (0..1).
  final double maxSkipRate;

  final bool enabled;

  SmartPlaylistDefinition copyWith({
    int? limit,
    int? daysWindow,
    int? minPlayCount,
    double? maxSkipRate,
    bool? enabled,
  }) => SmartPlaylistDefinition(
    kind: kind,
    limit: limit ?? this.limit,
    daysWindow: daysWindow ?? this.daysWindow,
    minPlayCount: minPlayCount ?? this.minPlayCount,
    maxSkipRate: maxSkipRate ?? this.maxSkipRate,
    enabled: enabled ?? this.enabled,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'limit': limit,
    'days_window': daysWindow,
    'min_play_count': minPlayCount,
    'max_skip_rate': maxSkipRate,
    'enabled': enabled,
  };

  static SmartPlaylistDefinition fromJson(Object? raw) {
    if (raw is! Map) {
      return const SmartPlaylistDefinition(
        kind: SmartPlaylistKind.recentlyPlayed,
      );
    }
    return SmartPlaylistDefinition(
      kind: SmartPlaylistKind.fromName(raw['kind']),
      limit: (raw['limit'] as num?)?.toInt() ?? 30,
      daysWindow: (raw['days_window'] as num?)?.toInt() ?? 0,
      minPlayCount: (raw['min_play_count'] as num?)?.toInt() ?? 1,
      maxSkipRate: (raw['max_skip_rate'] as num?)?.toDouble() ?? 0.6,
      enabled: raw['enabled'] != false,
    );
  }
}

/// One materialized row of a smart playlist.
class SmartPlaylistTrack {
  const SmartPlaylistTrack({
    required this.track,
    this.trackKey = '',
    this.playCount = 0,
    this.reason = '',
  });

  /// Playable through the existing queue path
  /// (`PlaybackController.playTrackList`).
  final Track track;

  /// Canonical history key when the row came from history.
  final String trackKey;
  final int playCount;

  /// Human hint, e.g. "12 plays", "added Tuesday".
  final String reason;
}

/// A materialized smart playlist.
class SmartPlaylist {
  const SmartPlaylist({
    required this.definition,
    required this.tracks,
    required this.materializedAt,
  });

  final SmartPlaylistDefinition definition;
  final List<SmartPlaylistTrack> tracks;
  final DateTime materializedAt;

  bool get isEmpty => tracks.isEmpty;
}

/// Materialization metadata persisted per playlist.
class SmartPlaylistState {
  const SmartPlaylistState({
    required this.playlistId,
    required this.lastMaterializedAt,
    required this.lastTrackCount,
  });

  final String playlistId;
  final DateTime? lastMaterializedAt;
  final int lastTrackCount;

  Map<String, Object?> toRow() => <String, Object?>{
    'playlist_id': playlistId,
    'definition_json': '{}',
    'last_materialized_at': lastMaterializedAt?.toUtc().toIso8601String(),
    'last_track_count': lastTrackCount,
  };

  static SmartPlaylistState fromRow(Map<String, Object?> row) =>
      SmartPlaylistState(
        playlistId: row['playlist_id']?.toString() ?? '',
        lastMaterializedAt: DateTime.tryParse(
          row['last_materialized_at']?.toString() ?? '',
        ),
        lastTrackCount: (row['last_track_count'] as num?)?.toInt() ?? 0,
      );
}
