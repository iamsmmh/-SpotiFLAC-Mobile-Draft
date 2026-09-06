package cloud

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestAcceptKeyMatchesRFC6455Example(t *testing.T) {
	// RFC 6455 §1.3 worked example.
	if got := acceptKey("dGhlIHNhbXBsZSBub25jZQ=="); got != "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=" {
		t.Fatalf("accept key = %q", got)
	}
}

func TestHeaderContainsToken(t *testing.T) {
	cases := []struct {
		header string
		token  string
		want   bool
	}{
		{"Upgrade", "upgrade", true},
		{"keep-alive, Upgrade", "upgrade", true},
		{"KEEP-ALIVE,UPGRADE", "Upgrade", true},
		{"keep-alive", "upgrade", false},
		{"", "upgrade", false},
	}
	for _, tc := range cases {
		if got := headerContainsToken(tc.header, tc.token); got != tc.want {
			t.Fatalf("headerContainsToken(%q, %q) = %v", tc.header, tc.token, got)
		}
	}
}

// upgradeGuard asserts Accept rejects a malformed handshake.
func upgradeGuard(t *testing.T, mutate func(*http.Request)) {
	t.Helper()
	var acceptErr error
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, acceptErr = Accept(w, r)
		if acceptErr != nil {
			w.WriteHeader(http.StatusBadRequest)
		}
	}))
	defer server.Close()

	req, err := http.NewRequest(http.MethodGet, server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Upgrade", "websocket")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Sec-WebSocket-Key", "dGhlIHNhbXBsZSBub25jZQ==")
	req.Header.Set("Sec-WebSocket-Version", "13")
	mutate(req)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return // a transport-level rejection is also a rejection
	}
	defer func() { _ = resp.Body.Close() }()
	if acceptErr == nil {
		t.Fatal("expected the handshake to be rejected")
	}
}

func TestAcceptRejectsMissingUpgradeHeader(t *testing.T) {
	upgradeGuard(t, func(r *http.Request) { r.Header.Del("Upgrade") })
}

func TestAcceptRejectsWrongVersion(t *testing.T) {
	upgradeGuard(t, func(r *http.Request) { r.Header.Set("Sec-WebSocket-Version", "8") })
}

func TestAcceptRejectsMissingKey(t *testing.T) {
	upgradeGuard(t, func(r *http.Request) { r.Header.Del("Sec-WebSocket-Key") })
}

// echoServer accepts a socket and echoes every message back.
func echoServer(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := Accept(w, r)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		defer func() { _ = conn.Close() }()
		for {
			message, err := conn.Read()
			if err != nil {
				return
			}
			if err := conn.WriteText(message.Data); err != nil {
				return
			}
		}
	}))
	t.Cleanup(server.Close)
	return server
}

func TestWebSocketEchoSmallFrame(t *testing.T) {
	server := echoServer(t)
	client, err := dialWS(server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Close() }()

	payload := []byte("hello world")
	if err := client.writeText(payload); err != nil {
		t.Fatal(err)
	}
	opcode, got, err := client.readFrame(3 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if opcode != opText || string(got) != string(payload) {
		t.Fatalf("echo mismatch: opcode=%x payload=%q", opcode, got)
	}
}

func TestWebSocketEchoExtendedLengthFrame(t *testing.T) {
	// >125 bytes exercises the 16-bit length path in both directions.
	server := echoServer(t)
	client, err := dialWS(server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Close() }()

	payload := []byte(strings.Repeat("x", 5000))
	if err := client.writeText(payload); err != nil {
		t.Fatal(err)
	}
	_, got, err := client.readFrame(5 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != len(payload) {
		t.Fatalf("expected %d bytes, got %d", len(payload), len(got))
	}
}

func TestWebSocketServerAnswersPing(t *testing.T) {
	server := echoServer(t)
	client, err := dialWS(server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Close() }()

	// A masked client ping; the server must reply with a pong.
	mask, err := maskKey()
	if err != nil {
		t.Fatal(err)
	}
	frame := []byte{0x89, 0x80}
	frame = append(frame, mask[:]...)
	if _, err := client.rw.Write(frame); err != nil {
		t.Fatal(err)
	}
	if err := client.rw.Flush(); err != nil {
		t.Fatal(err)
	}

	opcode, _, err := client.readFrame(3 * time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if opcode != opPong {
		t.Fatalf("expected a pong, got opcode %#x", opcode)
	}
}

func TestWebSocketCloseIsIdempotent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := Accept(w, r)
		if err != nil {
			return
		}
		_ = conn.Close()
		_ = conn.Close() // must not panic or double-close `done`
		select {
		case <-conn.Done():
		default:
			t.Error("Done was not closed")
		}
		if err := conn.WriteText([]byte("x")); err != ErrConnClosed {
			t.Errorf("write after close = %v, want ErrConnClosed", err)
		}
	}))
	defer server.Close()

	client, err := dialWS(server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	_ = client.Close()
	time.Sleep(100 * time.Millisecond)
}

func TestWebSocketRejectsUnmaskedClientFrame(t *testing.T) {
	// RFC 6455 §5.1: a server MUST close on an unmasked client frame.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := Accept(w, r)
		if err != nil {
			return
		}
		defer func() { _ = conn.Close() }()
		if _, err := conn.Read(); err == nil {
			t.Error("expected an unmasked frame to be rejected")
		}
	}))
	defer server.Close()

	client, err := dialWS(server.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Close() }()

	if _, err := client.rw.Write([]byte{0x81, 0x01, 'x'}); err != nil {
		t.Fatal(err)
	}
	if err := client.rw.Flush(); err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
}

func TestEventEncodeDecodeRoundTrip(t *testing.T) {
	original := NewSyncEvent("playlists", 9, "device-1", time.Now())
	raw, err := original.Encode()
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeEvent(raw)
	if err != nil {
		t.Fatal(err)
	}
	if got.Kind != original.Kind || got.Scope != original.Scope ||
		got.Revision != original.Revision || got.Origin != original.Origin {
		t.Fatalf("round trip mismatch: %+v vs %+v", got, original)
	}
}

func TestContinuityEventCarriesState(t *testing.T) {
	event := NewContinuityEvent(ContinuityState{
		DeviceID: "d1", TrackID: "t1", PositionMs: 1234,
	}, time.Now())
	if event.Kind != EventContinuity || event.Origin != "d1" {
		t.Fatalf("unexpected envelope: %+v", event)
	}
	state, err := decodeContinuity(event.Payload)
	if err != nil {
		t.Fatal(err)
	}
	if state.TrackID != "t1" || state.PositionMs != 1234 {
		t.Fatalf("payload lost data: %+v", state)
	}
}
