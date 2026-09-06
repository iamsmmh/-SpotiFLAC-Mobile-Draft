package cloud

import (
	"strings"
	"time"
)

// ContinuityState is the cross-device "resume from the exact timestamp"
// payload (Milestone 1 §3): the user starts a track on Android, opens the
// iPhone, and playback resumes at the same offset.
//
// It is deliberately a *single* row per user rather than a synced record
// scope: continuity is last-writer-wins by construction (there is only one
// pair of ears) and must survive a hand-off that happens in under a second,
// which the revision-based sync loop is too slow for.
type ContinuityState struct {
	UserID     string    `json:"-"`
	DeviceID   string    `json:"deviceId"`
	TrackID    string    `json:"trackId"`
	Title      string    `json:"title"`
	Artist     string    `json:"artist"`
	ArtworkURL string    `json:"artworkUrl"`
	PositionMs int64     `json:"positionMs"`
	DurationMs int64     `json:"durationMs"`
	Playing    bool      `json:"playing"`
	Queue      []string  `json:"queue"`
	QueueIndex int       `json:"queueIndex"`
	UpdatedAt  time.Time `json:"updatedAt"`
}

// MaxContinuityQueue bounds the hand-off payload. A queue longer than this
// is truncated around the current index rather than rejected: resuming with
// a partial queue is strictly better than not resuming.
const MaxContinuityQueue = 500

// Normalize clamps and trims the state so a hostile or buggy client cannot
// store unbounded data, and so the resume position is always inside the
// track. It returns the sanitized copy.
func (c ContinuityState) Normalize(now time.Time) ContinuityState {
	out := c
	out.DeviceID = strings.TrimSpace(out.DeviceID)
	out.TrackID = strings.TrimSpace(out.TrackID)
	out.Title = truncate(strings.TrimSpace(out.Title), 512)
	out.Artist = truncate(strings.TrimSpace(out.Artist), 512)
	out.ArtworkURL = truncate(strings.TrimSpace(out.ArtworkURL), 2048)

	if out.PositionMs < 0 {
		out.PositionMs = 0
	}
	if out.DurationMs < 0 {
		out.DurationMs = 0
	}
	// A position past the end means the client reported a stale duration;
	// clamping is safer than resuming past the end (which would look like
	// an instant skip on the receiving device).
	if out.DurationMs > 0 && out.PositionMs > out.DurationMs {
		out.PositionMs = out.DurationMs
	}

	out.Queue = clampQueue(out.Queue, &out.QueueIndex)

	if out.UpdatedAt.IsZero() {
		out.UpdatedAt = now
	}
	out.UpdatedAt = out.UpdatedAt.UTC()
	return out
}

// clampQueue truncates the queue to MaxContinuityQueue entries centred on
// the current index, adjusting the index to stay pointing at the same item.
func clampQueue(queue []string, index *int) []string {
	if *index < 0 {
		*index = 0
	}
	if len(queue) == 0 {
		*index = 0
		return nil
	}
	if *index >= len(queue) {
		*index = len(queue) - 1
	}
	if len(queue) <= MaxContinuityQueue {
		return queue
	}
	// Keep a window around the current item so both "what's playing" and
	// "what's next" survive the truncation.
	start := *index - MaxContinuityQueue/4
	if start < 0 {
		start = 0
	}
	if start+MaxContinuityQueue > len(queue) {
		start = len(queue) - MaxContinuityQueue
	}
	*index -= start
	return queue[start : start+MaxContinuityQueue]
}

// Fresher reports whether c should replace other. Continuity is
// last-write-wins on UpdatedAt; a tie is broken toward the *other* state so
// a retried identical write is a no-op rather than a spurious event.
func (c ContinuityState) Fresher(other ContinuityState) bool {
	return c.UpdatedAt.After(other.UpdatedAt)
}

// ResumePosition returns the offset a receiving device should seek to.
//
// When the writing device was still playing, the elapsed wall-clock time
// since the snapshot is added: without that correction a hand-off always
// resumes a few seconds in the past, which is exactly the artefact users
// notice. The result is clamped to the track duration.
func (c ContinuityState) ResumePosition(now time.Time) time.Duration {
	position := time.Duration(c.PositionMs) * time.Millisecond
	if c.Playing && !c.UpdatedAt.IsZero() {
		if elapsed := now.Sub(c.UpdatedAt); elapsed > 0 {
			position += elapsed
		}
	}
	if position < 0 {
		position = 0
	}
	if c.DurationMs > 0 {
		if max := time.Duration(c.DurationMs) * time.Millisecond; position > max {
			position = max
		}
	}
	return position
}

func truncate(value string, limit int) string {
	if len(value) <= limit {
		return value
	}
	// Trim on a rune boundary so the stored string stays valid UTF-8.
	cut := value[:limit]
	for len(cut) > 0 && !utf8Start(cut[len(cut)-1]) {
		cut = cut[:len(cut)-1]
	}
	return cut
}

// utf8Start reports whether b can begin a UTF-8 sequence (i.e. is not a
// continuation byte 10xxxxxx).
func utf8Start(b byte) bool { return b&0xC0 != 0x80 }
