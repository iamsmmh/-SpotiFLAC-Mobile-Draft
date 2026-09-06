package cloud

import (
	"context"
	"database/sql"
	"log"
	"os"
	"strings"
	"time"
)

// Config is the deployment configuration for the durable/scalable layer.
// The zero value is valid and means "single process, in-memory" — exactly
// the reference behaviour the repository shipped before this milestone.
type Config struct {
	// PostgresDSN enables durable storage. Requires DriverName to name a
	// driver the binary has registered (see OpenPostgres).
	PostgresDSN string
	DriverName  string

	// RedisAddr enables cross-process event fan-out.
	RedisAddr     string
	RedisPassword string

	// MaxOpenConns bounds the Postgres pool. Sized against the deployment's
	// connection budget, not the request rate.
	MaxOpenConns int
	MaxIdleConns int
	ConnLifetime time.Duration
}

// ConfigFromEnv reads the deployment configuration from the environment.
func ConfigFromEnv() Config {
	return Config{
		PostgresDSN:   strings.TrimSpace(os.Getenv("SPOTIFLAC_POSTGRES_DSN")),
		DriverName:    envDefault("SPOTIFLAC_POSTGRES_DRIVER", "pgx"),
		RedisAddr:     strings.TrimSpace(os.Getenv("SPOTIFLAC_REDIS_ADDR")),
		RedisPassword: os.Getenv("SPOTIFLAC_REDIS_PASSWORD"),
		MaxOpenConns:  25,
		MaxIdleConns:  5,
		ConnLifetime:  30 * time.Minute,
	}
}

func envDefault(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

// Runtime is the assembled cloud layer.
type Runtime struct {
	Hub      *Hub
	Storage  Storage
	Postgres *Postgres
	Redis    *RedisClient

	cancel context.CancelFunc
}

// Close releases the runtime's resources.
func (r *Runtime) Close() error {
	if r == nil {
		return nil
	}
	if r.cancel != nil {
		r.cancel()
	}
	if r.Hub != nil {
		r.Hub.Close()
	}
	if r.Redis != nil {
		_ = r.Redis.Close()
	}
	if r.Postgres != nil {
		return r.Postgres.DB().Close()
	}
	return nil
}

// Build assembles the runtime from config.
//
// Failure policy: a *misconfigured* dependency is fatal (returning an error)
// because silently degrading to in-memory would look like working software
// while quietly discarding every user's library. A dependency that is
// configured and simply unreachable at boot is also an error, for the same
// reason — the deployment should crash-loop and be noticed, not serve
// amnesia.
func Build(ctx context.Context, cfg Config, clock func() time.Time) (*Runtime, error) {
	if clock == nil {
		clock = time.Now
	}

	var (
		redis     *RedisClient
		publisher Publisher
	)
	if cfg.RedisAddr != "" {
		client, err := DialRedis(ctx, RedisOptions{
			Addr:     cfg.RedisAddr,
			Password: cfg.RedisPassword,
		})
		if err != nil {
			return nil, err
		}
		redis = client
		publisher = client
	}

	hub := NewHub(publisher, clock)

	bridgeCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	runtime := &Runtime{Hub: hub, Redis: redis, cancel: cancel}

	if redis != nil {
		// A process cannot know which users will connect to it, so it
		// pattern-subscribes to the whole namespace rather than
		// re-subscribing on every login. The hub drops events for users
		// with no local subscriber, so the extra traffic costs a map lookup.
		messages, err := redis.PSubscribe(bridgeCtx, AllUsersPattern())
		if err != nil {
			cancel()
			_ = redis.Close()
			return nil, err
		}
		go hub.Bridge(bridgeCtx, messages)
	}

	if cfg.PostgresDSN != "" {
		db, err := sql.Open(cfg.DriverName, cfg.PostgresDSN)
		if err != nil {
			_ = runtime.Close()
			return nil, err
		}
		if cfg.MaxOpenConns > 0 {
			db.SetMaxOpenConns(cfg.MaxOpenConns)
		}
		if cfg.MaxIdleConns > 0 {
			db.SetMaxIdleConns(cfg.MaxIdleConns)
		}
		if cfg.ConnLifetime > 0 {
			db.SetConnMaxLifetime(cfg.ConnLifetime)
		}
		store, err := OpenPostgres(ctx, db, clock)
		if err != nil {
			_ = db.Close()
			_ = runtime.Close()
			return nil, err
		}
		runtime.Postgres = store
		runtime.Storage = store
		log.Printf("cloud: postgres storage enabled")
	}
	if redis != nil {
		log.Printf("cloud: redis event bus enabled (%s)", cfg.RedisAddr)
	}
	return runtime, nil
}
