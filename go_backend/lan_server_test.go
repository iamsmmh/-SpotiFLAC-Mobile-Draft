package gobackend

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeLanFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	files := []string{
		"Aphex Twin - Xtal.flac",
		"Boards of Canada - Dayvan.txt.opus",
		"notaudio.txt",
		filepath.Join("sub", "Deep Cut - Track.mp3"),
	}
	for _, name := range files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(strings.Repeat("x", 4096)), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func TestScanLanTracks(t *testing.T) {
	root := writeLanFixture(t)
	tracks := scanLanTracks(root)
	if len(tracks) != 3 {
		t.Fatalf("want 3 audio files, got %d: %+v", len(tracks), tracks)
	}
	for _, tr := range tracks {
		if _, err := os.Stat(tr.Path); err != nil {
			t.Fatalf("scanned path not accessible: %v", err)
		}
	}
	for i, tr := range tracks {
		if tr.Index != i {
			t.Fatalf("index mismatch at %d: %d", i, tr.Index)
		}
	}
}

func TestLanMuxEndpoints(t *testing.T) {
	root := writeLanFixture(t)
	srv := httptest.NewServer(lanMux(root))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/api/tracks")
	if err != nil {
		t.Fatal(err)
	}
	var tracks []lanTrack
	if err := json.NewDecoder(resp.Body).Decode(&tracks); err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if len(tracks) != 3 {
		t.Fatalf("api/tracks returned %d entries", len(tracks))
	}

	resp, err = http.Get(srv.URL + "/media?i=1")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("media status %d", resp.StatusCode)
	}
	if len(body) != 4096 {
		t.Fatalf("media body length %d", len(body))
	}

	// Range requests must work so browsers can seek.
	req, _ := http.NewRequest("GET", srv.URL+"/media?i=0", nil)
	req.Header.Set("Range", "bytes=0-99")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent {
		t.Fatalf("range status %d, want 206", resp.StatusCode)
	}

	resp, err = http.Get(srv.URL + "/media?i=9999")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("out-of-range media status %d, want 404", resp.StatusCode)
	}

	resp, err = http.Get(srv.URL + "/media?i=../../etc/passwd")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("traversal-attempt media status %d, want 404", resp.StatusCode)
	}

	resp, err = http.Get(srv.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	pageBytes, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if !strings.Contains(string(pageBytes), "SpotiFLAC LAN Player") {
		t.Fatal("player page not served at /")
	}
}

func TestLanSecureMuxRequiresPin(t *testing.T) {
	root := writeLanFixture(t)
	srv := httptest.NewServer(lanSecureMux(root, "2468"))
	defer srv.Close()

	resp, err := http.Get(srv.URL + "/api/tracks")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("open request status %d, want 401", resp.StatusCode)
	}

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/tracks", nil)
	req.Header.Set("X-SpotiFLAC-Pin", "2468")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("pin request status %d, want 200", resp.StatusCode)
	}

	token := lanTokenForPin("2468")
	req, _ = http.NewRequest(http.MethodGet, srv.URL+"/api/tracks", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("bearer request status %d, want 200", resp.StatusCode)
	}

	req, _ = http.NewRequest(http.MethodPost, srv.URL+"/api/tracks", nil)
	req.Header.Set("X-SpotiFLAC-Pin", "2468")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("write status %d, want 405", resp.StatusCode)
	}
}

func TestLanSecureMuxEmptyPinIsOpen(t *testing.T) {
	root := writeLanFixture(t)
	srv := httptest.NewServer(lanSecureMux(root, ""))
	defer srv.Close()
	resp, err := http.Get(srv.URL + "/api/tracks")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("empty-pin status %d, want 200", resp.StatusCode)
	}
}
