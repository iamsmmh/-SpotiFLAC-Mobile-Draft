package playlists

import (
	"net/http"

	"github.com/zarz/spotiflac_android/backend/internal/httpx"
)

// Handler serves the playlist-sharing endpoints.
type Handler struct {
	shares *Service
}

// NewHandler wires the playlist handler. The share registry reads through
// the sync store held by the service.
func NewHandler(shares *Service) *Handler {
	return &Handler{shares: shares}
}

type shareRequest struct {
	RecordID string         `json:"recordId"`
	Payload  map[string]any `json:"payload"`
}

type shareResponse struct {
	Slug     string `json:"slug"`
	URLPath  string `json:"urlPath"`
	RecordID string `json:"recordId"`
}

type resolveResponse struct {
	Slug     string  `json:"slug"`
	Playlist Payload `json:"playlist"`
}

// Publish handles POST /v1/playlists/share (bearer auth). The record must
// already be pushed to the playlists scope and marked public.
func (h *Handler) Publish(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var req shareRequest
	if err := httpx.ReadJSON(w, r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	share, err := h.shares.Publish(r.Context(), userID, req.RecordID, req.Payload)
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, shareResponse{
		Slug:     share.Slug,
		URLPath:  "/v1/playlists/shared/" + share.Slug,
		RecordID: share.RecordID,
	})
}

// Unpublish handles DELETE /v1/playlists/share/{slug} (bearer auth).
func (h *Handler) Unpublish(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err := h.shares.Unpublish(r.Context(), userID, r.PathValue("slug")); err != nil {
		httpx.WriteError(w, http.StatusNotFound, err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Resolve handles GET /v1/playlists/shared/{slug} — public (no bearer
// token): this is what QR codes and deep links point at.
func (h *Handler) Resolve(w http.ResponseWriter, r *http.Request) {
	resolved, err := h.shares.Resolve(r.Context(), r.PathValue("slug"))
	if err != nil {
		httpx.WriteError(w, http.StatusNotFound, err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, resolveResponse{
		Slug:     resolved.Slug,
		Playlist: resolved.Playlist,
	})
}

// Routes registers the endpoints. `middleware` is the bearer-auth wrapper.
func (h *Handler) Routes(mux *http.ServeMux, middleware func(http.Handler) http.Handler) {
	protected := func(handler http.HandlerFunc) http.Handler {
		return middleware(handler)
	}
	mux.Handle("POST /v1/playlists/share", protected(h.Publish))
	mux.Handle("DELETE /v1/playlists/share/{slug}", protected(h.Unpublish))
	// Public on purpose: share links must work from a camera scan.
	mux.HandleFunc("GET /v1/playlists/shared/{slug}", h.Resolve)
}
