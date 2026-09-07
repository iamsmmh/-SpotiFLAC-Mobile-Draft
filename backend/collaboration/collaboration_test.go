package collaboration

import (
	"context"
	"testing"
	"time"
)

func TestRolePermissions(t *testing.T) {
	tests := []struct {
		role      Role
		canEdit   bool
		canManage bool
	}{
		{RoleOwner, true, true},
		{RoleEditor, true, false},
		{RoleViewer, false, false},
	}
	for _, tt := range tests {
		if got := tt.role.CanEdit(); got != tt.canEdit {
			t.Errorf("Role(%s).CanEdit() = %v, want %v", tt.role, got, tt.canEdit)
		}
		if got := tt.role.CanManage(); got != tt.canManage {
			t.Errorf("Role(%s).CanManage() = %v, want %v", tt.role, got, tt.canManage)
		}
	}
}

func TestInviteUser(t *testing.T) {
	store := &fakeStore{
		members: map[string][]Member{
			"pl-1": {
				{PlaylistID: "pl-1", UserID: "owner-1", Role: RoleOwner},
			},
		},
	}
	svc := NewService(store)

	invite, err := svc.InviteUser(context.Background(), "pl-1", "owner-1", "user-2", RoleEditor)
	if err != nil {
		t.Fatalf("InviteUser failed: %v", err)
	}
	if invite == nil {
		t.Fatal("expected invite, got nil")
	}
	if invite.InviteeID != "user-2" {
		t.Errorf("expected invitee user-2, got %s", invite.InviteeID)
	}
	if invite.Role != RoleEditor {
		t.Errorf("expected role EDITOR, got %s", invite.Role)
	}
}

func TestInviteUserForbidden(t *testing.T) {
	store := &fakeStore{
		members: map[string][]Member{
			"pl-1": {
				{PlaylistID: "pl-1", UserID: "viewer-1", Role: RoleViewer},
			},
		},
	}
	svc := NewService(store)

	_, err := svc.InviteUser(context.Background(), "pl-1", "viewer-1", "user-2", RoleEditor)
	if err != ErrForbidden {
		t.Errorf("expected ErrForbidden, got %v", err)
	}
}

func TestRecordTrackChange(t *testing.T) {
	store := &fakeStore{
		members: map[string][]Member{
			"pl-1": {
				{PlaylistID: "pl-1", UserID: "editor-1", Role: RoleEditor},
			},
		},
	}
	svc := NewService(store)

	err := svc.RecordTrackChange(context.Background(), "editor-1", "pl-1", "add", "track-42", 5)
	if err != nil {
		t.Fatalf("RecordTrackChange failed: %v", err)
	}

	changes, _ := svc.GetChanges(context.Background(), "pl-1", 0)
	if len(changes) != 1 {
		t.Fatalf("expected 1 change, got %d", len(changes))
	}
	if changes[0].TrackID != "track-42" {
		t.Errorf("expected track-42, got %s", changes[0].TrackID)
	}
}

// fakeStore implements the Store interface for testing.
type fakeStore struct {
	members map[string][]Member
	invites map[string]*Invite
	changes map[string][]Change
}

func (s *fakeStore) GetMember(_ context.Context, playlistID, userID string) (*Member, error) {
	for _, m := range s.members[playlistID] {
		if m.UserID == userID {
			return &m, nil
		}
	}
	return nil, ErrNotFound
}

func (s *fakeStore) AddMember(_ context.Context, member Member) error {
	s.members[member.PlaylistID] = append(s.members[member.PlaylistID], member)
	return nil
}

func (s *fakeStore) RemoveMember(_ context.Context, playlistID, userID string) error {
	members := s.members[playlistID]
	for i, m := range members {
		if m.UserID == userID {
			s.members[playlistID] = append(members[:i], members[i+1:]...)
			return nil
		}
	}
	return nil
}

func (s *fakeStore) ListMembers(_ context.Context, playlistID string) ([]Member, error) {
	return s.members[playlistID], nil
}

func (s *fakeStore) SetRole(_ context.Context, playlistID, userID string, role Role) error {
	return nil
}

func (s *fakeStore) CreateInvite(_ context.Context, invite Invite) error {
	if s.invites == nil {
		s.invites = make(map[string]*Invite)
	}
	s.invites[invite.ID] = &invite
	return nil
}

func (s *fakeStore) GetInvite(_ context.Context, inviteID string) (*Invite, error) {
	inv, ok := s.invites[inviteID]
	if !ok {
		return nil, ErrInviteNotFound
	}
	return inv, nil
}

func (s *fakeStore) ListInvites(_ context.Context, playlistID string) ([]Invite, error) {
	var result []Invite
	for _, inv := range s.invites {
		if inv.PlaylistID == playlistID {
			result = append(result, *inv)
		}
	}
	return result, nil
}

func (s *fakeStore) AcceptInvite(_ context.Context, inviteID string, at time.Time) error {
	if inv, ok := s.invites[inviteID]; ok {
		inv.AcceptedAt = &at
	}
	return nil
}

func (s *fakeStore) DeleteInvite(_ context.Context, inviteID string) error {
	delete(s.invites, inviteID)
	return nil
}

func (s *fakeStore) RecordChange(_ context.Context, change Change) error {
	s.changes[change.PlaylistID] = append(s.changes[change.PlaylistID], change)
	return nil
}

func (s *fakeStore) ListChanges(_ context.Context, playlistID string, sinceRevision int64) ([]Change, error) {
	var result []Change
	for _, c := range s.changes[playlistID] {
		if c.Revision > sinceRevision {
			result = append(result, c)
		}
	}
	return result, nil
}

func (s *fakeStore) ListCollaborativePlaylists(_ context.Context, userID string) ([]string, error) {
	return nil, nil
}
