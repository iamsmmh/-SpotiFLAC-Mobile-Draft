// Package users implements user profile management for the SpotiFLAC Cloud.
//
// Provides:
//   - Profile retrieval and updates (display name, avatar, bio)
//   - Public profile listing (for social features)
//   - Account deletion (cascades to all user data)
//   - Email verification
//
// Tables used: cloud_users (from schema.sql)
//
// All functions accept a context for cancellation and are safe for
// concurrent use.
package users

import (
	"context"
	"errors"
	"time"
)

// Errors returned by the users package.
var (
	ErrNotFound      = errors.New("user not found")
	ErrInvalidInput  = errors.New("invalid input")
	ErrAlreadyExists = errors.New("resource already exists")
)

// Profile represents a user's public profile data.
type Profile struct {
	UserID      string    `json:"userId"`
	Handle      string    `json:"handle"`
	DisplayName string    `json:"displayName"`
	Bio         string    `json:"bio"`
	AvatarURL   string    `json:"avatarUrl"`
	IsPublic    bool      `json:"isPublic"`
	CreatedAt   time.Time `json:"createdAt"`
}

// UpdateRequest contains the fields that can be updated by a user.
type UpdateRequest struct {
	DisplayName string `json:"displayName"`
	Bio         string `json:"bio"`
	AvatarURL   string `json:"avatarUrl"`
	IsPublic    *bool  `json:"isPublic"`
}

// Validate checks the update request for basic sanity.
func (u *UpdateRequest) Validate() error {
	if len(u.DisplayName) > 128 {
		return errors.New("display name too long")
	}
	if len(u.Bio) > 1024 {
		return errors.New("bio too long")
	}
	if len(u.AvatarURL) > 2048 {
		return errors.New("avatar URL too long")
	}
	return nil
}

// Store abstracts the persistence layer for user profiles.
type Store interface {
	// GetProfile returns the profile for the given user ID.
	GetProfile(ctx context.Context, userID string) (*Profile, error)

	// UpdateProfile applies the update request to the user's profile.
	UpdateProfile(ctx context.Context, userID string, req UpdateRequest) (*Profile, error)

	// ListPublicProfiles returns paginated public profiles.
	ListPublicProfiles(ctx context.Context, limit, offset int) ([]*Profile, error)

	// DeleteAccount permanently removes a user and all associated data.
	DeleteAccount(ctx context.Context, userID string) error

	// VerifyEmail marks the user's email as verified.
	VerifyEmail(ctx context.Context, userID string) error
}

// Service provides user management operations.
type Service struct {
	store Store
}

// NewService creates a new user service with the given store.
func NewService(store Store) *Service {
	return &Service{store: store}
}

// GetProfile returns the profile for the given user ID.
func (s *Service) GetProfile(ctx context.Context, userID string) (*Profile, error) {
	if userID == "" {
		return nil, ErrInvalidInput
	}
	return s.store.GetProfile(ctx, userID)
}

// UpdateProfile applies the update request after validation.
func (s *Service) UpdateProfile(ctx context.Context, userID string, req UpdateRequest) (*Profile, error) {
	if userID == "" {
		return nil, ErrInvalidInput
	}
	if err := req.Validate(); err != nil {
		return nil, ErrInvalidInput
	}
	return s.store.UpdateProfile(ctx, userID, req)
}

// ListPublicProfiles returns paginated public profiles.
func (s *Service) ListPublicProfiles(ctx context.Context, limit, offset int) ([]*Profile, error) {
	if limit <= 0 || limit > 100 {
		limit = 50
	}
	if offset < 0 {
		offset = 0
	}
	return s.store.ListPublicProfiles(ctx, limit, offset)
}

// DeleteAccount permanently removes a user and all associated data.
func (s *Service) DeleteAccount(ctx context.Context, userID string) error {
	if userID == "" {
		return ErrInvalidInput
	}
	return s.store.DeleteAccount(ctx, userID)
}

// VerifyEmail marks the user's email as verified.
func (s *Service) VerifyEmail(ctx context.Context, userID string) error {
	if userID == "" {
		return ErrInvalidInput
	}
	return s.store.VerifyEmail(ctx, userID)
}
