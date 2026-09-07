// Package telemetry implements the SpotiFLAC Cloud observability backend
// (Milestone 11).
//
// Receives, stores, and aggregates telemetry events from mobile clients:
//   - Crash reports (with stack traces and breadcrumbs)
//   - Performance metrics (startup time, frame drops)
//   - Sync diagnostics (latency, conflict counts)
//   - Streaming diagnostics (provider health, buffer underruns)
//   - Playback success/failure rates
//
// The backend provides a read API for the Provider Health Dashboard
// and aggregated metrics for monitoring.
package telemetry

import (
	"context"
	"errors"
	"time"
)

// Errors.
var (
	ErrInvalidInput = errors.New("invalid input")
	ErrQuotaExceeded = errors.New("telemetry quota exceeded")
)

// EventType categorizes telemetry events.
type EventType string

const (
	EventCrash       EventType = "crash"
	EventPerformance EventType = "performance"
	EventSync        EventType = "sync"
	EventStreaming   EventType = "streaming"
	EventPlayback    EventType = "playback"
	EventDownload    EventType = "download"
)

// Event is one telemetry report from a client.
type Event struct {
	ID          string            `json:"id"`
	UserID      string            `json:"userId"`
	DeviceID    string            `json:"deviceId"`
	Type        EventType         `json:"type"`
	Severity    string            `json:"severity"` // debug, info, warning, error, fatal
	Category    string            `json:"category"`
	Message     string            `json:"message"`
	Stacktrace  string            `json:"stacktrace,omitempty"`
	Metadata    map[string]string `json:"metadata,omitempty"`
	DurationMs  int64             `json:"durationMs,omitempty"`
	Success     *bool             `json:"success,omitempty"`
	ProviderID  string            `json:"providerId,omitempty"`
	CreatedAt   time.Time         `json:"createdAt"`
}

// Validate checks the event for basic sanity.
func (e *Event) Validate() error {
	if e.UserID == "" || e.DeviceID == "" {
		return ErrInvalidInput
	}
	if e.Type == "" {
		return ErrInvalidInput
	}
	if len(e.Message) > 4096 {
		return ErrInvalidInput
	}
	if len(e.Stacktrace) > 65536 {
		return ErrInvalidInput
	}
	return nil
}

// MetricsSummary contains aggregated metrics for a time window.
type MetricsSummary struct {
	Period            string  `json:"period"`
	PlaybackSuccess   float64 `json:"playbackSuccessRate"`
	StreamFailures    int64   `json:"streamFailures"`
	DownloadFailures  int64   `json:"downloadFailures"`
	ProviderAvailable float64 `json:"providerAvailability"`
	SyncLatencyMs     int64   `json:"syncLatencyMs"`
	CrashCount        int64   `json:"crashCount"`
	ActiveUsers       int64   `json:"activeUsers"`
}

// ProviderHealth tracks per-provider availability metrics.
type ProviderHealth struct {
	ProviderID  string    `json:"providerId"`
	Available   bool      `json:"available"`
	LatencyMs   int64     `json:"latencyMs"`
	ErrorRate   float64   `json:"errorRate"`
	LastChecked time.Time `json:"lastChecked"`
}

// Store abstracts persistence for telemetry events.
type Store interface {
	Ingest(ctx context.Context, event Event) error
	Query(ctx context.Context, userID string, eventType EventType, since time.Time, limit int) ([]Event, error)
	Summarize(ctx context.Context, period string, since time.Time) (*MetricsSummary, error)
	ProviderHealth(ctx context.Context) ([]ProviderHealth, error)
	RecordProviderHealth(ctx context.Context, health ProviderHealth) error
}

// Service provides telemetry operations.
type Service struct {
	store Store
}

// NewService creates a new telemetry service.
func NewService(store Store) *Service {
	return &Service{store: store}
}

// Ingest stores a telemetry event after validation.
func (s *Service) Ingest(ctx context.Context, event Event) error {
	if err := event.Validate(); err != nil {
		return err
	}
	if event.CreatedAt.IsZero() {
		event.CreatedAt = time.Now().UTC()
	}
	return s.store.Ingest(ctx, event)
}

// Query retrieves events matching the filter.
func (s *Service) Query(ctx context.Context, userID string, eventType EventType, since time.Time, limit int) ([]Event, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	return s.store.Query(ctx, userID, eventType, since, limit)
}

// Summary returns aggregated metrics for the given period.
func (s *Service) Summary(ctx context.Context, period string, since time.Time) (*MetricsSummary, error) {
	return s.store.Summarize(ctx, period, since)
}

// GetProviderHealth returns the current health of all streaming providers.
func (s *Service) GetProviderHealth(ctx context.Context) ([]ProviderHealth, error) {
	return s.store.ProviderHealth(ctx)
}
