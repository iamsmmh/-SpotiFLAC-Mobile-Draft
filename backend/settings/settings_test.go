package settings

import (
	"errors"
	"strings"
	"testing"
)

func TestValidateKeyValueForm(t *testing.T) {
	records, err := Validate(map[string]any{"key": "theme.mode", "value": "dark"})
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if len(records) != 1 || records[0].Key != "theme.mode" {
		t.Fatalf("records: %+v", records)
	}
	if records[0].Value != "dark" {
		t.Fatalf("value: %v", records[0].Value)
	}
}

func TestValidateFlatForm(t *testing.T) {
	records, err := Validate(map[string]any{
		"theme.mode":                "dark",
		"playback.crossfadeSeconds": float64(6),
	})
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("records: %+v", records)
	}
	if records[0].Key != "playback.crossfadeSeconds" {
		t.Fatalf("sort order: %+v", records)
	}
}

func TestValidateRejectsUnknownKeys(t *testing.T) {
	if _, err := Validate(map[string]any{"secrets.apiToken": "leak"}); !errors.Is(err, ErrKeyNotAllowed) {
		t.Fatalf("unknown key: %v", err)
	}
	if _, err := Validate(map[string]any{"key": "not.in.list", "value": 1}); !errors.Is(err, ErrKeyNotAllowed) {
		t.Fatalf("unknown key (kv form): %v", err)
	}
}

func TestValidateRejectsOversizedPayload(t *testing.T) {
	big := map[string]any{"theme.mode": strings.Repeat("x", MaxPayloadBytes+16)}
	if _, err := Validate(big); !errors.Is(err, ErrPayloadTooLarge) {
		t.Fatalf("oversized: %v", err)
	}
}

func TestAllowedKeyListIsSorted(t *testing.T) {
	keys := AllowedKeyList()
	if len(keys) == 0 {
		t.Fatal("empty allowlist")
	}
	for i := 1; i < len(keys); i++ {
		if keys[i-1] > keys[i] {
			t.Fatalf("not sorted at %d: %q > %q", i, keys[i-1], keys[i])
		}
	}
}
