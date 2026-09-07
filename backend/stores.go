package main

// In-memory store implementations for the new backend modules.
// These provide the reference implementations that the server wires up
// when no external database is configured.
//
// In production, each Store interface would be backed by PostgreSQL.
// The in-memory implementations here allow the server to run in
// single-process mode without any external dependencies, which is
// useful for development, testing, and small deployments.

import (
	"context"
	"sync"
	"time"

	"github.com/zarz/spotiflac_android/backend/collaboration"
	"github.com/zarz/spotiflac_android/backend/devices"
	"github.com/zarz/spotiflac_android/backend/marketplace"
	"github.com/zarz/spotiflac_android/backend/telemetry"
	"github.com/zarz/spotiflac_android/backend/users"
)

// ---------------------------------------------------------------------------
// User Store (in-memory)
// ---------------------------------------------------------------------------

type inMemoryUserStore struct {
	clock    func() time.Time
	mu       sync.RWMutex
	profiles map[string]*users.Profile
}

func (s *inMemoryUserStore) GetProfile(_ context.Context, userID string) (*users.Profile, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	p, ok := s.profiles[userID]
	if !ok {
		return nil, users.ErrNotFound
	}
	return p, nil
}

func (s *inMemoryUserStore) UpdateProfile(_ context.Context, userID string, req users.UpdateRequest) (*users.Profile, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.profiles == nil {
		s.profiles = make(map[string]*users.Profile)
	}
	p, ok := s.profiles[userID]
	if !ok {
		p = &users.Profile{UserID: userID, CreatedAt: s.clock()}
	}
	if req.DisplayName != "" {
		p.DisplayName = req.DisplayName
	}
	if req.Bio != "" {
		p.Bio = req.Bio
	}
	if req.AvatarURL != "" {
		p.AvatarURL = req.AvatarURL
	}
	if req.IsPublic != nil {
		p.IsPublic = *req.IsPublic
	}
	s.profiles[userID] = p
	return p, nil
}

func (s *inMemoryUserStore) ListPublicProfiles(_ context.Context, limit, offset int) ([]*users.Profile, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var result []*users.Profile
	for _, p := range s.profiles {
		if p.IsPublic {
			result = append(result, p)
		}
	}
	if offset >= len(result) {
		return nil, nil
	}
	end := offset + limit
	if end > len(result) {
		end = len(result)
	}
	return result[offset:end], nil
}

func (s *inMemoryUserStore) DeleteAccount(_ context.Context, userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.profiles, userID)
	return nil
}

func (s *inMemoryUserStore) VerifyEmail(_ context.Context, userID string) error {
	return nil
}

// ---------------------------------------------------------------------------
// Device Store (in-memory)
// ---------------------------------------------------------------------------

type inMemoryDeviceStore struct {
	clock   func() time.Time
	mu      sync.RWMutex
	devices map[string]map[string]*devices.Device // userID → deviceID → Device
}

func (s *inMemoryDeviceStore) Register(_ context.Context, userID string, req devices.RegisterRequest) (*devices.Device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.devices == nil {
		s.devices = make(map[string]map[string]*devices.Device)
	}
	if s.devices[userID] == nil {
		s.devices[userID] = make(map[string]*devices.Device)
	}
	now := s.clock()
	d := &devices.Device{
		ID:         req.ID,
		UserID:     userID,
		Name:       req.Name,
		Platform:   req.Platform,
		CreatedAt:  now,
		LastSeenAt: now,
	}
	s.devices[userID][req.ID] = d
	return d, nil
}

func (s *inMemoryDeviceStore) Get(_ context.Context, userID, deviceID string) (*devices.Device, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if userDevs, ok := s.devices[userID]; ok {
		if d, ok := userDevs[deviceID]; ok {
			return d, nil
		}
	}
	return nil, devices.ErrNotFound
}

func (s *inMemoryDeviceStore) List(_ context.Context, userID string) ([]*devices.Device, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var result []*devices.Device
	for _, d := range s.devices[userID] {
		result = append(result, d)
	}
	return result, nil
}

func (s *inMemoryDeviceStore) UpdateLastSeen(_ context.Context, userID, deviceID string, at time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if userDevs, ok := s.devices[userID]; ok {
		if d, ok := userDevs[deviceID]; ok {
			d.LastSeenAt = at
		}
	}
	return nil
}

func (s *inMemoryDeviceStore) UpdateLastSync(_ context.Context, userID, deviceID string, at time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if userDevs, ok := s.devices[userID]; ok {
		if d, ok := userDevs[deviceID]; ok {
			d.LastSyncAt = at
		}
	}
	return nil
}

func (s *inMemoryDeviceStore) Revoke(_ context.Context, userID, deviceID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if userDevs, ok := s.devices[userID]; ok {
		delete(userDevs, deviceID)
	}
	return nil
}

func (s *inMemoryDeviceStore) RevokeAll(_ context.Context, userID, exceptDeviceID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id := range s.devices[userID] {
		if id != exceptDeviceID {
			delete(s.devices[userID], id)
		}
	}
	return nil
}

func (s *inMemoryDeviceStore) SetTrusted(_ context.Context, userID, deviceID string, trusted bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if userDevs, ok := s.devices[userID]; ok {
		if d, ok := userDevs[deviceID]; ok {
			d.Trusted = trusted
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Collaboration Store (in-memory)
// ---------------------------------------------------------------------------

type inMemoryCollabStore struct {
	clock    func() time.Time
	mu       sync.RWMutex
	members  map[string][]collaboration.Member
	invites  map[string]*collaboration.Invite
	changes  map[string][]collaboration.Change
	revision map[string]int64
}

func (s *inMemoryCollabStore) GetMember(_ context.Context, playlistID, userID string) (*collaboration.Member, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, m := range s.members[playlistID] {
		if m.UserID == userID {
			return &m, nil
		}
	}
	return nil, collaboration.ErrNotFound
}

func (s *inMemoryCollabStore) AddMember(_ context.Context, member collaboration.Member) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.members[member.PlaylistID] = append(s.members[member.PlaylistID], member)
	return nil
}

func (s *inMemoryCollabStore) RemoveMember(_ context.Context, playlistID, userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	members := s.members[playlistID]
	for i, m := range members {
		if m.UserID == userID {
			s.members[playlistID] = append(members[:i], members[i+1:]...)
			return nil
		}
	}
	return nil
}

func (s *inMemoryCollabStore) ListMembers(_ context.Context, playlistID string) ([]collaboration.Member, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.members[playlistID], nil
}

func (s *inMemoryCollabStore) SetRole(_ context.Context, playlistID, userID string, role collaboration.Role) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	for i, m := range s.members[playlistID] {
		if m.UserID == userID {
			s.members[playlistID][i].Role = role
			return nil
		}
	}
	return nil
}

func (s *inMemoryCollabStore) CreateInvite(_ context.Context, invite collaboration.Invite) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.invites == nil {
		s.invites = make(map[string]*collaboration.Invite)
	}
	s.invites[invite.ID] = &invite
	return nil
}

func (s *inMemoryCollabStore) GetInvite(_ context.Context, inviteID string) (*collaboration.Invite, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	inv, ok := s.invites[inviteID]
	if !ok {
		return nil, collaboration.ErrInviteNotFound
	}
	return inv, nil
}

func (s *inMemoryCollabStore) ListInvites(_ context.Context, playlistID string) ([]collaboration.Invite, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var result []collaboration.Invite
	for _, inv := range s.invites {
		if inv.PlaylistID == playlistID && inv.AcceptedAt == nil {
			result = append(result, *inv)
		}
	}
	return result, nil
}

func (s *inMemoryCollabStore) AcceptInvite(_ context.Context, inviteID string, at time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if inv, ok := s.invites[inviteID]; ok {
		inv.AcceptedAt = &at
	}
	return nil
}

func (s *inMemoryCollabStore) DeleteInvite(_ context.Context, inviteID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.invites, inviteID)
	return nil
}

func (s *inMemoryCollabStore) RecordChange(_ context.Context, change collaboration.Change) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.revision == nil {
		s.revision = make(map[string]int64)
	}
	s.revision[change.PlaylistID]++
	change.Revision = s.revision[change.PlaylistID]
	s.changes[change.PlaylistID] = append(s.changes[change.PlaylistID], change)
	return nil
}

func (s *inMemoryCollabStore) ListChanges(_ context.Context, playlistID string, sinceRevision int64) ([]collaboration.Change, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var result []collaboration.Change
	for _, c := range s.changes[playlistID] {
		if c.Revision > sinceRevision {
			result = append(result, c)
		}
	}
	return result, nil
}

func (s *inMemoryCollabStore) ListCollaborativePlaylists(_ context.Context, userID string) ([]string, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var result []string
	for pid, members := range s.members {
		for _, m := range members {
			if m.UserID == userID {
				result = append(result, pid)
				break
			}
		}
	}
	return result, nil
}

// ---------------------------------------------------------------------------
// Marketplace Store (in-memory)
// ---------------------------------------------------------------------------

type inMemoryMarketStore struct {
	clock     func() time.Time
	mu        sync.RWMutex
	extensions map[string]*marketplace.Extension
	reviews    map[string][]marketplace.Review
	installs   map[string]map[string]*marketplace.InstallRecord
}

func (s *inMemoryMarketStore) GetExtension(_ context.Context, id string) (*marketplace.Extension, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	ext, ok := s.extensions[id]
	if !ok {
		return nil, marketplace.ErrNotFound
	}
	return ext, nil
}

func (s *inMemoryMarketStore) ListExtensions(_ context.Context, req marketplace.SearchRequest) ([]*marketplace.Extension, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var result []*marketplace.Extension
	for _, ext := range s.extensions {
		result = append(result, ext)
	}
	return result, nil
}

func (s *inMemoryMarketStore) PublishExtension(_ context.Context, ext marketplace.Extension) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.extensions == nil {
		s.extensions = make(map[string]*marketplace.Extension)
	}
	s.extensions[ext.ID] = &ext
	return nil
}

func (s *inMemoryMarketStore) UpdateExtension(ctx context.Context, ext marketplace.Extension) error {
	return s.PublishExtension(ctx, ext)
}

func (s *inMemoryMarketStore) GetReviews(_ context.Context, extensionID string, limit, offset int) ([]marketplace.Review, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.reviews[extensionID], nil
}

func (s *inMemoryMarketStore) AddReview(_ context.Context, review marketplace.Review) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.reviews == nil {
		s.reviews = make(map[string][]marketplace.Review)
	}
	s.reviews[review.ExtensionID] = append(s.reviews[review.ExtensionID], review)
	return nil
}

func (s *inMemoryMarketStore) GetAverageRating(_ context.Context, extensionID string) (float64, int, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	reviews := s.reviews[extensionID]
	if len(reviews) == 0 {
		return 0, 0, nil
	}
	var sum int
	for _, r := range reviews {
		sum += r.Rating
	}
	return float64(sum) / float64(len(reviews)), len(reviews), nil
}

func (s *inMemoryMarketStore) Install(_ context.Context, record marketplace.InstallRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.installs == nil {
		s.installs = make(map[string]map[string]*marketplace.InstallRecord)
	}
	if s.installs[record.ExtensionID] == nil {
		s.installs[record.ExtensionID] = make(map[string]*marketplace.InstallRecord)
	}
	s.installs[record.ExtensionID][record.UserID] = &record
	return nil
}

func (s *inMemoryMarketStore) Uninstall(_ context.Context, extensionID, userID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if userInstalls, ok := s.installs[extensionID]; ok {
		delete(userInstalls, userID)
	}
	return nil
}

func (s *inMemoryMarketStore) GetUserInstalls(_ context.Context, userID string) ([]marketplace.InstallRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var result []marketplace.InstallRecord
	for _, userInstalls := range s.installs {
		if rec, ok := userInstalls[userID]; ok {
			result = append(result, *rec)
		}
	}
	return result, nil
}

func (s *inMemoryMarketStore) CheckUpdates(_ context.Context, userID string) ([]marketplace.Extension, error) {
	return nil, nil
}

func (s *inMemoryMarketStore) RecordAnalytics(_ context.Context, record marketplace.AnalyticsRecord) error {
	return nil
}

func (s *inMemoryMarketStore) GetAnalytics(_ context.Context, extensionID string, period string) ([]marketplace.AnalyticsRecord, error) {
	return nil, nil
}

func (s *inMemoryMarketStore) SetVerified(_ context.Context, extensionID string, verified bool) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if ext, ok := s.extensions[extensionID]; ok {
		ext.Verified = verified
	}
	return nil
}

// ---------------------------------------------------------------------------
// Telemetry Store (in-memory)
// ---------------------------------------------------------------------------

type inMemoryTelStore struct {
	clock   func() time.Time
	mu      sync.RWMutex
	events  []telemetry.Event
	health  map[string]*telemetry.ProviderHealth
}

func (s *inMemoryTelStore) Ingest(_ context.Context, event telemetry.Event) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.events = append(s.events, event)
	// Cap at 10k events in memory.
	if len(s.events) > 10000 {
		s.events = s.events[len(s.events)-10000:]
	}
	return nil
}

func (s *inMemoryTelStore) Query(_ context.Context, userID string, eventType telemetry.EventType, since time.Time, limit int) ([]telemetry.Event, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var result []telemetry.Event
	for _, e := range s.events {
		if e.UserID != userID {
			continue
		}
		if eventType != "" && e.Type != eventType {
			continue
		}
		if e.CreatedAt.Before(since) {
			continue
		}
		result = append(result, e)
		if len(result) >= limit {
			break
		}
	}
	return result, nil
}

func (s *inMemoryTelStore) Summarize(_ context.Context, period string, since time.Time) (*telemetry.MetricsSummary, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var total, successes, streamFails, downloadFails, crashes int64
	for _, e := range s.events {
		if e.CreatedAt.Before(since) {
			continue
		}
		switch e.Type {
		case "playback_result":
			total++
			if e.Success != nil && *e.Success {
				successes++
			}
		case "stream_failure":
			streamFails++
		case "download_failure":
			downloadFails++
		case "crash":
			crashes++
		}
	}
	rate := 0.0
	if total > 0 {
		rate = float64(successes) / float64(total) * 100
	}
	return &telemetry.MetricsSummary{
		Period:            period,
		PlaybackSuccess:   rate,
		StreamFailures:    streamFails,
		DownloadFailures:  downloadFails,
		ProviderAvailable: 100,
		SyncLatencyMs:     0,
		CrashCount:        crashes,
		ActiveUsers:       0,
	}, nil
}

func (s *inMemoryTelStore) ProviderHealth(_ context.Context) ([]telemetry.ProviderHealth, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var result []telemetry.ProviderHealth
	for _, h := range s.health {
		result = append(result, *h)
	}
	return result, nil
}

func (s *inMemoryTelStore) RecordProviderHealth(_ context.Context, health telemetry.ProviderHealth) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.health == nil {
		s.health = make(map[string]*telemetry.ProviderHealth)
	}
	s.health[health.ProviderID] = &health
	return nil
}
