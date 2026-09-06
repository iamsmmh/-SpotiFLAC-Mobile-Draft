// Package cloud is the durable, horizontally-scalable half of SpotiFLAC
// Cloud (Milestone 1).
//
// The existing in-memory `auth.Store` / `sync.Store` remain the default and
// the reference semantics: every type here is an *optional* backing store
// that implements the same operations against PostgreSQL, plus the Redis
// fan-out and WebSocket transport a multi-process deployment needs.
//
// # Zero third-party dependencies
//
// The whole package is stdlib-only, deliberately:
//
//   - PostgreSQL is reached through `database/sql`, which is stdlib. The
//     *driver* is injected by the deployer (`cloud.OpenPostgres` takes an
//     already-open `*sql.DB`, or a driver name the binary registered), so
//     this module keeps an empty `go.mod` and stays inside the repository's
//     zero-dependency CI gates (`go vet`, `staticcheck`, `go test -race`).
//   - Redis speaks RESP2 over a plain `net.Conn` (see redis.go).
//   - WebSocket is a from-scratch RFC 6455 server over `http.Hijacker`
//     (see websocket.go).
//
// That choice is what makes the code in this package verifiable by CI
// instead of an unbuildable nested module.
//
// # Layout
//
//	storage.go     the storage ports (interfaces) + shared errors
//	schema.sql     PostgreSQL DDL, indexes and constraints
//	postgres.go    database/sql implementation of the ports
//	redis.go       minimal RESP2 client + pub/sub
//	websocket.go   RFC 6455 server framing
//	hub.go         per-user event hub (local fan-out + Redis bridge)
//	events.go      the event envelope shared by hub and clients
//	continuity.go  cross-device playback continuity
package cloud
