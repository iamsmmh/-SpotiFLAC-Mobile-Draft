// Package collaboration implements collaborative playlists for the
// SpotiFLAC Cloud (Milestone 4).
//
// Features:
//   - Invite users to a playlist
//   - Role-based access control (OWNER, EDITOR, VIEWER)
//   - Real-time change tracking via revision numbers
//   - WebSocket-based live updates
//
// Tables:
//   - playlist_members  (user ↔ playlist membership)
//   - playlist_invites  (pending invitations)
//   - playlist_changes  (audit log of modifications)
//
// Conflict resolution: last-writer-wins on individual track entries,
// with revision-based optimistic locking on structural changes (rename,
// reorder).
package collaboration

import (
	"context"
	"errors"
	"time"
)

// Errors returned by the collaboration package.
var (
	ErrNotFound       = errors.New("playlist not found")
	ErrForbidden      = errors.New("insufficient permissions")
	ErrInvalidInput   = errors.New("invalid input")
	ErrAlreadyMember  = errors.New("user is already a member")
	ErrInviteNotFound = errors.New("invite not found")
	ErrInviteExpired  = errors.New("invite has expired")
)

// Role defines access levels for playlist collaboration.
type Role string

const (
	RoleOwner  Role = "OWNER"
	RoleEditor Role = "EDITOR"
	RoleViewer Role = "VIEWER"
)

// CanEdit reports whether the role permits adding/removing tracks.
func (r Role) CanEdit() bool {
	return r == RoleOwner || r == RoleEditor
}

// CanManage reports whether the role permits inviting/removing members.
func (r Role) CanManage() bool {
	return r == RoleOwner
}

// Member represents a user's membership in a collaborative playlist.
type Member struct {
	PlaylistID string    `json:"playlistId"`
	UserID     string    `json:"userId"`
	Handle     string    `json:"handle"`
	Role       Role      `json:"role"`
	JoinedAt   time.Time `json:"joinedAt"`
}

// Invite represents a pending invitation to join a playlist.
type Invite struct {
	ID           string     `json:"id"`
	PlaylistID   string     `json:"playlistId"`
	PlaylistName string     `json:"playlistName"`
	InviterID    string     `json:"inviterId"`
	InviteeID    string     `json:"inviteeId"`
	Role         Role       `json:"role"`
	CreatedAt    time.Time  `json:"createdAt"`
	ExpiresAt    time.Time  `json:"expiresAt"`
	AcceptedAt   *time.Time `json:"acceptedAt,omitempty"`
}

// Change records one modification to a collaborative playlist.
type Change struct {
	ID         string `json:"id"`
	PlaylistID string `json:"playlistId"`
	UserID     string `json:"userId"`
	Action     string    `json:"action"` // "add", "remove", "reorder", "rename"
	TrackID   string    `json:"trackId,omitempty"`
	Position  int       `json:"position,omitempty"`
	Revision  int64     `json:"revision"`
	CreatedAt time.Time `json:"createdAt"`
}

// Store abstracts the persistence layer.
type Store interface {
	// Member operations
	GetMember(ctx context.Context, playlistID, userID string) (*Member, error)
	AddMember(ctx context.Context, member Member) error
	RemoveMember(ctx context.Context, playlistID, userID string) error
	ListMembers(ctx context.Context, playlistID string) ([]Member, error)
	SetRole(ctx context.Context, playlistID, userID string, role Role) error

	// Invite operations
	CreateInvite(ctx context.Context, invite Invite) error
	GetInvite(ctx context.Context, inviteID string) (*Invite, error)
	ListInvites(ctx context.Context, playlistID string) ([]Invite, error)
	AcceptInvite(ctx context.Context, inviteID string, at time.Time) error
	DeleteInvite(ctx context.Context, inviteID string) error

	// Change log
	RecordChange(ctx context.Context, change Change) error
	ListChanges(ctx context.Context, playlistID string, sinceRevision int64) ([]Change, error)

	// Playlist-level queries
	ListCollaborativePlaylists(ctx context.Context, userID string) ([]string, error)
}

// Service provides collaboration operations.
type Service struct {
	store Store
}

// NewService creates a new collaboration service.
func NewService(store Store) *Service {
	return &Service{store: store}
}

// InviteUser creates an invitation for a user to join a playlist.
func (s *Service) InviteUser(
	ctx context.Context,
	playlistID string,
	inviterID string,
	inviteeID string,
	role Role,
) (*Invite, error) {
	if playlistID == "" || inviterID == "" || inviteeID == "" {
		return nil, ErrInvalidInput
	}
	// Verify inviter has manage permission.
	inviter, err := s.store.GetMember(ctx, playlistID, inviterID)
	if err != nil {
		return nil, ErrForbidden
	}
	if !inviter.Role.CanManage() {
		return nil, ErrForbidden
	}
	// Check if invitee is already a member.
	if _, err := s.store.GetMember(ctx, playlistID, inviteeID); err == nil {
		return nil, ErrAlreadyMember
	}

	now := time.Now().UTC()
	invite := Invite{
		ID:         generateInviteID(inviterID, inviteeID, playlistID, now),
		PlaylistID: playlistID,
		InviterID:  inviterID,
		InviteeID:  inviteeID,
		Role:       role,
		CreatedAt:  now,
		ExpiresAt:  now.Add(7 * 24 * time.Hour), // 7-day expiry
	}
	if err := s.store.CreateInvite(ctx, invite); err != nil {
		return nil, err
	}
	return &invite, nil
}

// AcceptInvite accepts a pending invitation.
func (s *Service) AcceptInvite(ctx context.Context, inviteID, userID string) (*Member, error) {
	invite, err := s.store.GetInvite(ctx, inviteID)
	if err != nil {
		return nil, ErrInviteNotFound
	}
	if invite.InviteeID != userID {
		return nil, ErrForbidden
	}
	if time.Now().After(invite.ExpiresAt) {
		return nil, ErrInviteExpired
	}
	now := time.Now().UTC()
	if err := s.store.AcceptInvite(ctx, inviteID, now); err != nil {
		return nil, err
	}
	member := Member{
		PlaylistID: invite.PlaylistID,
		UserID:     userID,
		Role:       invite.Role,
		JoinedAt:   now,
	}
	if err := s.store.AddMember(ctx, member); err != nil {
		return nil, err
	}
	return &member, nil
}

// RemoveUser removes a member from a collaborative playlist.
func (s *Service) RemoveUser(ctx context.Context, playlistID, removerID, targetID string) error {
	remover, err := s.store.GetMember(ctx, playlistID, removerID)
	if err != nil {
		return ErrForbidden
	}
	if !remover.Role.CanManage() && removerID != targetID {
		return ErrForbidden
	}
	return s.store.RemoveMember(ctx, playlistID, targetID)
}

// ChangeRole updates a member's role.
func (s *Service) ChangeRole(ctx context.Context, playlistID, changerID, targetID string, newRole Role) error {
	changer, err := s.store.GetMember(ctx, playlistID, changerID)
	if err != nil {
		return ErrForbidden
	}
	if !changer.Role.CanManage() {
		return ErrForbidden
	}
	return s.store.SetRole(ctx, playlistID, targetID, newRole)
}

// RecordTrackChange records a track-level modification.
func (s *Service) RecordTrackChange(ctx context.Context, userID, playlistID, action, trackID string, position int) error {
	member, err := s.store.GetMember(ctx, playlistID, userID)
	if err != nil {
		return ErrForbidden
	}
	if !member.Role.CanEdit() {
		return ErrForbidden
	}
	change := Change{
		PlaylistID: playlistID,
		UserID:     userID,
		Action:     action,
		TrackID:    trackID,
		Position:   position,
		CreatedAt:  time.Now().UTC(),
	}
	return s.store.RecordChange(ctx, change)
}

// GetChanges returns all changes since the given revision.
func (s *Service) GetChanges(ctx context.Context, playlistID string, sinceRevision int64) ([]Change, error) {
	return s.store.ListChanges(ctx, playlistID, sinceRevision)
}

// ListMembers returns all members of a playlist.
func (s *Service) ListMembers(ctx context.Context, playlistID string) ([]Member, error) {
	return s.store.ListMembers(ctx, playlistID)
}

// generateInviteID creates a deterministic invite ID.
func generateInviteID(inviterID, inviteeID, playlistID string, at time.Time) string {
	// Simple concatenation-based ID; production would use crypto/rand.
	return playlistID + ":" + inviteeID + ":" + inviterID
}
