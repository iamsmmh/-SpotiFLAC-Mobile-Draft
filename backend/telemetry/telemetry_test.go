package telemetry

import (
	"context"
	"testing"
	"time"
)

func TestEventValidation(t *testing.T) {
	tests := []struct {
		name    string
		event   Event
		wantErr bool
	}{
		{
			"valid",
			Event{UserID: "u1", DeviceID: "d1", Type: EventCrash, Message: "test"},
			false,
		},
		{
			"empty user",
			Event{UserID: "", DeviceID: "d1", Type: EventCrash, Message: "test"},
			true,
		},
		{
			"empty type",
			Event{UserID: "u1", DeviceID: "d1", Type: "", Message: "test"},
			true,
		},
		{
			"message too long",
			Event{UserID: "u1", DeviceID: "d1", Type: EventCrash, Message: string(make([]byte, 5000))},
			true,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := tt.event.Validate()
			if (err != nil) != tt.wantErr {
				t.Errorf("Validate() error = %v, wantErr %v", err, tt.wantErr)
			}
		})
	}
}

func TestServiceIngest(t *testing.T) {
	store := &fakeTelStore{}
	svc := NewService(store)

	err := svc.Ingest(context.Background(), Event{
		UserID:   "u1",
		DeviceID: "d1",
		Type:     EventPlayback,
		Message:  "playback succeeded",
	})
	if err != nil {
		t.Fatalf("Ingest failed: %v", err)
	}
	if len(store.events) != 1 {
		t.Errorf("expected 1 event, got %d", len(store.events))
	}
}

func TestServiceQuery(t *testing.T) {
	now := time.Now()
	store := &fakeTelStore{
		events: []Event{
			{UserID: "u1", DeviceID: "d1", Type: EventPlayback, Message: "ok", CreatedAt: now},
			{UserID: "u1", DeviceID: "d1", Type: EventCrash, Message: "crash", CreatedAt: now},
			{UserID: "u2", DeviceID: "d2", Type: EventPlayback, Message: "ok", CreatedAt: now},
		},
	}
	svc := NewService(store)

	events, err := svc.Query(context.Background(), "u1", EventPlayback, now.Add(-time.Hour), 100)
	if err != nil {
		t.Fatalf("Query failed: %v", err)
	}
	if len(events) != 1 {
		t.Errorf("expected 1 event for u1/playback, got %d", len(events))
	}
}

type fakeTelStore struct {
	events []Event
}

func (s *fakeTelStore) Ingest(_ context.Context, event Event) error {
	s.events = append(s.events, event)
	return nil
}

func (s *fakeTelStore) Query(_ context.Context, userID string, eventType EventType, since time.Time, limit int) ([]Event, error) {
	var result []Event
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

func (s *fakeTelStore) Summarize(_ context.Context, period string, since time.Time) (*MetricsSummary, error) {
	return &MetricsSummary{Period: period}, nil
}

func (s *fakeTelStore) ProviderHealth(_ context.Context) ([]ProviderHealth, error) {
	return nil, nil
}

func (s *fakeTelStore) RecordProviderHealth(_ context.Context, health ProviderHealth) error {
	return nil
}
