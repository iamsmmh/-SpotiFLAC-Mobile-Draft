package cloud

import (
	"bufio"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// testClient is a minimal RFC 6455 *client*, used only by the tests in this
// package. It exists so the WebSocket server can be exercised end-to-end
// without a third-party dependency (see doc.go).
type testClient struct {
	conn net.Conn
	rw   *bufio.ReadWriter
}

// dialWS performs a client handshake against an httptest server URL.
func dialWS(rawURL string, header http.Header) (*testClient, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return nil, err
	}
	conn, err := net.DialTimeout("tcp", parsed.Host, 5*time.Second)
	if err != nil {
		return nil, err
	}
	rw := bufio.NewReadWriter(bufio.NewReader(conn), bufio.NewWriter(conn))

	key := base64.StdEncoding.EncodeToString([]byte("0123456789abcdef"))
	path := parsed.RequestURI()
	request := fmt.Sprintf(
		"GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"+
			"Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n",
		path, parsed.Host, key)
	for name, values := range header {
		for _, value := range values {
			request += name + ": " + value + "\r\n"
		}
	}
	request += "\r\n"

	if _, err := rw.WriteString(request); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if err := rw.Flush(); err != nil {
		_ = conn.Close()
		return nil, err
	}

	status, err := rw.ReadString('\n')
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	if !strings.Contains(status, "101") {
		_ = conn.Close()
		return nil, fmt.Errorf("handshake failed: %s", strings.TrimSpace(status))
	}
	// Drain the response headers, verifying the accept key on the way past:
	// a server that echoes the wrong digest is not RFC 6455 compliant, and
	// silently tolerating it here would hide exactly the bug these tests
	// are meant to catch.
	var gotAccept string
	for {
		line, err := rw.ReadString('\n')
		if err != nil {
			_ = conn.Close()
			return nil, err
		}
		if strings.TrimSpace(line) == "" {
			break
		}
		name, value, found := strings.Cut(line, ":")
		if found && strings.EqualFold(strings.TrimSpace(name), "Sec-WebSocket-Accept") {
			gotAccept = strings.TrimSpace(value)
		}
	}
	if want := acceptKey(key); gotAccept != want {
		_ = conn.Close()
		return nil, fmt.Errorf("bad Sec-WebSocket-Accept: got %q, want %q", gotAccept, want)
	}
	return &testClient{conn: conn, rw: rw}, nil
}

func (c *testClient) Close() error { return c.conn.Close() }

// writeText sends a masked client text frame (clients must mask).
func (c *testClient) writeText(payload []byte) error {
	mask, err := maskKey()
	if err != nil {
		return err
	}
	var header []byte
	size := len(payload)
	switch {
	case size < 126:
		header = []byte{0x81, byte(size) | 0x80}
	case size <= 0xFFFF:
		header = make([]byte, 4)
		header[0], header[1] = 0x81, 126|0x80
		binary.BigEndian.PutUint16(header[2:], uint16(size))
	default:
		header = make([]byte, 10)
		header[0], header[1] = 0x81, 127|0x80
		binary.BigEndian.PutUint64(header[2:], uint64(size))
	}
	if _, err := c.rw.Write(header); err != nil {
		return err
	}
	if _, err := c.rw.Write(mask[:]); err != nil {
		return err
	}
	masked := make([]byte, len(payload))
	for i := range payload {
		masked[i] = payload[i] ^ mask[i%4]
	}
	if _, err := c.rw.Write(masked); err != nil {
		return err
	}
	return c.rw.Flush()
}

// readFrame reads one server frame (server frames are never masked).
func (c *testClient) readFrame(timeout time.Duration) (opcode byte, payload []byte, err error) {
	if err := c.conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		return 0, nil, err
	}
	var header [2]byte
	if _, err := io.ReadFull(c.rw, header[:]); err != nil {
		return 0, nil, err
	}
	opcode = header[0] & 0x0F
	size := int(header[1] & 0x7F)
	switch size {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(c.rw, ext[:]); err != nil {
			return 0, nil, err
		}
		size = int(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(c.rw, ext[:]); err != nil {
			return 0, nil, err
		}
		size = int(binary.BigEndian.Uint64(ext[:]))
	}
	payload = make([]byte, size)
	if _, err := io.ReadFull(c.rw, payload); err != nil {
		return 0, nil, err
	}
	return opcode, payload, nil
}

// readEvent skips control frames and returns the next application event.
func (c *testClient) readEvent(timeout time.Duration) (Event, error) {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		opcode, payload, err := c.readFrame(time.Until(deadline))
		if err != nil {
			return Event{}, err
		}
		if opcode != opText {
			continue // ping/pong/close
		}
		return DecodeEvent(payload)
	}
	return Event{}, errors.New("timed out waiting for an event")
}
