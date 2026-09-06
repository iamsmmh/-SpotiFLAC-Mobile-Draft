/// Smart playlist engine (Feature Group 6).
///
/// Pure decision core: turns [SmartPlaylistInput] (history aggregates,
/// favorites, library recents, recommendation sections) into materialized
/// [SmartPlaylist]s per definition. No I/O, no Flutter — the provider
/// layer feeds real stores and persists the results' metadata.
library;

import 'package:spotiflac_android/ecosystem/favorites/favorites.dart';
import 'package:spotiflac_android/ecosystem/history/listening_history.dart';
import 'package:spotiflac_android/ecosystem/smart_playlists/smart_playlist_models.dart';
import 'package:spotiflac_android/engine/recommendations.dart';
import 'package:spotiflac_android/models/track.dart';

/// A local-library row projected for the engine (the ecosystem layer must
/// not import service models directly — the provider maps them).
class SmartLibraryEntry {
  const SmartLibraryEntry({
    required this.track,
    required this.scannedAt,
  });

  final Track track;
  final DateTime scannedAt;
}

/// Everything the engine needs for one run.
class SmartPlaylistInput {
  const SmartPlaylistInput({
    required this.history,
    required this.library,
    this.favorites = const <FavoriteEntry>[],
    this.recommendations = const <RecommendationSection>[],
    this.now,
    this.dailySeed = 0,
  });

  /// All per-track aggregates (from `ListeningHistoryRepository`).
  final List<TrackHistory> history;

  /// Local library rows (newest-last scan order irrelevant; engine sorts).
  final List<SmartLibraryEntry> library;

  /// Unified favorites index rows.
  final List<FavoriteEntry> favorites;

  /// For You sections (discovery mix source).
  final List<RecommendationSection> recommendations;

  final DateTime? now;

  /// Deterministic daily rotation seed (see `recommendationDailySeed`).
  final int dailySeed;
}

/// The engine.
class SmartPlaylistEngine {
  const SmartPlaylistEngine();

  /// Generates one playlist from [input].
  SmartPlaylist generate(
    SmartPlaylistDefinition definition,
    SmartPlaylistInput input,
  ) {
    final at = input.now ?? DateTime.now();
    final tracks = switch (definition.kind) {
      SmartPlaylistKind.recentlyPlayed => _recentlyPlayed(definition, input),
      SmartPlaylistKind.mostPlayed => _mostPlayed(definition, input),
      SmartPlaylistKind.favorites => _favorites(definition, input),
      SmartPlaylistKind.recentlyAdded => _recentlyAdded(definition, input),
      SmartPlaylistKind.discoverMix => _discoverMix(definition, input),
      SmartPlaylistKind.dailyMix => _dailyMix(definition, input, at),
    };
    return SmartPlaylist(
      definition: definition,
      tracks: tracks.take(definition.limit).toList(growable: false),
      materializedAt: at,
    );
  }

  /// Generates every enabled definition.
  List<SmartPlaylist> generateAll(
    List<SmartPlaylistDefinition> definitions,
    SmartPlaylistInput input,
  ) => <SmartPlaylist>[
    for (final definition in definitions)
      if (definition.enabled) generate(definition, input),
  ];

  List<SmartPlaylistTrack> _recentlyPlayed(
    SmartPlaylistDefinition definition,
    SmartPlaylistInput input,
  ) {
    final cutoff = definition.daysWindow > 0
        ? (input.now ?? DateTime.now()).subtract(
            Duration(days: definition.daysWindow),
          )
        : null;
    final sorted = <TrackHistory>[...input.history]
      ..sort((a, b) => b.lastPlayedAt.compareTo(a.lastPlayedAt));
    return <SmartPlaylistTrack>[
      for (final entry in sorted)
        if (cutoff == null || entry.lastPlayedAt.isAfter(cutoff))
          if (entry.skipRate <= definition.maxSkipRate ||
              entry.playCount <= 2)
            SmartPlaylistTrack(
              track: _trackFromHistory(entry),
              trackKey: entry.trackKey,
              playCount: entry.playCount,
              reason: '${entry.playCount} play'
                  '${entry.playCount == 1 ? '' : 's'}',
            ),
    ];
  }

  List<SmartPlaylistTrack> _mostPlayed(
    SmartPlaylistDefinition definition,
    SmartPlaylistInput input,
  ) {
    final qualified = <TrackHistory>[
      for (final entry in input.history)
        if (entry.playCount >= definition.minPlayCount &&
            entry.skipRate <= definition.maxSkipRate)
          entry,
    ]
      ..sort((a, b) {
        final byPlays = b.playCount.compareTo(a.playCount);
        if (byPlays != 0) return byPlays;
        final bySkip = a.skipRate.compareTo(b.skipRate);
        if (bySkip != 0) return bySkip;
        return b.lastPlayedAt.compareTo(a.lastPlayedAt);
      });
    return <SmartPlaylistTrack>[
      for (final entry in qualified)
        SmartPlaylistTrack(
          track: _trackFromHistory(entry),
          trackKey: entry.trackKey,
          playCount: entry.playCount,
          reason: '${entry.playCount} plays · '
              '${(entry.averageCompletion * 100).round()}% complete',
        ),
    ];
  }

  List<SmartPlaylistTrack> _favorites(
    SmartPlaylistDefinition definition,
    SmartPlaylistInput input,
  ) {
    final trackFavorites = <FavoriteEntry>[
      for (final entry in input.favorites)
        if (entry.kind == FavoriteKind.track && entry.track != null) entry,
    ]..sort((a, b) => b.addedAt.compareTo(a.addedAt));
    return <SmartPlaylistTrack>[
      for (final entry in trackFavorites)
        SmartPlaylistTrack(
          track: entry.track!,
          reason: 'Loved',
        ),
    ];
  }

  List<SmartPlaylistTrack> _recentlyAdded(
    SmartPlaylistDefinition definition,
    SmartPlaylistInput input,
  ) {
    final sorted = <SmartLibraryEntry>[...input.library]
      ..sort((a, b) => b.scannedAt.compareTo(a.scannedAt));
    return <SmartPlaylistTrack>[
      for (final entry in sorted)
        SmartPlaylistTrack(
          track: entry.track,
          reason: 'Added ${_relativeDay(entry.scannedAt, input)}',
        ),
    ];
  }

  List<SmartPlaylistTrack> _discoverMix(
    SmartPlaylistDefinition definition,
    SmartPlaylistInput input,
  ) {
    final List<RecommendedItem> items = <RecommendedItem>[
      for (final section in input.recommendations)
        if (section.kind == RecommendationSectionKind.discoveryMix ||
            section.kind == RecommendationSectionKind.similarTracks)
          ...section.items,
    ];
    return <SmartPlaylistTrack>[
      for (final item in items)
        if (item.kind == RecommendedItemKind.track)
          SmartPlaylistTrack(
            track: Track(
              id: item.id,
              name: item.title,
              artistName: item.subtitle,
              albumName: '',
              duration: 0,
              source: item.providerId,
            ),
            reason: 'Recommended',
          ),
    ];
  }

  List<SmartPlaylistTrack> _dailyMix(
    SmartPlaylistDefinition definition,
    SmartPlaylistInput input,
    DateTime at,
  ) {
    final top = _mostPlayed(
      definition.copyWith(minPlayCount: 2),
      input,
    ).take(definition.limit).toList(growable: false);
    return _seededShuffle(top, input.dailySeed ^ definition.kind.name.length);
  }

  /// Deterministic Fisher-Yates with an LCG (same trick the discovery mix
  /// uses): stable within a day, reshuffled by the next seed.
  List<SmartPlaylistTrack> _seededShuffle(
    List<SmartPlaylistTrack> items,
    int seed,
  ) {
    final list = <SmartPlaylistTrack>[...items];
    var state = seed == 0 ? 1 : seed.abs();
    for (var i = list.length - 1; i > 0; i--) {
      state = (state * 1103515245 + 12345) & 0x7FFFFFFF;
      final j = state % (i + 1);
      final tmp = list[i];
      list[i] = list[j];
      list[j] = tmp;
    }
    return list;
  }

  Track _trackFromHistory(TrackHistory entry) => Track(
    id: entry.trackKey,
    name: entry.title,
    artistName: entry.artist,
    albumName: entry.album,
    coverUrl: entry.coverUrl,
    duration: entry.totalListened.inSeconds > 0
        ? entry.totalListened.inSeconds
        : 0,
    source: 'history',
  );

  String _relativeDay(DateTime scannedAt, SmartPlaylistInput input) {
    final now = input.now ?? DateTime.now();
    final days = now.difference(scannedAt).inDays;
    if (days <= 0) return 'today';
    if (days == 1) return 'yesterday';
    if (days < 30) return '$days days ago';
    return '${scannedAt.year}-${scannedAt.month.toString().padLeft(2, '0')}'
        '-${scannedAt.day.toString().padLeft(2, '0')}';
  }
}
