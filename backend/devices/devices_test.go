package devices

import (
	"context"
	"testing"
	"time"
)

func TestRegisterRequestValidation(t *testing.T) {
	tests := []struct {
		name    string
		req     RegisterRequest
		wantErr bool
	}{
		{"valid", RegisterRequest{ID: "dev-1", Name: "My Phone", Platform: "android"}, false},
		{"empty id", RegisterRequest{ID: "", Name: "Phone", Platform: "android"}, true},
		{"long id", RegisterRequest{ID: string(make([]byte, 200)), Name: "Phone", Platform: "android"}, true},
		{"long name", RegisterRequest{ID: "dev-1", Name: string(make([]byte, 300)), Platform: "android"}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.req.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestDeviceServiceRegister(t *testing.T) {
	store := &fakeDeviceStore{}
	svc := NewService(store)

	device, err := svc.Register(context.Background(), "user-1", RegisterRequest{
		ID:       "dev-1",
		Name:     "Pixel 8",
		Platform: "android",
	})
	if err != nil {
		t.Fatalf("Register failed: %v", err)
	}
	if device.ID != "dev-1" {
		t.Errorf("expected device id dev-1, got %s", device.ID)
	}
	if device.UserID != "user-1" {
		t.Errorf("expected user-1, got %s", device.UserID)
	}
}

func TestDeviceServiceList(t *testing.T) {
	store := &fakeDeviceStore{
		devs: map[string]map[string]*Device{
			"user-1": {
				"dev-1": {ID: "dev-1", UserID: "user-1", Name: "Phone"},
				"dev-2": {ID: "dev-2", UserID: "user-1", Name: "Tablet"},
			},
		},
	}
	svc := NewService(store)

	devs, err := svc.List(context.Background(), "user-1")
	if err != nil {
		t.Fatalf("List failed: %v", err)
	}
	if len(devs) != 2 {
		t.Errorf("expected 2 devices, got %d", len(devs))
	}
}

func TestDeviceServiceInvalidInput(t *testing.T) {
	svc := NewService(&fakeDeviceStore{})
	_, err := svc.Register(context.Background(), "", RegisterRequest{ID: "dev-1"})
	if err != ErrInvalidInput {
		t.Errorf("expected ErrInvalidInput, got %v", err)
	}
}

// fakeDeviceStore implements the Store interface.
type fakeDeviceStore struct {
	devs map[string]map[string]*Device
}

func (s *fakeDeviceStore) Register(_ context.Context, userID string, req RegisterRequest) (*Device, error) {
	if s.devs == nil {
		s.devs = make(map[string]map[string]*Device)
	}
	if s.devs[userID] == nil {
		s.devs[userID] = make(map[string]*Device)
	}
	now := time.Now()
	d := &Device{
		ID:       req.ID, UserID: userID, Name: req.Name,
		Platform: req.Platform, CreatedAt: now, LastSeenAt: now,
	}
	s.devs[userID][req.ID] = d
	return d, nil
}

func (s *fakeDeviceStore) Get(_ context.Context, userID, deviceID string) (*Device, error) {
	if userDevs, ok := s.devs[userID]; ok {
		if d, ok := userDevs[deviceID]; ok {
			return d, nil
		}
	}
	return nil, ErrNotFound
}

func (s *fakeDeviceStore) List(_ context.Context, userID string) ([]*Device, error) {
	var result []*Device
	for _, d := range s.devs[userID] {
		result = append(result, d)
	}
	return result, nil
}

func (s *fakeDeviceStore) UpdateLastSeen(_ context.Context, userID, deviceID string, at time.Time) error {
	return nil
}

func (s *fakeDeviceStore) UpdateLastSync(_ context.Context, userID, deviceID string, at time.Time) error {
	return nil
}

func (s *fakeDeviceStore) Revoke(_ context.Context, userID, deviceID string) error {
	return nil
}

func (s *fakeDeviceStore) RevokeAll(_ context.Context, userID, exceptDeviceID string) error {
	return nil
}

func (s *fakeDeviceStore) SetTrusted(_ context.Context, userID, deviceID string, trusted bool) error {
	return nil
}
