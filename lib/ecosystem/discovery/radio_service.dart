/// Radio mode service (Phase 7 orchestration).
///
/// Wraps the pure [RadioEngine] with the two things it deliberately does not
/// know about: where candidates come from ([RadioPoolSource]) and where station
/// state lives (`ds_radio_sessions`). The split keeps the generation logic
/// unit-testable while the service stays a thin, honest adapter.
///
/// Stations resume across app restarts: the queue, the played ring and the
/// adapted affinities are all serialised, so reopening a station continues it
/// rather than restarting it.
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_schema.dart';
import 'package:spotiflac_android/ecosystem/discovery/recommendation_repository.dart';
import 'package:spotiflac_android/ecosystem/ecosystem_database.dart';
import 'package:spotiflac_android/engine/discovery/discovery_math.dart';
import 'package:spotiflac_android/engine/discovery/discovery_models.dart';
import 'package:spotiflac_android/engine/discovery/mood_engine.dart';
import 'package:spotiflac_android/engine/discovery/radio_engine.dart';
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('DiscoveryRadio');

/// Where the radio pulls candidates from. Implemented by the provider layer so
/// the service never reaches into SQLite or Riverpod directly.
abstract interface class RadioPoolSource {
  /// The current candidate pool. Implementations should cache this; the radio
  /// asks once per refill, not once per track.
  Future<DiscoveryCandidatePool> loadPool();
}

/// A station as listed on the home screen (no queue payload).
class RadioStationSummary {
  const RadioStationSummary({
    required this.sessionId,
    required this.kind,
    required this.seedKey,
    required this.label,
    required this.startedAt,
    required this.lastActiveAt,
    this.playCount = 0,
    this.skipCount = 0,
    this.queueLength = 0,
    this.coverUrl,
    this.isOpen = true,
  });

  final String sessionId;
  final RadioKind kind;
  final String seedKey;
  final String label;
  final DateTime startedAt;
  final DateTime lastActiveAt;
  final int playCount;
  final int skipCount;
  final int queueLength;
  final String? coverUrl;
  final bool isOpen;
}

/// Owns radio sessions.
class RadioService {
  RadioService({
    required this.poolSource,
    RadioEngine? engine,
    EcosystemDatabase? database,
    this.sessionIdPrefix = 'radio',
  }) : _engine = engine ?? const RadioEngine(),
       _database = database ?? EcosystemDatabase.instance;

  final RadioPoolSource poolSource;
  final RadioEngine _engine;
  final EcosystemDatabase _database;
  final String sessionIdPrefix;

  DiscoveryCandidatePool? _cachedPool;
  DateTime _cachedPoolAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// Pool cache lifetime. Radio refills happen every few tracks; rebuilding
  /// the pool each time would dominate the cost.
  static const Duration poolCacheTtl = Duration(minutes: 5);

  // -------------------------------------------------------------------------
  // Starting stations
  // -------------------------------------------------------------------------

  Future<RadioState> startArtistRadio({
    required String artistKey,
    required String label,
  }) async {
    final pool = await _pool();
    final tracks = pool.tracksByArtist(artistKey);
    final genres = <String, double>{};
    String? cover;
    for (final track in tracks) {
      for (final genre in track.genres) {
        genres[genre] = (genres[genre] ?? 0) + 1;
      }
      cover ??= track.coverUrl;
    }
    return _start(
      RadioSeed(
        kind: RadioKind.artist,
        key: artistKey,
        label: label,
        genres: Map<String, double>.unmodifiable(peakNormalise(genres)),
        artistKeys: <String>{artistKey},
        coverUrl: cover,
      ),
      pool,
    );
  }

  Future<RadioState> startTrackRadio({required String trackKey}) async {
    final pool = await _pool();
    final track = pool.track(trackKey);
    if (track == null) {
      throw ArgumentError.value(trackKey, 'trackKey', 'not in the candidate pool');
    }
    return _start(
      RadioSeed(
        kind: RadioKind.track,
        key: trackKey,
        label: track.title,
        genres: <String, double>{
          for (final genre in track.genres) genre: 1.0,
        },
        artistKeys: track.artistKey.isEmpty
            ? const <String>{}
            : <String>{track.artistKey},
        trackKeys: <String>{trackKey},
        targetBpm: track.bpm,
        coverUrl: track.coverUrl,
      ),
      pool,
    );
  }

  Future<RadioState> startGenreRadio({
    required String genre,
    String? label,
  }) async {
    final pool = await _pool();
    final key = discoveryKey(genre);
    // Include the genre's closest neighbours so the station has room to move:
    // a pure single-genre radio runs dry fast on a small library.
    final weights = <String, double>{key: 1.0};
    for (final track in pool.tracksInGenres(<String>[key]).take(40)) {
      for (final neighbour in track.genres) {
        if (neighbour == key) continue;
        weights[neighbour] = (weights[neighbour] ?? 0) + 0.35;
      }
    }
    return _start(
      RadioSeed(
        kind: RadioKind.genre,
        key: key,
        label: label ?? titleCaseGenre(genre),
        genres: Map<String, double>.unmodifiable(peakNormalise(weights)),
        coverUrl: pool.tracksInGenres(<String>[key]).isEmpty
            ? null
            : pool.tracksInGenres(<String>[key]).first.coverUrl,
      ),
      pool,
    );
  }

  Future<RadioState> startMoodRadio({required Mood mood}) async {
    final pool = await _pool();
    final profile = moodProfiles[mood]!;
    final genres = <String, double>{
      for (final genre in profile.genres) genre: 1.0,
    };
    return _start(
      RadioSeed(
        kind: RadioKind.mood,
        key: mood.name,
        label: profile.label,
        genres: Map<String, double>.unmodifiable(genres),
        targetBpm: (profile.bpmMin + profile.bpmMax) ~/ 2,
      ),
      pool,
    );
  }

  Future<RadioState> _start(RadioSeed seed, DiscoveryCandidatePool pool) async {
    final now = DateTime.now();
    final sessionId = '$sessionIdPrefix-${now.microsecondsSinceEpoch}';
    final state = _engine.start(
      sessionId: sessionId,
      seed: seed,
      pool: pool.tracks,
      signals: pool.signals,
      now: now,
    );
    await persist(state);
    _log.i('Started ${seed.kind.name} radio "${seed.label}"');
    return state;
  }

  // -------------------------------------------------------------------------
  // Running a station
  // -------------------------------------------------------------------------

  /// Tops the queue up when it runs low. Safe to call on every track advance.
  Future<RadioState> ensureQueue(RadioState state) async {
    if (!_engine.needsRefill(state)) return state;
    final pool = await _pool();
    final next = _engine.refill(
      state,
      pool: pool.tracks,
      signals: pool.signals,
      now: DateTime.now(),
    );
    await persist(next);
    return next;
  }

  /// Records a play or skip. The caller passes the outcome; the engine adapts.
  Future<RadioState> noteOutcome(
    RadioState state,
    String trackKey, {
    required bool skipped,
  }) async {
    final pool = await _pool();
    final next = _engine.consume(
      state,
      trackKey,
      skipped: skipped,
      signals: pool.signals,
    );
    await persist(next);
    return next;
  }

  /// Restores a station, refilling its queue if it ran dry while closed.
  Future<RadioState?> resume(String sessionId) async {
    final db = await _database.database;
    final rows = await db.query(
      dsRadioSessions,
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final state = RadioState.fromJson(
      _decodeObject(rows.first['state_json']?.toString()),
    );
    if (state == null) return null;
    return ensureQueue(state);
  }

  /// Stations for the "Radio Stations" home shelf: the open ones first, then
  /// the most recently played closed ones.
  Future<List<RadioStationSummary>> stations({int limit = 10}) async {
    final db = await _database.database;
    final rows = await db.query(
      dsRadioSessions,
      orderBy: 'closed ASC, last_active_at DESC',
      limit: limit,
    );
    final summaries = <RadioStationSummary>[];
    for (final row in rows) {
      final summary = _summaryFromRow(row);
      if (summary != null) summaries.add(summary);
    }
    return List<RadioStationSummary>.unmodifiable(summaries);
  }

  Future<void> close(String sessionId) async {
    final db = await _database.database;
    await db.update(
      dsRadioSessions,
      <String, Object?>{'closed': 1},
      where: 'session_id = ?',
      whereArgs: <Object?>[sessionId],
    );
  }

  /// Persists [state]. Called after every transition so a crash never loses
  /// more than the current track.
  Future<void> persist(RadioState state) async {
    final db = await _database.database;
    final now = DateTime.now().toUtc().toIso8601String();
    await db.insert(
      dsRadioSessions,
      <String, Object?>{
        'session_id': state.sessionId,
        'kind': state.seed.kind.name,
        'seed_key': state.seed.key,
        'seed_label': state.seed.label,
        'state_json': jsonEncode(state.toJson()),
        'started_at': state.startedAt.toUtc().toIso8601String(),
        'last_active_at': now,
        'play_count': state.playCount,
        'skip_count': state.skipCount,
        'queue_length': state.queue.length,
        'closed': 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Drops finished stations older than [keepDays]. Bounded growth: a heavy
  /// radio user would otherwise accumulate thousands of rows.
  Future<int> pruneClosedSessions({int keepDays = 30}) async {
    final db = await _database.database;
    final cutoff = DateTime.now()
        .toUtc()
        .subtract(Duration(days: keepDays))
        .toIso8601String();
    return db.delete(
      dsRadioSessions,
      where: 'closed = 1 AND last_active_at < ?',
      whereArgs: <Object?>[cutoff],
    );
  }

  Future<void> clear() async {
    final db = await _database.database;
    await db.delete(dsRadioSessions);
  }

  /// Drops the cached pool — called when the library or history changes.
  void invalidatePool() {
    _cachedPool = null;
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  Future<DiscoveryCandidatePool> _pool() async {
    final cached = _cachedPool;
    if (cached != null &&
        DateTime.now().difference(_cachedPoolAt) < poolCacheTtl) {
      return cached;
    }
    final pool = await poolSource.loadPool();
    _cachedPool = pool;
    _cachedPoolAt = DateTime.now();
    return pool;
  }

  RadioStationSummary? _summaryFromRow(Map<String, Object?> row) {
    final sessionId = row['session_id']?.toString() ?? '';
    if (sessionId.isEmpty) return null;
    RadioKind kind = RadioKind.artist;
    for (final value in RadioKind.values) {
      if (value.name == row['kind']?.toString()) {
        kind = value;
        break;
      }
    }
    int asInt(String key) {
      final value = row[key];
      return value is num ? value.toInt() : 0;
    }

    final seed = RadioSeed.fromJson(
      _decodeObject(row['state_json']?.toString())?['seed'],
    );
    return RadioStationSummary(
      sessionId: sessionId,
      kind: kind,
      seedKey: row['seed_key']?.toString() ?? '',
      label: row['seed_label']?.toString() ?? '',
      startedAt:
          DateTime.tryParse(row['started_at']?.toString() ?? '') ??
          DateTime.now(),
      lastActiveAt:
          DateTime.tryParse(row['last_active_at']?.toString() ?? '') ??
          DateTime.now(),
      playCount: asInt('play_count'),
      skipCount: asInt('skip_count'),
      queueLength: asInt('queue_length'),
      coverUrl: seed?.coverUrl,
      isOpen: asInt('closed') == 0,
    );
  }

  Map<String, Object?>? _decodeObject(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return null;
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map) return null;
      return Map<String, Object?>.from(decoded);
    } on FormatException {
      return null;
    }
  }
}

/// Display form of a normalised genre token (`"indie rock"` → `"Indie Rock"`).
String titleCaseGenre(String genre) {
  final key = discoveryKey(genre);
  if (key.isEmpty) return genre;
  return key
      .split(' ')
      .map((word) => word.isEmpty ? word : word[0].toUpperCase() + word.substring(1))
      .join(' ');
}
