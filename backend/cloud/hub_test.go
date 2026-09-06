package cloud

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

func TestHubDeliversToOtherDevices(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()

	phone := hub.Subscribe("usr_1", "device-phone")
	defer phone.Close()
	tablet := hub.Subscribe("usr_1", "device-tablet")
	defer tablet.Close()

	hub.Broadcast(context.Background(), "usr_1",
		NewSyncEvent("playlists", 7, "device-phone", time.Now()))

	select {
	case event := <-tablet.Events():
		if event.Scope != "playlists" || event.Revision != 7 {
			t.Fatalf("unexpected event: %+v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("tablet did not receive the event")
	}

	// The originating device must not receive its own echo.
	select {
	case event := <-phone.Events():
		t.Fatalf("origin device received its own echo: %+v", event)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestHubIsolatesUsers(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()

	mine := hub.Subscribe("usr_1", "a")
	defer mine.Close()
	theirs := hub.Subscribe("usr_2", "b")
	defer theirs.Close()

	hub.Broadcast(context.Background(), "usr_1", NewSyncEvent("favorites", 1, "", time.Now()))

	select {
	case <-mine.Events():
	case <-time.After(time.Second):
		t.Fatal("own user did not receive the event")
	}
	select {
	case event := <-theirs.Events():
		t.Fatalf("event leaked across users: %+v", event)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestHubDropsForSlowConsumerWithoutBlocking(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()

	sub := hub.Subscribe("usr_1", "slow")
	defer sub.Close()

	// Overrun the buffer by a wide margin; Broadcast must never block.
	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := 0; i < SubscriberBuffer*4; i++ {
			hub.Broadcast(context.Background(), "usr_1",
				NewSyncEvent("history", int64(i), "", time.Now()))
		}
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Broadcast blocked on a slow consumer")
	}
	if got := len(sub.Events()); got > SubscriberBuffer {
		t.Fatalf("buffer grew past its bound: %d", got)
	}
}

func TestSubscriptionCloseIsIdempotent(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()

	sub := hub.Subscribe("usr_1", "a")
	sub.Close()
	sub.Close() // must not panic or double-close the channel

	if hub.Connections("usr_1") != 0 {
		t.Fatal("subscription was not removed")
	}
}

func TestHubCloseUnblocksSubscribers(t *testing.T) {
	hub := NewHub(nil, time.Now)
	sub := hub.Subscribe("usr_1", "a")
	hub.Close()

	select {
	case _, ok := <-sub.Events():
		if ok {
			t.Fatal("expected the channel to be closed")
		}
	case <-time.After(time.Second):
		t.Fatal("Close did not release subscribers")
	}

	// Subscribing after Close must yield a closed channel, not a hang.
	after := hub.Subscribe("usr_1", "b")
	select {
	case _, ok := <-after.Events():
		if ok {
			t.Fatal("expected a closed channel after hub shutdown")
		}
	case <-time.After(time.Second):
		t.Fatal("post-close Subscribe did not return a closed channel")
	}
}

// recordingPublisher captures cross-process publishes.
type recordingPublisher struct {
	mu       sync.Mutex
	channels []string
	payloads [][]byte
	err      error
}

func (p *recordingPublisher) Publish(_ context.Context, channel string, payload []byte) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.channels = append(p.channels, channel)
	p.payloads = append(p.payloads, payload)
	return p.err
}

func (p *recordingPublisher) count() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.channels)
}

func TestHubPublishesCrossProcess(t *testing.T) {
	publisher := &recordingPublisher{}
	hub := NewHub(publisher, time.Now)
	defer hub.Close()

	hub.Broadcast(context.Background(), "usr_9", NewSyncEvent("settings", 3, "d1", time.Now()))

	if publisher.count() != 1 {
		t.Fatalf("expected one publish, got %d", publisher.count())
	}
	if publisher.channels[0] != UserChannel("usr_9") {
		t.Fatalf("wrong channel: %s", publisher.channels[0])
	}
}

func TestHubBroadcastSurvivesPublisherFailure(t *testing.T) {
	publisher := &recordingPublisher{err: errors.New("redis down")}
	hub := NewHub(publisher, time.Now)
	defer hub.Close()

	sub := hub.Subscribe("usr_1", "other")
	defer sub.Close()

	// A Redis outage must degrade cross-device latency, never the local
	// delivery or the caller's request.
	hub.Broadcast(context.Background(), "usr_1", NewSyncEvent("favorites", 2, "origin", time.Now()))

	select {
	case event := <-sub.Events():
		if event.Revision != 2 {
			t.Fatalf("unexpected event: %+v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("local delivery failed when the publisher errored")
	}
}

func TestHubBridgeDeliversRedisMessages(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()

	sub := hub.Subscribe("usr_5", "local")
	defer sub.Close()

	messages := make(chan RedisMessage, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go hub.Bridge(ctx, messages)

	payload, err := NewSyncEvent("playlists", 42, "remote", time.Now()).Encode()
	if err != nil {
		t.Fatal(err)
	}
	messages <- RedisMessage{Channel: UserChannel("usr_5"), Payload: payload}

	select {
	case event := <-sub.Events():
		if event.Revision != 42 {
			t.Fatalf("unexpected event: %+v", event)
		}
	case <-time.After(time.Second):
		t.Fatal("bridge did not deliver the message")
	}
}

func TestHubBridgeIgnoresForeignChannels(t *testing.T) {
	hub := NewHub(nil, time.Now)
	defer hub.Close()

	sub := hub.Subscribe("usr_5", "local")
	defer sub.Close()

	messages := make(chan RedisMessage, 2)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go hub.Bridge(ctx, messages)

	messages <- RedisMessage{Channel: "someone-elses:key", Payload: []byte(`{"kind":"sync"}`)}
	messages <- RedisMessage{Channel: UserChannel("usr_5"), Payload: []byte("not json")}

	select {
	case event := <-sub.Events():
		t.Fatalf("delivered an event it should have dropped: %+v", event)
	case <-time.After(100 * time.Millisecond):
	}
}

func TestUserChannelRoundTrip(t *testing.T) {
	if got := UserFromChannel(UserChannel("usr_abc")); got != "usr_abc" {
		t.Fatalf("round trip failed: %q", got)
	}
	if got := UserFromChannel("other:usr_abc"); got != "" {
		t.Fatalf("expected empty for a foreign channel, got %q", got)
	}
}

func TestHubConcurrentSubscribeBroadcast(t *testing.T) {
	// Guards the map against concurrent mutation; meaningful under -race.
	hub := NewHub(nil, time.Now)
	defer hub.Close()

	var wg sync.WaitGroup
	for i := 0; i < 16; i++ {
		wg.Add(2)
		go func() {
			defer wg.Done()
			sub := hub.Subscribe("usr_1", "d")
			time.Sleep(time.Millisecond)
			sub.Close()
		}()
		go func() {
			defer wg.Done()
			hub.Broadcast(context.Background(), "usr_1", NewSyncEvent("history", 1, "", time.Now()))
		}()
	}
	wg.Wait()
}
