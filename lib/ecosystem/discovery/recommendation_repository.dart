/// Candidate pool + repository for the discovery suite (Phase 11).
///
/// This is the one place that knows where tracks come from:
///
///   * `library.db`        — downloaded/locally indexed files (offline-capable)
///   * `ec_track_history`  — everything the user has ever played, incl. streams
///   * collections         — loved tracks, favorite artists/albums, playlists
///
/// and turns them into the provider-agnostic [DiscoveryTrack] the engines
/// rank. Nothing here touches Flutter or Riverpod: the provider layer feeds in
/// the collections data ([DiscoveryLibraryInput]) so this file stays testable.
///
/// Performance (Phase 12): the pool is read once per background refresh and
/// then indexed in memory (`byKey`, `byArtist`, `byGenre`). The engines are
/// pure functions over those indexes, so a 20 000-track library costs one SQL
/// pass plus O(n) map building — never a query per candidate.
library;

import 'package:spotiflac_android/ecosystem/discovery/listening_statistics_repository.dart';
import 'package:spotiflac_android/ecosystem/history/listening_history.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/similarity_engine.dart';
import 'package:spotiflac_android/services/library_database.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('DiscoveryRepo');

// ---------------------------------------------------------------------------
// Inputs from the collections store
// ---------------------------------------------------------------------------

/// Favorites and playlists, projected out of `collections.db` by the provider
/// layer. Kept as plain data so this repository has no Riverpod dependency.
class DiscoveryLibraryInput {
  const DiscoveryLibraryInput({
    this.favoriteTrackKeys = const <String>{},
    this.favoriteTracks = const <DiscoveryTrack>[],
    this.favoriteArtistKeys = const <String>{},
    this.favoriteAlbumKeys = const <String>{},
    this.playlistIdsByTrackKey = const <String, Set<String>>{},
    this.playlistTrackKeys = const <Set<String>>[],
    this.playlistNames = const <String, String>{},
  });

  /// Collection keys (`isrc:…` or `source:id`) of loved tracks.
  final Set<String> favoriteTrackKeys;

  /// Loved tracks with full metadata (genre, cover, provider id).
  final List<DiscoveryTrack> favoriteTracks;

  /// [discoveryEntityKey] of each followed artist / favorite album.
  final Set<String> favoriteArtistKeys;
  final Set<String> favoriteAlbumKeys;

  /// `track key → playlist ids containing it` (shared-playlist similarity).
  final Map<String, Set<String>> playlistIdsByTrackKey;

  /// Track-key set per playlist, in the same order as [playlistNames].
  final List<Set<String>> playlistTrackKeys;

  /// `playlist id → name`.
  final Map<String, String> playlistNames;

  bool get hasFavorites =>
      favoriteTrackKeys.isNotEmpty ||
      favoriteArtistKeys.isNotEmpty ||
      favoriteAlbumKeys.isNotEmpty;
}

/// The in-memory, pre-indexed candidate set.
class DiscoveryCandidatePool {
  DiscoveryCandidatePool({
    required this.tracks,
    required this.signals,
    required this.favoriteTrackKeys,
    required this.favoriteArtistKeys,
    required this.favoriteAlbumKeys,
    required this.playlistIdsByTrackKey,
    required this.coListenGraph,
    this.playlistIdsByArtistKey = const <String, Set<String>>{},
  }) : byKey = <String, DiscoveryTrack>{
         for (final track in tracks) track.key: track,
       },
       byArtist = _groupBy(tracks, (track) => track.artistKey),
       byAlbum = _groupBy(tracks, (track) => track.albumKey),
       byGenre = _groupByMany(tracks, (track) => track.genres) {
    _log.i(
      'Candidate pool: ${tracks.length} tracks, '
      '${byArtist.length} artists, ${byGenre.length} genres',
    );
  }

  final List<DiscoveryTrack> tracks;
  final Map<String, TrackSignals> signals;
  final Set<String> favoriteTrackKeys;
  final Set<String> favoriteArtistKeys;
  final Set<String> favoriteAlbumKeys;
  final Map<String, Set<String>> playlistIdsByTrackKey;
  final Map<String, Set<String>> playlistIdsByArtistKey;

  /// `artist → artists heard in the same session`.
  final Map<String, Set<String>> coListenGraph;

  final Map<String, DiscoveryTrack> byKey;
  final Map<String, List<DiscoveryTrack>> byArtist;
  final Map<String, List<DiscoveryTrack>> byAlbum;
  final Map<String, List<DiscoveryTrack>> byGenre;

  bool get isEmpty => tracks.isEmpty;

  DiscoveryTrack? track(String key) => byKey[key];

  TrackSignals? signalsFor(String key) => signals[key];

  List<DiscoveryTrack> tracksByArtist(String artistKey) =>
      byArtist[artistKey] ?? const <DiscoveryTrack>[];

  /// Tracks in any of [genres], de-duplicated, strongest genre first.
  List<DiscoveryTrack> tracksInGenres(Iterable<String> genres) {
    final result = <DiscoveryTrack>[];
    final seen = <String>{};
    for (final genre in genres) {
      for (final track in byGenre[genre] ?? const <DiscoveryTrack>[]) {
        if (seen.add(track.key)) result.add(track);
      }
    }
    return result;
  }

  static Map<String, List<DiscoveryTrack>> _groupBy(
    List<DiscoveryTrack> tracks,
    String Function(DiscoveryTrack) keyOf,
  ) {
    final result = <String, List<DiscoveryTrack>>{};
    for (final track in tracks) {
      final key = keyOf(track);
      if (key.isEmpty) continue;
      result.putIfAbsent(key, () => <DiscoveryTrack>[]).add(track);
    }
    return Map<String, List<DiscoveryTrack>>.unmodifiable(result);
  }

  static Map<String, List<DiscoveryTrack>> _groupByMany(
    List<DiscoveryTrack> tracks,
    List<String> Function(DiscoveryTrack) keysOf,
  ) {
    final result = <String, List<DiscoveryTrack>>{};
    for (final track in tracks) {
      for (final key in keysOf(track)) {
        if (key.isEmpty) continue;
        result.putIfAbsent(key, () => <DiscoveryTrack>[]).add(track);
      }
    }
    return Map<String, List<DiscoveryTrack>>.unmodifiable(result);
  }
}

// ---------------------------------------------------------------------------
// Repository
// ---------------------------------------------------------------------------

/// Reads and indexes the candidate pool.
class RecommendationRepository {
  RecommendationRepository({
    LibraryDatabase? library,
    ListeningHistoryRepository? history,
    ListeningStatisticsRepository? statistics,
  }) : _library = library ?? LibraryDatabase.instance,
       _history = history ?? ListeningHistoryRepository(),
       _statistics = statistics ?? ListeningStatisticsRepository();

  final LibraryDatabase _library;
  final ListeningHistoryRepository _history;
  final ListeningStatisticsRepository _statistics;

  /// Builds the pool.
  ///
  /// [localLimit] / [historyLimit] bound the read on huge libraries; the
  /// defaults are generous (a phone library rarely exceeds them) and the
  /// caller can lower them for a fast first paint.
  Future<DiscoveryCandidatePool> loadPool({
    required DiscoveryLibraryInput input,
    int localLimit = 20000,
    int historyLimit = 4000,
  }) async {
    final signals = await _statistics.signalsByKey(limit: 4000);

    final merged = <String, DiscoveryTrack>{};

    for (final track in await _localTracks(limit: localLimit)) {
      merged[track.key] = track;
    }
    for (final track in await _historyTracks(limit: historyLimit)) {
      // Local rows win: they carry the file path, so Smart Play can go
      // straight to offline playback instead of resolving a stream.
      final existing = merged[track.key];
      if (existing == null) {
        merged[track.key] = track;
      } else if (!existing.isOfflinePlayable && track.isOfflinePlayable) {
        merged[track.key] = track;
      } else {
        // Merge metadata: history rows often have a cover URL the local scan
        // could not extract, and vice versa for genres.
        merged[track.key] = _merge(existing, track);
      }
    }
    for (final track in input.favoriteTracks) {
      final existing = merged[track.key];
      merged[track.key] = existing == null ? track : _merge(existing, track);
    }

    // Mark favorites so the scorer sees explicit love without a second lookup.
    final tracks = <DiscoveryTrack>[];
    for (final entry in merged.entries) {
      var track = entry.value;
      final isFavorite =
          input.favoriteTrackKeys.contains(track.key) ||
          // Statistics rows carry the collection key too; the provider layer
          // passes both namespaces so either matches.
          input.favoriteTrackKeys.contains(_collectionKeyFor(track));
      if (isFavorite && !track.isFavorite) {
        track = track.copyWith(isFavorite: true);
      }
      tracks.add(track);
    }

    final artistPlaylists = <String, Set<String>>{};
    for (final track in tracks) {
      final ids = input.playlistIdsByTrackKey[track.key];
      if (ids == null || ids.isEmpty || track.artistKey.isEmpty) continue;
      final bucket = artistPlaylists.putIfAbsent(
        track.artistKey,
        () => <String>{},
      );
      bucket.addAll(ids);
    }

    return DiscoveryCandidatePool(
      tracks: List<DiscoveryTrack>.unmodifiable(tracks),
      signals: signals,
      favoriteTrackKeys: input.favoriteTrackKeys,
      favoriteArtistKeys: input.favoriteArtistKeys,
      favoriteAlbumKeys: input.favoriteAlbumKeys,
      playlistIdsByTrackKey: input.playlistIdsByTrackKey,
      playlistIdsByArtistKey: Map<String, Set<String>>.unmodifiable(
        artistPlaylists,
      ),
      coListenGraph: const <String, Set<String>>{},
    );
  }

  /// Builds the co-listen graph from the raw event log, bounded to
  /// [lookbackDays] so a long history cannot make a refresh expensive.
  Future<Map<String, Set<String>>> coListenGraph({
    int lookbackDays = 120,
    int maxEvents = 20000,
  }) async {
    final now = DateTime.now();
    final events = await _history.eventsBetween(
      now.subtract(Duration(days: lookbackDays)),
      now,
    );
    final capped = events.length > maxEvents
        ? events.sublist(events.length - maxEvents)
        : events;
    return buildCoListenGraph(
      capped.map(
        (event) => CoListenEvent(
          artistKey: discoveryEntityKey(event.artist),
          at: event.startedAt,
          trackKey: event.trackKey,
        ),
      ),
    );
  }

  /// Artist vectors for the similarity engine, built from the pool.
  List<ArtistVector> artistVectors(
    DiscoveryCandidatePool pool, {
    Map<String, double>? artistAffinity,
    int limit = 800,
  }) {
    final entries = pool.byArtist.entries.toList()
      ..sort((a, b) {
        final byAffinity = (artistAffinity?[b.key] ?? 0).compareTo(
          artistAffinity?[a.key] ?? 0,
        );
        if (byAffinity != 0) return byAffinity;
        return b.value.length.compareTo(a.value.length);
      });

    final vectors = <ArtistVector>[];
    for (final entry in entries) {
      if (vectors.length >= limit) break;
      final tracks = entry.value;
      if (tracks.isEmpty) continue;
      vectors.add(
        ArtistVector.fromTracks(
          entry.key,
          tracks.first.artist,
          tracks,
          signals: pool.signals,
          playlistIds:
              pool.playlistIdsByArtistKey[entry.key] ?? const <String>{},
          coListenedArtists:
              pool.coListenGraph[entry.key] ?? const <String>{},
        ),
      );
    }
    return List<ArtistVector>.unmodifiable(vectors);
  }

  // -------------------------------------------------------------------------
  // Source readers
  // -------------------------------------------------------------------------

  Future<List<DiscoveryTrack>> _localTracks({required int limit}) async {
    final rows = await _library.getAll(limit: limit);
    final tracks = <DiscoveryTrack>[];
    for (final row in rows) {
      final track = localRowToDiscoveryTrack(row);
      if (track != null) tracks.add(track);
    }
    return tracks;
  }

  Future<List<DiscoveryTrack>> _historyTracks({required int limit}) async {
    final aggregates = await _history.allAggregates();
    final capped = aggregates.length > limit
        ? aggregates.sublist(0, limit)
        : aggregates;
    return <DiscoveryTrack>[
      for (final entry in capped)
        DiscoveryTrack(
          key: entry.trackKey,
          title: entry.title,
          artist: entry.artist,
          artistKey: discoveryEntityKey(entry.artist),
          album: entry.album,
          albumKey: entry.album.isEmpty
              ? ''
              : discoveryEntityKey('${entry.album}|${entry.artist}'),
          coverUrl: entry.coverUrl,
          source: DiscoverySource.listeningHistory,
        ),
    ];
  }

  DiscoveryTrack _merge(DiscoveryTrack base, DiscoveryTrack other) {
    final genres = base.genres.isNotEmpty ? base.genres : other.genres;
    final tags = base.tags.isNotEmpty ? base.tags : other.tags;
    final cover = base.coverUrl ?? other.coverUrl;
    final album = base.album.isNotEmpty ? base.album : other.album;
    final albumKey = album == base.album ? base.albumKey : other.albumKey;
    final isFavorite = base.isFavorite || other.isFavorite;
    final localPath = base.localPath ?? other.localPath;
    final providerId = base.providerId ?? other.providerId;
    if (genres == base.genres &&
        tags == base.tags &&
        cover == base.coverUrl &&
        album == base.album &&
        isFavorite == base.isFavorite &&
        localPath == base.localPath &&
        providerId == base.providerId) {
      return base;
    }
    return DiscoveryTrack(
      key: base.key,
      title: base.title.isNotEmpty ? base.title : other.title,
      artist: base.artist.isNotEmpty ? base.artist : other.artist,
      artistKey: base.artistKey.isNotEmpty ? base.artistKey : other.artistKey,
      album: album,
      albumKey: albumKey,
      genres: genres,
      tags: tags,
      coverUrl: cover,
      localPath: localPath,
      providerId: providerId,
      externalId: base.externalId ?? other.externalId,
      isrc: base.isrc ?? other.isrc,
      durationMs: base.durationMs > 0 ? base.durationMs : other.durationMs,
      bpm: base.bpm ?? other.bpm,
      releaseDate: base.releaseDate ?? other.releaseDate,
      isFavorite: isFavorite,
      source: base.source,
    );
  }

  /// Best-effort collection key for a discovery track, mirroring
  /// `trackCollectionKey` in the collections store.
  String _collectionKeyFor(DiscoveryTrack track) {
    final provider = track.providerId?.trim() ?? '';
    final id = track.externalId?.trim() ?? track.key;
    if (provider.isEmpty) return 'builtin:$id';
    return '$provider:$id';
  }
}

// ---------------------------------------------------------------------------
// Row mapping
// ---------------------------------------------------------------------------

/// Maps a `library_visible` row to a [DiscoveryTrack].
///
/// Exposed as a top-level function so tests can pin the mapping without
/// opening SQLite.
DiscoveryTrack? localRowToDiscoveryTrack(Map<String, Object?> row) {
  final title = row['trackName']?.toString() ?? '';
  final artist = row['artistName']?.toString() ?? '';
  if (title.isEmpty && artist.isEmpty) return null;
  final album = row['albumName']?.toString() ?? '';
  final albumArtist = row['albumArtist']?.toString() ?? '';
  final genreRaw = row['genre']?.toString();
  final genres = splitTaxonomy(genreRaw);
  final tags = splitTaxonomy(row['comment']?.toString());
  final durationSeconds = row['duration'];
  final durationMs = durationSeconds is num
      ? (durationSeconds * 1000).round()
      : 0;

  return DiscoveryTrack(
    key: discoveryTrackKey(
      title: title,
      artist: artist,
      isrc: row['isrc']?.toString(),
    ),
    title: title,
    artist: artist,
    artistKey: discoveryEntityKey(artist),
    album: album,
    albumKey: album.isEmpty
        ? ''
        : discoveryEntityKey('$album|${albumArtist.isEmpty ? artist : albumArtist}'),
    genres: genres,
    tags: tags,
    localPath: row['filePath']?.toString(),
    coverUrl: row['coverPath']?.toString(),
    isrc: row['isrc']?.toString(),
    durationMs: durationMs,
    bpm: parseBpmToken(genreRaw) ?? parseBpmToken(row['comment']?.toString()),
    releaseDate: parseReleaseDate(row['releaseDate']?.toString()),
    source: DiscoverySource.localLibrary,
  );
}

/// Extracts a tempo from a free-form tag string (`"128bpm"`, `"128 BPM"`).
///
/// Returns null when the string carries no tempo — the mood engine then falls
/// back to genre/tag evidence and the UI says so. No tempo is ever invented.
int? parseBpmToken(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  final match = RegExp(r'(?<![0-9])([4-9][0-9]|1[0-9]{2}|2[0-4][0-9])\s*bpm',
          caseSensitive: false)
      .firstMatch(value);
  if (match == null) return null;
  final parsed = int.tryParse(match.group(1) ?? '');
  if (parsed == null) return null;
  if (parsed < 40 || parsed > 240) return null;
  return parsed;
}

/// Parses the loose date formats tag readers produce (`2021`, `2021-04`,
/// `2021-04-17`, `17/04/2021`). Null when unparseable.
DateTime? parseReleaseDate(String? raw) {
  final value = raw?.trim() ?? '';
  if (value.isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed != null) return parsed;

  final yearOnly = RegExp(r'^(\d{4})$').firstMatch(value);
  if (yearOnly != null) {
    final year = int.tryParse(yearOnly.group(1) ?? '');
    if (year == null || year < 1900 || year > 2200) return null;
    return DateTime.utc(year);
  }
  final yearMonth = RegExp(r'^(\d{4})[-/.](\d{1,2})').firstMatch(value);
  if (yearMonth != null) {
    final year = int.tryParse(yearMonth.group(1) ?? '');
    final month = int.tryParse(yearMonth.group(2) ?? '');
    if (year == null || month == null) return null;
    if (year < 1900 || year > 2200 || month < 1 || month > 12) return null;
    return DateTime.utc(year, month);
  }
  final dayFirst = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})$').firstMatch(
    value,
  );
  if (dayFirst != null) {
    final day = int.tryParse(dayFirst.group(1) ?? '');
    final month = int.tryParse(dayFirst.group(2) ?? '');
    final year = int.tryParse(dayFirst.group(3) ?? '');
    if (day == null || month == null || year == null) return null;
    if (year < 1900 || year > 2200) return null;
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime.utc(year, month, day);
  }
  return null;
}

/// Maps a collections `Track` to a [DiscoveryTrack] (used by the provider layer
/// for loved tracks and playlist members). Kept here so the mapping rules live
/// in one file; importing `models/track.dart` from `engine/` would break the
/// Flutter-free rule that layer enforces.
DiscoveryTrack discoveryTrackFrom({
  required String id,
  required String name,
  required String artistName,
  required String albumName,
  String? coverUrl,
  String? isrc,
  int durationSeconds = 0,
  String? genre,
  String? comment,
  String? releaseDate,
  String? providerId,
  bool isFavorite = false,
  String? localPath,
}) {
  return DiscoveryTrack(
    key: discoveryTrackKey(title: name, artist: artistName, isrc: isrc),
    title: name,
    artist: artistName,
    artistKey: discoveryEntityKey(artistName),
    album: albumName,
    albumKey: albumName.isEmpty
        ? ''
        : discoveryEntityKey('$albumName|$artistName'),
    genres: splitTaxonomy(genre),
    tags: splitTaxonomy(comment),
    coverUrl: coverUrl,
    localPath: localPath,
    providerId: providerId,
    externalId: id,
    isrc: isrc,
    durationMs: durationSeconds * 1000,
    bpm: parseBpmToken(genre) ?? parseBpmToken(comment),
    releaseDate: parseReleaseDate(releaseDate),
    isFavorite: isFavorite,
    source: localPath == null
        ? DiscoverySource.favorites
        : DiscoverySource.localLibrary,
  );
}
