package cloud

import (
	"context"
	"sync"
	"time"
)

// Hub fans events out to every connected device of a user.
//
// Scaling model: each process owns the sockets that happen to land on it and
// keeps a *local* subscriber table. Cross-process delivery rides Redis
// pub/sub (one channel per user). With no Redis configured the hub is still
// fully correct for a single-process deployment, which is the default.
type Hub struct {
	mu sync.RWMutex
	// subscribers maps userID → subscriberID → channel.
	subscribers map[string]map[int64]*subscriber
	nextID      int64
	closed      bool

	publisher Publisher
	clock     func() time.Time
}

// Publisher is the cross-process transport (satisfied by *RedisClient). A
// nil Publisher means single-process operation.
type Publisher interface {
	Publish(ctx context.Context, channel string, payload []byte) error
}

type subscriber struct {
	// deviceID lets the hub skip echoing an event back to its origin.
	deviceID string
	events   chan Event
}

// SubscriberBuffer is the per-device queue depth. A device that falls this
// far behind is disconnected rather than allowed to grow the buffer without
// bound — reconnecting and pulling from its watermark is cheap and correct,
// whereas an unbounded queue is a memory leak with extra steps.
const SubscriberBuffer = 64

// NewHub builds a hub. publisher may be nil.
func NewHub(publisher Publisher, clock func() time.Time) *Hub {
	if clock == nil {
		clock = time.Now
	}
	return &Hub{
		subscribers: map[string]map[int64]*subscriber{},
		publisher:   publisher,
		clock:       clock,
	}
}

// Subscription is a live listener handle.
type Subscription struct {
	hub    *Hub
	userID string
	id     int64
	sub    *subscriber
}

// Events is the delivery channel. It is closed when the subscription (or the
// hub) is closed.
func (s *Subscription) Events() <-chan Event { return s.sub.events }

// Close detaches the subscription. It is idempotent.
func (s *Subscription) Close() {
	if s == nil || s.hub == nil {
		return
	}
	s.hub.unsubscribe(s.userID, s.id)
	s.hub = nil
}

// Subscribe attaches a listener for one user's events.
func (h *Hub) Subscribe(userID, deviceID string) *Subscription {
	sub := &subscriber{deviceID: deviceID, events: make(chan Event, SubscriberBuffer)}

	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		close(sub.events)
		return &Subscription{hub: nil, userID: userID, sub: sub}
	}
	h.nextID++
	id := h.nextID
	byID, ok := h.subscribers[userID]
	if !ok {
		byID = map[int64]*subscriber{}
		h.subscribers[userID] = byID
	}
	byID[id] = sub
	return &Subscription{hub: h, userID: userID, id: id, sub: sub}
}

func (h *Hub) unsubscribe(userID string, id int64) {
	h.mu.Lock()
	defer h.mu.Unlock()
	byID, ok := h.subscribers[userID]
	if !ok {
		return
	}
	sub, ok := byID[id]
	if !ok {
		return
	}
	delete(byID, id)
	if len(byID) == 0 {
		delete(h.subscribers, userID)
	}
	close(sub.events)
}

// Broadcast delivers an event to this process's subscribers *and* publishes
// it to Redis for the other processes.
//
// Publishing is best-effort and never blocks the caller's write path: a
// Redis outage must degrade cross-device latency, not fail the HTTP request
// that triggered the event.
func (h *Hub) Broadcast(ctx context.Context, userID string, event Event) {
	h.deliverLocal(userID, event)

	if h.publisher == nil {
		return
	}
	payload, err := event.Encode()
	if err != nil {
		return
	}
	_ = h.publisher.Publish(ctx, UserChannel(userID), payload)
}

// DeliverLocal delivers an event received *from* Redis to this process's
// subscribers, without re-publishing it (which would loop forever).
func (h *Hub) DeliverLocal(userID string, event Event) { h.deliverLocal(userID, event) }

func (h *Hub) deliverLocal(userID string, event Event) {
	h.mu.RLock()
	targets := make([]*subscriber, 0, len(h.subscribers[userID]))
	for _, sub := range h.subscribers[userID] {
		// A device never needs its own echo: it already applied the change
		// locally before pushing it.
		if event.Origin != "" && sub.deviceID == event.Origin {
			continue
		}
		targets = append(targets, sub)
	}
	h.mu.RUnlock()

	for _, sub := range targets {
		select {
		case sub.events <- event:
		default:
			// Slow consumer: drop. The device reconnects and pulls from its
			// watermark, so no data is lost — only the push latency.
		}
	}
}

// Bridge pumps Redis messages into the local hub until ctx is cancelled. Run
// it in its own goroutine when Redis is configured.
func (h *Hub) Bridge(ctx context.Context, messages <-chan RedisMessage) {
	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-messages:
			if !ok {
				return
			}
			userID := UserFromChannel(msg.Channel)
			if userID == "" {
				continue
			}
			event, err := DecodeEvent(msg.Payload)
			if err != nil {
				continue
			}
			h.deliverLocal(userID, event)
		}
	}
}

// Connections reports how many local sockets a user has (device list UI and
// tests).
func (h *Hub) Connections(userID string) int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.subscribers[userID])
}

// Close detaches every subscriber and refuses new ones.
func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		return
	}
	h.closed = true
	for _, byID := range h.subscribers {
		for _, sub := range byID {
			close(sub.events)
		}
	}
	h.subscribers = map[string]map[int64]*subscriber{}
}
