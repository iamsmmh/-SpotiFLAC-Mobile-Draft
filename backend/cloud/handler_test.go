package cloud

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/zarz/spotiflac_android/backend/internal/httpx"
)

// authAs injects a fixed user id, standing in for the JWT middleware.
func authAs(userID string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			next.ServeHTTP(w, r.WithContext(httpx.WithUserID(r.Context(), userID)))
		})
	}
}

func newTestServer(t *testing.T, storage Storage, userID string) (*httptest.Server, *Handler) {
	t.Helper()
	hub := NewHub(nil, time.Now)
	handler := NewHandler(hub, storage, time.Now)
	mux := http.NewServeMux()
	handler.Routes(mux, authAs(userID))
	server := httptest.NewServer(mux)
	t.Cleanup(func() {
		server.Close()
		hub.Close()
	})
	return server, handler
}

func doJSON(t *testing.T, method, url string, body any, header http.Header) *http.Response {
	t.Helper()
	var reader *bytes.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(raw)
	} else {
		reader = bytes.NewReader(nil)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	for name, values := range header {
		for _, value := range values {
			req.Header.Add(name, value)
		}
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })
	return resp
}

// ---------------------------------------------------------------------------
// Continuity — Milestone 1 §3
// ---------------------------------------------------------------------------

func TestContinuityRoundTripAcrossDevices(t *testing.T) {
	storage := newFakeStorage()
	server, _ := newTestServer(t, storage, "usr_1")

	// Android writes a snapshot mid-track.
	resp := doJSON(t, http.MethodPut, server.URL+"/v1/cloud/continuity", ContinuityState{
		TrackID:    "track-42",
		Title:      "Nightcall",
		PositionMs: 45_000,
		DurationMs: 240_000,
		Playing:    true,
		UpdatedAt:  time.Now().UTC(),
	}, http.Header{DeviceHeader: []string{"android-1"}})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("PUT continuity: %d", resp.StatusCode)
	}

	// iPhone reads it back.
	resp = doJSON(t, http.MethodGet, server.URL+"/v1/cloud/continuity", nil,
		http.Header{DeviceHeader: []string{"ios-1"}})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET continuity: %d", resp.StatusCode)
	}
	var got continuityResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.State == nil || got.State.TrackID != "track-42" {
		t.Fatalf("unexpected state: %+v", got.State)
	}
	if got.State.DeviceID != "android-1" {
		t.Fatalf("device id was not taken from the header: %q", got.State.DeviceID)
	}
	// Resume must be at least where playback was; the elapsed correction
	// only ever moves it forward.
	if got.ResumeMs < 45_000 {
		t.Fatalf("resume rewound: %d", got.ResumeMs)
	}
}

func TestContinuityEmptyWhenNeverWritten(t *testing.T) {
	server, _ := newTestServer(t, newFakeStorage(), "usr_1")
	resp := doJSON(t, http.MethodGet, server.URL+"/v1/cloud/continuity", nil, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200 with an empty state, got %d", resp.StatusCode)
	}
	var got continuityResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if got.State != nil {
		t.Fatalf("expected no state, got %+v", got.State)
	}
}

func TestContinuityStaleWriteDoesNotRewind(t *testing.T) {
	storage := newFakeStorage()
	server, _ := newTestServer(t, storage, "usr_1")
	now := time.Now().UTC()

	doJSON(t, http.MethodPut, server.URL+"/v1/cloud/continuity", ContinuityState{
		TrackID: "new", PositionMs: 90_000, DurationMs: 240_000, UpdatedAt: now,
	}, nil)
	// An out-of-order delivery from a device whose snapshot is older.
	doJSON(t, http.MethodPut, server.URL+"/v1/cloud/continuity", ContinuityState{
		TrackID: "old", PositionMs: 1_000, DurationMs: 240_000,
		UpdatedAt: now.Add(-time.Minute),
	}, nil)

	state, err := storage.Continuity(t.Context(), "usr_1")
	if err != nil {
		t.Fatal(err)
	}
	if state.TrackID != "new" {
		t.Fatalf("a stale snapshot overwrote a newer one: %+v", state)
	}
}

func TestContinuityWithoutStorageReports501(t *testing.T) {
	server, _ := newTestServer(t, nil, "usr_1")
	resp := doJSON(t, http.MethodGet, server.URL+"/v1/cloud/continuity", nil, nil)
	if resp.StatusCode != http.StatusNotImplemented {
		t.Fatalf("expected 501 without storage, got %d", resp.StatusCode)
	}
}

func TestContinuityRejectsUnauthenticated(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()
	mux := http.NewServeMux()
	NewHandler(hub, newFakeStorage(), time.Now).Routes(mux, nil)
	server := httptest.NewServer(mux)
	defer server.Close()

	resp := doJSON(t, http.MethodGet, server.URL+"/v1/cloud/continuity", nil, nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

// ---------------------------------------------------------------------------
// Device management — Milestone 1 §5
// ---------------------------------------------------------------------------

func seedDevices(t *testing.T, storage *fakeStorage) {
	t.Helper()
	now := time.Now().UTC()
	for i, id := range []string{"android-1", "ios-1"} {
		if err := storage.UpsertDevice(t.Context(), DeviceRow{
			ID: id, UserID: "usr_1", Name: id, Platform: "test",
			CreatedAt: now, LastSeenAt: now.Add(time.Duration(i) * time.Minute),
		}); err != nil {
			t.Fatal(err)
		}
	}
}

func TestListDevicesMarksCurrent(t *testing.T) {
	storage := newFakeStorage()
	seedDevices(t, storage)
	server, _ := newTestServer(t, storage, "usr_1")

	resp := doJSON(t, http.MethodGet, server.URL+"/v1/cloud/devices", nil,
		http.Header{DeviceHeader: []string{"ios-1"}})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	var got devicesResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if len(got.Devices) != 2 {
		t.Fatalf("expected 2 devices, got %d", len(got.Devices))
	}
	var currents int
	for _, device := range got.Devices {
		if device.Current {
			currents++
			if device.ID != "ios-1" {
				t.Fatalf("wrong device flagged current: %s", device.ID)
			}
		}
	}
	if currents != 1 {
		t.Fatalf("expected exactly one current device, got %d", currents)
	}
}

func TestRenameAndTrustDevice(t *testing.T) {
	storage := newFakeStorage()
	seedDevices(t, storage)
	server, _ := newTestServer(t, storage, "usr_1")

	name, trusted := "Kitchen speaker", true
	resp := doJSON(t, http.MethodPatch, server.URL+"/v1/cloud/devices/android-1",
		patchDeviceRequest{Name: &name, Trusted: &trusted}, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}

	devices, err := storage.Devices(t.Context(), "usr_1")
	if err != nil {
		t.Fatal(err)
	}
	for _, device := range devices {
		if device.ID == "android-1" {
			if device.Name != name || !device.Trusted {
				t.Fatalf("patch not applied: %+v", device)
			}
			return
		}
	}
	t.Fatal("device disappeared")
}

func TestPatchUnknownDeviceIs404(t *testing.T) {
	server, _ := newTestServer(t, newFakeStorage(), "usr_1")
	name := "ghost"
	resp := doJSON(t, http.MethodPatch, server.URL+"/v1/cloud/devices/nope",
		patchDeviceRequest{Name: &name}, nil)
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}

func TestRevokeDeviceDropsItsSessions(t *testing.T) {
	storage := newFakeStorage()
	seedDevices(t, storage)
	if err := storage.PutRefresh(t.Context(), RefreshRow{
		Hash: "hash-a", UserID: "usr_1", DeviceID: "android-1",
		ExpiresAt: time.Now().Add(time.Hour),
	}); err != nil {
		t.Fatal(err)
	}
	server, _ := newTestServer(t, storage, "usr_1")

	resp := doJSON(t, http.MethodDelete, server.URL+"/v1/cloud/devices/android-1", nil, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	if _, err := storage.Refresh(t.Context(), "hash-a"); err == nil {
		t.Fatal("remote logout left the refresh token alive")
	}
}

func TestRevokedDeviceReceivesTheEvent(t *testing.T) {
	storage := newFakeStorage()
	seedDevices(t, storage)
	hub := NewHub(nil, time.Now)
	defer hub.Close()
	handler := NewHandler(hub, storage, time.Now)
	mux := http.NewServeMux()
	handler.Routes(mux, authAs("usr_1"))
	server := httptest.NewServer(mux)
	defer server.Close()

	// The revoked device is listening; echo suppression must NOT hide the
	// revocation from it, because it is the one that has to act on it.
	victim := hub.Subscribe("usr_1", "android-1")
	defer victim.Close()

	doJSON(t, http.MethodDelete, server.URL+"/v1/cloud/devices/android-1", nil,
		http.Header{DeviceHeader: []string{"ios-1"}})

	select {
	case event := <-victim.Events():
		if event.Kind != EventDeviceRevoked {
			t.Fatalf("unexpected event kind %q", event.Kind)
		}
		if !strings.Contains(string(event.Payload), "android-1") {
			t.Fatalf("payload missing the device id: %s", event.Payload)
		}
	case <-time.After(time.Second):
		t.Fatal("the revoked device never learned it was logged out")
	}
}

// ---------------------------------------------------------------------------
// Sync log — Milestone 1 §4
// ---------------------------------------------------------------------------

func TestSyncLogIsNewestFirst(t *testing.T) {
	storage := newFakeStorage()
	for i := 1; i <= 3; i++ {
		if err := storage.AppendSyncLog(t.Context(), SyncLogRow{
			UserID: "usr_1", Scope: "playlists", RecordID: "p" + itoa(i),
			Resolution: ResolutionAccepted, Revision: int64(i), At: time.Now(),
		}); err != nil {
			t.Fatal(err)
		}
	}
	server, _ := newTestServer(t, storage, "usr_1")

	resp := doJSON(t, http.MethodGet, server.URL+"/v1/cloud/sync-log", nil, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status %d", resp.StatusCode)
	}
	var got syncLogResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if len(got.Entries) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(got.Entries))
	}
	if got.Entries[0].Revision != 3 {
		t.Fatalf("expected newest first, got revision %d", got.Entries[0].Revision)
	}
}

func TestSyncLogHonoursLimit(t *testing.T) {
	storage := newFakeStorage()
	for i := 0; i < 10; i++ {
		_ = storage.AppendSyncLog(t.Context(), SyncLogRow{
			UserID: "usr_1", Scope: "favorites", RecordID: itoa(i),
			Resolution: ResolutionAccepted, At: time.Now(),
		})
	}
	server, _ := newTestServer(t, storage, "usr_1")

	resp := doJSON(t, http.MethodGet, server.URL+"/v1/cloud/sync-log?limit=4", nil, nil)
	var got syncLogResponse
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		t.Fatal(err)
	}
	if len(got.Entries) != 4 {
		t.Fatalf("limit ignored: got %d entries", len(got.Entries))
	}
}

// ---------------------------------------------------------------------------
// Realtime socket
// ---------------------------------------------------------------------------

func TestWebSocketDeliversSyncEvent(t *testing.T) {
	storage := newFakeStorage()
	hub := NewHub(nil, time.Now)
	defer hub.Close()
	mux := http.NewServeMux()
	NewHandler(hub, storage, time.Now).Routes(mux, authAs("usr_1"))
	server := httptest.NewServer(mux)
	defer server.Close()

	client, err := dialWS(server.URL+"/v1/cloud/events",
		http.Header{DeviceHeader: []string{"ios-1"}})
	if err != nil {
		t.Fatalf("handshake: %v", err)
	}
	defer func() { _ = client.Close() }()

	// Give the handler a moment to register the subscription.
	waitForSubscriber(t, hub, "usr_1")

	hub.Broadcast(t.Context(), "usr_1", NewSyncEvent("playlists", 11, "android-1", time.Now()))

	event, err := client.readEvent(3 * time.Second)
	if err != nil {
		t.Fatalf("read event: %v", err)
	}
	if event.Kind != EventSync || event.Scope != "playlists" || event.Revision != 11 {
		t.Fatalf("unexpected event: %+v", event)
	}
}

func TestWebSocketContinuityPushPersistsAndFansOut(t *testing.T) {
	storage := newFakeStorage()
	hub := NewHub(nil, time.Now)
	defer hub.Close()
	mux := http.NewServeMux()
	NewHandler(hub, storage, time.Now).Routes(mux, authAs("usr_1"))
	server := httptest.NewServer(mux)
	defer server.Close()

	client, err := dialWS(server.URL+"/v1/cloud/events",
		http.Header{DeviceHeader: []string{"android-1"}})
	if err != nil {
		t.Fatalf("handshake: %v", err)
	}
	defer func() { _ = client.Close() }()
	waitForSubscriber(t, hub, "usr_1")

	// A second device waiting for the hand-off.
	listener := hub.Subscribe("usr_1", "ios-1")
	defer listener.Close()

	event := NewContinuityEvent(ContinuityState{
		DeviceID: "android-1", TrackID: "t-1",
		PositionMs: 12_000, DurationMs: 200_000, Playing: true,
		UpdatedAt: time.Now().UTC(),
	}, time.Now())
	raw, err := event.Encode()
	if err != nil {
		t.Fatal(err)
	}
	if err := client.writeText(raw); err != nil {
		t.Fatal(err)
	}

	select {
	case got := <-listener.Events():
		if got.Kind != EventContinuity {
			t.Fatalf("unexpected kind %q", got.Kind)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("continuity was not fanned out")
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if state, err := storage.Continuity(t.Context(), "usr_1"); err == nil && state.TrackID == "t-1" {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("continuity was never persisted")
}

func TestWebSocketRejectsPlainGet(t *testing.T) {
	server, _ := newTestServer(t, newFakeStorage(), "usr_1")
	resp := doJSON(t, http.MethodGet, server.URL+"/v1/cloud/events", nil, nil)
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for a non-upgrade request, got %d", resp.StatusCode)
	}
}

func TestWebSocketDisconnectReleasesSubscription(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()
	mux := http.NewServeMux()
	NewHandler(hub, newFakeStorage(), time.Now).Routes(mux, authAs("usr_1"))
	server := httptest.NewServer(mux)
	defer server.Close()

	client, err := dialWS(server.URL+"/v1/cloud/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	waitForSubscriber(t, hub, "usr_1")
	_ = client.Close()

	// The reader goroutine must notice and unsubscribe: otherwise every
	// dropped mobile connection leaks a subscriber and its buffer.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if hub.Connections("usr_1") == 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("subscription leaked after the client disconnected")
}

func waitForSubscriber(t *testing.T, hub *Hub, userID string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if hub.Connections(userID) > 0 {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("the websocket handler never registered a subscriber")
}
