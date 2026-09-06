// Package playlists implements the playlist scope services on top of the
// sync record store: payload validation and the public share-link registry
// that backs QR / deep-link playlist sharing.
package playlists

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/zarz/spotiflac_android/backend/sync"
)

// Limits mirror the client-side codec (SharedPlaylistSyncPayload).
const (
	MaxTitleRunes       = 200
	MaxDescriptionRunes = 2000
	MaxTrackKeys        = 10_000
)

// Validation errors.
var (
	ErrPlaylistInvalid = errors.New("playlist payload is invalid")
	ErrPlaylistTooBig  = errors.New("playlist exceeds the size limits")
)

var slugPattern = regexp.MustCompile(`^pl_[A-Za-z0-9_-]{20,64}$`)

// Payload is the canonical shared-playlist payload (same keys the mobile
// client encodes).
type Payload struct {
	PlaylistID  string    `json:"playlistId"`
	Title       string    `json:"title"`
	TrackKeys   []string  `json:"trackKeys"`
	Description string    `json:"description"`
	CoverURL    string    `json:"coverUrl,omitempty"`
	IsPublic    bool      `json:"isPublic"`
	PublishedAt time.Time `json:"publishedAt,omitempty"`
}

// Validate normalizes and validates a playlist payload from a sync record.
func Validate(payload map[string]any) (Payload, error) {
	var out Payload
	out.PlaylistID = stringField(payload, "playlistId")
	out.Title = strings.TrimSpace(stringField(payload, "title"))
	out.Description = strings.TrimSpace(stringField(payload, "description"))
	out.CoverURL = strings.TrimSpace(stringField(payload, "coverUrl"))
	out.IsPublic = boolField(payload, "isPublic")
	if raw, ok := payload["trackKeys"].([]any); ok {
		out.TrackKeys = make([]string, 0, len(raw))
		for _, key := range raw {
			trimmed := strings.TrimSpace(fmt.Sprintf("%v", key))
			if trimmed != "" {
				out.TrackKeys = append(out.TrackKeys, trimmed)
			}
		}
	}
	if out.PlaylistID == "" || out.Title == "" {
		return out, ErrPlaylistInvalid
	}
	if len([]rune(out.Title)) > MaxTitleRunes ||
		len([]rune(out.Description)) > MaxDescriptionRunes ||
		len(out.TrackKeys) > MaxTrackKeys {
		return out, ErrPlaylistTooBig
	}
	if raw, ok := payload["publishedAt"].(string); ok {
		if parsed, err := time.Parse(time.RFC3339Nano, raw); err == nil {
			out.PublishedAt = parsed
		}
	}
	return out, nil
}

func stringField(payload map[string]any, key string) string {
	if value, ok := payload[key]; ok {
		return strings.TrimSpace(fmt.Sprintf("%v", value))
	}
	return ""
}

func boolField(payload map[string]any, key string) bool {
	value, ok := payload[key].(bool)
	return ok && value
}

// ---------------------------------------------------------------------------
// Share links
// ---------------------------------------------------------------------------

// Share is one published playlist link.
type Share struct {
	Slug      string    `json:"slug"`
	OwnerID   string    `json:"ownerId"`
	RecordID  string    `json:"recordId"`
	CreatedAt time.Time `json:"createdAt"`
	// Views counts fetches through the public endpoint (diagnostics).
	Views int64 `json:"views"`
}

// Service owns the slug registry.
type Service struct {
	mu     sync.RWMutex
	shares map[string]*Share // slug → share

	store *sync.Store
	clock func() time.Time
}

// NewService builds the share service over the sync store.
func NewService(store *sync.Store, clock func() time.Time) *Service {
	if clock == nil {
		clock = time.Now
	}
	return &Service{
		shares: map[string]*Share{},
		store:  store,
		clock:  clock,
	}
}

// NewSlug mints a fresh share slug ("pl_" + 22 url-safe chars).
func NewSlug() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", fmt.Errorf("share slug: %w", err)
	}
	return "pl_" + base64.RawURLEncoding.EncodeToString(raw), nil
}

// ValidSlug reports whether slug has the expected shape.
func ValidSlug(slug string) bool { return slugPattern.MatchString(slug) }

// Publish validates the record payload and mints (or reuses) a share link.
func (s *Service) Publish(ctx context.Context, userID, recordID string, payload map[string]any) (*Share, error) {
	if _, err := Validate(payload); err != nil {
		return nil, err
	}
	if !payloadPublic(payload) {
		return nil, ErrPlaylistInvalid
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, share := range s.shares {
		if share.OwnerID == userID && share.RecordID == recordID {
			return cloneShare(share), nil
		}
	}
	slug, err := NewSlug()
	if err != nil {
		return nil, err
	}
	share := &Share{
		Slug:      slug,
		OwnerID:   userID,
		RecordID:  recordID,
		CreatedAt: s.clock().UTC(),
	}
	s.shares[slug] = share
	return cloneShare(share), nil
}

func payloadPublic(payload map[string]any) bool {
	public, ok := payload["isPublic"].(bool)
	return ok && public
}

// Unpublish removes a share link (owner only).
func (s *Service) Unpublish(ctx context.Context, userID, slug string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	share, ok := s.shares[slug]
	if !ok || share.OwnerID != userID {
		return errors.New("share not found")
	}
	delete(s.shares, slug)
	return nil
}

// ResolvedShare is the public view of a shared playlist.
type ResolvedShare struct {
	Share
	Playlist Payload
}

// Resolve follows a slug to the current playlist payload. The referenced
// record must still exist and stay public.
func (s *Service) Resolve(ctx context.Context, slug string) (*ResolvedShare, error) {
	if !ValidSlug(slug) {
		return nil, errors.New("invalid share slug")
	}
	s.mu.Lock()
	share, ok := s.shares[slug]
	if ok {
		share.Views++
	}
	s.mu.Unlock()
	if !ok {
		return nil, errors.New("share not found")
	}
	records, err := s.store.Pull(ctx, share.OwnerID, "playlists", 0)
	if err != nil {
		return nil, err
	}
	for _, record := range records {
		if record.RecordID != share.RecordID || record.Deleted {
			continue
		}
		payload, err := Validate(record.Payload)
		if err != nil {
			return nil, err
		}
		if !payload.IsPublic {
			return nil, errors.New("playlist is no longer public")
		}
		return &ResolvedShare{Share: *cloneShare(share), Playlist: payload}, nil
	}
	return nil, errors.New("playlist no longer exists")
}

func cloneShare(share *Share) *Share {
	clone := *share
	return &clone
}
