package settings

import (
	"net/http"

	"github.com/zarz/spotiflac_android/backend/internal/httpx"
)

// Handler serves the settings-policy endpoints.
type Handler struct{}

// NewHandler wires the settings handler.
func NewHandler() *Handler { return &Handler{} }

type schemaResponse struct {
	Keys          []string `json:"keys"`
	MaxRecordByte int      `json:"maxRecordBytes"`
}

// Schema handles GET /v1/settings/schema (public): the allowlist the client
// filters its settings records against before pushing.
func (h *Handler) Schema(w http.ResponseWriter, _ *http.Request) {
	httpx.WriteJSON(w, http.StatusOK, schemaResponse{
		Keys:          AllowedKeyList(),
		MaxRecordByte: MaxPayloadBytes,
	})
}

// Validate handles POST /v1/settings/validate (bearer auth): dry-runs the
// policy over a record so clients can preflight a push.
func (h *Handler) Validate(w http.ResponseWriter, r *http.Request) {
	var payload map[string]any
	if err := httpx.ReadJSON(w, r, &payload); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	records, err := Validate(payload)
	if err != nil {
		httpx.WriteError(w, http.StatusUnprocessableEntity, err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"records": records})
}

// Routes registers the endpoints. `middleware` is the bearer-auth wrapper.
func (h *Handler) Routes(mux *http.ServeMux, middleware func(http.Handler) http.Handler) {
	mux.HandleFunc("GET /v1/settings/schema", h.Schema)
	mux.Handle("POST /v1/settings/validate", middleware(http.HandlerFunc(h.Validate)))
}
