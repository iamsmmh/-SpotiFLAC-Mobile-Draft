package sync

import (
	"errors"
	"net/http"
	"strings"

	"github.com/zarz/spotiflac_android/backend/internal/httpx"
)

// Handler serves the /v1/sync/* endpoints.
type Handler struct {
	store *Store
	// observer is the optional realtime hook (see observer.go). It is set
	// once during wiring and read without a lock on the push path.
	observer PushObserver
}

// NewHandler wires the sync handler.
func NewHandler(store *Store) *Handler { return &Handler{store: store} }

// Store exposes the backing store.
func (h *Handler) Store() *Store { return h.store }

type pullRequest struct {
	Scope         string `json:"scope"`
	SinceRevision *int64 `json:"sinceRevision"`
}

type pullResponse struct {
	Records []Record `json:"records"`
}

type pushRequest struct {
	Scope   string   `json:"scope"`
	Records []Record `json:"records"`
}

type pushResponse struct {
	Revisions map[string]int64 `json:"revisions"`
}

type meResponse struct {
	UserID     string `json:"userId"`
	ProviderID string `json:"providerId"`
}

// Pull handles POST /v1/sync/pull.
func (h *Handler) Pull(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var req pullRequest
	if err := httpx.ReadJSON(w, r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	var since int64
	if req.SinceRevision != nil {
		since = *req.SinceRevision
	}
	records, err := h.store.Pull(r.Context(), userID, req.Scope, since)
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	out := make([]Record, 0, len(records))
	for _, record := range records {
		out = append(out, *record)
	}
	httpx.WriteJSON(w, http.StatusOK, pullResponse{Records: out})
}

// Push handles POST /v1/sync/push.
func (h *Handler) Push(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var req pushRequest
	if err := httpx.ReadJSON(w, r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	results, err := h.store.Push(r.Context(), userID, req.Scope, req.Records)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, ErrScopeFull) {
			status = http.StatusInsufficientStorage
		}
		httpx.WriteError(w, status, err.Error())
		return
	}
	revisions := make(map[string]int64, len(results))
	for recordID, result := range results {
		revisions[recordID] = result.Revision
	}

	h.notify(r, userID, req.Scope, req.Records, results)

	httpx.WriteJSON(w, http.StatusOK, pushResponse{Revisions: revisions})
}

// Me handles GET /v1/sync/me.
func (h *Handler) Me(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	httpx.WriteJSON(w, http.StatusOK, meResponse{UserID: userID, ProviderID: "selfhosted"})
}

// Routes registers the sync endpoints (bearer auth applied by the caller).
func (h *Handler) Routes(mux *http.ServeMux, middleware func(http.Handler) http.Handler) {
	protected := func(handler http.HandlerFunc) http.Handler {
		return middleware(handler)
	}
	mux.Handle("POST /v1/sync/pull", protected(h.Pull))
	mux.Handle("POST /v1/sync/push", protected(h.Push))
	mux.Handle("GET /v1/sync/me", protected(h.Me))
}

// notify feeds the realtime observer. It reports every record's outcome for
// the sync log, then a single scope-advanced event so N pushed records cost
// one wake-up on the other devices rather than N.
func (h *Handler) notify(r *http.Request, userID, scope string, records []Record, results map[string]PushResult) {
	if h.observer == nil {
		return
	}
	ctx := r.Context()
	deviceID := strings.TrimSpace(r.Header.Get(DeviceHeader))
	now := h.store.clock().UTC()

	var maxRevision int64
	var changed bool
	for i := range records {
		result, ok := results[records[i].RecordID]
		if !ok {
			continue
		}
		h.observer.ObservePush(ctx, userID, deviceID, scope, records[i].RecordID,
			result.Revision, result.Accepted, records[i].Deleted, now)
		if result.Accepted {
			changed = true
			if result.Revision > maxRevision {
				maxRevision = result.Revision
			}
		}
	}
	if changed {
		h.observer.ObserveScopeAdvanced(ctx, userID, deviceID, scope, maxRevision, now)
	}
}
