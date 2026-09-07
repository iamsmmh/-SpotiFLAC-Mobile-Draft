package telemetry

import (
	"context"
	"encoding/json"
	stderrors "errors"
	"net/http"
	"time"
)

// Handler serves the /v1/telemetry/* endpoints.
type Handler struct {
	svc *Service
}

// NewHandler creates a new telemetry handler.
func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

// MiddlewareFunc is the signature for auth middleware.
type MiddlewareFunc func(http.Handler) http.Handler

// Routes registers telemetry endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth MiddlewareFunc) {
	mux.Handle("POST /v1/telemetry/events", auth(http.HandlerFunc(h.ingest)))
	mux.Handle("GET /v1/telemetry/events", auth(http.HandlerFunc(h.query)))
	mux.Handle("GET /v1/telemetry/summary", auth(http.HandlerFunc(h.summary)))
	mux.Handle("GET /v1/telemetry/providers", auth(http.HandlerFunc(h.providerHealth)))
}

func (h *Handler) ingest(w http.ResponseWriter, r *http.Request) {
	userID := telUserFromCtx(r.Context())
	deviceID := r.Header.Get("X-Device-Id")
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	var body struct {
		Events []Event `json:"events"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}

	accepted := 0
	for _, event := range body.Events {
		event.UserID = userID
		if deviceID != "" {
			event.DeviceID = deviceID
		}
		if err := h.svc.Ingest(r.Context(), event); err == nil {
			accepted++
		}
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_ = json.NewEncoder(w).Encode(map[string]int{"accepted": accepted})
}

func (h *Handler) query(w http.ResponseWriter, r *http.Request) {
	userID := telUserFromCtx(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	eventType := EventType(r.URL.Query().Get("type"))
	since := time.Now().Add(-24 * time.Hour)
	if v := r.URL.Query().Get("since"); v != "" {
		if t, err := time.Parse(time.RFC3339, v); err == nil {
			since = t
		}
	}
	limit := 100
	if events, err := h.svc.Query(r.Context(), userID, eventType, since, limit); err == nil {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(events)
	} else {
		http.Error(w, "query failed", http.StatusInternalServerError)
	}
}

func (h *Handler) summary(w http.ResponseWriter, r *http.Request) {
	period := r.URL.Query().Get("period")
	if period == "" {
		period = "day"
	}
	since := time.Now().Add(-24 * time.Hour)
	summary, err := h.svc.Summary(r.Context(), period, since)
	if err != nil {
		http.Error(w, "summary failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(summary)
}

func (h *Handler) providerHealth(w http.ResponseWriter, r *http.Request) {
	health, err := h.svc.GetProviderHealth(r.Context())
	if err != nil {
		http.Error(w, "health check failed", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(health)
}

type telContextKey string

const telUserKey telContextKey = "user_id"

func telUserFromCtx(ctx context.Context) string {
	v, _ := ctx.Value(telUserKey).(string)
	return v
}

// WithUserID adds the user ID to the context.
func WithUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, telUserKey, userID)
}

// writeTelError is a helper for error responses.
func writeTelError(w http.ResponseWriter, err error) {
	switch {
	case stderrors.Is(err, ErrInvalidInput):
		http.Error(w, err.Error(), http.StatusBadRequest)
	case stderrors.Is(err, ErrQuotaExceeded):
		http.Error(w, err.Error(), http.StatusTooManyRequests)
	default:
		http.Error(w, "internal error", http.StatusInternalServerError)
	}
}
