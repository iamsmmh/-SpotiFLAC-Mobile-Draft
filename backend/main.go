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
// State is in-memory: this binary is the reference implementation of the
// contract in docs/API_CONTRACTS.md; for durability back the stores with
// Postgres using server/schema.sql.
package main

import (
	"log"
	"net/http"
	"time"

	"github.com/zarz/spotiflac_android/backend/auth"
)

func main() {
	secret := jwtSecret()
	handler := newHandler(secret, time.Now, auth.NewUserID)

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
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	log.Fatal(server.ListenAndServe())
}
