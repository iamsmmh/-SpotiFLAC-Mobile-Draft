-- SpotiFLAC Cloud — Extended PostgreSQL schema (Milestones 4, 5, 6, 8, 11).
--
-- Applied by cloud.Migrate(); every statement is idempotent so the migration
-- is safe to run on every boot of every replica.
--
-- This file extends the base schema in backend/cloud/schema.sql with tables
-- for collaborative playlists, social features, marketplace, and telemetry.

-- ---------------------------------------------------------------------------
-- Milestone 4: Collaborative Playlists
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS playlist_members (
    playlist_id  TEXT NOT NULL,
    user_id      TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    role         TEXT NOT NULL DEFAULT 'VIEWER',
    joined_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (playlist_id, user_id)
);

CREATE INDEX IF NOT EXISTS playlist_members_user_idx
    ON playlist_members (user_id);

CREATE TABLE IF NOT EXISTS playlist_invites (
    id           TEXT PRIMARY KEY,
    playlist_id  TEXT NOT NULL,
    inviter_id   TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    invitee_id   TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    role         TEXT NOT NULL DEFAULT 'VIEWER',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at   TIMESTAMPTZ NOT NULL,
    accepted_at  TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS playlist_invites_invitee_idx
    ON playlist_invites (invitee_id) WHERE accepted_at IS NULL;

CREATE TABLE IF NOT EXISTS playlist_changes (
    id           BIGSERIAL PRIMARY KEY,
    playlist_id  TEXT NOT NULL,
    user_id      TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    action       TEXT NOT NULL,
    track_id     TEXT NOT NULL DEFAULT '',
    position     INTEGER NOT NULL DEFAULT 0,
    revision     BIGINT NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS playlist_changes_playlist_idx
    ON playlist_changes (playlist_id, revision);

-- ---------------------------------------------------------------------------
-- Milestone 5: Social Layer
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS social_profiles (
    user_id      TEXT PRIMARY KEY REFERENCES cloud_users (id) ON DELETE CASCADE,
    handle       TEXT UNIQUE NOT NULL,
    display_name TEXT NOT NULL DEFAULT '',
    bio          TEXT NOT NULL DEFAULT '',
    avatar_url   TEXT NOT NULL DEFAULT '',
    is_public    BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS social_followers (
    follower_id  TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    followee_id  TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    followed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (follower_id, followee_id)
);

CREATE INDEX IF NOT EXISTS social_followers_followee_idx
    ON social_followers (followee_id);

CREATE TABLE IF NOT EXISTS social_activity_feed (
    id           BIGSERIAL PRIMARY KEY,
    actor_id     TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    kind         TEXT NOT NULL,
    subject      TEXT NOT NULL DEFAULT '',
    subtitle     TEXT NOT NULL DEFAULT '',
    artwork_url  TEXT NOT NULL DEFAULT '',
    target_id    TEXT NOT NULL DEFAULT '',
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS social_activity_feed_actor_idx
    ON social_activity_feed (actor_id, occurred_at DESC);

-- Profile badges
CREATE TABLE IF NOT EXISTS social_badges (
    user_id      TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    badge_id     TEXT NOT NULL,
    earned_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, badge_id)
);

-- ---------------------------------------------------------------------------
-- Milestone 6: Extension Marketplace V2
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS marketplace_extensions (
    id              TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    version         TEXT NOT NULL,
    description     TEXT NOT NULL DEFAULT '',
    author_id       TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    author_name     TEXT NOT NULL DEFAULT '',
    verified        BOOLEAN NOT NULL DEFAULT FALSE,
    category        TEXT NOT NULL DEFAULT '',
    download_url    TEXT NOT NULL DEFAULT '',
    icon_url        TEXT NOT NULL DEFAULT '',
    screenshots     JSONB NOT NULL DEFAULT '[]'::jsonb,
    rating          REAL NOT NULL DEFAULT 0,
    rating_count    INTEGER NOT NULL DEFAULT 0,
    downloads       BIGINT NOT NULL DEFAULT 0,
    active_installs BIGINT NOT NULL DEFAULT 0,
    dependencies    JSONB NOT NULL DEFAULT '[]'::jsonb,
    size_bytes      BIGINT NOT NULL DEFAULT 0,
    min_app_version TEXT NOT NULL DEFAULT '',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS marketplace_reviews (
    id           TEXT PRIMARY KEY,
    extension_id TEXT NOT NULL REFERENCES marketplace_extensions (id) ON DELETE CASCADE,
    user_id      TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    rating       INTEGER NOT NULL CHECK (rating >= 1 AND rating <= 5),
    text         TEXT NOT NULL DEFAULT '',
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (extension_id, user_id)
);

CREATE TABLE IF NOT EXISTS marketplace_installs (
    extension_id TEXT NOT NULL REFERENCES marketplace_extensions (id) ON DELETE CASCADE,
    user_id      TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    version      TEXT NOT NULL,
    installed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    active       BOOLEAN NOT NULL DEFAULT TRUE,
    PRIMARY KEY (extension_id, user_id)
);

CREATE TABLE IF NOT EXISTS marketplace_analytics (
    extension_id TEXT NOT NULL REFERENCES marketplace_extensions (id) ON DELETE CASCADE,
    period       TEXT NOT NULL,
    installs     BIGINT NOT NULL DEFAULT 0,
    uninstalls   BIGINT NOT NULL DEFAULT 0,
    crashes      BIGINT NOT NULL DEFAULT 0,
    at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (extension_id, period, at)
);

-- ---------------------------------------------------------------------------
-- Milestone 8: Discovery AI — User/Track Vectors
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS discovery_user_vectors (
    user_id    TEXT PRIMARY KEY REFERENCES cloud_users (id) ON DELETE CASCADE,
    dimensions INTEGER NOT NULL DEFAULT 64,
    weights    JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS discovery_artist_vectors (
    artist_id    TEXT PRIMARY KEY,
    dimensions   INTEGER NOT NULL DEFAULT 64,
    weights      JSONB NOT NULL DEFAULT '[]'::jsonb,
    listen_count BIGINT NOT NULL DEFAULT 0,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS discovery_track_vectors (
    track_id   TEXT PRIMARY KEY,
    dimensions INTEGER NOT NULL DEFAULT 16,
    weights    JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Milestone 11: Telemetry
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS telemetry_events (
    id          BIGSERIAL PRIMARY KEY,
    user_id     TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    device_id   TEXT NOT NULL DEFAULT '',
    type        TEXT NOT NULL,
    category    TEXT NOT NULL DEFAULT '',
    severity    TEXT NOT NULL DEFAULT 'info',
    message     TEXT NOT NULL DEFAULT '',
    stacktrace  TEXT NOT NULL DEFAULT '',
    metadata    JSONB NOT NULL DEFAULT '{}'::jsonb,
    duration_ms BIGINT NOT NULL DEFAULT 0,
    success     BOOLEAN,
    provider_id TEXT NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS telemetry_events_user_idx
    ON telemetry_events (user_id, created_at DESC);

CREATE INDEX IF NOT EXISTS telemetry_events_type_idx
    ON telemetry_events (type, created_at DESC);

CREATE TABLE IF NOT EXISTS telemetry_provider_health (
    provider_id  TEXT NOT NULL,
    available    BOOLEAN NOT NULL DEFAULT TRUE,
    latency_ms   BIGINT NOT NULL DEFAULT 0,
    error_rate   REAL NOT NULL DEFAULT 0,
    last_checked TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (provider_id)
);

-- ---------------------------------------------------------------------------
-- Milestone 7: Smart Cache Index (client-side, schema for sync)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS cache_sync_metadata (
    user_id    TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    track_id   TEXT NOT NULL,
    cached_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    priority   TEXT NOT NULL DEFAULT 'medium',
    source     TEXT NOT NULL DEFAULT 'manual',
    PRIMARY KEY (user_id, track_id)
);
