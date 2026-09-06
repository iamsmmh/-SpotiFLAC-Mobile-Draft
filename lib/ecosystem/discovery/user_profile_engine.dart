/// User listening profile engine (Phase 1).
///
/// Two pieces with different responsibilities:
///
///   * [UserProfileEngine] — **pure**. Takes the rolled-up statistics, the
///     candidate metadata and the habits aggregate, and returns a
///     [ListeningProfile]. No clock, no I/O: unit-testable in isolation.
///   * [UserProfileRepository] — persistence. One row in `ds_user_profiles`,
///     written atomically, read back on cold start so the first paint of the
///     discovery home does not wait for a rebuild.
///
/// Affinity model: for every axis (track / artist / album / genre / tag) the
/// weight is
///
///     Σ  decay(lastPlayedAt) × log1p(playCount) × completionQuality
///        − skipPenalty   + favoriteBonus
///
/// then peak-normalised to `0..1`. Decay is what makes the profile a picture
/// of *current* taste rather than an all-time chart; the skip penalty is what
/// stops a skipped-once-then-never-again track from counting as love.
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_schema.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';

/// The single profile the app maintains. The column exists so a future
/// multi-account setup can add rows without a migration.
const String defaultProfileId = 'default';

/// Bumped when the affinity maths changes, so a stale cached profile is
/// rebuilt instead of being served with the old balance.
const int userProfileSchemaVersion = 1;

/// How much a skipped play subtracts from an axis weight.
const double _skipPenalty = 0.35;

/// Bonus added for an explicit favorite.
const double _favoriteBonus = 1.2;

/// Pure profile builder.
class UserProfileEngine {
  const UserProfileEngine({
    this.decayHalfLife = const Duration(days: 30),
    this.frequencyReferencePlays = 24,
    this.maxEntriesPerAxis = 120,
    this.maxGenreTokens = 200,
    this.maxTagTokens = 200,
  });

  final Duration decayHalfLife;
  final int frequencyReferencePlays;

  /// Cap per axis. 120 entries cover every taste the recommenders actually
  /// read while keeping the serialised profile well under a few hundred KB.
  final int maxEntriesPerAxis;
  final int maxGenreTokens;
  final int maxTagTokens;

  /// Builds the profile.
  ///
  /// [signals] are the rolled-up per-track statistics; [metadata] maps a track
  /// key to its [DiscoveryTrack] so genres/tags/album can be attributed. Tracks
  /// with statistics but no metadata still contribute to the track axis — they
  /// simply have no taxonomy.
  ListeningProfile build({
    required Iterable<TrackSignals> signals,
    required Map<String, DiscoveryTrack> metadata,
    required ListeningHabits habits,
    required DateTime now,
    Set<String> favoriteTrackKeys = const <String>{},
    Set<String> favoriteArtistKeys = const <String>{},
    Set<String> favoriteAlbumKeys = const <String>{},
  }) {
    final trackWeights = <String, _Axis>{};
    final artistWeights = <String, _Axis>{};
    final albumWeights = <String, _Axis>{};
    final genreWeights = <String, _Axis>{};
    final tagWeights = <String, _Axis>{};

    for (final signal in signals) {
      if (signal.trackKey.isEmpty) continue;
      final track = metadata[signal.trackKey];
      final isFavoriteTrack =
          signal.isFavorite || favoriteTrackKeys.contains(signal.trackKey);

      final weight = _axisWeight(
        signal,
        now: now,
        isFavorite: isFavoriteTrack,
      );
      if (weight <= 0 && signal.playCount == 0) continue;

      _bump(
        trackWeights,
        signal.trackKey,
        signal.title,
        weight,
        signal,
        isFavorite: isFavoriteTrack,
      );

      final artistLabel = track?.artist ?? signal.artist;
      final artistKey = artistLabel.trim().isEmpty
          ? ''
          : (track?.artistKey.isNotEmpty == true
                ? track!.artistKey
                : discoveryEntityKey(artistLabel));
      if (artistKey.isNotEmpty) {
        final isFavoriteArtist = favoriteArtistKeys.contains(artistKey);
        _bump(
          artistWeights,
          artistKey,
          artistLabel,
          weight,
          signal,
          isFavorite: isFavoriteArtist || isFavoriteTrack,
        );
      }

      final albumLabel = track?.album ?? signal.album;
      final albumKey = albumLabel.trim().isEmpty
          ? ''
          : (track?.albumKey.isNotEmpty == true
                ? track!.albumKey
                : discoveryEntityKey('$albumLabel|$artistLabel'));
      if (albumKey.isNotEmpty) {
        final isFavoriteAlbum = favoriteAlbumKeys.contains(albumKey);
        _bump(
          albumWeights,
          albumKey,
          albumLabel,
          weight,
          signal,
          isFavorite: isFavoriteAlbum || isFavoriteTrack,
        );
      }

      final genres = track?.genres ?? const <String>[];
      for (final genre in genres) {
        if (genreWeights.length >= maxGenreTokens &&
            !genreWeights.containsKey(genre)) {
          continue;
        }
        _bump(genreWeights, genre, genre, weight, signal);
      }
      final tags = track?.tags ?? const <String>[];
      for (final tag in tags) {
        if (tagWeights.length >= maxTagTokens &&
            !tagWeights.containsKey(tag)) {
          continue;
        }
        _bump(tagWeights, tag, tag, weight, signal);
      }
    }

    return ListeningProfile(
      generatedAt: now,
      tracks: _entries(trackWeights, now, limit: maxEntriesPerAxis),
      artists: _entries(artistWeights, now, limit: maxEntriesPerAxis),
      albums: _entries(albumWeights, now, limit: maxEntriesPerAxis),
      genres: _entries(genreWeights, now, limit: maxEntriesPerAxis),
      tags: _entries(tagWeights, now, limit: maxEntriesPerAxis),
      habits: habits,
    );
  }

  /// Decayed, quality-weighted axis weight for one signal.
  double _axisWeight(
    TrackSignals signal, {
    required DateTime now,
    required bool isFavorite,
  }) {
    final plays = signal.playCount;
    if (plays <= 0 && !isFavorite) return 0;

    final decay = timeDecay(signal.lastPlayedAt, now, halfLife: decayHalfLife);
    final frequency = logScaledCount(
      math.max(plays, 1),
      reference: frequencyReferencePlays,
    );
    // Completion quality: a track always skipped earns a third of a track
    // always finished. Never zero, so it can still be recovered by a penalty.
    final quality = 0.35 + 0.65 * signal.averageCompletion;

    var weight = (0.4 + 0.6 * decay) * frequency * quality;
    weight -= signal.skipRate * _skipPenalty * frequency;
    if (isFavorite) weight += _favoriteBonus * (0.4 + 0.6 * decay);
    return weight < 0 ? 0 : weight;
  }

  void _bump(
    Map<String, _Axis> target,
    String key,
    String label,
    double weight,
    TrackSignals signal, {
    bool isFavorite = false,
  }) {
    final axis = target.putIfAbsent(
      key,
      () => _Axis(key: key, label: label.isEmpty ? key : label),
    );
    axis.weight += weight;
    axis.playCount += signal.playCount;
    axis.skipCount += signal.skipCount;
    axis.listenedMs += signal.listenedMs;
    axis.completedCount += signal.completedCount;
    axis.completionSum += signal.completionSum;
    if (isFavorite) axis.isFavorite = true;
    if (label.isNotEmpty && axis.label == key) axis.label = label;
    if (signal.lastPlayedAt.isAfter(axis.lastPlayedAt)) {
      axis.lastPlayedAt = signal.lastPlayedAt;
    }
  }

  /// Peak-normalises and sorts one axis.
  List<TasteEntry> _entries(
    Map<String, _Axis> axes,
    DateTime now, {
    required int limit,
  }) {
    if (axes.isEmpty) return const <TasteEntry>[];
    final ranked = axes.values.toList()
      ..sort((a, b) {
        final byWeight = b.weight.compareTo(a.weight);
        if (byWeight != 0) return byWeight;
        return a.key.compareTo(b.key);
      });
    final peak = ranked.first.weight;
    final entries = <TasteEntry>[];
    for (final axis in ranked) {
      if (entries.length >= limit) break;
      if (axis.weight <= 0) continue;
      entries.add(
        TasteEntry(
          key: axis.key,
          label: axis.label,
          affinity: peak <= 0 ? 0 : (axis.weight / peak).clamp(0.0, 1.0),
          playCount: axis.playCount,
          listenedMs: axis.listenedMs,
          skipRate: axis.playCount <= 0
              ? 0
              : (axis.skipCount / axis.playCount).clamp(0.0, 1.0),
          averageCompletion: axis.playCount <= 0
              ? 0
              : (axis.completionSum / axis.playCount).clamp(0.0, 1.0),
          isFavorite: axis.isFavorite,
          lastPlayedAt: axis.lastPlayedAt == _epoch ? now : axis.lastPlayedAt,
        ),
      );
    }
    return List<TasteEntry>.unmodifiable(entries);
  }
}

final DateTime _epoch = DateTime.utc(1970);

/// Mutable accumulator used while folding signals into an axis.
class _Axis {
  _Axis({required this.key, required this.label}) : lastPlayedAt = _epoch;

  final String key;
  String label;
  double weight = 0;
  int playCount = 0;
  int skipCount = 0;
  int completedCount = 0;
  double completionSum = 0;
  int listenedMs = 0;
  bool isFavorite = false;
  DateTime lastPlayedAt;
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

/// Reads/writes the single profile row.
class UserProfileRepository {
  UserProfileRepository({EcosystemDatabase? database, this.profileId = defaultProfileId})
    : _database = database ?? EcosystemDatabase.instance;

  final EcosystemDatabase _database;
  final String profileId;

  Future<ListeningProfile?> load() async {
    final db = await _database.database;
    final rows = await db.query(
      dsUserProfiles,
      where: 'profile_id = ?',
      whereArgs: <Object?>[profileId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final version = row['schema_version'];
    if (version is num && version.toInt() != userProfileSchemaVersion) {
      // Maths changed since this row was written: rebuild rather than serve a
      // profile balanced by an older algorithm.
      return null;
    }
    return ListeningProfile.fromJson(<String, Object?>{
      'generatedAt': row['generated_at']?.toString(),
      'tracks': _decode(row['tracks_json']),
      'artists': _decode(row['artists_json']),
      'albums': _decode(row['albums_json']),
      'genres': _decode(row['genres_json']),
      'tags': _decode(row['tags_json']),
      'habits': _decode(row['habits_json']),
    });
  }

  Future<void> save(ListeningProfile profile) async {
    final db = await _database.database;
    final encoded = profile.toJson();
    await db.insert(
      dsUserProfiles,
      <String, Object?>{
        'profile_id': profileId,
        'generated_at': (profile.generatedAt ?? DateTime.now())
            .toUtc()
            .toIso8601String(),
        'schema_version': userProfileSchemaVersion,
        'totals_json': _encode(<String, Object?>{
          'plays': profile.habits.totalPlays,
          'listenedMs': profile.habits.totalListenedMs,
          'activeDays': profile.habits.activeDays,
        }),
        'habits_json': _encode(encoded['habits']),
        'tracks_json': _encode(encoded['tracks']),
        'artists_json': _encode(encoded['artists']),
        'albums_json': _encode(encoded['albums']),
        'genres_json': _encode(encoded['genres']),
        'tags_json': _encode(encoded['tags']),
        'track_count': profile.tracks.length,
        'artist_count': profile.artists.length,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(
      dsUserProfiles,
      where: 'profile_id = ?',
      whereArgs: <Object?>[profileId],
    );
  }

  String _encode(Object? value) => jsonEncode(value);

  /// Tolerant decode: a truncated or hand-edited column must yield "no data",
  /// never throw during startup.
  Object? _decode(Object? raw) {
    final value = raw?.toString().trim() ?? '';
    if (value.isEmpty) return null;
    try {
      return jsonDecode(value);
    } on FormatException {
      return null;
    }
  }
}
