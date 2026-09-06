// Command server runs the SpotiFLAC Cloud reference backend: JWT auth with
// refresh-token rotation, device registration, incremental record sync with
// the client conflict rule, playlist share links, listening-history
// aggregation, the settings allowlist, and backup blobs.
//
// Configuration (all optional):
//
//	PORT                  listen port (default 8080)
//	SPOTIFLAC_JWT_SECRET  HMAC secret (>= 32 bytes); a random one is
//	                      generated when absent (sessions then die on
//	                      restart — set this in production)
//	SPOTIFLAC_CORS_ORIGIN comma-separated allowed origins (default *)
//
//	SPOTIFLAC_POSTGRES_DSN     enable durable storage (see backend/cloud)
//	SPOTIFLAC_POSTGRES_DRIVER  registered driver name (default "pgx")
//	SPOTIFLAC_REDIS_ADDR       enable cross-process event fan-out
//	SPOTIFLAC_REDIS_PASSWORD   Redis AUTH password
//
// With neither Postgres nor Redis configured the binary runs exactly as the
// original reference implementation: in-memory state, single process, and
// the /v1/cloud/events socket still delivering realtime updates within that
// process. Durable deployments must set SPOTIFLAC_POSTGRES_DSN *and* link a
// driver — this module has no third-party dependencies, so the driver is
// registered by the deploying binary (see backend/cloud/doc.go).
package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/zarz/spotiflac_android/backend/auth"
	"github.com/zarz/spotiflac_android/backend/cloud"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	secret := jwtSecret()

	runtime, err := cloud.Build(ctx, cloud.ConfigFromEnv(), time.Now)
	if err != nil {
		// A configured-but-unreachable dependency is fatal on purpose:
		// falling back to in-memory would look healthy while discarding
		// every user's library (see cloud.Build).
		log.Fatalf("cloud layer: %v", err)
	}
	defer func() { _ = runtime.Close() }()

	handler := newHandlerWithCloud(secret, time.Now, auth.NewUserID, runtime)

	addr := ":" + envOr("PORT", "8080")
	if len(secret) < 32 {
		log.Printf("SPOTIFLAC_JWT_SECRET unset — generated an ephemeral secret (sessions will not survive a restart)")
	}
	log.Printf("SpotiFLAC Cloud listening on %s", addr)
	server := &http.Server{
		Addr:              addr,
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       60 * time.Second,
		// WriteTimeout must stay off: it applies to hijacked connections
		// too, so any positive value kills the /v1/cloud/events WebSocket
		// mid-stream. The event loop arms its own per-frame deadline
		// (cloud.WriteTimeout) instead.
		WriteTimeout: 0,
		IdleTimeout:  120 * time.Second,
	}

	// Graceful shutdown: stop accepting, let in-flight syncs finish.
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()

	if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
