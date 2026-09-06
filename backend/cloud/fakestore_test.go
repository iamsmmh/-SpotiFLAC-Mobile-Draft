package cloud

import (
	"context"
	"sort"
	"sync"
	"time"
)

// fakeStorage is an in-memory Storage used by the handler tests. It mirrors
// the Postgres semantics that the tests actually assert on (watermarks,
// freshness guard, device errors) rather than pretending to be a database.
type fakeStorage struct {
	mu sync.Mutex

	records    map[string]map[string]Record // "user|scope" → recordID → record
	watermarks map[string]int64             // "user|scope" → revision
	logs       map[string][]SyncLogRow
	nextLogID  int64

	users    map[string]UserRow
	byEmail  map[string]string
	refresh  map[string]RefreshRow
	devices  map[string]map[string]DeviceRow
	handoff  map[string]ContinuityState
	failNext error
}

func newFakeStorage() *fakeStorage {
	return &fakeStorage{
		records:    map[string]map[string]Record{},
		watermarks: map[string]int64{},
		logs:       map[string][]SyncLogRow{},
		users:      map[string]UserRow{},
		byEmail:    map[string]string{},
		refresh:    map[string]RefreshRow{},
		devices:    map[string]map[string]DeviceRow{},
		handoff:    map[string]ContinuityState{},
	}
}

func scopeKey(userID, scope string) string { return userID + "|" + scope }

// ---- SyncStorage ----------------------------------------------------------

func (f *fakeStorage) Push(_ context.Context, userID string, rec Record, accept func(a, b Record) bool) (int64, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	key := scopeKey(userID, rec.Scope)
	byID, ok := f.records[key]
	if !ok {
		byID = map[string]Record{}
		f.records[key] = byID
	}
	if current, exists := byID[rec.RecordID]; exists && accept != nil {
		candidate := rec
		candidate.Revision = rec.ClientRevision
		comparable := current
		comparable.Revision = current.ClientRevision
		comparable.UpdatedAt = current.ClientUpdatedAt
		if !accept(candidate, comparable) {
			return current.Revision, false, nil
		}
	}
	f.watermarks[key]++
	rec.Revision = f.watermarks[key]
	byID[rec.RecordID] = rec
	return rec.Revision, true, nil
}

func (f *fakeStorage) Pull(_ context.Context, userID, scope string, since int64, limit int) ([]Record, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []Record
	for _, rec := range f.records[scopeKey(userID, scope)] {
		if rec.Revision > since {
			out = append(out, rec)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Revision < out[j].Revision })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (f *fakeStorage) MaxRevision(_ context.Context, userID, scope string) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.watermarks[scopeKey(userID, scope)], nil
}

func (f *fakeStorage) CountScope(_ context.Context, userID, scope string) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	count := 0
	for _, rec := range f.records[scopeKey(userID, scope)] {
		if !rec.Deleted {
			count++
		}
	}
	return count, nil
}

func (f *fakeStorage) AppendSyncLog(_ context.Context, row SyncLogRow) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.failNext != nil {
		err := f.failNext
		f.failNext = nil
		return err
	}
	f.nextLogID++
	row.ID = f.nextLogID
	f.logs[row.UserID] = append(f.logs[row.UserID], row)
	return nil
}

func (f *fakeStorage) SyncLog(_ context.Context, userID string, limit int) ([]SyncLogRow, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	rows := f.logs[userID]
	out := make([]SyncLogRow, 0, len(rows))
	for i := len(rows) - 1; i >= 0; i-- { // newest first
		out = append(out, rows[i])
		if limit > 0 && len(out) >= limit {
			break
		}
	}
	return out, nil
}

// ---- AuthStorage ----------------------------------------------------------

func (f *fakeStorage) CreateUser(_ context.Context, user UserRow) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if user.Email != "" {
		if _, taken := f.byEmail[user.Email]; taken {
			return ErrConflict
		}
		f.byEmail[user.Email] = user.ID
	}
	f.users[user.ID] = user
	return nil
}

func (f *fakeStorage) UserByEmail(_ context.Context, email string) (UserRow, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	id, ok := f.byEmail[email]
	if !ok {
		return UserRow{}, ErrNotFound
	}
	return f.users[id], nil
}

func (f *fakeStorage) UserByID(_ context.Context, id string) (UserRow, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	user, ok := f.users[id]
	if !ok {
		return UserRow{}, ErrNotFound
	}
	return user, nil
}

func (f *fakeStorage) PutRefresh(_ context.Context, row RefreshRow) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.refresh[row.Hash] = row
	return nil
}

func (f *fakeStorage) Refresh(_ context.Context, hash string) (RefreshRow, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	row, ok := f.refresh[hash]
	if !ok {
		return RefreshRow{}, ErrNotFound
	}
	return row, nil
}

func (f *fakeStorage) MarkRotated(_ context.Context, hash string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	row, ok := f.refresh[hash]
	if !ok {
		return ErrNotFound
	}
	row.Rotated = true
	f.refresh[hash] = row
	return nil
}

func (f *fakeStorage) DeleteRefresh(_ context.Context, hash string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.refresh, hash)
	return nil
}

func (f *fakeStorage) RevokeUserRefresh(_ context.Context, userID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for hash, row := range f.refresh {
		if row.UserID == userID {
			delete(f.refresh, hash)
		}
	}
	return nil
}

func (f *fakeStorage) UpsertDevice(_ context.Context, device DeviceRow) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	byID, ok := f.devices[device.UserID]
	if !ok {
		byID = map[string]DeviceRow{}
		f.devices[device.UserID] = byID
	}
	if existing, found := byID[device.ID]; found {
		if device.Name == "" {
			device.Name = existing.Name
		}
		if device.Platform == "" {
			device.Platform = existing.Platform
		}
		device.CreatedAt = existing.CreatedAt
	}
	byID[device.ID] = device
	return nil
}

func (f *fakeStorage) Devices(_ context.Context, userID string) ([]DeviceRow, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := make([]DeviceRow, 0, len(f.devices[userID]))
	for _, device := range f.devices[userID] {
		out = append(out, device)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].LastSeenAt.After(out[j].LastSeenAt) })
	return out, nil
}

func (f *fakeStorage) DeleteDevice(_ context.Context, userID, deviceID string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	byID, ok := f.devices[userID]
	if !ok {
		return ErrNotFound
	}
	if _, found := byID[deviceID]; !found {
		return ErrNotFound
	}
	delete(byID, deviceID)
	for hash, row := range f.refresh {
		if row.UserID == userID && row.DeviceID == deviceID {
			delete(f.refresh, hash)
		}
	}
	return nil
}

func (f *fakeStorage) TouchDevice(_ context.Context, userID, deviceID string, at time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	device, ok := f.devices[userID][deviceID]
	if !ok {
		return ErrNotFound
	}
	device.LastSeenAt, device.LastSyncAt = at, at
	f.devices[userID][deviceID] = device
	return nil
}

func (f *fakeStorage) SetDeviceTrust(_ context.Context, userID, deviceID string, trusted bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	device, ok := f.devices[userID][deviceID]
	if !ok {
		return ErrNotFound
	}
	device.Trusted = trusted
	f.devices[userID][deviceID] = device
	return nil
}

func (f *fakeStorage) RenameDevice(_ context.Context, userID, deviceID, name string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	device, ok := f.devices[userID][deviceID]
	if !ok {
		return ErrNotFound
	}
	device.Name = name
	f.devices[userID][deviceID] = device
	return nil
}

// ---- ContinuityStorage ----------------------------------------------------

func (f *fakeStorage) PutContinuity(_ context.Context, state ContinuityState) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	// Mirror the SQL freshness guard: a stale write is a no-op.
	if existing, ok := f.handoff[state.UserID]; ok && !state.Fresher(existing) {
		return nil
	}
	f.handoff[state.UserID] = state
	return nil
}

func (f *fakeStorage) Continuity(_ context.Context, userID string) (ContinuityState, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	state, ok := f.handoff[userID]
	if !ok {
		return ContinuityState{}, ErrNotFound
	}
	return state, nil
}
