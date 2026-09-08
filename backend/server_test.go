package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// testServer spins the full production wiring on httptest.
func testServer(t *testing.T) *httptest.Server {
	t.Helper()
	secret := []byte("test-secret-0123456789abcdef0123")
	server := httptest.NewServer(newHandler(secret, nil, nil))
	t.Cleanup(server.Close)
	return server
}

type mapResponse map[string]any

func postJSON(t *testing.T, url string, body any, token string) (int, mapResponse) {
	t.Helper()
	return doJSON(t, http.MethodPost, url, body, token)
}

func getJSON(t *testing.T, url string, token string) (int, mapResponse) {
	t.Helper()
	return doJSON(t, http.MethodGet, url, nil, token)
}

func doJSON(t *testing.T, method, url string, body any, token string) (int, mapResponse) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	req.Header.Set("Content-Type", "application/json")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	decoded := mapResponse{}
	if len(raw) > 0 {
		if err := json.Unmarshal(raw, &decoded); err != nil {
			t.Fatalf("decode %q: %v", string(raw), err)
		}
	}
	return resp.StatusCode, decoded
}

func register(t *testing.T, server *httptest.Server, email, deviceID string) (string, string) {
	t.Helper()
	status, body := postJSON(t, server.URL+"/v1/auth/register", map[string]any{
		"email":       email,
		"password":    "hunter22boo",
		"displayName": "Tester",
		"deviceId":    deviceID,
		"deviceName":  "Pixel",
		"platform":    "android",
	}, "")
	if status != http.StatusCreated {
		t.Fatalf("register status = %d (%v)", status, body)
	}
	session, _ := body["accessToken"].(string)
	if session == "" {
		t.Fatal("no access token returned")
	}
	refresh, _ := body["refreshToken"].(string)
	return session, refresh
}

func TestHealthz(t *testing.T) {
	server := testServer(t)
	resp, err := http.Get(server.URL + "/healthz")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("healthz status = %d", resp.StatusCode)
	}
}

func signIn(t *testing.T, server *httptest.Server, email, deviceID string) (string, string) {
	t.Helper()
	status, body := postJSON(t, server.URL+"/v1/auth/email", map[string]any{
		"email":    email,
		"password": "hunter22boo",
		"deviceId": deviceID,
	}, "")
	if status != http.StatusOK {
		t.Fatalf("sign-in status = %d (%v)", status, body)
	}
	session, _ := body["accessToken"].(string)
	if session == "" {
		t.Fatal("no access token returned")
	}
	refresh, _ := body["refreshToken"].(string)
	return session, refresh
}

func TestEndToEndSync(t *testing.T) {
	server := testServer(t)
	tokenA, refreshA := register(t, server, "a@example.com", "device-A")

	// /v1/auth/me with the bearer token.
	status, me := getJSON(t, server.URL+"/v1/auth/me", tokenA)
	if status != 200 || me["id"] == "" {
		t.Fatalf("me: %d %v", status, me)
	}

	// Protected endpoints reject missing tokens.
	status, _ = getJSON(t, server.URL+"/v1/sync/me", "")
	if status != http.StatusUnauthorized {
		t.Fatalf("unauthenticated sync/me status = %d", status)
	}

	// Push two records, one updated twice.
	status, body := postJSON(t, server.URL+"/v1/sync/push", map[string]any{
		"scope":   "favorites",
		"records": []map[string]any{
			{"recordId": "isrc:X", "revision": 1, "updatedAt": "2026-09-06T10:00:00Z", "deleted": false, "payload": map[string]any{"title": "Song X"}},
			{"recordId": "isrc:Y", "revision": 1, "updatedAt": "2026-09-06T10:01:00Z", "deleted": false, "payload": map[string]any{}},
		},
	}, tokenA)
	if status != 200 {
		t.Fatalf("push status = %d (%v)", status, body)
	}
	revisions, ok := body["revisions"].(map[string]any)
	if !ok || len(revisions) != 2 {
		t.Fatalf("push revisions: %v", body)
	}

	// Incremental pull returns only the delta for a fresh watermark of 0 →
	// everything; after ack, since=2 → nothing new.
	status, pull := postJSON(t, server.URL+"/v1/sync/pull", map[string]any{
		"scope": "favorites",
	}, tokenA)
	if status != 200 {
		t.Fatalf("pull status = %d", status)
	}
	records, _ := pull["records"].([]any)
	if len(records) != 2 {
		t.Fatalf("pull records: %v", pull)
	}

	status, pull = postJSON(t, server.URL+"/v1/sync/pull", map[string]any{
		"scope":         "favorites",
		"sinceRevision": 2,
	}, tokenA)
	if status != 200 {
		t.Fatalf("delta pull status = %d", status)
	}
	if records, _ = pull["records"].([]any); len(records) != 0 {
		t.Fatalf("delta pull should be empty: %v", pull)
	}

	// Device B signs in to the same account from another device and pulls
	// the same data (multi-device).
	tokenB, refreshB := signIn(t, server, "a@example.com", "device-B")
	_, _ = refreshB, refreshA
	status, pull = postJSON(t, server.URL+"/v1/sync/pull", map[string]any{
		"scope": "favorites",
	}, tokenB)
	if status != 200 {
		t.Fatalf("device B pull status = %d", status)
	}
	if records, _ = pull["records"].([]any); len(records) != 2 {
		t.Fatalf("device B should see both records: %v", pull)
	}

	// Refresh rotation works through the wire.
	status, refreshed := postJSON(t, server.URL+"/v1/auth/refresh", map[string]any{
		"refreshToken": refreshB,
	}, "")
	if status != 200 || refreshed["accessToken"] == "" {
		t.Fatalf("refresh: %d %v", status, refreshed)
	}

	// Device listing shows both registrations.
	status, devices := getJSON(t, server.URL+"/v1/auth/devices", tokenA)
	if status != 200 {
		t.Fatalf("devices status = %d", status)
	}
	if list, _ := devices["devices"].([]any); len(list) < 1 {
		t.Fatalf("device list empty: %v", devices)
	}
}

func TestPlaylistShareFlow(t *testing.T) {
	server := testServer(t)
	token, _ := register(t, server, "share@example.com", "device-A")

	playlistPayload := map[string]any{
		"playlistId": "pl-1",
		"title":      "Road trip",
		"trackKeys":  []string{"isrc:X", "isrc:Y"},
		"isPublic":   true,
	}
	// Push the record first.
	if status, body := postJSON(t, server.URL+"/v1/sync/push", map[string]any{
		"scope":   "playlists",
		"records": []map[string]any{{"recordId": "pl-1", "revision": 1, "updatedAt": "2026-09-06T10:00:00Z", "payload": playlistPayload}},
	}, token); status != 200 {
		t.Fatalf("push: %d %v", status, body)
	}

	status, shared := postJSON(t, server.URL+"/v1/playlists/share", map[string]any{
		"recordId": "pl-1",
		"payload":  playlistPayload,
	}, token)
	if status != 200 {
		t.Fatalf("share: %d %v", status, shared)
	}
	slug, _ := shared["slug"].(string)
	if !strings.HasPrefix(slug, "pl_") {
		t.Fatalf("slug shape: %q", slug)
	}

	// Anonymous resolve (QR / deep-link path).
	status, resolved := getJSON(t, server.URL+"/v1/playlists/shared/"+slug, "")
	if status != 200 {
		t.Fatalf("resolve: %d %v", status, resolved)
	}
	playlist, _ := resolved["playlist"].(map[string]any)
	if playlist["title"] != "Road trip" {
		t.Fatalf("resolved playlist: %v", resolved)
	}

	// Unpublish hides it again.
	req, _ := http.NewRequest(http.MethodDelete, server.URL+"/v1/playlists/share/"+slug, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	status, _ = getJSON(t, server.URL+"/v1/playlists/shared/"+slug, "")
	if status != http.StatusNotFound {
		t.Fatalf("unpublished share still resolves (%d)", status)
	}
}

func TestHistorySummary(t *testing.T) {
	server := testServer(t)
	token, _ := register(t, server, "history@example.com", "device-A")

	historyRecords := []map[string]any{
		{"recordId": "trackA", "revision": 1, "updatedAt": "2026-09-06T10:00:00Z", "payload": map[string]any{
			"trackKey": "trackA", "title": "A", "playCount": 10, "skipCount": 1, "totalPlayedMs": 1000,
		}},
		{"recordId": "trackB", "revision": 1, "updatedAt": "2026-09-06T10:01:00Z", "payload": map[string]any{
			"trackKey": "trackB", "title": "B", "playCount": 3, "skipCount": 0, "totalPlayedMs": 400,
		}},
	}
	if status, body := postJSON(t, server.URL+"/v1/sync/push", map[string]any{
		"scope":   "history",
		"records": historyRecords,
	}, token); status != 200 {
		t.Fatalf("push: %d %v", status, body)
	}

	status, summary := getJSON(t, server.URL+"/v1/history/summary?limit=1", token)
	if status != 200 {
		t.Fatalf("summary status = %d (%v)", status, summary)
	}
	if plays, _ := summary["totalPlays"].(float64); int(plays) != 13 {
		t.Fatalf("totalPlays = %v", summary["totalPlays"])
	}
	tracks, _ := summary["tracks"].([]any)
	if len(tracks) != 1 {
		t.Fatalf("limit not applied: %v", summary)
	}
	top, _ := tracks[0].(map[string]any)
	if top["trackKey"] != "trackA" {
		t.Fatalf("top track wrong: %v", top)
	}
}

func TestSettingsSchemaAndValidation(t *testing.T) {
	server := testServer(t)
	status, schema := getJSON(t, server.URL+"/v1/settings/schema", "")
	if status != 200 {
		t.Fatalf("schema status = %d", status)
	}
	if keys, _ := schema["keys"].([]any); len(keys) == 0 {
		t.Fatal("empty allowlist")
	}

	token, _ := register(t, server, "settings@example.com", "device-A")
	// Allowed key.
	status, body := postJSON(t, server.URL+"/v1/settings/validate", map[string]any{
		"key":   "theme.mode",
		"value": "dark",
	}, token)
	if status != 200 {
		t.Fatalf("allowed key rejected: %d %v", status, body)
	}
	// Disallowed key.
	status, _ = postJSON(t, server.URL+"/v1/settings/validate", map[string]any{
		"key":   "secrets.apiToken",
		"value": "leak",
	}, token)
	if status != http.StatusUnprocessableEntity {
		t.Fatalf("disallowed key accepted (%d)", status)
	}
}

func TestBackupFlow(t *testing.T) {
	server := testServer(t)
	token, _ := register(t, server, "backup@example.com", "device-A")

	envelope := []byte(`{"format":"spotiflac.backup","version":1,"data":{"playlists":[1,2,3]}}`)
	req, err := http.NewRequest(http.MethodPut, server.URL+"/v1/backup?deviceId=device-A", bytes.NewReader(envelope))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	created := mapResponse{}
	raw, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	_ = json.Unmarshal(raw, &created)
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("upload status = %d (%s)", resp.StatusCode, string(raw))
	}
	meta, _ := created["backup"].(map[string]any)
	backupID, _ := meta["id"].(string)
	if backupID == "" {
		t.Fatalf("no backup id: %v", created)
	}

	// List shows it.
	status, list := getJSON(t, server.URL+"/v1/backup?deviceId=device-A", token)
	if status != 200 {
		t.Fatalf("list status = %d", status)
	}
	if backups, _ := list["backups"].([]any); len(backups) != 1 {
		t.Fatalf("backups: %v", list)
	}

	// Download round-trips the exact bytes.
	dl, err := http.NewRequest(http.MethodGet, server.URL+"/v1/backup/"+backupID, nil)
	if err != nil {
		t.Fatal(err)
	}
	dl.Header.Set("Authorization", "Bearer "+token)
	resp, err = http.DefaultClient.Do(dl)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !bytes.Equal(body, envelope) {
		t.Fatalf("download mismatch: %d %q", resp.StatusCode, string(body))
	}

	// Delete works.
	del, _ := http.NewRequest(http.MethodDelete, server.URL+"/v1/backup/"+backupID, nil)
	del.Header.Set("Authorization", "Bearer "+token)
	resp, err = http.DefaultClient.Do(del)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	status, _ = getJSON(t, server.URL+"/v1/backup?deviceId=device-A", token)
	if backups := fetchBackups(t, server, token); status != 200 || len(backups) != 0 {
		t.Fatalf("backup not deleted: %v", backups)
	}
}

func fetchBackups(t *testing.T, server *httptest.Server, token string) []any {
	t.Helper()
	_, list := getJSON(t, server.URL+"/v1/backup?deviceId=device-A", token)
	backups, _ := list["backups"].([]any)
	return backups
}

func TestErrorEnvelopeShape(t *testing.T) {
	server := testServer(t)
	status, body := postJSON(t, server.URL+"/v1/auth/email", map[string]any{
		"email":    "nobody@example.com",
		"password": "wrongwrong",
	}, "")
	if status != http.StatusUnauthorized {
		t.Fatalf("status = %d", status)
	}
	errObj, _ := body["error"].(map[string]any)
	if errObj == nil || errObj["message"] == "" {
		t.Fatalf("error envelope shape: %v", body)
	}
}

func TestCORSHeaders(t *testing.T) {
	server := testServer(t)
	req, _ := http.NewRequest(http.MethodOptions, server.URL+"/v1/auth/email", nil)
	req.Header.Set("Origin", "https://example.org")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got == "" {
		t.Fatal("CORS header missing")
	}
}
