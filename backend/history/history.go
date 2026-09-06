// Package history implements listening-history aggregation over the sync
// store: the payload shape is the client's HistorySyncPayload (trackKey,
// playCount, skipCount, totalPlayedMs, …).
package history

import (
	"context"
	"errors"
	"sort"
	"strconv"
	"strings"
	"sync"
)

// Entry is one aggregated track statistic.
type Entry struct {
	TrackKey          string  `json:"trackKey"`
	Title             string  `json:"title"`
	Artist            string  `json:"artist"`
	Album             string  `json:"album"`
	PlayCount         int     `json:"playCount"`
	SkipCount         int     `json:"skipCount"`
	TotalPlayedMs     int64   `json:"totalPlayedMs"`
	AverageCompletion float64 `json:"averageCompletion"`
}

// Summary is the aggregate response.
type Summary struct {
	TotalPlays int64   `json:"totalPlays"`
	Tracks     []Entry `json:"tracks"`
}

// Aggregator computes summaries from history-scope records.
type Aggregator struct {
	mu sync.Mutex

	// cache is keyed by userID; invalidated on Invalidate.
	cache map[string]Summary
}

// NewAggregator builds the aggregator.
func NewAggregator() *Aggregator {
	return &Aggregator{cache: map[string]Summary{}}
}

// ErrNoHistory is returned when the user has no history records.
var ErrNoHistory = errors.New("no listening history")

func intField(payload map[string]any, key string) int {
	switch value := payload[key].(type) {
	case float64:
		return int(value)
	case int:
		return value
	case string:
		parsed, err := strconv.Atoi(strings.TrimSpace(value))
		if err != nil {
			return 0
		}
		return parsed
	}
	return 0
}

func floatField(payload map[string]any, key string) float64 {
	switch value := payload[key].(type) {
	case float64:
		return value
	case int:
		return float64(value)
	case string:
		parsed, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
		if err != nil {
			return 0
		}
		return parsed
	}
	return 0
}

func stringField(payload map[string]any, key string) string {
	value, _ := payload[key].(string)
	return value
}

// EntryFromPayload converts one record payload. Returns ok=false for
// records without a usable trackKey.
func EntryFromPayload(payload map[string]any) (Entry, bool) {
	trackKey := strings.TrimSpace(stringField(payload, "trackKey"))
	if trackKey == "" {
		return Entry{}, false
	}
	return Entry{
		TrackKey:          trackKey,
		Title:             stringField(payload, "title"),
		Artist:            stringField(payload, "artist"),
		Album:             stringField(payload, "album"),
		PlayCount:         intField(payload, "playCount"),
		SkipCount:         intField(payload, "skipCount"),
		TotalPlayedMs:     int64(intField(payload, "totalPlayedMs")),
		AverageCompletion: floatField(payload, "averageCompletion"),
	}, true
}

// Summarize aggregates the user's history scope. The puller indirection
// keeps this package decoupled from the store implementation.
func (a *Aggregator) Summarize(
	ctx context.Context,
	userID string,
	pull func(ctx context.Context, userID, scope string, since int64) ([]map[string]any, error),
	limit int,
) (Summary, error) {
	a.mu.Lock()
	cached, ok := a.cache[userID]
	a.mu.Unlock()
	if ok {
		return truncate(cached, limit), nil
	}

	records, err := pull(ctx, userID, "history", 0)
	if err != nil {
		return Summary{}, err
	}
	if len(records) == 0 {
		return Summary{}, ErrNoHistory
	}

	byKey := map[string]Entry{}
	var totalPlays int64
	for _, payload := range records {
		entry, ok := EntryFromPayload(payload)
		if !ok {
			continue
		}
		totalPlays += int64(entry.PlayCount)
		if existing, seen := byKey[entry.TrackKey]; seen {
			// Two devices may contribute parallel entries for one track;
			// sum the counters (the sync layer deduplicates identical
			// records, this merges the remainder deterministically).
			existing.PlayCount += entry.PlayCount
			existing.SkipCount += entry.SkipCount
			existing.TotalPlayedMs += entry.TotalPlayedMs
			if entry.AverageCompletion > existing.AverageCompletion {
				existing.AverageCompletion = entry.AverageCompletion
			}
			byKey[entry.TrackKey] = existing
			continue
		}
		byKey[entry.TrackKey] = entry
	}

	entries := make([]Entry, 0, len(byKey))
	for _, entry := range byKey {
		entries = append(entries, entry)
	}
	sort.Slice(entries, func(i, j int) bool {
		if entries[i].PlayCount != entries[j].PlayCount {
			return entries[i].PlayCount > entries[j].PlayCount
		}
		return entries[i].TrackKey < entries[j].TrackKey
	})
	summary := Summary{TotalPlays: totalPlays, Tracks: entries}

	a.mu.Lock()
	a.cache[userID] = summary
	a.mu.Unlock()
	return truncate(summary, limit), nil
}

// Invalidate drops the cached summary (after a push mutates the scope).
func (a *Aggregator) Invalidate(userID string) {
	a.mu.Lock()
	delete(a.cache, userID)
	a.mu.Unlock()
}

func truncate(summary Summary, limit int) Summary {
	if limit <= 0 || limit >= len(summary.Tracks) {
		return summary
	}
	return Summary{TotalPlays: summary.TotalPlays, Tracks: summary.Tracks[:limit]}
}
