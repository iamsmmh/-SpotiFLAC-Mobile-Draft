package main

import (
	"crypto/rand"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/zarz/spotiflac_android/backend/auth"
	"github.com/zarz/spotiflac_android/backend/cloud"
	"github.com/zarz/spotiflac_android/backend/history"
	"github.com/zarz/spotiflac_android/backend/playlists"
	"github.com/zarz/spotiflac_android/backend/settings"
	"github.com/zarz/spotiflac_android/backend/sync"
)

// newHandler wires the complete backend (routes + CORS). Split from main so
// tests exercise the exact production wiring.
func newHandler(secret []byte, clock func() time.Time, newID func() string) http.Handler {
	return newHandlerWithCloud(secret, clock, newID, nil)
}

// newHandlerWithCloud is newHandler plus the optional durable/realtime layer
// (Milestone 1). A nil runtime keeps the exact pre-existing behaviour: the
// in-memory stores stay authoritative and the /v1/cloud endpoints report
// 501 rather than pretending to persist.
func newHandlerWithCloud(
	secret []byte,
	clock func() time.Time,
	newID func() string,
	runtime *cloud.Runtime,
) http.Handler {
	if clock == nil {
		clock = time.Now
	}
	mux := http.NewServeMux()

	// /healthz — liveness for load balancers.
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	authStore := auth.NewStore(clock)
	tokens := auth.NewTokenIssuer(secret, "spotiflac-cloud", "spotiflac-mobile", clock)
	authHandler := auth.NewHandler(authStore, tokens)
	authHandler.Routes(mux)

	syncStore := sync.NewStore(clock)
	syncHandler := sync.NewHandler(syncStore)

	// Realtime layer. The hub always exists (single-process fan-out is
	// useful on its own); durable storage and the Redis bridge only when
	// the deployment configured them.
	var (
		hub     *cloud.Hub
		storage cloud.Storage
	)
	if runtime != nil {
		hub, storage = runtime.Hub, runtime.Storage
	}
	if hub == nil {
		hub = cloud.NewHub(nil, clock)
	}
	cloudHandler := cloud.NewHandler(hub, storage, clock)
	cloudHandler.Routes(mux, authHandler.Middleware)

	// Push → sync log + wake the user's other devices. Attached before the
	// handler serves traffic (see sync.Handler.SetObserver).
	if storage != nil || hub != nil {
		syncHandler.SetObserver(cloud.NewSyncObserver(hub, storage))
	}

	syncHandler.Routes(mux, authHandler.Middleware)

	shareService := playlists.NewService(syncStore, clock)
	playlists.NewHandler(shareService).Routes(mux, authHandler.Middleware)

	history.NewHandler(syncStore, history.NewAggregator()).Routes(mux, authHandler.Middleware)

	settings.NewHandler().Routes(mux, authHandler.Middleware)

	backupStore := sync.NewBackupStore(clock, newID)
	sync.NewBackupHandler(backupStore).Routes(mux, authHandler.Middleware)

	return cors(os.Getenv("SPOTIFLAC_CORS_ORIGIN"))(mux)
}

// cors adds permissive CORS headers: the app authenticates with bearer
// tokens (never cookies), so no credentials are involved.
func cors(allowOrigin string) func(http.Handler) http.Handler {
	origin := "*"
	if origins := strings.Split(allowOrigin, ","); len(origins) > 0 && origins[0] != "" {
		origin = strings.TrimSpace(origins[0])
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Access-Control-Allow-Origin", origin)
			w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Api-Key")
			if r.Method == http.MethodOptions {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

func jwtSecret() []byte {
	if secret := strings.TrimSpace(os.Getenv("SPOTIFLAC_JWT_SECRET")); secret != "" {
		return []byte(secret)
	}
	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		log.Fatalf("entropy unavailable: %v", err)
	}
	return raw
}

func envOr(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}
