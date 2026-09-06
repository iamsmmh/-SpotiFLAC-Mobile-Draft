// Backup blobs: device → cloud backup upload/download. Backups are opaque
// versioned JSON envelopes produced by the client's CloudBackupManager; the
// server only enforces a size cap and keeps the latest few per device.
package sync

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"
)

// MaxBackupBytes caps one backup envelope.
const MaxBackupBytes = 8 << 20 // 8 MiB

// KeptBackupsPerDevice bounds storage per device.
const KeptBackupsPerDevice = 3

// Backup is one stored envelope (metadata only in listings).
type Backup struct {
	ID        string    `json:"id"`
	DeviceID  string    `json:"deviceId"`
	SizeBytes int       `json:"sizeBytes"`
	SHA256    string    `json:"sha256"`
	CreatedAt time.Time `json:"createdAt"`
}

type backupBlob struct {
	meta  Backup
	bytes []byte
}

// ErrBackupTooLarge is returned when an upload exceeds MaxBackupBytes.
var ErrBackupTooLarge = errors.New("backup exceeds the size limit")

// ErrBackupNotFound is returned for unknown backup ids.
var ErrBackupNotFound = errors.New("backup not found")

// BackupStore keeps the latest backups per device.
type BackupStore struct {
	mu sync.Mutex

	blobs map[string][]*backupBlob // userID → blobs (newest last)
	clock func() time.Time
	ids   func() string
}

// NewBackupStore builds the store.
func NewBackupStore(clock func() time.Time, ids func() string) *BackupStore {
	if clock == nil {
		clock = time.Now
	}
	if ids == nil {
		ids = NewBackupID
	}
	return &BackupStore{blobs: map[string][]*backupBlob{}, clock: clock, ids: ids}
}

// NewBackupID generates a random identifier for a stored backup.
func NewBackupID() string {
	buf := make([]byte, 12)
	if _, err := rand.Read(buf); err != nil {
		// Fall back to a timestamp-based id; uniqueness only matters for
		// colliding uploads within the same process.
		return fmt.Sprintf("b%d", time.Now().UnixNano())
	}
	return hex.EncodeToString(buf)
}

// backupID embeds a content fingerprint plus a random suffix so the id is
// both dedupable and unique even across replacement uploads.
func backupID(sum [sha256.Size]byte, idFactory func() string) string {
	suffix := idFactory()
	if len(suffix) > 4 {
		suffix = suffix[4:]
	}
	if suffix == "" {
		suffix = NewBackupID()
	}
	return "bkp_" + hex.EncodeToString(sum[:6]) + "_" + suffix
}

// Upload stores an envelope, pruning to KeptBackupsPerDevice.
func (s *BackupStore) Upload(_ context.Context, userID, deviceID string, payload []byte) (Backup, error) {
	if len(payload) == 0 {
		return Backup{}, errors.New("backup payload is empty")
	}
	if len(payload) > MaxBackupBytes {
		return Backup{}, ErrBackupTooLarge
	}
	if deviceID == "" {
		return Backup{}, errors.New("deviceId is required")
	}
	sum := sha256.Sum256(payload)
	meta := Backup{
		ID:        backupID(sum, s.ids()),
		DeviceID:  deviceID,
		SizeBytes: len(payload),
		SHA256:    hex.EncodeToString(sum[:]),
		CreatedAt: s.clock().UTC(),
	}
	blob := &backupBlob{meta: meta, bytes: append([]byte(nil), payload...)}

	s.mu.Lock()
	defer s.mu.Unlock()
	list := append(s.blobs[userID], blob)
	if len(list) > KeptBackupsPerDevice {
		list = list[len(list)-KeptBackupsPerDevice:]
	}
	s.blobs[userID] = list
	return meta, nil
}

// Download returns the payload for one backup.
func (s *BackupStore) Download(_ context.Context, userID, backupID string) (Backup, []byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, blob := range s.blobs[userID] {
		if blob.meta.ID == backupID {
			return blob.meta, append([]byte(nil), blob.bytes...), nil
		}
	}
	return Backup{}, nil, ErrBackupNotFound
}

// List returns the backups of one device, newest first.
func (s *BackupStore) List(_ context.Context, userID, deviceID string) []Backup {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Backup, 0, len(s.blobs[userID]))
	for _, blob := range s.blobs[userID] {
		if deviceID == "" || blob.meta.DeviceID == deviceID {
			out = append(out, blob.meta)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].CreatedAt.After(out[j].CreatedAt)
	})
	return out
}

// Delete removes one backup.
func (s *BackupStore) Delete(_ context.Context, userID, backupID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := s.blobs[userID]
	kept := make([]*backupBlob, 0, len(list))
	found := false
	for _, blob := range list {
		if blob.meta.ID == backupID {
			found = true
			continue
		}
		kept = append(kept, blob)
	}
	if !found {
		return ErrBackupNotFound
	}
	s.blobs[userID] = kept
	return nil
}
