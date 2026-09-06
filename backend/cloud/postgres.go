package cloud

import (
	"context"
	"database/sql"
	_ "embed"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

//go:embed schema.sql
var schemaSQL string

// Schema returns the DDL applied by Migrate (also used by deployment
// tooling that prefers to run migrations out-of-band).
func Schema() string { return schemaSQL }

// Postgres implements Storage on top of database/sql.
//
// The *sql.DB is injected rather than opened here so the driver dependency
// belongs to the deploying binary and this module keeps an empty go.mod
// (see doc.go). A deployment does:
//
//	import _ "github.com/jackc/pgx/v5/stdlib"
//	db, _ := sql.Open("pgx", dsn)
//	store, _ := cloud.OpenPostgres(ctx, db)
type Postgres struct {
	db    *sql.DB
	clock func() time.Time
}

// OpenPostgres verifies connectivity, applies the schema, and returns the
// store.
func OpenPostgres(ctx context.Context, db *sql.DB, clock func() time.Time) (*Postgres, error) {
	if db == nil {
		return nil, errors.New("cloud: nil *sql.DB")
	}
	if clock == nil {
		clock = time.Now
	}
	if err := db.PingContext(ctx); err != nil {
		return nil, fmt.Errorf("cloud: postgres ping: %w", err)
	}
	store := &Postgres{db: db, clock: clock}
	if err := store.Migrate(ctx); err != nil {
		return nil, err
	}
	return store, nil
}

// Migrate applies the idempotent schema.
func (p *Postgres) Migrate(ctx context.Context) error {
	if _, err := p.db.ExecContext(ctx, schemaSQL); err != nil {
		return fmt.Errorf("cloud: migrate: %w", err)
	}
	return nil
}

// DB exposes the handle for health checks.
func (p *Postgres) DB() *sql.DB { return p.db }

// ---------------------------------------------------------------------------
// SyncStorage
// ---------------------------------------------------------------------------

// Push applies one record inside a transaction that also bumps the scope
// watermark.
//
// The SELECT takes a row lock (FOR UPDATE) so two devices pushing the same
// record concurrently cannot both read the same "current" row and both
// decide they win — that race is exactly how a lost update happens, and it
// is the reason this cannot be done with a bare UPSERT.
func (p *Postgres) Push(
	ctx context.Context,
	userID string,
	rec Record,
	accept func(incoming, current Record) bool,
) (int64, bool, error) {
	tx, err := p.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelReadCommitted})
	if err != nil {
		return 0, false, fmt.Errorf("cloud: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	var (
		current    Record
		exists     bool
		payloadRaw []byte
	)
	row := tx.QueryRowContext(ctx, `
		SELECT revision, deleted, payload, client_revision, client_updated_at
		  FROM cloud_records
		 WHERE user_id = $1 AND scope = $2 AND record_id = $3
		   FOR UPDATE`,
		userID, rec.Scope, rec.RecordID)
	err = row.Scan(
		&current.Revision, &current.Deleted, &payloadRaw,
		&current.ClientRevision, &current.ClientUpdatedAt,
	)
	switch {
	case err == nil:
		exists = true
		// The conflict rule compares *client* revisions and timestamps, so
		// present the stored row the way the client last saw it.
		current.Scope = rec.Scope
		current.RecordID = rec.RecordID
		current.UpdatedAt = current.ClientUpdatedAt
		if len(payloadRaw) > 0 {
			_ = json.Unmarshal(payloadRaw, &current.Payload)
		}
	case errors.Is(err, sql.ErrNoRows):
		exists = false
	default:
		return 0, false, fmt.Errorf("cloud: select record: %w", err)
	}

	if exists && accept != nil {
		candidate := rec
		candidate.Revision = rec.ClientRevision
		comparable := current
		comparable.Revision = current.ClientRevision
		if !accept(candidate, comparable) {
			// Loser: the stored server revision stays authoritative.
			if err := tx.Commit(); err != nil {
				return 0, false, fmt.Errorf("cloud: commit: %w", err)
			}
			return current.Revision, false, nil
		}
	}

	var revision int64
	if err := tx.QueryRowContext(ctx, `
		INSERT INTO cloud_scope_watermarks (user_id, scope, max_revision)
		VALUES ($1, $2, 1)
		ON CONFLICT (user_id, scope)
		DO UPDATE SET max_revision = cloud_scope_watermarks.max_revision + 1
		RETURNING max_revision`,
		userID, rec.Scope,
	).Scan(&revision); err != nil {
		return 0, false, fmt.Errorf("cloud: bump watermark: %w", err)
	}

	payload, err := json.Marshal(orEmptyMap(rec.Payload))
	if err != nil {
		return 0, false, fmt.Errorf("cloud: encode payload: %w", err)
	}
	if _, err := tx.ExecContext(ctx, `
		INSERT INTO cloud_records
			(user_id, scope, record_id, revision, updated_at, deleted,
			 payload, client_revision, client_updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
		ON CONFLICT (user_id, scope, record_id) DO UPDATE SET
			revision          = EXCLUDED.revision,
			updated_at        = EXCLUDED.updated_at,
			deleted           = EXCLUDED.deleted,
			payload           = EXCLUDED.payload,
			client_revision   = EXCLUDED.client_revision,
			client_updated_at = EXCLUDED.client_updated_at`,
		userID, rec.Scope, rec.RecordID, revision, rec.UpdatedAt.UTC(), rec.Deleted,
		payload, rec.ClientRevision, nonZeroTime(rec.ClientUpdatedAt, rec.UpdatedAt),
	); err != nil {
		return 0, false, fmt.Errorf("cloud: upsert record: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return 0, false, fmt.Errorf("cloud: commit: %w", err)
	}
	return revision, true, nil
}

// Pull returns the delta above `since`.
func (p *Postgres) Pull(ctx context.Context, userID, scope string, since int64, limit int) ([]Record, error) {
	query := `
		SELECT record_id, revision, updated_at, deleted, payload,
		       client_revision, client_updated_at
		  FROM cloud_records
		 WHERE user_id = $1 AND scope = $2 AND revision > $3
		 ORDER BY revision ASC`
	args := []any{userID, scope, since}
	if limit > 0 {
		query += " LIMIT $4"
		args = append(args, limit)
	}

	rows, err := p.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("cloud: pull: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []Record
	for rows.Next() {
		rec := Record{Scope: scope}
		var payloadRaw []byte
		if err := rows.Scan(
			&rec.RecordID, &rec.Revision, &rec.UpdatedAt, &rec.Deleted,
			&payloadRaw, &rec.ClientRevision, &rec.ClientUpdatedAt,
		); err != nil {
			return nil, fmt.Errorf("cloud: scan record: %w", err)
		}
		if len(payloadRaw) > 0 {
			if err := json.Unmarshal(payloadRaw, &rec.Payload); err != nil {
				// A corrupt payload must not abort the whole delta: the
				// client still needs the other records and the tombstone
				// state of this one.
				rec.Payload = map[string]any{}
			}
		}
		out = append(out, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("cloud: pull rows: %w", err)
	}
	return out, nil
}

// MaxRevision returns the scope watermark (0 when the scope is empty).
func (p *Postgres) MaxRevision(ctx context.Context, userID, scope string) (int64, error) {
	var revision int64
	err := p.db.QueryRowContext(ctx,
		`SELECT max_revision FROM cloud_scope_watermarks WHERE user_id = $1 AND scope = $2`,
		userID, scope,
	).Scan(&revision)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("cloud: watermark: %w", err)
	}
	return revision, nil
}

// CountScope counts live (non-tombstone) records.
func (p *Postgres) CountScope(ctx context.Context, userID, scope string) (int, error) {
	var count int
	err := p.db.QueryRowContext(ctx,
		`SELECT count(*) FROM cloud_records
		  WHERE user_id = $1 AND scope = $2 AND NOT deleted`,
		userID, scope,
	).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("cloud: count scope: %w", err)
	}
	return count, nil
}

// AppendSyncLog records a conflict decision.
func (p *Postgres) AppendSyncLog(ctx context.Context, row SyncLogRow) error {
	_, err := p.db.ExecContext(ctx, `
		INSERT INTO cloud_sync_log (user_id, device_id, scope, record_id, resolution, revision, at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		row.UserID, row.DeviceID, row.Scope, row.RecordID, row.Resolution, row.Revision,
		nonZeroTime(row.At, p.clock()),
	)
	if err != nil {
		return fmt.Errorf("cloud: append sync log: %w", err)
	}
	return nil
}

// SyncLog returns the newest-first audit trail.
func (p *Postgres) SyncLog(ctx context.Context, userID string, limit int) ([]SyncLogRow, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := p.db.QueryContext(ctx, `
		SELECT id, device_id, scope, record_id, resolution, revision, at
		  FROM cloud_sync_log
		 WHERE user_id = $1
		 ORDER BY id DESC
		 LIMIT $2`, userID, limit)
	if err != nil {
		return nil, fmt.Errorf("cloud: sync log: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []SyncLogRow
	for rows.Next() {
		row := SyncLogRow{UserID: userID}
		if err := rows.Scan(&row.ID, &row.DeviceID, &row.Scope, &row.RecordID,
			&row.Resolution, &row.Revision, &row.At); err != nil {
			return nil, fmt.Errorf("cloud: scan sync log: %w", err)
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

// ---------------------------------------------------------------------------
// AuthStorage
// ---------------------------------------------------------------------------

// CreateUser inserts an account, mapping a unique violation to ErrConflict.
func (p *Postgres) CreateUser(ctx context.Context, user UserRow) error {
	var email any
	if strings.TrimSpace(user.Email) != "" {
		email = strings.ToLower(strings.TrimSpace(user.Email))
	}
	_, err := p.db.ExecContext(ctx, `
		INSERT INTO cloud_users (id, email, display_name, password_hash, guest, email_verified, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		user.ID, email, user.DisplayName, user.PasswordHash, user.Guest,
		user.EmailVerified, nonZeroTime(user.CreatedAt, p.clock()),
	)
	if err != nil {
		if isUniqueViolation(err) {
			return ErrConflict
		}
		return fmt.Errorf("cloud: create user: %w", err)
	}
	return nil
}

// UserByEmail looks an account up by (case-folded) address.
func (p *Postgres) UserByEmail(ctx context.Context, email string) (UserRow, error) {
	return p.scanUser(p.db.QueryRowContext(ctx, `
		SELECT id, coalesce(email, ''), display_name, password_hash, guest, email_verified, created_at
		  FROM cloud_users WHERE email = $1`, strings.ToLower(strings.TrimSpace(email))))
}

// UserByID looks an account up by id.
func (p *Postgres) UserByID(ctx context.Context, id string) (UserRow, error) {
	return p.scanUser(p.db.QueryRowContext(ctx, `
		SELECT id, coalesce(email, ''), display_name, password_hash, guest, email_verified, created_at
		  FROM cloud_users WHERE id = $1`, id))
}

func (p *Postgres) scanUser(row *sql.Row) (UserRow, error) {
	var user UserRow
	err := row.Scan(&user.ID, &user.Email, &user.DisplayName, &user.PasswordHash,
		&user.Guest, &user.EmailVerified, &user.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return UserRow{}, ErrNotFound
	}
	if err != nil {
		return UserRow{}, fmt.Errorf("cloud: scan user: %w", err)
	}
	return user, nil
}

// PutRefresh stores a refresh-token digest.
func (p *Postgres) PutRefresh(ctx context.Context, row RefreshRow) error {
	_, err := p.db.ExecContext(ctx, `
		INSERT INTO cloud_refresh_tokens (hash, user_id, device_id, expires_at, rotated)
		VALUES ($1, $2, $3, $4, $5)
		ON CONFLICT (hash) DO UPDATE SET
			expires_at = EXCLUDED.expires_at,
			rotated    = EXCLUDED.rotated`,
		row.Hash, row.UserID, row.DeviceID, row.ExpiresAt.UTC(), row.Rotated)
	if err != nil {
		return fmt.Errorf("cloud: put refresh: %w", err)
	}
	return nil
}

// Refresh loads a refresh-token row (including rotated ones, so the caller
// can detect reuse).
func (p *Postgres) Refresh(ctx context.Context, hash string) (RefreshRow, error) {
	var row RefreshRow
	err := p.db.QueryRowContext(ctx, `
		SELECT hash, user_id, device_id, expires_at, rotated
		  FROM cloud_refresh_tokens WHERE hash = $1`, hash,
	).Scan(&row.Hash, &row.UserID, &row.DeviceID, &row.ExpiresAt, &row.Rotated)
	if errors.Is(err, sql.ErrNoRows) {
		return RefreshRow{}, ErrNotFound
	}
	if err != nil {
		return RefreshRow{}, fmt.Errorf("cloud: refresh: %w", err)
	}
	return row, nil
}

// MarkRotated flags a token as already exchanged. The row is *kept* on
// purpose: deleting it would make a replay indistinguishable from an unknown
// token, and reuse detection is the whole point of rotation.
func (p *Postgres) MarkRotated(ctx context.Context, hash string) error {
	_, err := p.db.ExecContext(ctx,
		`UPDATE cloud_refresh_tokens SET rotated = TRUE WHERE hash = $1`, hash)
	if err != nil {
		return fmt.Errorf("cloud: mark rotated: %w", err)
	}
	return nil
}

// DeleteRefresh removes one token.
func (p *Postgres) DeleteRefresh(ctx context.Context, hash string) error {
	_, err := p.db.ExecContext(ctx, `DELETE FROM cloud_refresh_tokens WHERE hash = $1`, hash)
	if err != nil {
		return fmt.Errorf("cloud: delete refresh: %w", err)
	}
	return nil
}

// RevokeUserRefresh drops every session of a user (reuse-attack response).
func (p *Postgres) RevokeUserRefresh(ctx context.Context, userID string) error {
	_, err := p.db.ExecContext(ctx, `DELETE FROM cloud_refresh_tokens WHERE user_id = $1`, userID)
	if err != nil {
		return fmt.Errorf("cloud: revoke user refresh: %w", err)
	}
	return nil
}

// UpsertDevice registers or refreshes a device.
func (p *Postgres) UpsertDevice(ctx context.Context, device DeviceRow) error {
	now := p.clock().UTC()
	_, err := p.db.ExecContext(ctx, `
		INSERT INTO cloud_devices (id, user_id, name, platform, trusted, created_at, last_seen_at, last_sync_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (user_id, id) DO UPDATE SET
			-- An empty name/platform means "unchanged": re-registration on
			-- app launch must not wipe a name the user chose.
			name         = CASE WHEN EXCLUDED.name = '' THEN cloud_devices.name ELSE EXCLUDED.name END,
			platform     = CASE WHEN EXCLUDED.platform = '' THEN cloud_devices.platform ELSE EXCLUDED.platform END,
			last_seen_at = EXCLUDED.last_seen_at`,
		device.ID, device.UserID, device.Name, device.Platform, device.Trusted,
		nonZeroTime(device.CreatedAt, now), nonZeroTime(device.LastSeenAt, now),
		nullableTime(device.LastSyncAt),
	)
	if err != nil {
		return fmt.Errorf("cloud: upsert device: %w", err)
	}
	return nil
}

// Devices lists a user's devices, most recently active first.
func (p *Postgres) Devices(ctx context.Context, userID string) ([]DeviceRow, error) {
	rows, err := p.db.QueryContext(ctx, `
		SELECT id, name, platform, trusted, created_at, last_seen_at, coalesce(last_sync_at, 'epoch'::timestamptz)
		  FROM cloud_devices WHERE user_id = $1
		 ORDER BY last_seen_at DESC`, userID)
	if err != nil {
		return nil, fmt.Errorf("cloud: devices: %w", err)
	}
	defer func() { _ = rows.Close() }()

	var out []DeviceRow
	for rows.Next() {
		device := DeviceRow{UserID: userID}
		if err := rows.Scan(&device.ID, &device.Name, &device.Platform, &device.Trusted,
			&device.CreatedAt, &device.LastSeenAt, &device.LastSyncAt); err != nil {
			return nil, fmt.Errorf("cloud: scan device: %w", err)
		}
		out = append(out, device)
	}
	return out, rows.Err()
}

// DeleteDevice removes a device and every session bound to it (remote
// logout).
func (p *Postgres) DeleteDevice(ctx context.Context, userID, deviceID string) error {
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("cloud: begin: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	result, err := tx.ExecContext(ctx,
		`DELETE FROM cloud_devices WHERE user_id = $1 AND id = $2`, userID, deviceID)
	if err != nil {
		return fmt.Errorf("cloud: delete device: %w", err)
	}
	affected, err := result.RowsAffected()
	if err == nil && affected == 0 {
		return ErrNotFound
	}
	if _, err := tx.ExecContext(ctx,
		`DELETE FROM cloud_refresh_tokens WHERE user_id = $1 AND device_id = $2`,
		userID, deviceID); err != nil {
		return fmt.Errorf("cloud: delete device sessions: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("cloud: commit: %w", err)
	}
	return nil
}

// TouchDevice updates the activity and sync timestamps.
func (p *Postgres) TouchDevice(ctx context.Context, userID, deviceID string, at time.Time) error {
	_, err := p.db.ExecContext(ctx, `
		UPDATE cloud_devices SET last_seen_at = $3, last_sync_at = $3
		 WHERE user_id = $1 AND id = $2`, userID, deviceID, at.UTC())
	if err != nil {
		return fmt.Errorf("cloud: touch device: %w", err)
	}
	return nil
}

// SetDeviceTrust flips the trust flag.
func (p *Postgres) SetDeviceTrust(ctx context.Context, userID, deviceID string, trusted bool) error {
	return p.updateDevice(ctx, userID, deviceID,
		`UPDATE cloud_devices SET trusted = $3 WHERE user_id = $1 AND id = $2`, trusted)
}

// RenameDevice sets a user-chosen name.
func (p *Postgres) RenameDevice(ctx context.Context, userID, deviceID, name string) error {
	return p.updateDevice(ctx, userID, deviceID,
		`UPDATE cloud_devices SET name = $3 WHERE user_id = $1 AND id = $2`,
		truncate(strings.TrimSpace(name), 128))
}

func (p *Postgres) updateDevice(ctx context.Context, userID, deviceID, query string, value any) error {
	result, err := p.db.ExecContext(ctx, query, userID, deviceID, value)
	if err != nil {
		return fmt.Errorf("cloud: update device: %w", err)
	}
	if affected, err := result.RowsAffected(); err == nil && affected == 0 {
		return ErrNotFound
	}
	return nil
}

// ---------------------------------------------------------------------------
// ContinuityStorage
// ---------------------------------------------------------------------------

// PutContinuity stores the hand-off snapshot, keeping the freshest write.
//
// The `WHERE ... < EXCLUDED.updated_at` guard makes a late-arriving stale
// snapshot a no-op instead of rewinding playback on every other device —
// out-of-order delivery is normal when two devices are both writing.
func (p *Postgres) PutContinuity(ctx context.Context, state ContinuityState) error {
	state = state.Normalize(p.clock())
	queue, err := json.Marshal(orEmptySlice(state.Queue))
	if err != nil {
		return fmt.Errorf("cloud: encode queue: %w", err)
	}
	_, err = p.db.ExecContext(ctx, `
		INSERT INTO cloud_continuity
			(user_id, device_id, track_id, title, artist, artwork_url,
			 position_ms, duration_ms, playing, queue, queue_index, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
		ON CONFLICT (user_id) DO UPDATE SET
			device_id   = EXCLUDED.device_id,
			track_id    = EXCLUDED.track_id,
			title       = EXCLUDED.title,
			artist      = EXCLUDED.artist,
			artwork_url = EXCLUDED.artwork_url,
			position_ms = EXCLUDED.position_ms,
			duration_ms = EXCLUDED.duration_ms,
			playing     = EXCLUDED.playing,
			queue       = EXCLUDED.queue,
			queue_index = EXCLUDED.queue_index,
			updated_at  = EXCLUDED.updated_at
		WHERE cloud_continuity.updated_at < EXCLUDED.updated_at`,
		state.UserID, state.DeviceID, state.TrackID, state.Title, state.Artist,
		state.ArtworkURL, state.PositionMs, state.DurationMs, state.Playing,
		queue, state.QueueIndex, state.UpdatedAt,
	)
	if err != nil {
		return fmt.Errorf("cloud: put continuity: %w", err)
	}
	return nil
}

// Continuity loads the latest hand-off snapshot.
func (p *Postgres) Continuity(ctx context.Context, userID string) (ContinuityState, error) {
	state := ContinuityState{UserID: userID}
	var queueRaw []byte
	err := p.db.QueryRowContext(ctx, `
		SELECT device_id, track_id, title, artist, artwork_url, position_ms,
		       duration_ms, playing, queue, queue_index, updated_at
		  FROM cloud_continuity WHERE user_id = $1`, userID,
	).Scan(&state.DeviceID, &state.TrackID, &state.Title, &state.Artist,
		&state.ArtworkURL, &state.PositionMs, &state.DurationMs, &state.Playing,
		&queueRaw, &state.QueueIndex, &state.UpdatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return ContinuityState{}, ErrNotFound
	}
	if err != nil {
		return ContinuityState{}, fmt.Errorf("cloud: continuity: %w", err)
	}
	if len(queueRaw) > 0 {
		_ = json.Unmarshal(queueRaw, &state.Queue)
	}
	return state, nil
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// isUniqueViolation detects a PostgreSQL 23505 without importing a driver:
// every driver renders the SQLSTATE in the error text, so a substring match
// is the portable test available to a dependency-free module.
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	text := strings.ToLower(err.Error())
	return strings.Contains(text, "23505") ||
		strings.Contains(text, "duplicate key value") ||
		strings.Contains(text, "unique constraint")
}

func nonZeroTime(value, fallback time.Time) time.Time {
	if value.IsZero() {
		return fallback.UTC()
	}
	return value.UTC()
}

func nullableTime(value time.Time) any {
	if value.IsZero() {
		return nil
	}
	return value.UTC()
}

func orEmptyMap(payload map[string]any) map[string]any {
	if payload == nil {
		return map[string]any{}
	}
	return payload
}

func orEmptySlice(values []string) []string {
	if values == nil {
		return []string{}
	}
	return values
}
