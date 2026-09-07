package users

import (
	"context"
	"encoding/json"
	stderrors "errors"
	"net/http"
	"strconv"
	"strings"
)

// Handler serves the /v1/users/* endpoints.
type Handler struct {
	svc *Service
}

// NewHandler creates a new user handler.
func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

// MiddlewareFunc is the signature for auth middleware.
type MiddlewareFunc func(http.HandlerFunc) http.HandlerFunc

// Routes registers user endpoints on the given mux.
func (h *Handler) Routes(mux *http.ServeMux, auth MiddlewareFunc) {
	mux.HandleFunc("GET /v1/users/me", auth(h.getMe))
	mux.HandleFunc("PUT /v1/users/me", auth(h.updateMe))
	mux.HandleFunc("DELETE /v1/users/me", auth(h.deleteMe))
	mux.HandleFunc("GET /v1/users/public", auth(h.listPublic))
}

type profileResponse struct {
	UserID      string `json:"userId"`
	Handle      string `json:"handle"`
	DisplayName string `json:"displayName"`
	Bio         string `json:"bio"`
	AvatarURL   string `json:"avatarUrl"`
	IsPublic    bool   `json:"isPublic"`
}

func (h *Handler) getMe(w http.ResponseWriter, r *http.Request) {
	userID := UserIDFromContext(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	profile, err := h.svc.GetProfile(r.Context(), userID)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toProfileResponse(profile))
}

func (h *Handler) updateMe(w http.ResponseWriter, r *http.Request) {
	userID := UserIDFromContext(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	var req UpdateRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	profile, err := h.svc.UpdateProfile(r.Context(), userID, req)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, toProfileResponse(profile))
}

func (h *Handler) deleteMe(w http.ResponseWriter, r *http.Request) {
	userID := UserIDFromContext(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if err := h.svc.DeleteAccount(r.Context(), userID); err != nil {
		writeError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) listPublic(w http.ResponseWriter, r *http.Request) {
	limit := 50
	offset := 0
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && n > 0 {
			limit = n
		}
	}
	if v := r.URL.Query().Get("offset"); v != "" {
		if n, err := strconv.Atoi(strings.TrimSpace(v)); err == nil && n >= 0 {
			offset = n
		}
	}
	profiles, err := h.svc.ListPublicProfiles(r.Context(), limit, offset)
	if err != nil {
		writeError(w, err)
		return
	}
	resp := make([]profileResponse, 0, len(profiles))
	for _, p := range profiles {
		resp = append(resp, toProfileResponse(p))
	}
	writeJSON(w, http.StatusOK, resp)
}

// contextKey is an unexported type for context keys in this package.
type contextKey string

const userIDKey contextKey = "user_id"

// UserIDFromContext extracts the authenticated user ID.
func UserIDFromContext(ctx context.Context) string {
	v, _ := ctx.Value(userIDKey).(string)
	return v
}

// WithUserID adds the user ID to the context.
func WithUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, userIDKey, userID)
}

func toProfileResponse(p *Profile) profileResponse {
	if p == nil {
		return profileResponse{}
	}
	return profileResponse{
		UserID:      p.UserID,
		Handle:      p.Handle,
		DisplayName: p.DisplayName,
		Bio:         p.Bio,
		AvatarURL:   p.AvatarURL,
		IsPublic:    p.IsPublic,
	}
}

func writeJSON(w http.ResponseWriter, status int, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, err error) {
	switch {
	case stderrors.Is(err, ErrNotFound):
		http.Error(w, err.Error(), http.StatusNotFound)
	case stderrors.Is(err, ErrInvalidInput):
		http.Error(w, err.Error(), http.StatusBadRequest)
	case stderrors.Is(err, ErrAlreadyExists):
		http.Error(w, err.Error(), http.StatusConflict)
	default:
		http.Error(w, "internal error", http.StatusInternalServerError)
	}
}
