// Package settings implements the settings-scope policy: an allowlist of
// preference keys that are safe to synchronize (nothing account-sensitive,
// nothing device-specific) plus per-record size caps. Records with unknown
// top-level keys are rejected rather than silently rewritten, so a bug on
// one device can never corrupt another device's preferences.
package settings

import (
	"errors"
	"fmt"
	"sort"
	"strings"
)

// MaxPayloadBytes bounds one settings record.
const MaxPayloadBytes = 16 * 1024

// AllowedKeys is the allowlist of synchronizable preference keys. Keep in
// sync with the client's settings sync payloads.
var AllowedKeys = map[string]bool{
	"theme.mode":                  true,
	"theme.useDynamicColor":       true,
	"playback.normalization":      true,
	"playback.gapless":            true,
	"playback.crossfadeSeconds":   true,
	"playback.crossfadeSmart":     true,
	"playback.replayGainMode":     true,
	"playback.loudnessTargetLufs": true,
	"playback.preloadNextTrack":   true,
	"playback.qualityProfile":     true,
	"downloads.quality":           true,
	"downloads.format":            true,
	"downloads.networkPolicy":     true,
	"library.autoScan":            true,
	"lyrics.providerPriority":     true,
	"metadata.providerPriority":   true,
	"streaming.enabled":           true,
	"streaming.cacheStreams":      true,
	"engine.glassUi":              true,
	"audio_engine.settings":       true,
}

// ErrKeyNotAllowed is returned for keys outside the allowlist.
var ErrKeyNotAllowed = errors.New("settings key is not synchronizable")

// ErrPayloadTooLarge is returned when a record exceeds MaxPayloadBytes.
var ErrPayloadTooLarge = errors.New("settings record too large")

// ErrNotAnObject is returned for non-object payloads.
var ErrNotAnObject = errors.New("settings payload must be an object")

// Record is one whitelisted settings entry.
type Record struct {
	Key   string `json:"key"`
	Value any    `json:"value"`
}

// Validate checks a payload shaped like {"key": "theme.mode", "value": …}
// (the client's settings sync record) or a flat {"theme.mode": value} map.
func Validate(payload map[string]any) ([]Record, error) {
	if payload == nil {
		return nil, ErrNotAnObject
	}
	if encoded, err := estimateSize(payload); err == nil && encoded > MaxPayloadBytes {
		return nil, ErrPayloadTooLarge
	}
	var out []Record
	if rawKey, ok := payload["key"].(string); ok {
		key := strings.TrimSpace(rawKey)
		if !AllowedKeys[key] {
			return nil, fmt.Errorf("%w: %q", ErrKeyNotAllowed, key)
		}
		out = append(out, Record{Key: key, Value: payload["value"]})
		return out, nil
	}
	for _, key := range sortedKeys(payload) {
		if !AllowedKeys[key] {
			return nil, fmt.Errorf("%w: %q", ErrKeyNotAllowed, key)
		}
		out = append(out, Record{Key: key, Value: payload[key]})
	}
	return out, nil
}

// AllowedKeyList returns the sorted allowlist (for the schema endpoint).
func AllowedKeyList() []string {
	keys := make([]string, 0, len(AllowedKeys))
	for key := range AllowedKeys {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func sortedKeys(payload map[string]any) []string {
	keys := make([]string, 0, len(payload))
	for key := range payload {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// estimateSize approximates the JSON size of a payload without encoding it
// (length of string values + a small per-field constant is enough to catch
// runaway records).
func estimateSize(payload map[string]any) (int, error) {
	total := 2
	for key, value := range payload {
		total += len(key) + 6
		switch typed := value.(type) {
		case string:
			total += len(typed)
		case map[string]any:
			nested, err := estimateSize(typed)
			if err != nil {
				return 0, err
			}
			total += nested
		default:
			total += 16
		}
	}
	return total, nil
}
