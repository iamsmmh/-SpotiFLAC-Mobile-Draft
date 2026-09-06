package cloud

import (
	"errors"
	"testing"
	"time"
)

func TestObserverLogsAcceptedAndRejected(t *testing.T) {
	storage := newFakeStorage()
	hub := NewHub(nil, time.Now)
	defer hub.Close()
	observer := NewSyncObserver(hub, storage)

	ctx := t.Context()
	now := time.Now()
	observer.ObservePush(ctx, "usr_1", "d1", "playlists", "p1", 5, true, false, now)
	observer.ObservePush(ctx, "usr_1", "d1", "playlists", "p2", 6, false, false, now)
	observer.ObservePush(ctx, "usr_1", "d1", "playlists", "p3", 7, true, true, now)

	rows, err := storage.SyncLog(ctx, "usr_1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != 3 {
		t.Fatalf("expected 3 log rows, got %d", len(rows))
	}

	byRecord := map[string]string{}
	for _, row := range rows {
		byRecord[row.RecordID] = row.Resolution
	}
	if byRecord["p1"] != ResolutionAccepted {
		t.Fatalf("p1: %s", byRecord["p1"])
	}
	if byRecord["p2"] != ResolutionRejected {
		t.Fatalf("p2: %s", byRecord["p2"])
	}
	// An accepted delete is a tombstone, which is worth distinguishing in
	// an audit trail from an ordinary accepted write.
	if byRecord["p3"] != ResolutionTombstone {
		t.Fatalf("p3: %s", byRecord["p3"])
	}
}

func TestObserverCanSkipRejections(t *testing.T) {
	storage := newFakeStorage()
	observer := NewSyncObserver(nil, storage)
	observer.SetLogRejections(false)

	observer.ObservePush(t.Context(), "usr_1", "d1", "favorites", "f1", 1, false, false, time.Now())

	rows, _ := storage.SyncLog(t.Context(), "usr_1", 0)
	if len(rows) != 0 {
		t.Fatalf("expected rejections to be skipped, got %d rows", len(rows))
	}
}

func TestObserverSurvivesLogFailure(t *testing.T) {
	storage := newFakeStorage()
	storage.failNext = errors.New("disk full")
	observer := NewSyncObserver(nil, storage)

	// The audit trail is diagnostic: a write failure must never surface as
	// an error on the user's sync.
	observer.ObservePush(t.Context(), "usr_1", "d1", "history", "h1", 1, true, false, time.Now())
}

func TestObserverWithoutStorageIsInert(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()
	observer := NewSyncObserver(hub, nil)
	observer.ObservePush(t.Context(), "usr_1", "d1", "history", "h1", 1, true, false, time.Now())
}

func TestObserverBroadcastsScopeAdvance(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()
	observer := NewSyncObserver(hub, newFakeStorage())

	listener := hub.Subscribe("usr_1", "other-device")
	defer listener.Close()

	observer.ObserveScopeAdvanced(t.Context(), "usr_1", "pushing-device", "playlists", 12, time.Now())

	select {
	case event := <-listener.Events():
		if event.Kind != EventSync || event.Revision != 12 || event.Scope != "playlists" {
			t.Fatalf("unexpected event: %+v", event)
		}
		if event.Origin != "pushing-device" {
			t.Fatalf("origin not propagated: %q", event.Origin)
		}
	case <-time.After(time.Second):
		t.Fatal("no scope-advance event")
	}
}

func TestObserverSuppressesEchoToPusher(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()
	observer := NewSyncObserver(hub, nil)

	pusher := hub.Subscribe("usr_1", "pushing-device")
	defer pusher.Close()

	observer.ObserveScopeAdvanced(t.Context(), "usr_1", "pushing-device", "favorites", 3, time.Now())

	// The pushing device already applied the change; re-pulling it would be
	// pure waste (and can loop if the client re-pushes on every event).
	select {
	case event := <-pusher.Events():
		t.Fatalf("pusher received its own echo: %+v", event)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestObserverWithNilHubIsInert(t *testing.T) {
	observer := NewSyncObserver(nil, newFakeStorage())
	observer.ObserveScopeAdvanced(t.Context(), "usr_1", "d", "favorites", 1, time.Now())
}
