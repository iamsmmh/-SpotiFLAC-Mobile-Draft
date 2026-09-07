// Package devices manages device registration and lifecycle for the
// SpotiFLAC Cloud. Each user can register multiple devices (Android, iOS,
// desktop) that participate in sync and playback continuity.
//
// Tables used: cloud_devices (from schema.sql)
package devices

import (
	"context"
	"errors"
	"time"
)

// Errors returned by the devices package.
var (
	ErrNotFound     = errors.New("device not found")
	ErrInvalidInput = errors.New("invalid input")
	ErrMaxDevices   = errors.New("maximum device limit reached")
)

// Device represents a registered device.
type Device struct {
	ID         string    `json:"id"`
	UserID     string    `json:"userId"`
	Name       string    `json:"name"`
	Platform   string    `json:"platform"`
	Trusted    bool      `json:"trusted"`
	CreatedAt  time.Time `json:"createdAt"`
	LastSeenAt time.Time `json:"lastSeenAt"`
	LastSyncAt time.Time `json:"lastSyncAt"`
}

// RegisterRequest is the payload for device registration.
type RegisterRequest struct {
	ID       string `json:"id"`
	Name     string `json:"name"`
	Platform string `json:"platform"`
}

// MaxDevicesPerUser is the maximum number of devices a user can register.
const MaxDevicesPerUser = 20

// Validate checks the registration request.
func (r *RegisterRequest) Validate() error {
	if r.ID == "" || len(r.ID) > 128 {
		return ErrInvalidInput
	}
	if len(r.Name) > 256 {
		return ErrInvalidInput
	}
	if len(r.Platform) > 64 {
		return ErrInvalidInput
	}
	return nil
}

// Store abstracts the persistence layer.
type Store interface {
	Register(ctx context.Context, userID string, req RegisterRequest) (*Device, error)
	Get(ctx context.Context, userID, deviceID string) (*Device, error)
	List(ctx context.Context, userID string) ([]*Device, error)
	UpdateLastSeen(ctx context.Context, userID, deviceID string, at time.Time) error
	UpdateLastSync(ctx context.Context, userID, deviceID string, at time.Time) error
	Revoke(ctx context.Context, userID, deviceID string) error
	RevokeAll(ctx context.Context, userID string, exceptDeviceID string) error
	SetTrusted(ctx context.Context, userID, deviceID string, trusted bool) error
}

// Service provides device management operations.
type Service struct {
	store Store
}

// NewService creates a new device service.
func NewService(store Store) *Service {
	return &Service{store: store}
}

// Register adds a new device for the user.
func (s *Service) Register(ctx context.Context, userID string, req RegisterRequest) (*Device, error) {
	if userID == "" {
		return nil, ErrInvalidInput
	}
	if err := req.Validate(); err != nil {
		return nil, err
	}
	return s.store.Register(ctx, userID, req)
}

// Get returns a specific device.
func (s *Service) Get(ctx context.Context, userID, deviceID string) (*Device, error) {
	if userID == "" || deviceID == "" {
		return nil, ErrInvalidInput
	}
	return s.store.Get(ctx, userID, deviceID)
}

// List returns all devices for a user.
func (s *Service) List(ctx context.Context, userID string) ([]*Device, error) {
	if userID == "" {
		return nil, ErrInvalidInput
	}
	return s.store.List(ctx, userID)
}

// Touch updates the last-seen timestamp for a device.
func (s *Service) Touch(ctx context.Context, userID, deviceID string) error {
	return s.store.UpdateLastSeen(ctx, userID, deviceID, time.Now().UTC())
}

// Revoke removes a device registration.
func (s *Service) Revoke(ctx context.Context, userID, deviceID string) error {
	if userID == "" || deviceID == "" {
		return ErrInvalidInput
	}
	return s.store.Revoke(ctx, userID, deviceID)
}

// RevokeAll removes all device registrations except the specified one.
func (s *Service) RevokeAll(ctx context.Context, userID, exceptDeviceID string) error {
	if userID == "" {
		return ErrInvalidInput
	}
	return s.store.RevokeAll(ctx, userID, exceptDeviceID)
}

// SetTrusted marks or unmarks a device as trusted.
func (s *Service) SetTrusted(ctx context.Context, userID, deviceID string, trusted bool) error {
	if userID == "" || deviceID == "" {
		return ErrInvalidInput
	}
	return s.store.SetTrusted(ctx, userID, deviceID, trusted)
}
