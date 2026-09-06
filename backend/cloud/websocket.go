package cloud

import (
	"bufio"
	"crypto/rand"
	"crypto/sha1"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// A from-scratch RFC 6455 server. Only what the event stream needs is
// implemented — text/binary data frames, ping/pong, close — which is what
// keeps the backend module dependency-free (see doc.go).

// wsGUID is the RFC 6455 §1.3 magic value for the accept handshake.
const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Frame opcodes.
const (
	opContinuation byte = 0x0
	opText         byte = 0x1
	opBinary       byte = 0x2
	opClose        byte = 0x8
	opPing         byte = 0x9
	opPong         byte = 0xA
)

// MaxFrameBytes caps an inbound message. Clients only ever send small
// control messages (subscribe/ack/continuity), so this is generous.
const MaxFrameBytes = 1 << 20 // 1 MiB

// ErrConnClosed is returned once the connection is finished.
var ErrConnClosed = errors.New("cloud: websocket closed")

// Conn is a server-side WebSocket connection. It is safe for one concurrent
// reader and any number of concurrent writers.
type Conn struct {
	raw  net.Conn
	buf  *bufio.ReadWriter
	wmu  sync.Mutex
	once sync.Once
	done chan struct{}
}

// Accept performs the RFC 6455 handshake and hijacks the connection.
func Accept(w http.ResponseWriter, r *http.Request) (*Conn, error) {
	if !strings.EqualFold(r.Header.Get("Upgrade"), "websocket") {
		return nil, errors.New("cloud: not a websocket upgrade")
	}
	if !headerContainsToken(r.Header.Get("Connection"), "upgrade") {
		return nil, errors.New("cloud: missing Connection: Upgrade")
	}
	if r.Header.Get("Sec-WebSocket-Version") != "13" {
		return nil, errors.New("cloud: unsupported websocket version")
	}
	key := strings.TrimSpace(r.Header.Get("Sec-WebSocket-Key"))
	if key == "" {
		return nil, errors.New("cloud: missing Sec-WebSocket-Key")
	}

	hijacker, ok := w.(http.Hijacker)
	if !ok {
		return nil, errors.New("cloud: response writer does not support hijacking")
	}
	raw, buf, err := hijacker.Hijack()
	if err != nil {
		return nil, fmt.Errorf("cloud: hijack: %w", err)
	}

	// http.Server's ReadTimeout/WriteTimeout deadlines are already armed on
	// this conn and survive hijacking; leaving them would tear the socket
	// down mid-stream. The event loop sets its own per-write deadline.
	_ = raw.SetDeadline(time.Time{})

	accept := acceptKey(key)
	response := "HTTP/1.1 101 Switching Protocols\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Accept: " + accept + "\r\n\r\n"
	if _, err := buf.WriteString(response); err != nil {
		_ = raw.Close()
		return nil, fmt.Errorf("cloud: handshake write: %w", err)
	}
	if err := buf.Flush(); err != nil {
		_ = raw.Close()
		return nil, fmt.Errorf("cloud: handshake flush: %w", err)
	}
	return &Conn{raw: raw, buf: buf, done: make(chan struct{})}, nil
}

// acceptKey computes the Sec-WebSocket-Accept response value.
//
// SHA-1 is mandated by RFC 6455 for this handshake and carries no security
// weight here (it proves neither identity nor integrity — TLS does that);
// it exists so caches cannot confuse a WebSocket handshake with an HTTP
// response.
func acceptKey(key string) string {
	sum := sha1.Sum([]byte(key + wsGUID)) // #nosec G401 -- protocol-mandated
	return base64.StdEncoding.EncodeToString(sum[:])
}

func headerContainsToken(header, token string) bool {
	for _, part := range strings.Split(header, ",") {
		if strings.EqualFold(strings.TrimSpace(part), token) {
			return true
		}
	}
	return false
}

// Done is closed when the connection is torn down.
func (c *Conn) Done() <-chan struct{} { return c.done }

// Close tears the connection down exactly once, best-effort sending a
// normal-closure frame first.
func (c *Conn) Close() error {
	var err error
	c.once.Do(func() {
		_ = c.writeFrame(opClose, closePayload(1000, "bye"))
		close(c.done)
		err = c.raw.Close()
	})
	return err
}

func closePayload(code uint16, reason string) []byte {
	payload := make([]byte, 2, 2+len(reason))
	binary.BigEndian.PutUint16(payload, code)
	return append(payload, reason...)
}

// WriteText sends one text frame.
func (c *Conn) WriteText(payload []byte) error { return c.writeFrame(opText, payload) }

// WritePing sends a keepalive ping.
func (c *Conn) WritePing() error { return c.writeFrame(opPing, nil) }

// SetWriteDeadline bounds a slow consumer so one stuck device cannot pin a
// goroutine and its buffers forever.
func (c *Conn) SetWriteDeadline(t time.Time) error { return c.raw.SetWriteDeadline(t) }

// SetReadDeadline bounds the read side.
func (c *Conn) SetReadDeadline(t time.Time) error { return c.raw.SetReadDeadline(t) }

// writeFrame writes a single unmasked server frame (servers must not mask).
func (c *Conn) writeFrame(opcode byte, payload []byte) error {
	select {
	case <-c.done:
		return ErrConnClosed
	default:
	}

	c.wmu.Lock()
	defer c.wmu.Unlock()

	var header [10]byte
	header[0] = 0x80 | opcode // FIN set; no extensions negotiated.
	size := len(payload)
	var headerLen int
	switch {
	case size < 126:
		header[1] = byte(size)
		headerLen = 2
	case size <= 0xFFFF:
		header[1] = 126
		binary.BigEndian.PutUint16(header[2:4], uint16(size))
		headerLen = 4
	default:
		header[1] = 127
		binary.BigEndian.PutUint64(header[2:10], uint64(size))
		headerLen = 10
	}
	if _, err := c.buf.Write(header[:headerLen]); err != nil {
		return err
	}
	if len(payload) > 0 {
		if _, err := c.buf.Write(payload); err != nil {
			return err
		}
	}
	return c.buf.Flush()
}

// Message is one inbound application message.
type Message struct {
	Binary bool
	Data   []byte
}

// Read returns the next application message, transparently answering pings
// and honouring close frames. Fragmented messages are reassembled.
func (c *Conn) Read() (Message, error) {
	var (
		assembled []byte
		binaryMsg bool
		building  bool
	)
	for {
		opcode, payload, fin, err := c.readFrame()
		if err != nil {
			return Message{}, err
		}
		switch opcode {
		case opPing:
			if err := c.writeFrame(opPong, payload); err != nil {
				return Message{}, err
			}
		case opPong:
			// Keepalive answer; nothing to do.
		case opClose:
			_ = c.Close()
			return Message{}, ErrConnClosed
		case opText, opBinary:
			if building {
				return Message{}, errors.New("cloud: interleaved data frame")
			}
			binaryMsg = opcode == opBinary
			assembled = payload
			if fin {
				return Message{Binary: binaryMsg, Data: assembled}, nil
			}
			building = true
		case opContinuation:
			if !building {
				return Message{}, errors.New("cloud: unexpected continuation frame")
			}
			if len(assembled)+len(payload) > MaxFrameBytes {
				return Message{}, errors.New("cloud: message too large")
			}
			assembled = append(assembled, payload...)
			if fin {
				return Message{Binary: binaryMsg, Data: assembled}, nil
			}
		default:
			return Message{}, fmt.Errorf("cloud: unknown opcode %#x", opcode)
		}
	}
}

// readFrame reads one frame, unmasking the payload (client frames must be
// masked per RFC 6455 §5.1).
func (c *Conn) readFrame() (opcode byte, payload []byte, fin bool, err error) {
	var header [2]byte
	if _, err = io.ReadFull(c.buf, header[:]); err != nil {
		return 0, nil, false, err
	}
	fin = header[0]&0x80 != 0
	if header[0]&0x70 != 0 {
		return 0, nil, false, errors.New("cloud: reserved bits set")
	}
	opcode = header[0] & 0x0F
	masked := header[1]&0x80 != 0
	if !masked {
		return 0, nil, false, errors.New("cloud: client frame must be masked")
	}

	size := int(header[1] & 0x7F)
	switch size {
	case 126:
		var ext [2]byte
		if _, err = io.ReadFull(c.buf, ext[:]); err != nil {
			return 0, nil, false, err
		}
		size = int(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err = io.ReadFull(c.buf, ext[:]); err != nil {
			return 0, nil, false, err
		}
		size64 := binary.BigEndian.Uint64(ext[:])
		if size64 > MaxFrameBytes {
			return 0, nil, false, errors.New("cloud: frame too large")
		}
		size = int(size64)
	}
	if size > MaxFrameBytes {
		return 0, nil, false, errors.New("cloud: frame too large")
	}
	// Control frames carry at most 125 bytes and are never fragmented.
	if opcode >= opClose && (size > 125 || !fin) {
		return 0, nil, false, errors.New("cloud: invalid control frame")
	}

	var mask [4]byte
	if _, err = io.ReadFull(c.buf, mask[:]); err != nil {
		return 0, nil, false, err
	}
	payload = make([]byte, size)
	if _, err = io.ReadFull(c.buf, payload); err != nil {
		return 0, nil, false, err
	}
	for i := range payload {
		payload[i] ^= mask[i%4]
	}
	return opcode, payload, fin, nil
}

// maskKey generates a client-side mask. Exposed for the test client.
func maskKey() ([4]byte, error) {
	var key [4]byte
	_, err := rand.Read(key[:])
	return key, err
}
