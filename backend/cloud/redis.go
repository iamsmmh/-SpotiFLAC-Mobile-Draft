package cloud

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"
)

// A minimal RESP2 client: PUBLISH/SUBSCRIBE for the event bus, plus
// GET/SET/DEL/EXPIRE for the session and rate-limit caches. Written against
// the wire protocol rather than pulling in a driver, so the backend module
// keeps an empty go.mod (see doc.go).

// RedisMessage is one pub/sub delivery.
type RedisMessage struct {
	Channel string
	Payload []byte
}

// RedisClient is a single-connection RESP2 client. Commands are serialized
// by a mutex; the throughput this backend needs (event fan-out, not a hot
// cache path) does not justify a pool.
type RedisClient struct {
	mu   sync.Mutex
	conn net.Conn
	rw   *bufio.ReadWriter

	addr     string
	password string
	dialer   func(ctx context.Context, addr string) (net.Conn, error)
}

// RedisOptions configures the client.
type RedisOptions struct {
	Addr     string
	Password string
	// Dialer is injectable so tests can run against an in-process fake.
	Dialer func(ctx context.Context, addr string) (net.Conn, error)
}

// DialRedis connects and authenticates.
func DialRedis(ctx context.Context, opts RedisOptions) (*RedisClient, error) {
	if strings.TrimSpace(opts.Addr) == "" {
		return nil, errors.New("cloud: redis address is required")
	}
	dialer := opts.Dialer
	if dialer == nil {
		dialer = func(ctx context.Context, addr string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "tcp", addr)
		}
	}
	conn, err := dialer(ctx, opts.Addr)
	if err != nil {
		return nil, fmt.Errorf("cloud: redis dial: %w", err)
	}
	client := &RedisClient{
		conn:     conn,
		rw:       bufio.NewReadWriter(bufio.NewReader(conn), bufio.NewWriter(conn)),
		addr:     opts.Addr,
		password: opts.Password,
		dialer:   dialer,
	}
	if opts.Password != "" {
		if _, err := client.Do(ctx, "AUTH", opts.Password); err != nil {
			_ = conn.Close()
			return nil, fmt.Errorf("cloud: redis auth: %w", err)
		}
	}
	return client, nil
}

// Close releases the connection.
func (c *RedisClient) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conn == nil {
		return nil
	}
	err := c.conn.Close()
	c.conn = nil
	return err
}

// Do issues one command and returns the decoded reply.
func (c *RedisClient) Do(ctx context.Context, args ...string) (any, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.do(ctx, args...)
}

func (c *RedisClient) do(ctx context.Context, args ...string) (any, error) {
	if c.conn == nil {
		return nil, ErrUnavailable
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = c.conn.SetDeadline(deadline)
		defer func() { _ = c.conn.SetDeadline(time.Time{}) }()
	}
	if err := writeCommand(c.rw, args); err != nil {
		return nil, err
	}
	return readReply(c.rw.Reader)
}

// Publish sends an event to a channel.
func (c *RedisClient) Publish(ctx context.Context, channel string, payload []byte) error {
	_, err := c.Do(ctx, "PUBLISH", channel, string(payload))
	return err
}

// Set stores a value with an optional TTL (zero means no expiry).
func (c *RedisClient) Set(ctx context.Context, key, value string, ttl time.Duration) error {
	args := []string{"SET", key, value}
	if ttl > 0 {
		args = append(args, "PX", strconv.FormatInt(ttl.Milliseconds(), 10))
	}
	_, err := c.Do(ctx, args...)
	return err
}

// Get reads a value; a missing key returns ErrNotFound.
func (c *RedisClient) Get(ctx context.Context, key string) (string, error) {
	reply, err := c.Do(ctx, "GET", key)
	if err != nil {
		return "", err
	}
	if reply == nil {
		return "", ErrNotFound
	}
	value, ok := reply.(string)
	if !ok {
		return "", fmt.Errorf("cloud: unexpected GET reply %T", reply)
	}
	return value, nil
}

// Del removes keys.
func (c *RedisClient) Del(ctx context.Context, keys ...string) error {
	if len(keys) == 0 {
		return nil
	}
	_, err := c.Do(ctx, append([]string{"DEL"}, keys...)...)
	return err
}

// Subscribe streams the named channels.
func (c *RedisClient) Subscribe(ctx context.Context, channels ...string) (<-chan RedisMessage, error) {
	return c.subscribe(ctx, "SUBSCRIBE", channels...)
}

// PSubscribe streams every channel matching the glob patterns. This is what
// the event bus uses: a process cannot know in advance which users will
// connect to it, so it matches the whole `spotiflac:events:*` namespace
// rather than re-subscribing on every login.
func (c *RedisClient) PSubscribe(ctx context.Context, patterns ...string) (<-chan RedisMessage, error) {
	return c.subscribe(ctx, "PSUBSCRIBE", patterns...)
}

// AllUsersPattern matches every user's event channel.
func AllUsersPattern() string { return channelPrefix + "*" }

// subscribe opens a *dedicated* connection (a subscribed RESP2 connection
// cannot serve normal commands) and streams messages until ctx is cancelled.
// The returned channel is closed when the subscription ends.
func (c *RedisClient) subscribe(ctx context.Context, command string, channels ...string) (<-chan RedisMessage, error) {
	if len(channels) == 0 {
		return nil, errors.New("cloud: subscribe needs at least one channel")
	}
	conn, err := c.dialer(ctx, c.addr)
	if err != nil {
		return nil, fmt.Errorf("cloud: redis subscribe dial: %w", err)
	}
	rw := bufio.NewReadWriter(bufio.NewReader(conn), bufio.NewWriter(conn))

	if c.password != "" {
		if err := writeCommand(rw, []string{"AUTH", c.password}); err != nil {
			_ = conn.Close()
			return nil, err
		}
		if _, err := readReply(rw.Reader); err != nil {
			_ = conn.Close()
			return nil, err
		}
	}
	if err := writeCommand(rw, append([]string{command}, channels...)); err != nil {
		_ = conn.Close()
		return nil, err
	}

	out := make(chan RedisMessage, SubscriberBuffer)
	go func() {
		defer close(out)
		defer func() { _ = conn.Close() }()
		// Unblock the blocking read below when the caller cancels.
		go func() {
			<-ctx.Done()
			_ = conn.SetReadDeadline(time.Now())
		}()
		for {
			reply, err := readReply(rw.Reader)
			if err != nil {
				return
			}
			parts, ok := reply.([]any)
			if !ok || len(parts) < 3 {
				continue
			}
			kind, _ := parts[0].(string)
			// SUBSCRIBE delivers ["message", channel, payload]; PSUBSCRIBE
			// delivers ["pmessage", pattern, channel, payload]. Everything
			// else is a subscribe confirmation.
			var channel, payload string
			switch {
			case kind == "message" && len(parts) == 3:
				channel, _ = parts[1].(string)
				payload, _ = parts[2].(string)
			case kind == "pmessage" && len(parts) == 4:
				channel, _ = parts[2].(string)
				payload, _ = parts[3].(string)
			default:
				continue
			}
			select {
			case out <- RedisMessage{Channel: channel, Payload: []byte(payload)}:
			case <-ctx.Done():
				return
			}
		}
	}()
	return out, nil
}

// ---------------------------------------------------------------------------
// RESP2 codec
// ---------------------------------------------------------------------------

// writeCommand emits a command as a RESP array of bulk strings.
func writeCommand(rw *bufio.ReadWriter, args []string) error {
	if _, err := fmt.Fprintf(rw, "*%d\r\n", len(args)); err != nil {
		return err
	}
	for _, arg := range args {
		if _, err := fmt.Fprintf(rw, "$%d\r\n%s\r\n", len(arg), arg); err != nil {
			return err
		}
	}
	return rw.Flush()
}

// readReply decodes one RESP2 reply into: string (simple/bulk), int64,
// []any (array), nil (null), or an error (error reply).
func readReply(r *bufio.Reader) (any, error) {
	prefix, err := r.ReadByte()
	if err != nil {
		return nil, err
	}
	switch prefix {
	case '+':
		return readLine(r)
	case '-':
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("cloud: redis: %s", line)
	case ':':
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		return strconv.ParseInt(line, 10, 64)
	case '$':
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		size, err := strconv.Atoi(line)
		if err != nil {
			return nil, fmt.Errorf("cloud: bad bulk length %q", line)
		}
		if size < 0 {
			return nil, nil
		}
		if size > MaxFrameBytes {
			return nil, errors.New("cloud: redis bulk reply too large")
		}
		payload := make([]byte, size+2) // include trailing CRLF
		if _, err := readFull(r, payload); err != nil {
			return nil, err
		}
		return string(payload[:size]), nil
	case '*':
		line, err := readLine(r)
		if err != nil {
			return nil, err
		}
		count, err := strconv.Atoi(line)
		if err != nil {
			return nil, fmt.Errorf("cloud: bad array length %q", line)
		}
		if count < 0 {
			return nil, nil
		}
		if count > 1<<20 {
			return nil, errors.New("cloud: redis array reply too large")
		}
		items := make([]any, 0, count)
		for i := 0; i < count; i++ {
			item, err := readReply(r)
			if err != nil {
				return nil, err
			}
			items = append(items, item)
		}
		return items, nil
	default:
		return nil, fmt.Errorf("cloud: unknown RESP prefix %q", prefix)
	}
}

func readLine(r *bufio.Reader) (string, error) {
	line, err := r.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

func readFull(r *bufio.Reader, buf []byte) (int, error) {
	read := 0
	for read < len(buf) {
		n, err := r.Read(buf[read:])
		read += n
		if err != nil {
			return read, err
		}
	}
	return read, nil
}
