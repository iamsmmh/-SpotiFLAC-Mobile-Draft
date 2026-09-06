-- SpotiFLAC Cloud — PostgreSQL schema (Milestone 1).
--
-- Applied by cloud.Migrate(); every statement is idempotent so the migration
-- is safe to run on every boot of every replica.
--
-- Design notes
--   * `revision` is a per-(user, scope) monotonic counter, not a global
--     sequence: delta sync compares watermarks per scope, and a global
--     sequence would make every unrelated write invalidate every client's
--     watermark.
--   * Payloads are JSONB so partial indexes / server-side filtering stay
--     possible without a schema change per scope.
--   * Refresh tokens are stored only as SHA-256 hex digests.

CREATE TABLE IF NOT EXISTS cloud_users (
    id             TEXT PRIMARY KEY,
    email          TEXT UNIQUE,
    display_name   TEXT NOT NULL DEFAULT '',
    password_hash  TEXT NOT NULL DEFAULT '',
    guest          BOOLEAN NOT NULL DEFAULT FALSE,
    email_verified BOOLEAN NOT NULL DEFAULT FALSE,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Guest accounts have no email; the UNIQUE above already permits many NULLs.
CREATE INDEX IF NOT EXISTS cloud_users_guest_idx
    ON cloud_users (guest) WHERE guest;

CREATE TABLE IF NOT EXISTS cloud_devices (
    id           TEXT NOT NULL,
    user_id      TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    name         TEXT NOT NULL DEFAULT '',
    platform     TEXT NOT NULL DEFAULT '',
    trusted      BOOLEAN NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_sync_at TIMESTAMPTZ,
    PRIMARY KEY (user_id, id)
);

CREATE INDEX IF NOT EXISTS cloud_devices_last_seen_idx
    ON cloud_devices (user_id, last_seen_at DESC);

CREATE TABLE IF NOT EXISTS cloud_refresh_tokens (
    hash       TEXT PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    device_id  TEXT NOT NULL DEFAULT '',
    expires_at TIMESTAMPTZ NOT NULL,
    rotated    BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS cloud_refresh_user_idx
    ON cloud_refresh_tokens (user_id);
-- Reuse detection scans rotated tokens; keep them cheap to find and expire.
CREATE INDEX IF NOT EXISTS cloud_refresh_expiry_idx
    ON cloud_refresh_tokens (expires_at);

CREATE TABLE IF NOT EXISTS cloud_records (
    user_id             TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    scope               TEXT NOT NULL,
    record_id           TEXT NOT NULL,
    revision            BIGINT NOT NULL,
    updated_at          TIMESTAMPTZ NOT NULL,
    deleted             BOOLEAN NOT NULL DEFAULT FALSE,
    payload             JSONB NOT NULL DEFAULT '{}'::jsonb,
    client_revision     BIGINT NOT NULL DEFAULT 0,
    client_updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (user_id, scope, record_id)
);

-- The one index that matters: incremental pull is
-- "WHERE user_id=$1 AND scope=$2 AND revision > $3 ORDER BY revision".
CREATE INDEX IF NOT EXISTS cloud_records_delta_idx
    ON cloud_records (user_id, scope, revision);

CREATE TABLE IF NOT EXISTS cloud_scope_watermarks (
    user_id      TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    scope        TEXT NOT NULL,
    max_revision BIGINT NOT NULL DEFAULT 0,
    PRIMARY KEY (user_id, scope)
);

CREATE TABLE IF NOT EXISTS cloud_sync_log (
    id         BIGSERIAL PRIMARY KEY,
    user_id    TEXT NOT NULL REFERENCES cloud_users (id) ON DELETE CASCADE,
    device_id  TEXT NOT NULL DEFAULT '',
    scope      TEXT NOT NULL,
    record_id  TEXT NOT NULL,
    resolution TEXT NOT NULL,
    revision   BIGINT NOT NULL DEFAULT 0,
    at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS cloud_sync_log_user_idx
    ON cloud_sync_log (user_id, id DESC);

CREATE TABLE IF NOT EXISTS cloud_continuity (
    user_id      TEXT PRIMARY KEY REFERENCES cloud_users (id) ON DELETE CASCADE,
    device_id    TEXT NOT NULL DEFAULT '',
    track_id     TEXT NOT NULL DEFAULT '',
    title        TEXT NOT NULL DEFAULT '',
    artist       TEXT NOT NULL DEFAULT '',
    artwork_url  TEXT NOT NULL DEFAULT '',
    position_ms  BIGINT NOT NULL DEFAULT 0,
    duration_ms  BIGINT NOT NULL DEFAULT 0,
    playing      BOOLEAN NOT NULL DEFAULT FALSE,
    queue        JSONB NOT NULL DEFAULT '[]'::jsonb,
    queue_index  INTEGER NOT NULL DEFAULT 0,
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
