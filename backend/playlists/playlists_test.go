package playlists

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/zarz/spotiflac_android/backend/sync"
)

func validPayload() map[string]any {
	return map[string]any{
		"playlistId": "pl-1",
		"title":      "Road trip",
		"trackKeys":  []any{"isrc:X", "isrc:Y", " "},
		"isPublic":   true,
	}
}

func TestValidateNormalizes(t *testing.T) {
	payload, err := Validate(validPayload())
	if err != nil {
		t.Fatalf("Validate: %v", err)
	}
	if payload.PlaylistID != "pl-1" || payload.Title != "Road trip" {
		t.Fatalf("fields: %+v", payload)
	}
	// Blank track keys are dropped during normalization.
	if len(payload.TrackKeys) != 2 {
		t.Fatalf("trackKeys: %v", payload.TrackKeys)
	}
}

func TestValidateRejects(t *testing.T) {
	if _, err := Validate(map[string]any{"title": "no id"}); err != ErrPlaylistInvalid {
		t.Fatalf("missing id: %v", err)
	}
	if _, err := Validate(map[string]any{"playlistId": "x"}); err != ErrPlaylistInvalid {
		t.Fatalf("missing title: %v", err)
	}
	big := validPayload()
	big["trackKeys"] = make([]any, MaxTrackKeys+1)
	if _, err := Validate(big); err != ErrPlaylistTooBig {
		t.Fatalf("oversized: %v", err)
	}
	longTitle := validPayload()
	longTitle["title"] = strings.Repeat("x", MaxTitleRunes+1)
	if _, err := Validate(longTitle); err != ErrPlaylistTooBig {
		t.Fatalf("long title: %v", err)
	}
}

func TestNewSlugShape(t *testing.T) {
	slug, err := NewSlug()
	if err != nil {
		t.Fatalf("NewSlug: %v", err)
	}
	if !ValidSlug(slug) {
		t.Fatalf("generated slug invalid: %q", slug)
	}
	if ValidSlug("not-a-slug") || ValidSlug("pl_short") {
		t.Fatal("invalid slugs accepted")
	}
}

func newHarness(t *testing.T) (*sync.Store, *Service) {
	t.Helper()
	store := sync.NewStore(nil)
	return store, NewService(store, nil)
}

func TestPublishResolveUnpublish(t *testing.T) {
	ctx := context.Background()
	store, service := newHarness(t)
	userID := "usr_1"

	if _, err := store.Push(ctx, userID, "playlists", []sync.Record{{
		RecordID:  "pl-1",
		UpdatedAt: time.Now().UTC(),
		Payload:   validPayload(),
	}}); err != nil {
		t.Fatalf("push: %v", err)
	}

	share, err := service.Publish(ctx, userID, "pl-1", validPayload())
	if err != nil {
		t.Fatalf("Publish: %v", err)
	}

	// Re-publishing the same record reuses the slug.
	again, err := service.Publish(ctx, userID, "pl-1", validPayload())
	if err != nil {
		t.Fatalf("re-publish: %v", err)
	}
	if again.Slug != share.Slug {
		t.Fatalf("slug reused: %q vs %q", again.Slug, share.Slug)
	}

	resolved, err := service.Resolve(ctx, share.Slug)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if resolved.Playlist.Title != "Road trip" || !resolved.Playlist.IsPublic {
		t.Fatalf("resolved: %+v", resolved.Playlist)
	}
	if resolved.Views != 1 {
		t.Fatalf("views: %d", resolved.Views)
	}

	if err := service.Unpublish(ctx, userID, share.Slug); err != nil {
		t.Fatalf("Unpublish: %v", err)
	}
	if _, err := service.Resolve(ctx, share.Slug); err == nil {
		t.Fatal("unpublished share still resolves")
	}
}

func TestPublishRejectsPrivatePayload(t *testing.T) {
	_, service := newHarness(t)
	private := validPayload()
	private["isPublic"] = false
	if _, err := service.Publish(context.Background(), "u", "pl-1", private); err != ErrPlaylistInvalid {
		t.Fatalf("private payload: %v", err)
	}
}

func TestResolveValidatesSlugAndMissingRecord(t *testing.T) {
	_, service := newHarness(t)
	if _, err := service.Resolve(context.Background(), "../evil"); err == nil {
		t.Fatal("path traversal slug accepted")
	}
	slug, _ := NewSlug()
	if _, err := service.Resolve(context.Background(), slug); err == nil {
		t.Fatal("unknown share resolved")
	}
}

func TestResolveFailsWhenRecordDeletedOrPrivate(t *testing.T) {
	ctx := context.Background()
	store, service := newHarness(t)
	userID := "usr_1"
	if _, err := store.Push(ctx, userID, "playlists", []sync.Record{{
		RecordID:  "pl-1",
		UpdatedAt: time.Now().UTC(),
		Payload:   validPayload(),
	}}); err != nil {
		t.Fatal(err)
	}
	share, err := service.Publish(ctx, userID, "pl-1", validPayload())
	if err != nil {
		t.Fatal(err)
	}
	// Flip the record private server-side.
	if _, err := store.Push(ctx, userID, "playlists", []sync.Record{{
		RecordID:  "pl-1",
		UpdatedAt: time.Now().UTC().Add(time.Second),
		Payload:   map[string]any{
			"playlistId": "pl-1",
			"title":      "Road trip",
			"trackKeys":  []any{"isrc:X"},
			"isPublic":   false,
		},
	}}); err != nil {
		t.Fatal(err)
	}
	if _, err := service.Resolve(ctx, share.Slug); err == nil {
		t.Fatal("private playlist still shared")
	}
}
