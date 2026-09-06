package cloud

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/zarz/spotiflac_android/backend/internal/httpx"
)

// DeviceHeader carries the calling installation's stable device id. It is a
// header rather than a body field so *every* endpoint (including the
// WebSocket upgrade, which has no body) can identify its origin.
const DeviceHeader = "X-Device-Id"

// Handler serves /v1/cloud/*: the realtime event socket, playback
// continuity, device management and the sync log.
//
// Every dependency is optional. With no Storage the continuity and device
// endpoints answer 501 instead of crashing, so the reference in-memory
// deployment keeps working unchanged — this handler only *adds* surface.
type Handler struct {
	hub     *Hub
	storage Storage
	clock   func() time.Time
}

// NewHandler wires the cloud handler. storage may be nil.
func NewHandler(hub *Hub, storage Storage, clock func() time.Time) *Handler {
	if clock == nil {
		clock = time.Now
	}
	if hub == nil {
		hub = NewHub(nil, clock)
	}
	return &Handler{hub: hub, storage: storage, clock: clock}
}

// Hub exposes the event hub so other packages (sync, playlists) can
// broadcast without importing the transport.
func (h *Handler) Hub() *Hub { return h.hub }

// Routes mounts the endpoints behind the shared auth middleware.
func (h *Handler) Routes(mux *http.ServeMux, middleware func(http.Handler) http.Handler) {
	guard := middleware
	if guard == nil {
		guard = func(next http.Handler) http.Handler { return next }
	}
	mux.Handle("GET /v1/cloud/events", guard(http.HandlerFunc(h.Events)))
	mux.Handle("GET /v1/cloud/continuity", guard(http.HandlerFunc(h.GetContinuity)))
	mux.Handle("PUT /v1/cloud/continuity", guard(http.HandlerFunc(h.PutContinuity)))
	mux.Handle("GET /v1/cloud/devices", guard(http.HandlerFunc(h.ListDevices)))
	mux.Handle("PATCH /v1/cloud/devices/{id}", guard(http.HandlerFunc(h.PatchDevice)))
	mux.Handle("DELETE /v1/cloud/devices/{id}", guard(http.HandlerFunc(h.RevokeDevice)))
	mux.Handle("GET /v1/cloud/sync-log", guard(http.HandlerFunc(h.SyncLog)))
}

// ---------------------------------------------------------------------------
// Realtime events
// ---------------------------------------------------------------------------

// PingInterval is the server keepalive cadence. Mobile networks and proxies
// drop idle sockets aggressively; a ping well under the usual 60 s idle
// timeout keeps the hand-off path warm.
const PingInterval = 25 * time.Second

// WriteTimeout bounds a single frame write to a stuck peer.
const WriteTimeout = 10 * time.Second

// Events upgrades to a WebSocket and streams the user's events.
func (h *Handler) Events(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	deviceID := strings.TrimSpace(r.Header.Get(DeviceHeader))

	conn, err := Accept(w, r)
	if err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}

	subscription := h.hub.Subscribe(userID, deviceID)

	// The connection outlives this handler's request context, so derive a
	// fresh one; cancellation is driven by the socket itself.
	ctx, cancel := context.WithCancel(context.WithoutCancel(r.Context()))
	defer cancel()
	defer subscription.Close()
	defer func() { _ = conn.Close() }()

	// Reader goroutine: consumes client frames (acks, continuity pushes)
	// and, more importantly, notices the peer going away. Without an active
	// reader a half-closed socket is invisible until the next write fails.
	go func() {
		defer cancel()
		for {
			message, err := conn.Read()
			if err != nil {
				return
			}
			h.handleClientMessage(ctx, userID, deviceID, message)
		}
	}()

	ticker := time.NewTicker(PingInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-conn.Done():
			return
		case event, ok := <-subscription.Events():
			if !ok {
				return
			}
			payload, err := event.Encode()
			if err != nil {
				continue
			}
			_ = conn.SetWriteDeadline(h.clock().Add(WriteTimeout))
			if err := conn.WriteText(payload); err != nil {
				return
			}
		case <-ticker.C:
			_ = conn.SetWriteDeadline(h.clock().Add(WriteTimeout))
			if err := conn.WritePing(); err != nil {
				return
			}
		}
	}
}

// handleClientMessage applies an inbound frame. Continuity snapshots arrive
// here (rather than over HTTP) during active playback so a hand-off costs
// one frame instead of a request.
func (h *Handler) handleClientMessage(ctx context.Context, userID, deviceID string, message Message) {
	event, err := DecodeEvent(message.Data)
	if err != nil {
		return
	}
	if event.Kind != EventContinuity || len(event.Payload) == 0 {
		return
	}
	state, err := decodeContinuity(event.Payload)
	if err != nil {
		return
	}
	state.UserID = userID
	if state.DeviceID == "" {
		state.DeviceID = deviceID
	}
	h.storeContinuity(ctx, state)
}

// storeContinuity persists (when a store is configured) and fans out.
func (h *Handler) storeContinuity(ctx context.Context, state ContinuityState) {
	state = state.Normalize(h.clock())
	if h.storage != nil {
		if err := h.storage.PutContinuity(ctx, state); err != nil {
			// A persistence failure must not stop the live hand-off: the
			// other device can still resume from the broadcast snapshot.
			_ = err
		}
	}
	h.hub.Broadcast(ctx, state.UserID, NewContinuityEvent(state, h.clock()))
}

// ---------------------------------------------------------------------------
// Continuity
// ---------------------------------------------------------------------------

type continuityResponse struct {
	State      *ContinuityState `json:"state"`
	ResumeMs   int64            `json:"resumeMs"`
	ServerTime time.Time        `json:"serverTime"`
}

// GetContinuity returns the latest snapshot plus the corrected resume
// offset, so the client does not have to trust its own clock.
func (h *Handler) GetContinuity(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if h.storage == nil {
		httpx.WriteError(w, http.StatusNotImplemented, "continuity storage is not configured")
		return
	}
	state, err := h.storage.Continuity(r.Context(), userID)
	if errors.Is(err, ErrNotFound) {
		httpx.WriteJSON(w, http.StatusOK, continuityResponse{ServerTime: h.clock().UTC()})
		return
	}
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "could not load continuity")
		return
	}
	now := h.clock()
	httpx.WriteJSON(w, http.StatusOK, continuityResponse{
		State:      &state,
		ResumeMs:   state.ResumePosition(now).Milliseconds(),
		ServerTime: now.UTC(),
	})
}

// PutContinuity stores a snapshot and notifies the user's other devices.
func (h *Handler) PutContinuity(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	var state ContinuityState
	if err := httpx.ReadJSON(w, r, &state); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	state.UserID = userID
	if strings.TrimSpace(state.DeviceID) == "" {
		state.DeviceID = strings.TrimSpace(r.Header.Get(DeviceHeader))
	}
	h.storeContinuity(r.Context(), state)
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// decodeContinuity parses a snapshot from a raw event payload.
func decodeContinuity(payload []byte) (ContinuityState, error) {
	var state ContinuityState
	err := jsonUnmarshal(payload, &state)
	return state, err
}

// ---------------------------------------------------------------------------
// Device management (Settings → Devices)
// ---------------------------------------------------------------------------

type deviceView struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Platform   string     `json:"platform"`
	Trusted    bool       `json:"trusted"`
	CreatedAt  time.Time  `json:"createdAt"`
	LastSeenAt time.Time  `json:"lastSeenAt"`
	LastSyncAt *time.Time `json:"lastSyncAt,omitempty"`
	Online     bool       `json:"online"`
	Current    bool       `json:"current"`
}

type devicesResponse struct {
	Devices []deviceView `json:"devices"`
}

// ListDevices returns the device list for Settings → Devices.
func (h *Handler) ListDevices(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if h.storage == nil {
		httpx.WriteError(w, http.StatusNotImplemented, "device storage is not configured")
		return
	}
	rows, err := h.storage.Devices(r.Context(), userID)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "could not list devices")
		return
	}
	current := strings.TrimSpace(r.Header.Get(DeviceHeader))
	// A user with N devices has at most a handful of live sockets, so the
	// online flag is derived from the local hub count only when it is the
	// sole process; it is advisory either way.
	online := h.hub.Connections(userID) > 0

	views := make([]deviceView, 0, len(rows))
	for _, row := range rows {
		view := deviceView{
			ID:         row.ID,
			Name:       row.Name,
			Platform:   row.Platform,
			Trusted:    row.Trusted,
			CreatedAt:  row.CreatedAt,
			LastSeenAt: row.LastSeenAt,
			Current:    current != "" && row.ID == current,
		}
		if !row.LastSyncAt.IsZero() && row.LastSyncAt.Year() > 1971 {
			at := row.LastSyncAt
			view.LastSyncAt = &at
		}
		view.Online = view.Current && online
		views = append(views, view)
	}
	httpx.WriteJSON(w, http.StatusOK, devicesResponse{Devices: views})
}

type patchDeviceRequest struct {
	Name    *string `json:"name"`
	Trusted *bool   `json:"trusted"`
}

// PatchDevice renames a device and/or flips its trust flag.
func (h *Handler) PatchDevice(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if h.storage == nil {
		httpx.WriteError(w, http.StatusNotImplemented, "device storage is not configured")
		return
	}
	var req patchDeviceRequest
	if err := httpx.ReadJSON(w, r, &req); err != nil {
		httpx.WriteError(w, http.StatusBadRequest, err.Error())
		return
	}
	deviceID := r.PathValue("id")
	if req.Name != nil {
		if err := h.storage.RenameDevice(r.Context(), userID, deviceID, *req.Name); err != nil {
			h.writeDeviceError(w, err)
			return
		}
	}
	if req.Trusted != nil {
		if err := h.storage.SetDeviceTrust(r.Context(), userID, deviceID, *req.Trusted); err != nil {
			h.writeDeviceError(w, err)
			return
		}
	}
	h.hub.Broadcast(r.Context(), userID, NewDeviceEvent(EventDevices, deviceID, h.clock()))
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// RevokeDevice performs a remote logout.
func (h *Handler) RevokeDevice(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if h.storage == nil {
		httpx.WriteError(w, http.StatusNotImplemented, "device storage is not configured")
		return
	}
	deviceID := r.PathValue("id")
	if err := h.storage.DeleteDevice(r.Context(), userID, deviceID); err != nil {
		h.writeDeviceError(w, err)
		return
	}
	// Tell the revoked device first (so it can wipe its tokens), then the
	// rest so their device lists refresh.
	h.hub.Broadcast(r.Context(), userID, Event{
		Kind: EventDeviceRevoked,
		// No Origin: the revoked device is precisely the one that must
		// receive this, so echo suppression has to stay off.
		Payload: mustJSON(map[string]string{"deviceId": deviceID}),
		At:      h.clock().UTC(),
	})
	httpx.WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *Handler) writeDeviceError(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrNotFound) {
		httpx.WriteError(w, http.StatusNotFound, "device not found")
		return
	}
	httpx.WriteError(w, http.StatusInternalServerError, "device update failed")
}

// ---------------------------------------------------------------------------
// Sync log
// ---------------------------------------------------------------------------

type syncLogEntry struct {
	ID         int64     `json:"id"`
	DeviceID   string    `json:"deviceId"`
	Scope      string    `json:"scope"`
	RecordID   string    `json:"recordId"`
	Resolution string    `json:"resolution"`
	Revision   int64     `json:"revision"`
	At         time.Time `json:"at"`
}

type syncLogResponse struct {
	Entries []syncLogEntry `json:"entries"`
}

// SyncLog returns the conflict-resolution audit trail.
func (h *Handler) SyncLog(w http.ResponseWriter, r *http.Request) {
	userID := httpx.UserIDFrom(r.Context())
	if userID == "" {
		httpx.WriteError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if h.storage == nil {
		httpx.WriteError(w, http.StatusNotImplemented, "sync log storage is not configured")
		return
	}
	limit := 200
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 && parsed <= 1000 {
			limit = parsed
		}
	}
	rows, err := h.storage.SyncLog(r.Context(), userID, limit)
	if err != nil {
		httpx.WriteError(w, http.StatusInternalServerError, "could not load sync log")
		return
	}
	entries := make([]syncLogEntry, 0, len(rows))
	for _, row := range rows {
		entries = append(entries, syncLogEntry{
			ID:         row.ID,
			DeviceID:   row.DeviceID,
			Scope:      row.Scope,
			RecordID:   row.RecordID,
			Resolution: row.Resolution,
			Revision:   row.Revision,
			At:         row.At,
		})
	}
	httpx.WriteJSON(w, http.StatusOK, syncLogResponse{Entries: entries})
}
