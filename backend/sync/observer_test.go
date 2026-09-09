package sync

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/zarz/spotiflac_android/backend/internal/httpx"
)

// capturingObserver records every callback for assertion.
type capturingObserver struct {
	mu sync.Mutex

	pushes   []pushCall
	advances []advanceCall
}

type pushCall struct {
	userID, deviceID, scope, recordID string
	revision                          int64
	accepted, deleted                 bool
}

type advanceCall struct {
	userID, deviceID, scope string
	revision                int64
}

func (o *capturingObserver) ObservePush(
	_ context.Context,
	userID, deviceID, scope, recordID string,
	revision int64,
	accepted, deleted bool,
	_ time.Time,
) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.pushes = append(o.pushes, pushCall{
		userID:   userID, deviceID: deviceID, scope: scope, recordID: recordID,
		revision: revision, accepted: accepted, deleted: deleted,
	})
}

func (o *capturingObserver) ObserveScopeAdvanced(
	_ context.Context,
	userID, deviceID, scope string,
	revision int64,
	_ time.Time,
) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.advances = append(o.advances, advanceCall{
		userID: userID, deviceID: deviceID, scope: scope, revision: revision,
	})
}

func (o *capturingObserver) snapshot() ([]pushCall, []advanceCall) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return append([]pushCall(nil), o.pushes...), append([]advanceCall(nil), o.advances...)
}

// pushVia posts records through the real HTTP handler.
func pushVia(t *testing.T, handler *Handler, userID, deviceID, scope string, records []Record) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(pushRequest{Scope: scope, Records: records})
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/sync/push", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	if deviceID != "" {
		req.Header.Set(DeviceHeader, deviceID)
	}
	req = req.WithContext(httpx.WithUserID(req.Context(), userID))

	recorder := httptest.NewRecorder()
	handler.Push(recorder, req)
	return recorder
}

func TestObserverSeesAcceptedPush(t *testing.T) {
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	handler := NewHandler(NewStore(func() time.Time { return now }))
	observer := &capturingObserver{}
	handler.SetObserver(observer)

	recorder := pushVia(t, handler, "usr_1", "android-1", "playlists", []Record{
		{RecordID: "p1", UpdatedAt: now, Payload: map[string]any{"title": "Mix"}},
	})
	if recorder.Code != http.StatusOK {
		t.Fatalf("push status %d: %s", recorder.Code, recorder.Body)
	}

	pushes, advances := observer.snapshot()
	if len(pushes) != 1 {
		t.Fatalf("expected 1 push callback, got %d", len(pushes))
	}
	if !pushes[0].accepted || pushes[0].recordID != "p1" {
		t.Fatalf("unexpected push callback: %+v", pushes[0])
	}
	if pushes[0].deviceID != "android-1" {
		t.Fatalf("device header not propagated: %q", pushes[0].deviceID)
	}
	if len(advances) != 1 || advances[0].scope != "playlists" {
		t.Fatalf("unexpected advance callbacks: %+v", advances)
	}
}

func TestObserverCoalescesScopeAdvance(t *testing.T) {
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	handler := NewHandler(NewStore(func() time.Time { return now }))
	observer := &capturingObserver{}
	handler.SetObserver(observer)

	records := make([]Record, 0, 5)
	for i := 0; i < 5; i++ {
		records = append(records, Record{
			RecordID: "p" + string(rune('a'+i)), UpdatedAt: now,
		})
	}
	pushVia(t, handler, "usr_1", "android-1", "favorites", records)

	pushes, advances := observer.snapshot()
	if len(pushes) != 5 {
		t.Fatalf("expected a callback per record, got %d", len(pushes))
	}
	// N records must cost exactly one wake-up on the other devices, not N.
	if len(advances) != 1 {
		t.Fatalf("expected 1 coalesced advance, got %d", len(advances))
	}
	if advances[0].revision != 5 {
		t.Fatalf("advance should carry the highest revision, got %d", advances[0].revision)
	}
}

func TestObserverReportsRejectedPush(t *testing.T) {
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	handler := NewHandler(NewStore(func() time.Time { return now }))

	// Seed a newer record, then push an older one that must lose.
	pushVia(t, handler, "usr_1", "d1", "playlists", []Record{
		{RecordID: "p1", UpdatedAt: now, Payload: map[string]any{"v": "new"}},
	})

	observer := &capturingObserver{}
	handler.SetObserver(observer)
	pushVia(t, handler, "usr_1", "d2", "playlists", []Record{
		{RecordID: "p1", UpdatedAt: now.Add(-time.Hour), Payload: map[string]any{"v": "old"}},
	})

	pushes, advances := observer.snapshot()
	if len(pushes) != 1 || pushes[0].accepted {
		t.Fatalf("expected a rejected push callback, got %+v", pushes)
	}
	// Nothing changed, so no device needs waking.
	if len(advances) != 0 {
		t.Fatalf("a rejected push must not advance the scope: %+v", advances)
	}
}

func TestObserverReportsTombstone(t *testing.T) {
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	handler := NewHandler(NewStore(func() time.Time { return now }))
	observer := &capturingObserver{}
	handler.SetObserver(observer)

	pushVia(t, handler, "usr_1", "d1", "playlists", []Record{
		{RecordID: "p1", UpdatedAt: now, Deleted: true},
	})

	pushes, _ := observer.snapshot()
	if len(pushes) != 1 || !pushes[0].deleted || !pushes[0].accepted {
		t.Fatalf("expected an accepted tombstone, got %+v", pushes)
	}
}

func TestPushWithoutObserverIsUnchanged(t *testing.T) {
	// The observer is optional: the pre-existing behaviour must be intact
	// when nothing is attached.
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	handler := NewHandler(NewStore(func() time.Time { return now }))

	recorder := pushVia(t, handler, "usr_1", "", "playlists", []Record{
		{RecordID: "p1", UpdatedAt: now},
	})
	if recorder.Code != http.StatusOK {
		t.Fatalf("status %d: %s", recorder.Code, recorder.Body)
	}
	var response pushResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.Revisions["p1"] != 1 {
		t.Fatalf("unexpected revisions: %+v", response.Revisions)
	}
}

func TestSetObserverNilDetaches(t *testing.T) {
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	handler := NewHandler(NewStore(func() time.Time { return now }))
	observer := &capturingObserver{}
	handler.SetObserver(observer)
	handler.SetObserver(nil)

	pushVia(t, handler, "usr_1", "d1", "playlists", []Record{
		{RecordID: "p1", UpdatedAt: now},
	})

	pushes, _ := observer.snapshot()
	if len(pushes) != 0 {
		t.Fatalf("detached observer still received %d callbacks", len(pushes))
	}
}

func TestObserverNotCalledOnInvalidScope(t *testing.T) {
	now := time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)
	handler := NewHandler(NewStore(func() time.Time { return now }))
	observer := &capturingObserver{}
	handler.SetObserver(observer)

	recorder := pushVia(t, handler, "usr_1", "d1", "not-a-scope", []Record{
		{RecordID: "p1", UpdatedAt: now},
	})
	if recorder.Code == http.StatusOK {
		t.Fatal("an unknown scope must be rejected")
	}
	pushes, advances := observer.snapshot()
	if len(pushes) != 0 || len(advances) != 0 {
		t.Fatalf("observer fired on a failed push: %+v %+v", pushes, advances)
	}
}
