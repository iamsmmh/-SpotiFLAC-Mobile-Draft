/// SQLite persistence for the SpotiFLAC **ecosystem** features.
///
/// Deliberately separate from the four pre-existing stores
/// (`app_state.db`, `library.db`, `collections.db`, `history.db`): every table
/// here is new, so adding them can never migrate, lock or corrupt data the
/// downloader, player, library or extension subsystems already own.
///
/// Schema contract:
///   * every table is created idempotently (`IF NOT EXISTS`) so a partially
///     applied migration can resume;
///   * every statement is exposed as data ([ecosystemMigrations]) so the
///     migration engine, the docs generator and the tests all read one source
///     of truth;
///   * timestamps are ISO-8601 UTC strings, booleans are 0/1 integers — the
///     same conventions as the rest of the app.
library;

import 'package:sqflite/sqflite.dart';
import 'package:spotiflac_android/ecosystem/discovery/discovery_schema.dart';
import 'package:spotiflac_android/services/sqlite_helpers.dart' as sqlite;
import 'package:spotiflac_android/utils/logger.dart';

final _log = AppLogger('EcosystemDb');

const String ecosystemDbFileName = 'ecosystem.db';

/// Current schema version. Bump together with a new [EcosystemMigration].
const int ecosystemDatabaseVersion = 6;

// ---------------------------------------------------------------------------
// Table names
// ---------------------------------------------------------------------------

const String tableListeningEvents = 'ec_listening_events';
const String tableTrackHistory = 'ec_track_history';
const String tableFavoritePlaylists = 'ec_favorite_playlists';
const String tableStreamCache = 'ec_stream_cache';
const String tablePodcastSubscriptions = 'ec_podcast_subscriptions';
const String tablePodcastEpisodes = 'ec_podcast_episodes';
const String tableRecognitionHistory = 'ec_recognition_history';
const String tableOfflineCollections = 'ec_offline_collections';
const String tableSmartPlaylistState = 'ec_smart_playlist_state';
const String tableSocialCache = 'ec_social_cache';
const String tableAccountState = 'ec_account_state';
const String tableSyncTombstones = 'ec_sync_tombstones';
const String tableEcosystemMeta = 'ec_meta';

/// One idempotent forward step of the ecosystem schema.
///
/// Kept as pure data (a list of SQL statements) so it can be validated in unit
/// tests without opening a database, and printed verbatim into
/// `docs/MIGRATIONS.md` by `tool/generate_schema_doc.dart`.
class EcosystemMigration {
  const EcosystemMigration({
    required this.fromVersion,
    required this.toVersion,
    required this.statements,
    this.description = '',
  });

  final int fromVersion;
  final int toVersion;
  final List<String> statements;
  final String description;

  Future<void> apply(DatabaseExecutor db) async {
    for (final statement in statements) {
      try {
        await db.execute(statement);
      } on DatabaseException catch (error) {
        // Additive migrations must tolerate re-application: schema v1
        // already ships every "later" column to fresh installs, so the
        // 1→2/2→3/… `ALTER TABLE … ADD COLUMN` steps are no-ops there and
        // SQLite answers "duplicate column name". Skipping exactly that
        // case keeps a partially applied migration resumable (the stated
        // contract) without masking unrelated DDL failures.
        if (!error.isDuplicateColumnError(error.toString())) {
          rethrow;
        }
      }
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'from': fromVersion,
    'to': toVersion,
    'description': description,
    'statements': statements,
  };
}

/// Schema v1 — the whole ecosystem surface in one shot (fresh installs).
const List<String> ecosystemSchemaV1 = <String>[
  // ---- Listening history (Feature Group 4) -------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $tableListeningEvents (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    track_key TEXT NOT NULL,
    title TEXT NOT NULL,
    artist TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    cover_url TEXT,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    played_ms INTEGER NOT NULL DEFAULT 0,
    completed INTEGER NOT NULL DEFAULT 0,
    skipped INTEGER NOT NULL DEFAULT 0,
    source TEXT NOT NULL DEFAULT 'unknown',
    started_at TEXT NOT NULL,
    ended_at TEXT
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${tableListeningEvents}_started '
      'ON $tableListeningEvents(started_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_${tableListeningEvents}_track '
      'ON $tableListeningEvents(track_key)',
  '''
  CREATE TABLE IF NOT EXISTS $tableTrackHistory (
    track_key TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    artist TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    cover_url TEXT,
    play_count INTEGER NOT NULL DEFAULT 0,
    skip_count INTEGER NOT NULL DEFAULT 0,
    total_played_ms INTEGER NOT NULL DEFAULT 0,
    completion_sum REAL NOT NULL DEFAULT 0,
    completion_count INTEGER NOT NULL DEFAULT 0,
    first_played_at TEXT NOT NULL,
    last_played_at TEXT NOT NULL
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${tableTrackHistory}_last '
      'ON $tableTrackHistory(last_played_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_${tableTrackHistory}_plays '
      'ON $tableTrackHistory(play_count DESC)',

  // ---- Favorites: playlists (Feature Group 3) ----------------------------
  // Songs / albums / artists keep living in `collections.db` (owned by the
  // pre-existing favorites UI); only the *new* kind needs a table.
  '''
  CREATE TABLE IF NOT EXISTS $tableFavoritePlaylists (
    playlist_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    cover_path TEXT,
    track_count INTEGER NOT NULL DEFAULT 0,
    added_at TEXT NOT NULL
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${tableFavoritePlaylists}_added '
      'ON $tableFavoritePlaylists(added_at DESC)',

  // ---- Streaming cache (Feature Group 7) ---------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $tableStreamCache (
    cache_key TEXT PRIMARY KEY,
    track_key TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    artist TEXT NOT NULL DEFAULT '',
    file_name TEXT NOT NULL,
    audio_format TEXT NOT NULL DEFAULT 'unknown',
    bytes INTEGER NOT NULL DEFAULT 0,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    source_url TEXT,
    created_at TEXT NOT NULL,
    last_accessed_at TEXT NOT NULL,
    access_count INTEGER NOT NULL DEFAULT 0,
    pinned INTEGER NOT NULL DEFAULT 0,
    complete INTEGER NOT NULL DEFAULT 0
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${tableStreamCache}_lru '
      'ON $tableStreamCache(last_accessed_at ASC)',
  'CREATE INDEX IF NOT EXISTS idx_${tableStreamCache}_track '
      'ON $tableStreamCache(track_key)',

  // ---- Podcasts (Feature Group 9) ----------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $tablePodcastSubscriptions (
    feed_url TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    author TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    image_url TEXT,
    categories TEXT NOT NULL DEFAULT '',
    added_at TEXT NOT NULL,
    last_checked_at TEXT,
    auto_download INTEGER NOT NULL DEFAULT 0,
    keep_episodes INTEGER NOT NULL DEFAULT 3,
    notify_new INTEGER NOT NULL DEFAULT 1
  )
  ''',
  '''
  CREATE TABLE IF NOT EXISTS $tablePodcastEpisodes (
    episode_key TEXT PRIMARY KEY,
    feed_url TEXT NOT NULL,
    guid TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT NOT NULL DEFAULT '',
    audio_url TEXT NOT NULL,
    image_url TEXT,
    duration_seconds INTEGER NOT NULL DEFAULT 0,
    published_at TEXT,
    file_path TEXT,
    played_seconds INTEGER NOT NULL DEFAULT 0,
    is_played INTEGER NOT NULL DEFAULT 0,
    download_state TEXT NOT NULL DEFAULT 'none',
    added_at TEXT NOT NULL
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${tablePodcastEpisodes}_feed '
      'ON $tablePodcastEpisodes(feed_url, published_at DESC)',
  'CREATE INDEX IF NOT EXISTS idx_${tablePodcastEpisodes}_played '
      'ON $tablePodcastEpisodes(is_played)',

  // ---- Music identification (Feature Group 10) ---------------------------
  '''
  CREATE TABLE IF NOT EXISTS $tableRecognitionHistory (
    result_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    artist TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    provider_id TEXT NOT NULL DEFAULT '',
    confidence REAL NOT NULL DEFAULT 0,
    identified_at TEXT NOT NULL,
    payload_json TEXT NOT NULL DEFAULT '{}'
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${tableRecognitionHistory}_time '
      'ON $tableRecognitionHistory(identified_at DESC)',

  // ---- Smart offline mode (Feature Group 8) ------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $tableOfflineCollections (
    collection_key TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    track_count INTEGER NOT NULL DEFAULT 0,
    auto_sync INTEGER NOT NULL DEFAULT 1,
    wifi_only INTEGER NOT NULL DEFAULT 1,
    last_synced_at TEXT,
    added_at TEXT NOT NULL
  )
  ''',

  // ---- Smart playlists (Feature Group 6) ---------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $tableSmartPlaylistState (
    playlist_id TEXT PRIMARY KEY,
    definition_json TEXT NOT NULL,
    last_materialized_at TEXT,
    last_track_count INTEGER NOT NULL DEFAULT 0
  )
  ''',

  // ---- Social cache (Feature Group 11) -----------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $tableSocialCache (
    cache_key TEXT PRIMARY KEY,
    payload_json TEXT NOT NULL,
    updated_at TEXT NOT NULL
  )
  ''',

  // ---- Account session mirror (Feature Group 1) --------------------------
  // Tokens live in the platform secure store; this row only caches the
  // non-secret profile so the UI can render before the keystore unlocks.
  '''
  CREATE TABLE IF NOT EXISTS $tableAccountState (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    provider_id TEXT NOT NULL DEFAULT '',
    user_id TEXT NOT NULL DEFAULT '',
    email TEXT NOT NULL DEFAULT '',
    display_name TEXT NOT NULL DEFAULT '',
    avatar_url TEXT,
    is_guest INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL
  )
  ''',

  // ---- Sync bookkeeping (Feature Group 2) --------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $tableSyncTombstones (
    scope TEXT NOT NULL,
    record_id TEXT NOT NULL,
    deleted_at TEXT NOT NULL,
    PRIMARY KEY (scope, record_id)
  )
  ''',

  // ---- Key/value metadata -------------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $tableEcosystemMeta (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )
  ''',
];

/// Forward migrations. `fromVersion` is the version being upgraded *from*.
const List<EcosystemMigration> ecosystemMigrations = <EcosystemMigration>[
  EcosystemMigration(
    fromVersion: 0,
    toVersion: 1,
    description: 'Initial ecosystem schema (history, favorites, cache, '
        'podcasts, recognition, offline, smart playlists, social, account).',
    statements: ecosystemSchemaV1,
  ),
  EcosystemMigration(
    fromVersion: 1,
    toVersion: 2,
    description: 'Adds episode playback progress + download bookkeeping to '
        'the podcast tables and a completion index to listening events.',
    statements: <String>[
      'ALTER TABLE $tablePodcastEpisodes ADD COLUMN played_seconds INTEGER '
          'NOT NULL DEFAULT 0',
      'ALTER TABLE $tablePodcastEpisodes ADD COLUMN is_played INTEGER '
          'NOT NULL DEFAULT 0',
      'ALTER TABLE $tablePodcastEpisodes ADD COLUMN download_state TEXT '
          'NOT NULL DEFAULT \'none\'',
      'CREATE INDEX IF NOT EXISTS idx_${tablePodcastEpisodes}_played '
          'ON $tablePodcastEpisodes(is_played)',
      'CREATE INDEX IF NOT EXISTS idx_${tableListeningEvents}_completed '
          'ON $tableListeningEvents(completed)',
    ],
  ),
  EcosystemMigration(
    fromVersion: 2,
    toVersion: 3,
    description: 'Offline collections gain per-collection network policy; '
        'stream cache tracks completion for partial-artifact sweeps.',
    statements: <String>[
      'ALTER TABLE $tableOfflineCollections ADD COLUMN wifi_only INTEGER '
          'NOT NULL DEFAULT 1',
      'ALTER TABLE $tableStreamCache ADD COLUMN complete INTEGER '
          'NOT NULL DEFAULT 0',
      'ALTER TABLE $tableStreamCache ADD COLUMN source_url TEXT',
    ],
  ),
  EcosystemMigration(
    fromVersion: 3,
    toVersion: 4,
    description: 'Podcast subscriptions gain retention/notification policy '
        'and the smart-playlist cache records materialization results.',
    statements: <String>[
      'ALTER TABLE $tablePodcastSubscriptions ADD COLUMN auto_download '
          'INTEGER NOT NULL DEFAULT 0',
      'ALTER TABLE $tablePodcastSubscriptions ADD COLUMN keep_episodes '
          'INTEGER NOT NULL DEFAULT 3',
      'ALTER TABLE $tablePodcastSubscriptions ADD COLUMN notify_new '
          'INTEGER NOT NULL DEFAULT 1',
      'ALTER TABLE $tableSmartPlaylistState ADD COLUMN last_track_count '
          'INTEGER NOT NULL DEFAULT 0',
    ],
  ),
  EcosystemMigration(
    fromVersion: 4,
    toVersion: 5,
    description: 'Stream cache gains integrity + at-rest encryption '
        'bookkeeping: SHA-256 digest, encryption marker and cipher IV '
        '(Feature Group 7 activation).',
    statements: <String>[
      'ALTER TABLE $tableStreamCache ADD COLUMN sha256 TEXT '
          "NOT NULL DEFAULT ''",
      'ALTER TABLE $tableStreamCache ADD COLUMN encrypted INTEGER '
          'NOT NULL DEFAULT 0',
      'ALTER TABLE $tableStreamCache ADD COLUMN iv_hex TEXT '
          "NOT NULL DEFAULT ''",
    ],
  ),
  EcosystemMigration(
    fromVersion: 5,
    toVersion: 6,
    description: 'Discovery & recommendations: day-bucketed listening '
        'statistics, user profiles, recommendation cache, daily mixes, '
        'discover weekly, radio sessions, artist/track similarity, mood '
        'profiles, trending statistics and continue-listening resume points. '
        'Purely additive — no existing table is touched.',
    statements: discoverySchemaV6,
  ),
];

/// Steps required to move [from] to [to], in order.
///
/// Pure function — unit-tested without touching SQLite.
List<EcosystemMigration> migrationsBetween(int from, int to) {
  if (to <= from) return const <EcosystemMigration>[];
  final steps = <EcosystemMigration>[];
  var cursor = from;
  while (cursor < to) {
    final step = ecosystemMigrations.cast<EcosystemMigration?>().firstWhere(
      (migration) => migration != null && migration.fromVersion == cursor,
      orElse: () => null,
    );
    if (step == null) break;
    steps.add(step);
    cursor = step.toVersion;
  }
  return steps;
}

/// The singleton ecosystem store.
class EcosystemDatabase {
  EcosystemDatabase._init();

  static final EcosystemDatabase instance = EcosystemDatabase._init();

  static final sqlite.SingleFlightInitializer<Database> _initializer =
      sqlite.SingleFlightInitializer<Database>();

  Future<Database> get database => _initializer.getOrCreate(_open);

  Future<Database> _open() {
    return sqlite.openAppDatabase(
      ecosystemDbFileName,
      version: ecosystemDatabaseVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    _log.i('Creating ecosystem database schema v$version');
    for (final migration in migrationsBetween(0, version)) {
      await migration.apply(db);
    }
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    _log.i('Upgrading ecosystem database v$oldVersion -> v$newVersion');
    // Fresh install of a newer build: create everything, then replay only the
    // steps an older database is missing.
    for (final statement in ecosystemSchemaV1) {
      await db.execute(statement);
    }
    for (final migration in migrationsBetween(oldVersion, newVersion)) {
      await migration.apply(db);
    }
  }

  /// Reads a value from the metadata table.
  Future<String?> readMeta(String key) async {
    final db = await database;
    final rows = await db.query(
      tableEcosystemMeta,
      where: 'key = ?',
      whereArgs: <Object?>[key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value']?.toString();
  }

  /// Writes a value into the metadata table (upsert).
  Future<void> writeMeta(String key, String value) async {
    final db = await database;
    await db.insert(tableEcosystemMeta, <String, Object?>{
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Deletes every ecosystem row. Used by "erase account data" and by tests.
  Future<void> clearAll() async {
    final db = await database;
    const tables = <String>[
      tableListeningEvents,
      tableTrackHistory,
      tableFavoritePlaylists,
      tableStreamCache,
      tablePodcastSubscriptions,
      tablePodcastEpisodes,
      tableRecognitionHistory,
      tableOfflineCollections,
      tableSmartPlaylistState,
      tableSocialCache,
      tableAccountState,
      tableSyncTombstones,
      tableEcosystemMeta,
      // Discovery & recommendations (schema v6).
      ...discoveryTables,
    ];
    final batch = db.batch();
    for (final table in tables) {
      batch.delete(table);
    }
    await batch.commit(noResult: true);
  }
}
