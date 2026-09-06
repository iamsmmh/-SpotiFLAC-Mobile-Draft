// Package sync implements the SpotiFLAC Cloud record store: per-user,
// per-scope versioned records with server-assigned revisions, incremental
// pull (since a revision watermark) and the deterministic push conflict
// rule from docs/API_CONTRACTS.md §2 (the exact rule the client
// `SyncOrchestrator.resolve` implements, mirrored server-side):
//
//  1. a tombstone wins over a live record when its updatedAt is newer or
//     equal;
//  2. otherwise the newer updatedAt wins;
//  3. equal timestamps → the higher client revision wins;
//  4. still equal → the record is considered identical (rejected as a
//     no-op, current server revision returned).
package sync

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

// Record is one synchronized record.
type Record struct {
	Scope     string         `json:"scope"`
	RecordID  string         `json:"recordId"`
	Revision  int64          `json:"revision"`
	UpdatedAt time.Time      `json:"updatedAt"`
	Deleted   bool           `json:"deleted"`
	Payload   map[string]any `json:"payload"`
}

// ValidScopes is the exact set of wire ids the client can synchronize.
var ValidScopes = map[string]bool{
	"favorites":           true,
	"playlists":           true,
	"settings":            true,
	"history":             true,
	"queueState":          true,
	"downloadPreferences": true,
	"podcasts":            true,
	"social":              true,
}

// MaxRecordsPerScope bounds abuse.
const MaxRecordsPerScope = 10_000

// ErrScopeUnknown is returned for scopes outside ValidScopes.
var ErrScopeUnknown = errors.New("unknown sync scope")

// ErrScopeFull is returned when a scope would exceed MaxRecordsPerScope.
var ErrScopeFull = errors.New("scope record limit reached")

// ErrRecordInvalid is returned for structurally invalid records.
var ErrRecordInvalid = errors.New("invalid sync record")

type scopeState struct {
	records     map[string]*storedRecord
	maxRevision int64
}

// storedRecord keeps the server-assigned revision (what pulls return and
// watermarks compare) *and* the client revision the conflict rule needs for
// its tie-break — the two are not the same number.
type storedRecord struct {
	record          Record
	clientRevision  int64
	clientUpdatedAt time.Time
}

// Store holds all user data. The zero value is ready (see NewStore).
type Store struct {
	mu sync.RWMutex

	users map[string]map[string]*scopeState // userID → scope → state
	clock func() time.Time
}

// NewStore creates an empty store.
func NewStore(clock func() time.Time) *Store {
	if clock == nil {
		clock = time.Now
	}
	return &Store{
		users: map[string]map[string]*scopeState{},
		clock: clock,
	}
}

func (s *Store) scopeFor(userID, scope string) *scopeState {
	byScope, ok := s.users[userID]
	if !ok {
		byScope = map[string]*scopeState{}
		s.users[userID] = byScope
	}
	state, ok := byScope[scope]
	if !ok {
		state = &scopeState{records: map[string]*storedRecord{}}
		byScope[scope] = state
	}
	return state
}

// PushResult is the per-record outcome of a push.
type PushResult struct {
	// Final server revision (the authoritative value for the ack map,
	// whether the record was accepted or rejected as stale).
	Revision int64
	// Accepted is true when the incoming record became the stored one.
	Accepted bool
}

// Push applies incoming records under the conflict rule and returns the
// authoritative revision per record id, in input order.
func (s *Store) Push(_ context.Context, userID, scope string, incoming []Record) (map[string]PushResult, error) {
	if !ValidScopes[scope] {
		return nil, ErrScopeUnknown
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	state := s.scopeFor(userID, scope)
	results := make(map[string]PushResult, len(incoming))
	for i := range incoming {
		record := incoming[i]
		if record.RecordID == "" {
			return nil, ErrRecordInvalid
		}
		if record.UpdatedAt.IsZero() {
			record.UpdatedAt = s.clock().UTC()
		}
		record.UpdatedAt = record.UpdatedAt.UTC()
		record.Scope = scope

		existing, ok := state.records[record.RecordID]
		if ok {
			current := existing.record
			current.Revision = existing.clientRevision
			current.UpdatedAt = existing.clientUpdatedAt
			if !wins(record, current) {
				results[record.RecordID] = PushResult{
					Revision: existing.record.Revision,
					Accepted: false,
				}
				continue
			}
		}
		if !ok && len(state.records) >= MaxRecordsPerScope {
			return nil, ErrScopeFull
		}
		state.maxRevision++
		stored := storedRecord{
			record:          record,
			clientRevision:  record.Revision,
			clientUpdatedAt: record.UpdatedAt,
		}
		stored.record.Revision = state.maxRevision
		state.records[record.RecordID] = &stored
		results[record.RecordID] = PushResult{
			Revision: stored.record.Revision,
			Accepted: true,
		}
	}
	return results, nil
}

// wins is the deterministic conflict rule (docs §2). `candidate` is the
// incoming record (client revision), `current` the stored one (client
// revision restored).
func wins(candidate, current Record) bool {
	switch {
	// 1. A newer tombstone always wins; a tombstone tie beats a live record.
	case candidate.Deleted && !current.Deleted:
		return !candidate.UpdatedAt.Before(current.UpdatedAt)
	case current.Deleted && !candidate.Deleted:
		return candidate.UpdatedAt.After(current.UpdatedAt)
	// 2. Newer updatedAt wins (both live or both tombstones).
	case candidate.UpdatedAt.After(current.UpdatedAt):
		return true
	case candidate.UpdatedAt.Before(current.UpdatedAt):
		return false
	// 3. Equal timestamps: higher client revision wins.
	case candidate.Revision > current.Revision:
		return true
	case candidate.Revision < current.Revision:
		return false
	}
	// 4. Fully tied: identical by contract.
	return false
}

// Pull returns every record in the scope with revision > since, ordered by
// revision ascending. since < 0 or 0 returns the full snapshot.
func (s *Store) Pull(_ context.Context, userID, scope string, since int64) ([]*Record, error) {
	if !ValidScopes[scope] {
		return nil, ErrScopeUnknown
	}
	s.mu.RLock()
	defer s.mu.RUnlock()

	byScope, ok := s.users[userID]
	if !ok {
		return []*Record{}, nil
	}
	state, ok := byScope[scope]
	if !ok {
		return []*Record{}, nil
	}
	out := make([]*Record, 0, len(state.records))
	for _, stored := range state.records {
		if stored.record.Revision > since {
			out = append(out, &stored.record)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Revision < out[j].Revision
	})
	return out, nil
}

// Watermark returns the highest revision in a scope (0 when empty).
func (s *Store) Watermark(_ context.Context, userID, scope string) int64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	byScope, ok := s.users[userID]
	if !ok {
		return 0
	}
	state, ok := byScope[scope]
	if !ok {
		return 0
	}
	return state.maxRevision
}
