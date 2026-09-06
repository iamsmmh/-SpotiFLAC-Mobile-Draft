package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strings"
	"sync"
	"time"
)

// User is one cloud account.
type User struct {
	ID            string    `json:"id"`
	Email         string    `json:"email"`
	DisplayName   string    `json:"displayName"`
	PasswordHash  string    `json:"-"`
	CreatedAt     time.Time `json:"createdAt"`
	EmailVerified bool      `json:"emailVerified"`
}

// Device is one registered installation.
type Device struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	Platform   string    `json:"platform"`
	CreatedAt  time.Time `json:"createdAt"`
	LastSeenAt time.Time `json:"lastSeenAt"`
}

// Session is the wire payload every auth endpoint answers with (the shape
// from docs/API_CONTRACTS.md §1.3).
type Session struct {
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
	ExpiresIn    int64  `json:"expiresIn"`
	User         User   `json:"user"`
}

// refreshRecord keeps only the SHA-256 of the token material, never the
// material itself.
type refreshRecord struct {
	hash     string
	userID   string
	deviceID string
	expires  time.Time
}

// Store is the in-memory auth state. Production deployments back the same
// operations with Postgres (see server/schema.sql); the method set below is
// the surface an SQL adapter would implement.
type Store struct {
	mu sync.RWMutex

	usersByEmail map[string]*User
	usersByID    map[string]*User

	// refresh holds live refresh tokens by SHA-256 hex. rotated marks
	// hashes that were already exchanged once; presenting one of those
	// again is a reuse attack and revokes every session of the owner.
	// rotatedOwner remembers which user a rotated hash belonged to so
	// revocation can find the victim account.
	refresh      map[string]*refreshRecord
	rotated      map[string]bool
	rotatedOwner map[string]string

	devices map[string][]*Device // userID → devices
	clock   Clock
}

// NewStore creates an empty store.
func NewStore(clock Clock) *Store {
	if clock == nil {
		clock = time.Now
	}
	return &Store{
		usersByEmail: map[string]*User{},
		usersByID:    map[string]*User{},
		refresh:      map[string]*refreshRecord{},
		rotated:      map[string]bool{},
		rotatedOwner: map[string]string{},
		devices:      map[string][]*Device{},
		clock:        clock,
	}
}

// Now exposes the store clock.
func (s *Store) Now() time.Time { return s.clock() }

// ---------------------------------------------------------------------------
// Users
// ---------------------------------------------------------------------------

// Register creates a user. Emails are case-folded and trimmed.
func (s *Store) Register(_ context.Context, email, password, displayName string) (*User, error) {
	email = normalizeEmail(email)
	if email == "" || !strings.Contains(email, "@") {
		return nil, errors.New("a valid email is required")
	}
	hash, err := HashPassword(password)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.usersByEmail[email]; exists {
		return nil, ErrEmailTaken
	}
	user := &User{
		ID:            newID("usr"),
		Email:         email,
		DisplayName:   strings.TrimSpace(displayName),
		PasswordHash:  hash,
		CreatedAt:     s.clock().UTC(),
		EmailVerified: false,
	}
	s.usersByEmail[email] = user
	s.usersByID[user.ID] = user
	return user, nil
}

// Authenticate verifies the credentials.
func (s *Store) Authenticate(_ context.Context, email, password string) (*User, error) {
	email = normalizeEmail(email)
	s.mu.RLock()
	user, ok := s.usersByEmail[email]
	s.mu.RUnlock()
	if !ok {
		// Burn comparable time so unknown users are indistinguishable from
		// wrong passwords.
		_ = VerifyPassword(password, dummyHash)
		return nil, ErrInvalidCredentials
	}
	if !VerifyPassword(password, user.PasswordHash) {
		return nil, ErrInvalidCredentials
	}
	return user, nil
}

// dummyHash is a well-formed hash of an unguessable password, used only to
// equalize timing for unknown users.
var dummyHash = func() string {
	salt := make([]byte, saltLen)
	for i := range salt {
		salt[i] = 0x5a
	}
	dk := PBKDF2SHA256([]byte("spotiflac-dummy-password"), salt, passwordIterations, passwordKeyLen)
	return fmt.Sprintf(
		"pbkdf2-sha256$%d$%s$%s",
		passwordIterations,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(dk),
	)
}()

// UserByID looks a user up by id.
func (s *Store) UserByID(_ context.Context, id string) (*User, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	user, ok := s.usersByID[id]
	if !ok {
		return nil, ErrUnauthorized
	}
	return user, nil
}

// ---------------------------------------------------------------------------
// Refresh tokens (rotation + reuse detection)
// ---------------------------------------------------------------------------

// RefreshTTL is the refresh-token lifetime.
const RefreshTTL = 30 * 24 * time.Hour

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func newTokenMaterial() (string, error) {
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("token material: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(raw), nil
}

// IssueSession creates a fresh access + refresh token pair for the user.
// deviceID may be empty (untracked sign-in).
func (s *Store) IssueSession(_ context.Context, user *User, deviceID string, token *TokenIssuer) (*Session, error) {
	access, err := token.Issue(user.ID)
	if err != nil {
		return nil, err
	}
	material, err := newTokenMaterial()
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	s.refresh[hashToken(material)] = &refreshRecord{
		hash:     hashToken(material),
		userID:   user.ID,
		deviceID: deviceID,
		expires:  s.clock().UTC().Add(RefreshTTL),
	}
	s.mu.Unlock()
	return &Session{
		AccessToken:  access,
		RefreshToken: material,
		ExpiresIn:    int64(TokenTTL.Seconds()),
		User:         *user,
	}, nil
}

// RotateRefreshToken exchanges a refresh token for a fresh session.
// Presenting an already-rotated token revokes every session of its owner
// (reuse detection, RFC 6749 §10.4 / OAuth BCP).
func (s *Store) RotateRefreshToken(ctx context.Context, refreshToken string, token *TokenIssuer) (*Session, error) {
	hash := hashToken(refreshToken)
	now := s.clock().UTC()

	s.mu.Lock()
	record, ok := s.refresh[hash]
	if ok {
		if now.After(record.expires) {
			delete(s.refresh, hash)
			s.mu.Unlock()
			return nil, ErrUnauthorized
		}
		user, okUser := s.usersByID[record.userID]
		if !okUser {
			delete(s.refresh, hash)
			s.mu.Unlock()
			return nil, ErrUnauthorized
		}
		deviceID := record.deviceID
		delete(s.refresh, hash)
		s.rotated[hash] = true
		s.rotatedOwner[hash] = user.ID
		s.mu.Unlock()

		if deviceID != "" {
			s.TouchDevice(ctx, user.ID, deviceID)
		}
		return s.IssueSession(ctx, user, deviceID, token)
	}
	s.mu.Unlock()

	if s.isRotated(hash) {
		s.revokeAllForRotated(hash)
		return nil, ErrUnauthorized
	}
	return nil, ErrUnauthorized
}

func (s *Store) isRotated(hash string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.rotated[hash]
}

// revokeAllForRotated evicts every live refresh token of the user who
// originally owned the rotated token identified by hash.
func (s *Store) revokeAllForRotated(hash string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	userID, ok := s.rotatedOwner[hash]
	if !ok {
		return
	}
	for h, record := range s.refresh {
		if record.userID == userID {
			delete(s.refresh, h)
			s.rotated[h] = true
			s.rotatedOwner[h] = userID
		}
	}
}

// RevokeRefreshToken removes one token (logout) and remembers its owner so
// a later reuse attempt is still detected.
func (s *Store) RevokeRefreshToken(_ context.Context, refreshToken string) {
	hash := hashToken(refreshToken)
	s.mu.Lock()
	defer s.mu.Unlock()
	if record, ok := s.refresh[hash]; ok {
		s.rotatedOwner[hash] = record.userID
		delete(s.refresh, hash)
		s.rotated[hash] = true
	}
}

// ---------------------------------------------------------------------------
// Devices
// ---------------------------------------------------------------------------

// maxDevicesPerUser bounds the fleet per account.
const maxDevicesPerUser = 32

// RegisterDevice upserts a device for the user and returns the full list.
func (s *Store) RegisterDevice(_ context.Context, userID, deviceID, name, platform string) ([]*Device, error) {
	if strings.TrimSpace(deviceID) == "" {
		return nil, errors.New("deviceId is required")
	}
	now := s.clock().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	list := s.devices[userID]
	for _, device := range list {
		if device.ID == deviceID {
			device.Name = strings.TrimSpace(name)
			device.Platform = strings.TrimSpace(platform)
			device.LastSeenAt = now
			return copyDevices(list), nil
		}
	}
	list = append(list, &Device{
		ID:         deviceID,
		Name:       strings.TrimSpace(name),
		Platform:   strings.TrimSpace(platform),
		CreatedAt:  now,
		LastSeenAt: now,
	})
	if len(list) > maxDevicesPerUser {
		sort.Slice(list, func(i, j int) bool {
			return list[i].LastSeenAt.Before(list[j].LastSeenAt)
		})
		list = list[len(list)-maxDevicesPerUser:]
	}
	s.devices[userID] = list
	return copyDevices(list), nil
}

// Devices lists the user's devices, newest activity first.
func (s *Store) Devices(_ context.Context, userID string) []*Device {
	s.mu.RLock()
	defer s.mu.RUnlock()
	list := copyDevices(s.devices[userID])
	sort.Slice(list, func(i, j int) bool {
		return list[i].LastSeenAt.After(list[j].LastSeenAt)
	})
	return list
}

// RevokeDevice removes a device and its refresh tokens.
func (s *Store) RevokeDevice(_ context.Context, userID, deviceID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := s.devices[userID]
	found := false
	kept := make([]*Device, 0, len(list))
	for _, device := range list {
		if device.ID == deviceID {
			found = true
			continue
		}
		kept = append(kept, device)
	}
	if !found {
		return errors.New("device not found")
	}
	s.devices[userID] = kept
	for hash, record := range s.refresh {
		if record.userID == userID && record.deviceID == deviceID {
			delete(s.refresh, hash)
		}
	}
	return nil
}

// TouchDevice refreshes lastSeenAt (best effort; unknown devices are
// ignored — registration is the source of truth).
func (s *Store) TouchDevice(_ context.Context, userID, deviceID string) {
	now := s.clock().UTC()
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, device := range s.devices[userID] {
		if device.ID == deviceID {
			device.LastSeenAt = now
			return
		}
	}
}

func copyDevices(list []*Device) []*Device {
	out := make([]*Device, 0, len(list))
	for _, device := range list {
		clone := *device
		out = append(out, &clone)
	}
	return out
}

func normalizeEmail(email string) string {
	return strings.ToLower(strings.TrimSpace(email))
}

func newID(prefix string) string {
	raw := make([]byte, 12)
	if _, err := rand.Read(raw); err != nil {
		// crypto/rand never fails on the supported platforms; panicking is
		// honest rather than issuing colliding ids.
		panic(fmt.Sprintf("auth: entropy unavailable: %v", err))
	}
	return prefix + "_" + hex.EncodeToString(raw)
}

// NewUserID exposes id generation for other packages.
func NewUserID() string { return newID("usr") }
