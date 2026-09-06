package sync

import (
	"context"
	"testing"
	"time"
)

func fixedTime(t *testing.T) time.Time {
	parsed, err := time.Parse(time.RFC3339, "2026-09-06T12:00:00Z")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	return parsed
}

func record(id string, at time.Time, revision int64, deleted bool) Record {
	return Record{
		Scope:     "favorites",
		RecordID:  id,
		Revision:  revision,
		UpdatedAt: at,
		Deleted:   deleted,
		Payload:   map[string]any{"k": id},
	}
}

func TestPushAssignsMonotonicRevisions(t *testing.T) {
	store := NewStore(nil)
	ctx := context.Background()
	base := fixedTime(t)

	results, err := store.Push(ctx, "u1", "favorites", []Record{
		record("isrc:A", base, 1, false),
		record("isrc:B", base, 1, false),
	})
	if err != nil {
		t.Fatalf("Push: %v", err)
	}
	if !results["isrc:A"].Accepted || results["isrc:A"].Revision != 1 {
		t.Fatalf("A: %+v", results["isrc:A"])
	}
	if results["isrc:B"].Revision != 2 {
		t.Fatalf("B: %+v", results["isrc:B"])
	}

	// Idempotent re-push of the same record: rejected as identical, the
	// server revision is returned so the client ack stays correct.
	results, err = store.Push(ctx, "u1", "favorites", []Record{record("isrc:A", base, 1, false)})
	if err != nil {
		t.Fatalf("re-push: %v", err)
	}
	if results["isrc:A"].Accepted {
		t.Fatal("identical re-push accepted")
	}
	if results["isrc:A"].Revision != 1 {
		t.Fatalf("re-push revision: %+v", results["isrc:A"])
	}
	if store.Watermark(ctx, "u1", "favorites") != 2 {
		t.Fatalf("watermark moved on rejected push: %d", store.Watermark(ctx, "u1", "favorites"))
	}
}

func TestConflictRule(t *testing.T) {
	store := NewStore(nil)
	ctx := context.Background()
	base := fixedTime(t)
	later := base.Add(time.Minute)

	// Newer update wins.
	if _, err := store.Push(ctx, "u1", "favorites", []Record{record("t", base, 1, false)}); err != nil {
		t.Fatal(err)
	}
	results, _ := store.Push(ctx, "u1", "favorites", []Record{record("t", later, 1, false)})
	if !results["t"].Accepted {
		t.Fatal("newer update rejected")
	}

	// Older update loses.
	results, _ = store.Push(ctx, "u1", "favorites", []Record{record("t", base, 9, false)})
	if results["t"].Accepted {
		t.Fatal("older update accepted")
	}

	// Equal timestamps: higher client revision wins.
	results, _ = store.Push(ctx, "u1", "favorites", []Record{record("t", later, 5, false)})
	if !results["t"].Accepted {
		t.Fatal("equal-ts higher revision rejected")
	}
	results, _ = store.Push(ctx, "u1", "favorites", []Record{record("t", later, 5, false)})
	if results["t"].Accepted {
		t.Fatal("equal-ts equal revision accepted")
	}
}

func TestTombstoneRules(t *testing.T) {
	store := NewStore(nil)
	ctx := context.Background()
	base := fixedTime(t)
	later := base.Add(time.Second)

	// Live record first.
	if _, err := store.Push(ctx, "u1", "playlists", []Record{record("p1", base, 1, false)}); err != nil {
		t.Fatal(err)
	}
	// Equal-timestamp tombstone beats the live record (rule 1).
	results, _ := store.Push(ctx, "u1", "playlists", []Record{record("p1", base, 2, true)})
	if !results["p1"].Accepted {
		t.Fatal("equal-ts tombstone rejected")
	}
	// A live update at the same ts must NOT resurrect the tombstone.
	results, _ = store.Push(ctx, "u1", "playlists", []Record{record("p1", base, 3, false)})
	if results["p1"].Accepted {
		t.Fatal("live record resurrected a tombstone at equal ts")
	}
	// A strictly newer live update does resurrect.
	results, _ = store.Push(ctx, "u1", "playlists", []Record{record("p1", later, 4, false)})
	if !results["p1"].Accepted {
		t.Fatal("newer live update could not beat an older tombstone")
	}
	// Newer tombstone wins again.
	results, _ = store.Push(ctx, "u1", "playlists", []Record{record("p1", later.Add(time.Second), 1, true)})
	if !results["p1"].Accepted {
		t.Fatal("newer tombstone rejected")
	}
}

func TestPullIncremental(t *testing.T) {
	store := NewStore(nil)
	ctx := context.Background()
	base := fixedTime(t)

	if _, err := store.Push(ctx, "u1", "history", []Record{
		record("h1", base, 1, false),
		record("h2", base, 2, false),
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.Push(ctx, "u1", "history", []Record{record("h3", base, 3, false)}); err != nil {
		t.Fatal(err)
	}

	full, err := store.Pull(ctx, "u1", "history", 0)
	if err != nil {
		t.Fatalf("Pull: %v", err)
	}
	if len(full) != 3 || full[0].RecordID != "h1" || full[2].RecordID != "h3" {
		t.Fatalf("full pull wrong: %+v", full)
	}
	delta, err := store.Pull(ctx, "u1", "history", 2)
	if err != nil {
		t.Fatalf("delta pull: %v", err)
	}
	if len(delta) != 1 || delta[0].RecordID != "h3" {
		t.Fatalf("delta pull wrong: %+v", delta)
	}

	// Other users are isolated.
	other, _ := store.Pull(ctx, "u2", "history", 0)
	if len(other) != 0 {
		t.Fatalf("user isolation broken: %+v", other)
	}
}

func TestPushValidation(t *testing.T) {
	store := NewStore(nil)
	ctx := context.Background()
	base := fixedTime(t)

	if _, err := store.Push(ctx, "u1", "not-a-scope", nil); err != ErrScopeUnknown {
		t.Fatalf("unknown scope: got %v", err)
	}
	if _, err := store.Push(ctx, "u1", "settings", []Record{{UpdatedAt: base}}); err != ErrRecordInvalid {
		t.Fatalf("empty record id: got %v", err)
	}
	// Zero updatedAt is stamped by the server.
	results, err := store.Push(ctx, "u1", "settings", []Record{{RecordID: "s1"}})
	if err != nil {
		t.Fatalf("server-stamped push: %v", err)
	}
	if !results["s1"].Accepted {
		t.Fatal("server-stamped push rejected")
	}
	pulled, _ := store.Pull(ctx, "u1", "settings", 0)
	if pulled[0].UpdatedAt.IsZero() {
		t.Fatal("server did not stamp updatedAt")
	}
}
