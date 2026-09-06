package cloud

import (
	"context"
	"errors"
	"time"
)

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

// ErrNotFound is returned when a lookup misses. Callers map it to 404.
var ErrNotFound = errors.New("cloud: not found")

// ErrConflict is returned when a write loses a deterministic conflict rule
// or violates a uniqueness constraint.
var ErrConflict = errors.New("cloud: conflict")

// ErrUnavailable is returned when the backing store cannot be reached. It is
// deliberately distinct from ErrNotFound so the caller can fail *open* (serve
// from the in-memory store) rather than reporting missing data.
var ErrUnavailable = errors.New("cloud: backing store unavailable")

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

// Record mirrors sync.Record on the storage boundary. It is redeclared here
// (rather than imported) so `backend/cloud` never imports `backend/sync`:
// the dependency points the other way, which is what lets an SQL store be
// swapped in without touching the reference semantics.
type Record struct {
	Scope     string
	RecordID  string
	Revision  int64
	UpdatedAt time.Time
	Deleted   bool
	Payload   map[string]any

	// ClientRevision and ClientUpdatedAt are the values the *client* sent.
	// They are stored alongside the server revision because the conflict
	// rule tie-breaks on the client revision, not the server one.
	ClientRevision  int64
	ClientUpdatedAt time.Time
}

// DeviceRow is one registered installation.
type DeviceRow struct {
	ID         string
	UserID     string
	Name       string
	Platform   string
	Trusted    bool
	CreatedAt  time.Time
	LastSeenAt time.Time
	LastSyncAt time.Time
}

// UserRow is one cloud account.
type UserRow struct {
	ID            string
	Email         string
	DisplayName   string
	PasswordHash  string
	Guest         bool
	EmailVerified bool
	CreatedAt     time.Time
}

// RefreshRow is one live refresh token, stored only as a SHA-256 hex digest.
type RefreshRow struct {
	Hash      string
	UserID    string
	DeviceID  string
	ExpiresAt time.Time
	Rotated   bool
}

// SyncLogRow is one audit entry for the conflict-resolution log surfaced in
// Settings → Devices → Sync log.
type SyncLogRow struct {
	ID         int64
	UserID     string
	DeviceID   string
	Scope      string
	RecordID   string
	Resolution string
	Revision   int64
	At         time.Time
}

// Resolution values recorded in the sync log.
const (
	ResolutionAccepted  = "accepted"
	ResolutionRejected  = "rejected"
	ResolutionMerged    = "merged"
	ResolutionTombstone = "tombstone"
	ResolutionRecovered = "recovered"
)

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------

// SyncStorage is the durable record store. Implementations must be safe for
// concurrent use.
type SyncStorage interface {
	// Push applies one record under the caller-supplied conflict decision
	// and returns the authoritative server revision. `accept` reports
	// whether the incoming record won; when false the stored revision is
	// returned unchanged.
	Push(ctx context.Context, userID string, rec Record, accept func(incoming, current Record) bool) (revision int64, accepted bool, err error)

	// Pull returns every record in the scope with revision > since,
	// ordered by revision ascending, capped at limit (<=0 means no cap).
	Pull(ctx context.Context, userID, scope string, since int64, limit int) ([]Record, error)

	// MaxRevision is the scope watermark, for delta sync.
	MaxRevision(ctx context.Context, userID, scope string) (int64, error)

	// CountScope reports how many live records a scope holds (quota).
	CountScope(ctx context.Context, userID, scope string) (int, error)

	// AppendSyncLog records one conflict decision.
	AppendSyncLog(ctx context.Context, row SyncLogRow) error

	// SyncLog returns the newest-first audit trail, capped at limit.
	SyncLog(ctx context.Context, userID string, limit int) ([]SyncLogRow, error)
}

// AuthStorage is the durable identity store.
type AuthStorage interface {
	CreateUser(ctx context.Context, user UserRow) error
	UserByEmail(ctx context.Context, email string) (UserRow, error)
	UserByID(ctx context.Context, id string) (UserRow, error)

	PutRefresh(ctx context.Context, row RefreshRow) error
	Refresh(ctx context.Context, hash string) (RefreshRow, error)
	MarkRotated(ctx context.Context, hash string) error
	DeleteRefresh(ctx context.Context, hash string) error
	RevokeUserRefresh(ctx context.Context, userID string) error

	UpsertDevice(ctx context.Context, device DeviceRow) error
	Devices(ctx context.Context, userID string) ([]DeviceRow, error)
	DeleteDevice(ctx context.Context, userID, deviceID string) error
	TouchDevice(ctx context.Context, userID, deviceID string, at time.Time) error
	SetDeviceTrust(ctx context.Context, userID, deviceID string, trusted bool) error
	RenameDevice(ctx context.Context, userID, deviceID, name string) error
}

// ContinuityStorage persists the cross-device "resume from the exact
// timestamp" state (Milestone 1 §3).
type ContinuityStorage interface {
	PutContinuity(ctx context.Context, state ContinuityState) error
	Continuity(ctx context.Context, userID string) (ContinuityState, error)
}

// Storage bundles the three ports; a single Postgres handle satisfies all.
type Storage interface {
	SyncStorage
	AuthStorage
	ContinuityStorage
}
