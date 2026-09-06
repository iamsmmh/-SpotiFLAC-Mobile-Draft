/// Discovery / recommendation schema (Phase 13).
///
/// Lives in the **existing** `ecosystem.db` as schema v6 — purely additive, so
/// an upgrade can never migrate, lock or corrupt data the downloader, player,
/// library or extension subsystems own. The rules from
/// `docs/MIGRATIONS.md` are enforced here and pinned by
/// `test/discovery_schema_test.dart`:
///
///   * every statement is a single idempotent `CREATE … IF NOT EXISTS`;
///   * no `ON CONFLICT … DO UPDATE` (Android API 24 ships SQLite 3.9);
///   * timestamps are ISO-8601 UTC strings, booleans are `0/1`;
///   * hot paths are indexed at creation time, not retrofitted.
library;

// ---------------------------------------------------------------------------
// Table names
// ---------------------------------------------------------------------------

/// Day-bucketed listening statistics — the input to every profile refresh.
const String dsListeningStatistics = 'ds_listening_statistics';

/// Serialised [ListeningProfile] snapshots.
const String dsUserProfiles = 'ds_user_profiles';

/// Generated shelves keyed by a stable cache key.
const String dsRecommendationCache = 'ds_recommendation_cache';

/// Daily Mix 1..5 for the current day.
const String dsDailyMixes = 'ds_daily_mixes';

/// One row per ISO week of Discover Weekly.
const String dsDiscoverWeekly = 'ds_discover_weekly';

/// Live and finished radio stations.
const String dsRadioSessions = 'ds_radio_sessions';

/// Persisted artist↔artist similarity.
const String dsArtistSimilarity = 'ds_artist_similarity';

/// Persisted track↔track similarity.
const String dsTrackSimilarity = 'ds_track_similarity';

/// Generated mood playlists.
const String dsMoodProfiles = 'ds_mood_profiles';

/// Computed trending shelves.
const String dsTrendingStatistics = 'ds_trending_statistics';

/// Continue-listening resume points (Phase 8).
const String dsContinueListening = 'ds_continue_listening';

/// Every table this module owns, used by "erase listening data" and tests.
const List<String> discoveryTables = <String>[
  dsListeningStatistics,
  dsUserProfiles,
  dsRecommendationCache,
  dsDailyMixes,
  dsDiscoverWeekly,
  dsRadioSessions,
  dsArtistSimilarity,
  dsTrackSimilarity,
  dsMoodProfiles,
  dsTrendingStatistics,
  dsContinueListening,
];

// ---------------------------------------------------------------------------
// Schema v6
// ---------------------------------------------------------------------------

/// The discovery surface, in one additive migration step.
///
/// One statement per list entry (`Database.execute` does not run batches).
const List<String> discoverySchemaV6 = <String>[
  // ---- listening_statistics ----------------------------------------------
  // Day-bucketed so "this week", "this month" and "day vs. night" are indexed
  // range scans instead of full-table walks over the raw event log.
  '''
  CREATE TABLE IF NOT EXISTS $dsListeningStatistics (
    track_key TEXT NOT NULL,
    bucket TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    artist TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    play_count INTEGER NOT NULL DEFAULT 0,
    skip_count INTEGER NOT NULL DEFAULT 0,
    completed_count INTEGER NOT NULL DEFAULT 0,
    repeat_count INTEGER NOT NULL DEFAULT 0,
    listened_ms INTEGER NOT NULL DEFAULT 0,
    completion_sum REAL NOT NULL DEFAULT 0,
    night_play_count INTEGER NOT NULL DEFAULT 0,
    weekend_play_count INTEGER NOT NULL DEFAULT 0,
    hour_histogram TEXT NOT NULL DEFAULT '',
    last_played_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (track_key, bucket)
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${dsListeningStatistics}_bucket '
      'ON $dsListeningStatistics(bucket DESC)',
  'CREATE INDEX IF NOT EXISTS idx_${dsListeningStatistics}_plays '
      'ON $dsListeningStatistics(play_count DESC)',
  'CREATE INDEX IF NOT EXISTS idx_${dsListeningStatistics}_last '
      'ON $dsListeningStatistics(last_played_at DESC)',

  // ---- user_profiles ------------------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $dsUserProfiles (
    profile_id TEXT PRIMARY KEY,
    generated_at TEXT NOT NULL,
    schema_version INTEGER NOT NULL DEFAULT 1,
    totals_json TEXT NOT NULL DEFAULT '{}',
    habits_json TEXT NOT NULL DEFAULT '{}',
    tracks_json TEXT NOT NULL DEFAULT '[]',
    artists_json TEXT NOT NULL DEFAULT '[]',
    albums_json NOT NULL DEFAULT '[]',
    genres_json TEXT NOT NULL DEFAULT '[]',
    tags_json TEXT NOT NULL DEFAULT '[]',
    track_count INTEGER NOT NULL DEFAULT 0,
    artist_count INTEGER NOT NULL DEFAULT 0
  )
  ''',

  // ---- recommendation_cache ----------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $dsRecommendationCache (
    cache_key TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    generated_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    track_count INTEGER NOT NULL DEFAULT 0,
    engine_version INTEGER NOT NULL DEFAULT 1,
    compute_ms INTEGER NOT NULL DEFAULT 0
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${dsRecommendationCache}_kind '
      'ON $dsRecommendationCache(kind)',
  'CREATE INDEX IF NOT EXISTS idx_${dsRecommendationCache}_expires '
      'ON $dsRecommendationCache(expires_at)',

  // ---- daily_mixes --------------------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $dsDailyMixes (
    mix_id TEXT PRIMARY KEY,
    day_key TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    title TEXT NOT NULL DEFAULT '',
    subtitle TEXT NOT NULL DEFAULT '',
    cluster_json TEXT NOT NULL DEFAULT '{}',
    items_json TEXT NOT NULL DEFAULT '[]',
    seed_labels_json TEXT NOT NULL DEFAULT '[]',
    generated_at TEXT NOT NULL DEFAULT '',
    expires_at TEXT NOT NULL DEFAULT '',
    track_count INTEGER NOT NULL DEFAULT 0
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${dsDailyMixes}_day '
      'ON $dsDailyMixes(day_key DESC, position ASC)',

  // ---- discover_weekly ----------------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $dsDiscoverWeekly (
    week_key TEXT PRIMARY KEY,
    items_json TEXT NOT NULL DEFAULT '[]',
    seed_artists_json TEXT NOT NULL DEFAULT '[]',
    generated_at TEXT NOT NULL DEFAULT '',
    expires_at TEXT NOT NULL DEFAULT '',
    track_count INTEGER NOT NULL DEFAULT 0,
    hidden_gem_count INTEGER NOT NULL DEFAULT 0,
    new_release_count INTEGER NOT NULL DEFAULT 0
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${dsDiscoverWeekly}_generated '
      'ON $dsDiscoverWeekly(generated_at DESC)',

  // ---- radio_sessions -----------------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $dsRadioSessions (
    session_id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    seed_key TEXT NOT NULL DEFAULT '',
    seed_label TEXT NOT NULL DEFAULT '',
    state_json TEXT NOT NULL DEFAULT '{}',
    started_at TEXT NOT NULL,
    last_active_at TEXT NOT NULL,
    play_count INTEGER NOT NULL DEFAULT 0,
    skip_count INTEGER NOT NULL DEFAULT 0,
    queue_length INTEGER NOT NULL DEFAULT 0,
    closed INTEGER NOT NULL DEFAULT 0
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${dsRadioSessions}_active '
      'ON $dsRadioSessions(closed ASC, last_active_at DESC)',

  // ---- artist_similarity --------------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $dsArtistSimilarity (
    artist_key TEXT NOT NULL,
    other_key TEXT NOT NULL,
    label TEXT NOT NULL DEFAULT '',
    score REAL NOT NULL DEFAULT 0,
    genre_overlap REAL NOT NULL DEFAULT 0,
    tag_overlap REAL NOT NULL DEFAULT 0,
    colisten_overlap REAL NOT NULL DEFAULT 0,
    playlist_overlap REAL NOT NULL DEFAULT 0,
    computed_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (artist_key, other_key)
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${dsArtistSimilarity}_score '
      'ON $dsArtistSimilarity(artist_key, score DESC)',

  // ---- track_similarity ---------------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $dsTrackSimilarity (
    track_key TEXT NOT NULL,
    other_key TEXT NOT NULL,
    score REAL NOT NULL DEFAULT 0,
    computed_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (track_key, other_key)
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${dsTrackSimilarity}_score '
      'ON $dsTrackSimilarity(track_key, score DESC)',

  // ---- mood_profiles ------------------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $dsMoodProfiles (
    mood TEXT PRIMARY KEY,
    label TEXT NOT NULL DEFAULT '',
    items_json TEXT NOT NULL DEFAULT '[]',
    generated_at TEXT NOT NULL DEFAULT '',
    expires_at TEXT NOT NULL DEFAULT '',
    track_count INTEGER NOT NULL DEFAULT 0,
    bpm_evidence_count INTEGER NOT NULL DEFAULT 0
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${dsMoodProfiles}_expires '
      'ON $dsMoodProfiles(expires_at)',

  // ---- trending_statistics ------------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $dsTrendingStatistics (
    period TEXT NOT NULL,
    track_key TEXT NOT NULL,
    label TEXT NOT NULL DEFAULT '',
    subtitle TEXT NOT NULL DEFAULT '',
    cover_url TEXT,
    rank INTEGER NOT NULL DEFAULT 0,
    score REAL NOT NULL DEFAULT 0,
    play_count INTEGER NOT NULL DEFAULT 0,
    delta REAL NOT NULL DEFAULT 0,
    is_artist INTEGER NOT NULL DEFAULT 0,
    computed_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (period, track_key)
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${dsTrendingStatistics}_rank '
      'ON $dsTrendingStatistics(period, rank ASC)',

  // ---- continue_listening -------------------------------------------------
  '''
  CREATE TABLE IF NOT EXISTS $dsContinueListening (
    slot TEXT PRIMARY KEY,
    kind TEXT NOT NULL DEFAULT 'track',
    track_key TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    artist TEXT NOT NULL DEFAULT '',
    album TEXT NOT NULL DEFAULT '',
    cover_url TEXT,
    local_path TEXT,
    provider_id TEXT,
    external_id TEXT,
    isrc TEXT,
    position_ms INTEGER NOT NULL DEFAULT 0,
    duration_ms INTEGER NOT NULL DEFAULT 0,
    context_id TEXT NOT NULL DEFAULT '',
    context_label TEXT NOT NULL DEFAULT '',
    queue_json TEXT NOT NULL DEFAULT '[]',
    queue_index INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT ''
  )
  ''',
  'CREATE INDEX IF NOT EXISTS idx_${dsContinueListening}_updated '
      'ON $dsContinueListening(updated_at DESC)',
];
