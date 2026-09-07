package devices

import (
	"context"
	"encoding/json"
	stderrors "errors"
	"net/http"
	"time"
)

// Handler serves the /v1/devices/* endpoints.
type Handler struct {
	svc *Service
}

// NewHandler creates a new device handler.
func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

// MiddlewareFunc is the signature for auth middleware.
type MiddlewareFunc func(http.Handler) http.Handler

// Routes registers device endpoints on the given mux.
func (h *Handler) Routes(mux *http.ServeMux, auth MiddlewareFunc) {
	mux.Handle("POST /v1/devices", auth(http.HandlerFunc(h.register)))
	mux.Handle("GET /v1/devices", auth(http.HandlerFunc(h.list)))
	mux.Handle("GET /v1/devices/{id}", auth(http.HandlerFunc(h.get)))
	mux.Handle("DELETE /v1/devices/{id}", auth(http.HandlerFunc(h.revoke)))
	mux.Handle("PUT /v1/devices/{id}/trust", auth(http.HandlerFunc(h.setTrust)))
	mux.Handle("DELETE /v1/devices", auth(http.HandlerFunc(h.revokeAll)))
}

func (h *Handler) register(w http.ResponseWriter, r *http.Request) {
	userID := userFromContext(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var req RegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	device, err := h.svc.Register(r.Context(), userID, req)
	if err != nil {
		writeDeviceError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(device)
}

func (h *Handler) list(w http.ResponseWriter, r *http.Request) {
	userID := userFromContext(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	devices, err := h.svc.List(r.Context(), userID)
	if err != nil {
		writeDeviceError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(devices)
}

func (h *Handler) get(w http.ResponseWriter, r *http.Request) {
	userID := userFromContext(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	deviceID := r.PathValue("id")
	device, err := h.svc.Get(r.Context(), userID, deviceID)
	if err != nil {
		writeDeviceError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(device)
}

func (h *Handler) revoke(w http.ResponseWriter, r *http.Request) {
	userID := userFromContext(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	deviceID := r.PathValue("id")
	if err := h.svc.Revoke(r.Context(), userID, deviceID); err != nil {
		writeDeviceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) revokeAll(w http.ResponseWriter, r *http.Request) {
	userID := userFromContext(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	exceptDevice := r.Header.Get("X-Device-Id")
	if err := h.svc.RevokeAll(r.Context(), userID, exceptDevice); err != nil {
		writeDeviceError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) setTrust(w http.ResponseWriter, r *http.Request) {
	userID := userFromContext(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	deviceID := r.PathValue("id")
	var body struct {
		Trusted bool `json:"trusted"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if err := h.svc.SetTrusted(r.Context(), userID, deviceID, body.Trusted); err != nil {
		writeDeviceError(w, err)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// deviceContextKey is used to store the authenticated user ID.
type deviceContextKey string

const deviceUserKey deviceContextKey = "user_id"

func userFromContext(ctx context.Context) string {
	v, _ := ctx.Value(deviceUserKey).(string)
	return v
}

// WithUserID adds the user ID to the context.
func WithUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, deviceUserKey, userID)
}

// TouchMiddleware records device activity on every authenticated request.
func (h *Handler) TouchMiddleware() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			userID := userFromContext(r.Context())
			deviceID := r.Header.Get("X-Device-Id")
			if userID != "" && deviceID != "" {
				_ = h.svc.store.UpdateLastSeen(r.Context(), userID, deviceID, time.Now().UTC())
			}
			next.ServeHTTP(w, r)
		})
	}
}

func writeDeviceError(w http.ResponseWriter, err error) {
	switch {
	case stderrors.Is(err, ErrNotFound):
		http.Error(w, err.Error(), http.StatusNotFound)
	case stderrors.Is(err, ErrInvalidInput):
		http.Error(w, err.Error(), http.StatusBadRequest)
	case stderrors.Is(err, ErrMaxDevices):
		http.Error(w, err.Error(), http.StatusTooManyRequests)
	default:
		http.Error(w, "internal error", http.StatusInternalServerError)
	}
}
