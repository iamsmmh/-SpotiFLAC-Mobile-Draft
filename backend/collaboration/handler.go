package collaboration

import (
	"context"
	"encoding/json"
	stderrors "errors"
	"net/http"
)

// Handler serves the /v1/collaboration/* endpoints.
type Handler struct {
	svc *Service
}

// NewHandler creates a new collaboration handler.
func NewHandler(svc *Service) *Handler {
	return &Handler{svc: svc}
}

// MiddlewareFunc is the signature for auth middleware.
type MiddlewareFunc func(http.HandlerFunc) http.HandlerFunc

// Routes registers collaboration endpoints.
func (h *Handler) Routes(mux *http.ServeMux, auth MiddlewareFunc) {
	mux.HandleFunc("POST /v1/collaboration/playlists/{id}/invite", auth(h.invite))
	mux.HandleFunc("POST /v1/collaboration/invites/{id}/accept", auth(h.acceptInvite))
	mux.HandleFunc("GET /v1/collaboration/playlists/{id}/members", auth(h.listMembers))
	mux.HandleFunc("DELETE /v1/collaboration/playlists/{id}/members/{userId}", auth(h.removeMember))
	mux.HandleFunc("PUT /v1/collaboration/playlists/{id}/members/{userId}/role", auth(h.changeRole))
	mux.HandleFunc("GET /v1/collaboration/playlists/{id}/changes", auth(h.getChanges))
	mux.HandleFunc("POST /v1/collaboration/playlists/{id}/changes", auth(h.recordChange))
}

func (h *Handler) invite(w http.ResponseWriter, r *http.Request) {
	userID := userFromCtx(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	playlistID := r.PathValue("id")
	var body struct {
		UserID string `json:"userId"`
		Role   string `json:"role"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	role := Role(body.Role)
	if role == "" {
		role = RoleViewer
	}
	invite, err := h.svc.InviteUser(r.Context(), playlistID, userID, body.UserID, role)
	if err != nil {
		writeCollabError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(invite)
}

func (h *Handler) acceptInvite(w http.ResponseWriter, r *http.Request) {
	userID := userFromCtx(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	inviteID := r.PathValue("id")
	member, err := h.svc.AcceptInvite(r.Context(), inviteID, userID)
	if err != nil {
		writeCollabError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(member)
}

func (h *Handler) listMembers(w http.ResponseWriter, r *http.Request) {
	playlistID := r.PathValue("id")
	members, err := h.svc.ListMembers(r.Context(), playlistID)
	if err != nil {
		writeCollabError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(members)
}

func (h *Handler) removeMember(w http.ResponseWriter, r *http.Request) {
	userID := userFromCtx(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	playlistID := r.PathValue("id")
	targetID := r.PathValue("userId")
	if err := h.svc.RemoveUser(r.Context(), playlistID, userID, targetID); err != nil {
		writeCollabError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) changeRole(w http.ResponseWriter, r *http.Request) {
	userID := userFromCtx(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	playlistID := r.PathValue("id")
	targetID := r.PathValue("userId")
	var body struct {
		Role string `json:"role"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	if err := h.svc.ChangeRole(r.Context(), playlistID, userID, targetID, Role(body.Role)); err != nil {
		writeCollabError(w, err)
		return
	}
	w.WriteHeader(http.StatusOK)
}

func (h *Handler) getChanges(w http.ResponseWriter, r *http.Request) {
	playlistID := r.PathValue("id")
	var sinceRevision int64
	if v := r.URL.Query().Get("since"); v != "" {
		for _, c := range v {
			if c >= '0' && c <= '9' {
				sinceRevision = sinceRevision*10 + int64(c-'0')
			}
		}
	}
	changes, err := h.svc.GetChanges(r.Context(), playlistID, sinceRevision)
	if err != nil {
		writeCollabError(w, err)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(changes)
}

func (h *Handler) recordChange(w http.ResponseWriter, r *http.Request) {
	userID := userFromCtx(r.Context())
	if userID == "" {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	playlistID := r.PathValue("id")
	var body struct {
		Action   string `json:"action"`
		TrackID  string `json:"trackId"`
		Position int    `json:"position"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "invalid body", http.StatusBadRequest)
		return
	}
	if err := h.svc.RecordTrackChange(r.Context(), userID, playlistID, body.Action, body.TrackID, body.Position); err != nil {
		writeCollabError(w, err)
		return
	}
	w.WriteHeader(http.StatusCreated)
}

type collabContextKey string

const collabUserKey collabContextKey = "user_id"

func userFromCtx(ctx context.Context) string {
	v, _ := ctx.Value(collabUserKey).(string)
	return v
}

// WithUserID adds the user ID to the context.
func WithUserID(ctx context.Context, userID string) context.Context {
	return context.WithValue(ctx, collabUserKey, userID)
}

func writeCollabError(w http.ResponseWriter, err error) {
	switch {
	case stderrors.Is(err, ErrNotFound):
		http.Error(w, err.Error(), http.StatusNotFound)
	case stderrors.Is(err, ErrForbidden):
		http.Error(w, err.Error(), http.StatusForbidden)
	case stderrors.Is(err, ErrInvalidInput):
		http.Error(w, err.Error(), http.StatusBadRequest)
	case stderrors.Is(err, ErrAlreadyMember):
		http.Error(w, err.Error(), http.StatusConflict)
	case stderrors.Is(err, ErrInviteExpired):
		http.Error(w, err.Error(), http.StatusGone)
	case stderrors.Is(err, ErrInviteNotFound):
		http.Error(w, err.Error(), http.StatusNotFound)
	default:
		http.Error(w, "internal error", http.StatusInternalServerError)
	}
}
