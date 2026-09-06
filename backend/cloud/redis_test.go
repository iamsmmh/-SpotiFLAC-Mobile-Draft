package cloud

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"strings"
	"testing"
	"time"
)

func TestReadReplySimpleString(t *testing.T) {
	got, err := readReply(bufio.NewReader(strings.NewReader("+OK\r\n")))
	if err != nil {
		t.Fatal(err)
	}
	if got != "OK" {
		t.Fatalf("got %#v", got)
	}
}

func TestReadReplyInteger(t *testing.T) {
	got, err := readReply(bufio.NewReader(strings.NewReader(":42\r\n")))
	if err != nil {
		t.Fatal(err)
	}
	if got != int64(42) {
		t.Fatalf("got %#v", got)
	}
}

func TestReadReplyBulkString(t *testing.T) {
	got, err := readReply(bufio.NewReader(strings.NewReader("$5\r\nhello\r\n")))
	if err != nil {
		t.Fatal(err)
	}
	if got != "hello" {
		t.Fatalf("got %#v", got)
	}
}

func TestReadReplyBulkStringWithEmbeddedCRLF(t *testing.T) {
	// The length prefix is authoritative; a payload containing CRLF must
	// survive intact (JSON event payloads routinely do).
	got, err := readReply(bufio.NewReader(strings.NewReader("$7\r\na\r\nb\r\nc\r\n")))
	if err != nil {
		t.Fatal(err)
	}
	if got != "a\r\nb\r\nc" {
		t.Fatalf("got %#v", got)
	}
}

func TestReadReplyNullBulk(t *testing.T) {
	got, err := readReply(bufio.NewReader(strings.NewReader("$-1\r\n")))
	if err != nil {
		t.Fatal(err)
	}
	if got != nil {
		t.Fatalf("expected nil, got %#v", got)
	}
}

func TestReadReplyError(t *testing.T) {
	_, err := readReply(bufio.NewReader(strings.NewReader("-ERR nope\r\n")))
	if err == nil || !strings.Contains(err.Error(), "ERR nope") {
		t.Fatalf("expected the server error, got %v", err)
	}
}

func TestReadReplyArray(t *testing.T) {
	raw := "*3\r\n$7\r\nmessage\r\n$5\r\nchan1\r\n$2\r\nhi\r\n"
	got, err := readReply(bufio.NewReader(strings.NewReader(raw)))
	if err != nil {
		t.Fatal(err)
	}
	parts, ok := got.([]any)
	if !ok || len(parts) != 3 {
		t.Fatalf("got %#v", got)
	}
	if parts[0] != "message" || parts[1] != "chan1" || parts[2] != "hi" {
		t.Fatalf("got %#v", parts)
	}
}

func TestReadReplyRejectsHugeBulk(t *testing.T) {
	_, err := readReply(bufio.NewReader(strings.NewReader("$99999999\r\n")))
	if err == nil {
		t.Fatal("expected an oversize bulk reply to be rejected")
	}
}

func TestReadReplyRejectsUnknownPrefix(t *testing.T) {
	if _, err := readReply(bufio.NewReader(strings.NewReader("?what\r\n"))); err == nil {
		t.Fatal("expected an error for an unknown RESP prefix")
	}
}

func TestWriteCommandEncodesRESPArray(t *testing.T) {
	var out bytes.Buffer
	rw := bufio.NewReadWriter(bufio.NewReader(strings.NewReader("")), bufio.NewWriter(&out))
	if err := writeCommand(rw, []string{"PUBLISH", "ch", "payload"}); err != nil {
		t.Fatal(err)
	}
	want := "*3\r\n$7\r\nPUBLISH\r\n$2\r\nch\r\n$7\r\npayload\r\n"
	if out.String() != want {
		t.Fatalf("got %q, want %q", out.String(), want)
	}
}

// fakeRedis is an in-process RESP2 server good enough for the client tests.
type fakeRedis struct {
	listener net.Listener
	// script maps an uppercased command name to a canned reply.
	replies map[string]string
}

func startFakeRedis(t *testing.T, replies map[string]string) *fakeRedis {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := &fakeRedis{listener: listener, replies: replies}
	go server.serve()
	t.Cleanup(func() { _ = listener.Close() })
	return server
}

func (s *fakeRedis) addr() string { return s.listener.Addr().String() }

func (s *fakeRedis) serve() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return
		}
		go s.handle(conn)
	}
}

func (s *fakeRedis) handle(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	reader := bufio.NewReader(conn)
	for {
		command, err := readCommand(reader)
		if err != nil {
			return
		}
		reply, ok := s.replies[strings.ToUpper(command)]
		if !ok {
			reply = "+OK\r\n"
		}
		if _, err := conn.Write([]byte(reply)); err != nil {
			return
		}
	}
}

// readCommand parses a RESP array of bulk strings and returns the verb.
func readCommand(r *bufio.Reader) (string, error) {
	reply, err := readReply(r)
	if err != nil {
		return "", err
	}
	parts, ok := reply.([]any)
	if !ok || len(parts) == 0 {
		return "", nil
	}
	verb, _ := parts[0].(string)
	return verb, nil
}

func TestRedisPublish(t *testing.T) {
	server := startFakeRedis(t, map[string]string{"PUBLISH": ":1\r\n"})
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	client, err := DialRedis(ctx, RedisOptions{Addr: server.addr()})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Close() }()

	if err := client.Publish(ctx, "spotiflac:events:usr_1", []byte(`{"kind":"sync"}`)); err != nil {
		t.Fatalf("publish: %v", err)
	}
}

func TestRedisGetMissingKeyIsNotFound(t *testing.T) {
	server := startFakeRedis(t, map[string]string{"GET": "$-1\r\n"})
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	client, err := DialRedis(ctx, RedisOptions{Addr: server.addr()})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Close() }()

	if _, err := client.Get(ctx, "missing"); err != ErrNotFound {
		t.Fatalf("expected ErrNotFound, got %v", err)
	}
}

func TestRedisSetRoundTrip(t *testing.T) {
	server := startFakeRedis(t, map[string]string{"SET": "+OK\r\n", "GET": "$5\r\nvalue\r\n"})
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()

	client, err := DialRedis(ctx, RedisOptions{Addr: server.addr()})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Close() }()

	if err := client.Set(ctx, "k", "value", time.Minute); err != nil {
		t.Fatal(err)
	}
	got, err := client.Get(ctx, "k")
	if err != nil {
		t.Fatal(err)
	}
	if got != "value" {
		t.Fatalf("got %q", got)
	}
}

func TestDialRedisRequiresAddress(t *testing.T) {
	if _, err := DialRedis(t.Context(), RedisOptions{}); err == nil {
		t.Fatal("expected an error for an empty address")
	}
}

func TestRedisDelWithNoKeysIsNoop(t *testing.T) {
	server := startFakeRedis(t, nil)
	client, err := DialRedis(t.Context(), RedisOptions{Addr: server.addr()})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Close() }()

	if err := client.Del(t.Context()); err != nil {
		t.Fatalf("expected a no-op, got %v", err)
	}
}

func TestRedisAfterCloseIsUnavailable(t *testing.T) {
	server := startFakeRedis(t, nil)
	client, err := DialRedis(t.Context(), RedisOptions{Addr: server.addr()})
	if err != nil {
		t.Fatal(err)
	}
	_ = client.Close()

	if _, err := client.Do(t.Context(), "PING"); err != ErrUnavailable {
		t.Fatalf("expected ErrUnavailable, got %v", err)
	}
}

func TestAllUsersPatternMatchesNamespace(t *testing.T) {
	pattern := AllUsersPattern()
	if !strings.HasSuffix(pattern, "*") || UserFromChannel(strings.TrimSuffix(pattern, "*")+"u1") != "u1" {
		t.Fatalf("pattern does not cover the namespace: %q", pattern)
	}
}

func TestSubscribeRequiresChannels(t *testing.T) {
	server := startFakeRedis(t, nil)
	client, err := DialRedis(t.Context(), RedisOptions{Addr: server.addr()})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.Close() }()

	if _, err := client.Subscribe(t.Context()); err == nil {
		t.Fatal("expected an error with no channels")
	}
}
