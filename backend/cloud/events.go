package cloud

import (
	"encoding/json"
	"strings"
	"time"
)

// Event kinds pushed to connected devices.
const (
	// EventSync tells a device that a scope advanced; the device then runs
	// its normal incremental pull from its own watermark. The event carries
	// the new watermark so a device already at that revision can skip the
	// round-trip entirely.
	EventSync = "sync"
	// EventContinuity carries a playback hand-off snapshot.
	EventContinuity = "continuity"
	// EventDeviceRevoked tells a device it was logged out remotely.
	EventDeviceRevoked = "device.revoked"
	// EventDevices tells devices the device list changed.
	EventDevices = "devices"
	// EventPlaylist signals a collaborative playlist change.
	EventPlaylist = "playlist"
	// EventPing is the server keepalive.
	EventPing = "ping"
)

// Event is the envelope every WebSocket frame carries.
type Event struct {
	Kind string `json:"kind"`
	// Scope is set for EventSync.
	Scope string `json:"scope,omitempty"`
	// Revision is the scope watermark for EventSync.
	Revision int64 `json:"revision,omitempty"`
	// Origin is the device that caused the event, so the sender can ignore
	// its own echo instead of re-pulling what it just pushed.
	Origin string `json:"origin,omitempty"`
	// Payload carries kind-specific data (continuity snapshots, playlist
	// deltas). Kept as raw JSON so the hub never re-encodes it.
	Payload json.RawMessage `json:"payload,omitempty"`
	At      time.Time       `json:"at"`
}

// NewSyncEvent builds a scope-advanced notification.
func NewSyncEvent(scope string, revision int64, origin string, at time.Time) Event {
	return Event{
		Kind:     EventSync,
		Scope:    scope,
		Revision: revision,
		Origin:   origin,
		At:       at.UTC(),
	}
}

// NewContinuityEvent builds a playback hand-off notification. A marshalling
// failure yields an event with no payload rather than an error: the
// receiving device falls back to GET /v1/cloud/continuity, so a degraded
// event is still useful and must never break the fan-out.
func NewContinuityEvent(state ContinuityState, at time.Time) Event {
	payload, err := json.Marshal(state)
	if err != nil {
		payload = nil
	}
	return Event{
		Kind:    EventContinuity,
		Origin:  state.DeviceID,
		Payload: payload,
		At:      at.UTC(),
	}
}

// NewDeviceEvent builds a device-list or revocation notification.
func NewDeviceEvent(kind, deviceID string, at time.Time) Event {
	return Event{Kind: kind, Origin: deviceID, At: at.UTC()}
}

// Encode serializes the event for the wire.
func (e Event) Encode() ([]byte, error) { return json.Marshal(e) }

// DecodeEvent parses a wire frame.
func DecodeEvent(raw []byte) (Event, error) {
	var event Event
	err := json.Unmarshal(raw, &event)
	return event, err
}

// ---------------------------------------------------------------------------
// Redis channel naming
// ---------------------------------------------------------------------------

// channelPrefix namespaces the pub/sub keyspace so a shared Redis can host
// other tenants.
const channelPrefix = "spotiflac:events:"

// UserChannel is the Redis pub/sub channel carrying one user's events.
func UserChannel(userID string) string { return channelPrefix + userID }

// UserFromChannel is the inverse of UserChannel; it returns "" for channels
// outside the namespace.
func UserFromChannel(channel string) string {
	if !strings.HasPrefix(channel, channelPrefix) {
		return ""
	}
	return strings.TrimPrefix(channel, channelPrefix)
}
