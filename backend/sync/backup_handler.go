package sync

import (
	"io"
	"net/http"

	"github.com/zarz/spotiflac_android/backend/internal/httpx"
)

// BackupHandler serves the /v1/backup/* endpoints.
type BackupHandler struct {
	store *BackupStore
}

// NewBackupHandler wires the backup handler.
func NewBackupHandler(store *BackupStore) *BackupHandler {
	return &BackupHandler{store: store}
}

type uploadResponse struct {
	Backup Backup `json:"backup"`
}

type listResponse struct {
	Backups []Backup `json:"backups"`
}

// Upload handles PUT /v1/backup?deviceId=… with the raw envelope body.
func (h *BackupHandler) Upload(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	deviceID := r.URL.Query().Get("deviceId")
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, MaxBackupBytes+1))
	if err != nil {
		httpx.WriteError(w, http.StatusRequestEntityTooLarge, ErrBackupTooLarge.Error())
		return
	}
	meta, err := h.store.Upload(r.Context(), userID, deviceID, body)
	if err != nil {
		status := http.StatusBadRequest
		if err == ErrBackupTooLarge {
			status = http.StatusRequestEntityTooLarge
		}
		httpx.WriteError(w, status, err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, uploadResponse{Backup: meta})
}

// List handles GET /v1/backup?deviceId=…
func (h *BackupHandler) List(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, listResponse{
		Backups: h.store.List(r.Context(), userID, r.URL.Query().Get("deviceId")),
	})
}

// Download handles GET /v1/backup/{id}.
func (h *BackupHandler) Download(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	meta, payload, err := h.store.Download(r.Context(), userID, r.PathValue("id"))
	if err != nil {
		httpx.WriteError(w, http.StatusNotFound, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-Backup-SHA256", meta.SHA256)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(payload)
}

// Delete handles DELETE /v1/backup/{id}.
func (h *BackupHandler) Delete(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if err := h.store.Delete(r.Context(), userID, r.PathValue("id")); err != nil {
		httpx.WriteError(w, http.StatusNotFound, err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Routes registers the endpoints. `middleware` is the bearer-auth wrapper.
func (h *BackupHandler) Routes(mux *http.ServeMux, middleware func(http.Handler) http.Handler) {
	protected := func(handler http.HandlerFunc) http.Handler {
		return middleware(handler)
	}
	mux.Handle("PUT /v1/backup", protected(h.Upload))
	mux.Handle("GET /v1/backup", protected(h.List))
	mux.Handle("GET /v1/backup/{id}", protected(h.Download))
	mux.Handle("DELETE /v1/backup/{id}", protected(h.Delete))
}
