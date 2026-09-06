package history

import (
	"context"
	"errors"
	"testing"
)

func fakePull(records ...map[string]any) func(context.Context, string, string, int64) ([]map[string]any, error) {
	return func(context.Context, string, string, int64) ([]map[string]any, error) {
		return records, nil
	}
}

func payload(trackKey string, plays int) map[string]any {
	return map[string]any{
		"trackKey":          trackKey,
		"title":             "Track " + trackKey,
		"playCount":         float64(plays), // JSON numbers decode as float64
		"skipCount":         float64(1),
		"totalPlayedMs":     float64(plays * 1000),
		"averageCompletion": 0.8,
	}
}

func TestEntryFromPayloadCoercions(t *testing.T) {
	entry, ok := EntryFromPayload(payload("t1", 3))
	if !ok {
		t.Fatal("valid payload rejected")
	}
	if entry.PlayCount != 3 || entry.TotalPlayedMs != 3000 || entry.SkipCount != 1 {
		t.Fatalf("coercion wrong: %+v", entry)
	}
	// String numbers are tolerated (defensive), missing trackKey is not.
	if _, ok := EntryFromPayload(map[string]any{"playCount": "5"}); ok {
		t.Fatal("payload without trackKey accepted")
	}
	loose, ok := EntryFromPayload(map[string]any{"trackKey": "t", "playCount": "5"})
	if !ok || loose.PlayCount != 5 {
		t.Fatalf("string count: %+v", loose)
	}
}

func TestSummarizeRanksAndLimits(t *testing.T) {
	agg := NewAggregator()
	summary, err := agg.Summarize(
		context.Background(), "u1",
		fakePull(payload("b", 3), payload("a", 10), payload("c", 3)),
		2,
	)
	if err != nil {
		t.Fatalf("Summarize: %v", err)
	}
	if summary.TotalPlays != 16 {
		t.Fatalf("totalPlays = %d", summary.TotalPlays)
	}
	if len(summary.Tracks) != 2 {
		t.Fatalf("limit not applied: %+v", summary.Tracks)
	}
	if summary.Tracks[0].TrackKey != "a" {
		t.Fatalf("top track = %s", summary.Tracks[0].TrackKey)
	}
	// Tie between b and c is broken deterministically by key.
	if summary.Tracks[1].TrackKey != "b" {
		t.Fatalf("tie-break = %s", summary.Tracks[1].TrackKey)
	}
}

func TestSummarizeMergesDuplicatesAcrossDevices(t *testing.T) {
	agg := NewAggregator()
	summary, err := agg.Summarize(
		context.Background(), "u1",
		fakePull(payload("a", 3), payload("a", 4)),
		0,
	)
	if err != nil {
		t.Fatalf("Summarize: %v", err)
	}
	if len(summary.Tracks) != 1 {
		t.Fatalf("duplicates not merged: %+v", summary.Tracks)
	}
	if summary.Tracks[0].PlayCount != 7 {
		t.Fatalf("playCount merged = %d", summary.Tracks[0].PlayCount)
	}
}

func TestSummarizeCachesAndInvalidates(t *testing.T) {
	agg := NewAggregator()
	calls := 0
	pull := func(context.Context, string, string, int64) ([]map[string]any, error) {
		calls++
		return []map[string]any{payload("a", 1)}, nil
	}
	if _, err := agg.Summarize(context.Background(), "u1", pull, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := agg.Summarize(context.Background(), "u1", pull, 0); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("pull called %d times, cache not used", calls)
	}
	agg.Invalidate("u1")
	if _, err := agg.Summarize(context.Background(), "u1", pull, 0); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("invalidate had no effect (%d calls)", calls)
	}
}

func TestSummarizeEmptyHistory(t *testing.T) {
	agg := NewAggregator()
	if _, err := agg.Summarize(context.Background(), "u1", fakePull(), 0); err != ErrNoHistory {
		t.Fatalf("empty history: got %v", err)
	}
	pullErr := errors.New("boom")
	if _, err := agg.Summarize(context.Background(), "u1",
		func(context.Context, string, string, int64) ([]map[string]any, error) {
			return nil, pullErr
		}, 0); err != pullErr {
		t.Fatalf("pull error not propagated: %v", err)
	}
}
