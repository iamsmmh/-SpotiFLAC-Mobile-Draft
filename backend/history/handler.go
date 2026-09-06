package history

import (
	"context"
	"net/http"
	"strconv"

	"github.com/zarz/spotiflac_android/backend/internal/httpx"
	"github.com/zarz/spotiflac_android/backend/sync"
)

// Handler serves the listening-history endpoints.
type Handler struct {
	store      *sync.Store
	aggregator *Aggregator
}

// NewHandler wires the history handler.
func NewHandler(store *sync.Store, aggregator *Aggregator) *Handler {
	return &Handler{store: store, aggregator: aggregator}
}

// pullAdapter converts sync records into plain payloads for the aggregator.
func (h *Handler) pullAdapter(ctx context.Context, userID, scope string, since int64) ([]map[string]any, error) {
	records, err := h.store.Pull(ctx, userID, scope, since)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(records))
	for _, record := range records {
		if record.Deleted {
			continue
		}
		out = append(out, record.Payload)
	}
	return out, nil
}

// Summary handles GET /v1/history/summary?limit=N (bearer auth).
func (h *Handler) Summary(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 && parsed <= 500 {
			limit = parsed
		}
	}
	summary, err := h.aggregator.Summarize(r.Context(), userID, h.pullAdapter, limit)
	if err != nil {
		httpx.WriteError(w, http.StatusNotFound, err.Error())
		return
	}
	httpx.WriteJSON(w, http.StatusOK, summary)
}

// Invalidate handles POST /v1/history/invalidate (bearer auth): drops the
// cached aggregate so the next summary reflects fresh pushes.
func (h *Handler) Invalidate(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	h.aggregator.Invalidate(userID)
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Routes registers the endpoints. `middleware` is the bearer-auth wrapper.
func (h *Handler) Routes(mux *http.ServeMux, middleware func(http.Handler) http.Handler) {
	protected := func(handler http.HandlerFunc) http.Handler {
		return middleware(handler)
	}
	mux.Handle("GET /v1/history/summary", protected(h.Summary))
	mux.Handle("POST /v1/history/invalidate", protected(h.Invalidate))
}
