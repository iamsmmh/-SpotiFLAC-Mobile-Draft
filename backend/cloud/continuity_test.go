package cloud

import (
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

var testNow = time.Date(2026, 9, 7, 12, 0, 0, 0, time.UTC)

func TestContinuityNormalizeClampsPosition(t *testing.T) {
	state := ContinuityState{
		PositionMs: 500_000,
		DurationMs: 200_000,
	}.Normalize(testNow)

	if state.PositionMs != 200_000 {
		t.Fatalf("position was not clamped to the duration: %d", state.PositionMs)
	}
}

func TestContinuityNormalizeRejectsNegatives(t *testing.T) {
	state := ContinuityState{PositionMs: -5, DurationMs: -9, QueueIndex: -3}.Normalize(testNow)
	if state.PositionMs != 0 || state.DurationMs != 0 || state.QueueIndex != 0 {
		t.Fatalf("negatives survived normalization: %+v", state)
	}
}

func TestContinuityNormalizeStampsTime(t *testing.T) {
	state := ContinuityState{}.Normalize(testNow)
	if !state.UpdatedAt.Equal(testNow) {
		t.Fatalf("expected the clock value, got %s", state.UpdatedAt)
	}
}

func TestContinuityNormalizeTruncatesStrings(t *testing.T) {
	state := ContinuityState{Title: strings.Repeat("a", 5000)}.Normalize(testNow)
	if len(state.Title) > 512 {
		t.Fatalf("title was not truncated: %d", len(state.Title))
	}
}

func TestContinuityTruncationKeepsValidUTF8(t *testing.T) {
	// "あ" is 3 bytes and the 512-byte cap is not a multiple of 3, so a
	// naive cut lands mid-rune.
	state := ContinuityState{Title: strings.Repeat("あ", 400)}.Normalize(testNow)
	if !utf8.ValidString(state.Title) {
		t.Fatalf("truncation produced invalid UTF-8: %q", state.Title)
	}
	if len(state.Title) > 512 {
		t.Fatalf("title exceeded the cap: %d bytes", len(state.Title))
	}
}

func TestContinuityQueueTruncationKeepsCurrentItem(t *testing.T) {
	queue := make([]string, 2000)
	for i := range queue {
		queue[i] = "track-" + string(rune('a'+i%26)) + itoa(i)
	}
	const index = 1500
	state := ContinuityState{Queue: queue, QueueIndex: index}.Normalize(testNow)

	if len(state.Queue) != MaxContinuityQueue {
		t.Fatalf("queue not clamped: %d", len(state.Queue))
	}
	if state.QueueIndex < 0 || state.QueueIndex >= len(state.Queue) {
		t.Fatalf("index out of range after truncation: %d", state.QueueIndex)
	}
	// The whole point: the item that was playing must still be the item the
	// adjusted index points at.
	if state.Queue[state.QueueIndex] != queue[index] {
		t.Fatalf("truncation lost the current item: %q vs %q",
			state.Queue[state.QueueIndex], queue[index])
	}
}

func TestContinuityQueueIndexPastEndIsClamped(t *testing.T) {
	state := ContinuityState{Queue: []string{"a", "b"}, QueueIndex: 99}.Normalize(testNow)
	if state.QueueIndex != 1 {
		t.Fatalf("expected the last index, got %d", state.QueueIndex)
	}
}

func TestResumePositionAdvancesWhilePlaying(t *testing.T) {
	state := ContinuityState{
		PositionMs: 30_000,
		DurationMs: 300_000,
		Playing:    true,
		UpdatedAt:  testNow,
	}
	// Ten seconds after the snapshot the listener expects to be ten seconds
	// further in, not back where they left off.
	got := state.ResumePosition(testNow.Add(10 * time.Second))
	if want := 40 * time.Second; got != want {
		t.Fatalf("resume position = %s, want %s", got, want)
	}
}

func TestResumePositionFrozenWhilePaused(t *testing.T) {
	state := ContinuityState{
		PositionMs: 30_000,
		DurationMs: 300_000,
		Playing:    false,
		UpdatedAt:  testNow,
	}
	got := state.ResumePosition(testNow.Add(time.Hour))
	if want := 30 * time.Second; got != want {
		t.Fatalf("paused state drifted: %s, want %s", got, want)
	}
}

func TestResumePositionClampsToDuration(t *testing.T) {
	state := ContinuityState{
		PositionMs: 290_000,
		DurationMs: 300_000,
		Playing:    true,
		UpdatedAt:  testNow,
	}
	// The device was offline for an hour; resuming must land at the end of
	// the track, not an hour past it.
	got := state.ResumePosition(testNow.Add(time.Hour))
	if want := 300 * time.Second; got != want {
		t.Fatalf("resume overshot the track: %s, want %s", got, want)
	}
}

func TestResumePositionHandlesClockSkew(t *testing.T) {
	state := ContinuityState{PositionMs: 5_000, Playing: true, UpdatedAt: testNow}
	// A receiver whose clock is behind the writer's must not rewind.
	got := state.ResumePosition(testNow.Add(-time.Minute))
	if want := 5 * time.Second; got != want {
		t.Fatalf("negative elapsed time changed the position: %s, want %s", got, want)
	}
}

func TestContinuityFresher(t *testing.T) {
	older := ContinuityState{UpdatedAt: testNow}
	newer := ContinuityState{UpdatedAt: testNow.Add(time.Second)}

	if !newer.Fresher(older) {
		t.Fatal("newer state should win")
	}
	if older.Fresher(newer) {
		t.Fatal("older state must not win")
	}
	// A retried identical write must be a no-op, not a spurious event.
	if older.Fresher(older) {
		t.Fatal("a tie must not count as fresher")
	}
}

// itoa avoids importing strconv for the test fixture above.
func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	var digits []byte
	for value > 0 {
		digits = append([]byte{byte('0' + value%10)}, digits...)
		value /= 10
	}
	return string(digits)
}
