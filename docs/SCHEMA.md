# Ecosystem database schema

`ecosystem.db` — a dedicated SQLite file opened with the shared helper
`services/sqlite_helpers.dart` (WAL, `synchronous=NORMAL`, 5 s busy timeout),
version **6**.

It is deliberately separate from the four pre-existing stores:

| File | Owned by | Untouched by the ecosystem |
|---|---|---|
| `app_state.db` | download queue, recents, playback session | ✅ |
| `library.db` | local library ledger | ✅ |
| `collections.db` | wishlist/loved/playlists/favorite artists+albums | ✅ (read-only projection) |
| `history.db` | download history | ✅ |
| **`ecosystem.db`** | **all new ecosystem tables** | — |

Conventions: timestamps are ISO-8601 UTC strings, booleans are `0/1` integers,
all tables are created with `IF NOT EXISTS` so an interrupted migration resumes.

> Android API 24 ships SQLite 3.9, so **no `ON CONFLICT … DO UPDATE`** is used
> anywhere: aggregates are maintained with an explicit read-modify-write inside
> a transaction.

## Tables

```sql
CREATE TABLE IF NOT EXISTS ec_listening_events (
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
```

```sql
CREATE TABLE IF NOT EXISTS ec_track_history (
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
```

```sql
CREATE TABLE IF NOT EXISTS ec_favorite_playlists (
  playlist_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  cover_path TEXT,
  track_count INTEGER NOT NULL DEFAULT 0,
  added_at TEXT NOT NULL
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_stream_cache (
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
```

```sql
CREATE TABLE IF NOT EXISTS ec_podcast_subscriptions (
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
```

```sql
CREATE TABLE IF NOT EXISTS ec_podcast_episodes (
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
```

```sql
CREATE TABLE IF NOT EXISTS ec_recognition_history (
  result_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  artist TEXT NOT NULL DEFAULT '',
  album TEXT NOT NULL DEFAULT '',
  provider_id TEXT NOT NULL DEFAULT '',
  confidence REAL NOT NULL DEFAULT 0,
  identified_at TEXT NOT NULL,
  payload_json TEXT NOT NULL DEFAULT '{}'
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_offline_collections (
  collection_key TEXT PRIMARY KEY,
  kind TEXT NOT NULL,
  title TEXT NOT NULL,
  track_count INTEGER NOT NULL DEFAULT 0,
  auto_sync INTEGER NOT NULL DEFAULT 1,
  wifi_only INTEGER NOT NULL DEFAULT 1,
  last_synced_at TEXT,
  added_at TEXT NOT NULL
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_smart_playlist_state (
  playlist_id TEXT PRIMARY KEY,
  definition_json TEXT NOT NULL,
  last_materialized_at TEXT,
  last_track_count INTEGER NOT NULL DEFAULT 0
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_social_cache (
  cache_key TEXT PRIMARY KEY,
  payload_json TEXT NOT NULL,
  updated_at TEXT NOT NULL
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_account_state (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  provider_id TEXT NOT NULL DEFAULT '',
  user_id TEXT NOT NULL DEFAULT '',
  email TEXT NOT NULL DEFAULT '',
  display_name TEXT NOT NULL DEFAULT '',
  avatar_url TEXT,
  is_guest INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_sync_tombstones (
  scope TEXT NOT NULL,
  record_id TEXT NOT NULL,
  deleted_at TEXT NOT NULL,
  PRIMARY KEY (scope, record_id)
)
```

```sql
CREATE TABLE IF NOT EXISTS ec_meta (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)
```

## Indexes

* `CREATE INDEX IF NOT EXISTS idx_ec_favorite_playlists_added ON ec_favorite_playlists(added_at DESC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_listening_events_started ON ec_listening_events(started_at DESC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_listening_events_track ON ec_listening_events(track_key)`
* `CREATE INDEX IF NOT EXISTS idx_ec_podcast_episodes_feed ON ec_podcast_episodes(feed_url, published_at DESC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_podcast_episodes_played ON ec_podcast_episodes(is_played)`
* `CREATE INDEX IF NOT EXISTS idx_ec_recognition_history_time ON ec_recognition_history(identified_at DESC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_stream_cache_lru ON ec_stream_cache(last_accessed_at ASC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_stream_cache_track ON ec_stream_cache(track_key)`
* `CREATE INDEX IF NOT EXISTS idx_ec_track_history_last ON ec_track_history(last_played_at DESC)`
* `CREATE INDEX IF NOT EXISTS idx_ec_track_history_plays ON ec_track_history(play_count DESC)`

## Discovery tables (v6)

Added by the 5 → 6 migration for the on-device recommendation engine. Purely additive: no `ec_*` table is altered and no column is dropped. Every table is prefixed `ds_`, listed in `discoveryTables`, and cleared by `EcosystemDatabase.clearAll`.

### `ds_listening_statistics`

Day-bucketed roll-up of `ec_listening_events`: one row per `(track_key, UTC day)` with plays, skips, listened milliseconds, completions, repeats and a 24-bucket hour histogram. The roll-up is incremental — a `last_event_id` watermark in `ec_meta` means a normal launch reads only new events, which is what keeps Phase 1 off the battery budget.

```sql
CREATE TABLE IF NOT EXISTS ds_listening_statistics (
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
```

### `ds_user_profiles`

Serialised `ListeningProfile` (top tracks / artists / albums / genres / tags plus listening habits). Regenerated at most every 6 h; `schema_version` invalidates a profile written by an older algorithm instead of mixing two definitions of affinity.

```sql
CREATE TABLE IF NOT EXISTS ds_user_profiles (
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
```

### `ds_recommendation_cache`

Generated shelves keyed by `(kind, key)`. Stores the engine version and an expiry timestamp, so a code change or a stale entry is a cache miss rather than a stale shelf.

```sql
CREATE TABLE IF NOT EXISTS ds_recommendation_cache (
    cache_key TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    generated_at TEXT NOT NULL,
    expires_at TEXT NOT NULL,
    track_count INTEGER NOT NULL DEFAULT 0,
    engine_version INTEGER NOT NULL DEFAULT 1,
    compute_ms INTEGER NOT NULL DEFAULT 0
  )
```

### `ds_daily_mixes`

Daily Mix 1-5: one row per `(day_key, position)`. `cluster_json` holds the genre centroid that seeded the mix, `seed_labels_json` the genre names shown as chips.

```sql
CREATE TABLE IF NOT EXISTS ds_daily_mixes (
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
```

### `ds_discover_weekly`

Discover Weekly: one row per ISO week (`week_key`), 30-50 tracks in `items_json`, plus the counts surfaced on the card (hidden gems and new releases).

```sql
CREATE TABLE IF NOT EXISTS ds_discover_weekly (
    week_key TEXT PRIMARY KEY,
    items_json TEXT NOT NULL DEFAULT '[]',
    seed_artists_json TEXT NOT NULL DEFAULT '[]',
    generated_at TEXT NOT NULL DEFAULT '',
    expires_at TEXT NOT NULL DEFAULT '',
    track_count INTEGER NOT NULL DEFAULT 0,
    hidden_gem_count INTEGER NOT NULL DEFAULT 0,
    new_release_count INTEGER NOT NULL DEFAULT 0
  )
```

### `ds_radio_sessions`

Persisted radio stations — seed, queue, played keys and affinity vectors — so a station survives an app restart. Closed sessions are pruned after 30 days.

```sql
CREATE TABLE IF NOT EXISTS ds_radio_sessions (
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
```

### `ds_artist_similarity`

Cached artist→artist similarity with its five component overlaps (genre, tag, co-listen, playlist, album), so the percentage shown in the UI can be explained.

```sql
CREATE TABLE IF NOT EXISTS ds_artist_similarity (
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
```

### `ds_track_similarity`

Cached track→track similarity used by Track Radio and "more like this".

```sql
CREATE TABLE IF NOT EXISTS ds_track_similarity (
    track_key TEXT NOT NULL,
    other_key TEXT NOT NULL,
    score REAL NOT NULL DEFAULT 0,
    computed_at TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (track_key, other_key)
  )
```

### `ds_mood_profiles`

Mood playlists (Chill, Focus, Workout, ...). `bpm_evidence_count` records how much of the playlist was scored from real BPM metadata; the UI shows that instead of claiming tempo data it does not have.

```sql
CREATE TABLE IF NOT EXISTS ds_mood_profiles (
    mood TEXT PRIMARY KEY,
    label TEXT NOT NULL DEFAULT '',
    items_json TEXT NOT NULL DEFAULT '[]',
    generated_at TEXT NOT NULL DEFAULT '',
    expires_at TEXT NOT NULL DEFAULT '',
    track_count INTEGER NOT NULL DEFAULT 0,
    bpm_evidence_count INTEGER NOT NULL DEFAULT 0
  )
```

### `ds_trending_statistics`

Per-period trending snapshots (week, month, fastest growing, emerging artists) computed from the windowed play counts on `ds_listening_statistics`.

```sql
CREATE TABLE IF NOT EXISTS ds_trending_statistics (
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
```

### `ds_continue_listening`

Resume points: the primary "pick up where you left off" slot plus per-context rows (album, playlist, radio). The stored offset is cleared at >= 95 % completion so a finished track never resumes.

```sql
CREATE TABLE IF NOT EXISTS ds_continue_listening (
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
```

### Discovery indexes

```sql
CREATE INDEX IF NOT EXISTS idx_ds_listening_statistics_bucket ON ds_listening_statistics(bucket DESC);
CREATE INDEX IF NOT EXISTS idx_ds_listening_statistics_plays ON ds_listening_statistics(play_count DESC);
CREATE INDEX IF NOT EXISTS idx_ds_listening_statistics_last ON ds_listening_statistics(last_played_at DESC);
CREATE INDEX IF NOT EXISTS idx_ds_recommendation_cache_kind ON ds_recommendation_cache(kind);
CREATE INDEX IF NOT EXISTS idx_ds_recommendation_cache_expires ON ds_recommendation_cache(expires_at);
CREATE INDEX IF NOT EXISTS idx_ds_daily_mixes_day ON ds_daily_mixes(day_key DESC, position ASC);
CREATE INDEX IF NOT EXISTS idx_ds_discover_weekly_generated ON ds_discover_weekly(generated_at DESC);
CREATE INDEX IF NOT EXISTS idx_ds_radio_sessions_active ON ds_radio_sessions(closed ASC, last_active_at DESC);
CREATE INDEX IF NOT EXISTS idx_ds_artist_similarity_score ON ds_artist_similarity(artist_key, score DESC);
CREATE INDEX IF NOT EXISTS idx_ds_track_similarity_score ON ds_track_similarity(track_key, score DESC);
CREATE INDEX IF NOT EXISTS idx_ds_mood_profiles_expires ON ds_mood_profiles(expires_at);
CREATE INDEX IF NOT EXISTS idx_ds_trending_statistics_rank ON ds_trending_statistics(period, rank ASC);
CREATE INDEX IF NOT EXISTS idx_ds_continue_listening_updated ON ds_continue_listening(updated_at DESC);
```

## Columns added after v1

Migrations 1 → 5 only add columns (`ALTER TABLE … ADD COLUMN … NOT NULL DEFAULT …`), so an older build reading a newer database still works.

| Step | Table | Columns added |
|---|---|---|
| 2 → 3 | `ec_offline_collections` | per-collection network policy |
| 2 → 3 | `ec_stream_cache` | completion + source URL |
| 3 → 4 | `ec_podcast_subscriptions` | `auto_download`, `keep_episodes`, `notify_new` |
| 3 → 4 | `ec_smart_playlist_state` | `last_track_count` |
| 4 → 5 | `ec_stream_cache` | `sha256`, `encrypted`, `iv_hex` |
| 5 → 6 | — | discovery tables only (no columns added) |

## Key conventions

* **Identity.** Favorite/sync records use stable, provider-namespaced keys
  (`isrc:USRC17607839`, `qobuz:albumId`, `playlist:<uuid>`). A key is never
  derived from a title, so renaming a track cannot orphan its history.
* **Aggregates.** `ec_track_history` is derived data: it can always be rebuilt
  from `ec_listening_events` (`completion_sum / completion_count` is the average
  completion).
* **Secrets.** No token ever lands here. `ec_account_state` holds only the
  non-secret profile mirror; tokens live in the platform keystore.
* **Sync bookkeeping.** `ec_sync_tombstones` records deletions that must
  propagate to other devices even after the local row is gone.

## Server-side schema

For a self-hosted/Supabase deployment, `server/schema.sql` contains an
equivalent PostgreSQL schema (including RLS policies) implementing the same
contract.
