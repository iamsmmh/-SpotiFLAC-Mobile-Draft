# SpotiFLAC Mobile — Architecture

> Single source for the *shape* of the system. Feature-level state lives in
> [`../STATUS.md`](../STATUS.md); audits in [`history/`](history/); sync design
> in `CLOUD_SYNC.md`; streaming details in [`streaming.md`](streaming.md);
> extension contract in [`extensions.md`](extensions.md); verification gates
> in [`testing.md`](testing.md); release history in [`changelog.md`](changelog.md).

## Layered view

```
                                  ┌───────────────────────────────┐
   UI (screens/widgets)           │  Material 3, Liquid Glass     │
                                  └───────────────┬───────────────┘
   Presentation (Riverpod 3)      │  providers/ — Notifiers,      │
                                  │  family providers, composition│
                                  └───────────────┬───────────────┘
   Engines (pure Dart)            │  engine/ — streaming, smart   │
                                  │  play, replay gain, adaptive  │
                                  │  buffer, RECOMMENDATIONS      │
                                  └───────────────┬───────────────┘
   Core (hexagonal)               │  core/domain (ports/entities) │
                                  │  core/application (managers)  │
                                  │  core/data (bridge adapters)  │
                                  │  core/SYNC (entities/orch.)   │
                                  └───────────────┬───────────────┘
   Services & stores              │  services/ — sqflite stores,  │
                                  │  backup, bridge, ffmpeg,      │
                                  │  search history, caches       │
                                  └───────────────┬───────────────┘
   Platform                       │  Go backend (gomobile AAR/    │
                                  │  XCFramework) + thin Android/ │
                                  │  iOS shells                   │
                                  └───────────────────────────────┘
```

Dependency rules:
- `core/domain` imports nothing outside itself; outer layers depend inward.
- `lib/engine/**` stays Flutter-free (pure Dart) so ranking/normalization
  logic is unit-testable headlessly. (`unreachable_from_main` lint + CI
  `flutter analyze` keep the graph honest — dead code fails the build.)
- UI never calls the Go bridge directly; it goes through services/providers.

## Subsystems

### Playback & streaming (`lib/engine/`, `lib/services/music_player_service.dart`)
Track → Source → Playback Engine: canonical identity (ISRC-first), Smart Play
(local → stream → download&play), provider health scoring with failover,
next-track preloading, per-network quality profiles, adaptive buffering and
gapless/crossfade/ReplayGain policies — feeding one `audio_service` handler
(progressive `UrlSource`). Full DSP chain (Android DynamicsProcessing/EQ)
restores per-session; iOS EQ is unavailable by platform constraint and the UI
says so.

#### Offline audio cache design (deferred — see audit §5)
Progressive streams are currently not persisted. The designed (not yet landed)
increment: a cache-first HTTP source proxy between the player and remote URLs
(content-addressed segments, LRU budget from the existing cache settings,
integrity-checked on finalize). It must not sit on the critical path of the
verified `UrlSource` pipeline, hence it lands only with emulator coverage of
seek/replay/abort cycles.

### Downloads (`core/application/download_manager.dart`, Go `exports_download.go`)
Event-driven queue with priority lanes, hold/resume, retry policy, cooperative
cancellation; transactional **staging → sanity probe → integrity check
(SHA-256/size) → atomic commit**; duplicate detection and user review;
scheduling windows and connectivity gates. Extension providers are isolated
drivers behind `core/domain/ports.dart`; the UI consumes only queue events.

### Library & favorites (`services/library_*`, `providers/library_collections_provider.dart`)
SQLite stores (single-flighted openers, indexed hot paths):
- `library.db` — scanned local files, incremental scan
- `library_collections.db` (v3) — wishlist, loved tracks, playlists(+tracks),
  favorite artists, **favorite albums** (added v3)
- `history.db` — download history
Derived state keeps `Set`/`Map` indexes rebuilt on `copyWith`; backup/restore
round-trips every table as JSON.

### Extensions (Go `extension_*.go`, `core/data/bridge_extension_driver.dart`)
goja-sandboxed JavaScript providers with signed sessions, permission gates
(upgrade confirmation), per-extension cookie jars, rate limiting, priority
ordering, health hooks, and fuzz-hardened manifest/payload parsing. The
extension boundary never performs DRM circumvention; it consumes each
service's authorized API surface.

### Search (Phase 9, this pass)
Provider search (extensions) + **local layer**: persisted query history
(`SearchHistoryStore`, capped 20, case-insensitive dedupe), fuzzy ranking
(`utils/fuzzy_match.dart` — subsequence scorer with contiguity/word-boundary/
coverage signals and diacritics folding), and a suggestions provider fusing
history + loved tracks + favorite artists/albums. All on-device; the Home
"recent" surface renders recent searches (chips) and short-input suggestions.

### Recommendations (Phase 7, this pass)
`lib/engine/recommendations.dart` defines the `RecommendationProvider` port
(no provider hardcoded). The shipped `LocalRecommendationEngine` derives
recently/frequently played, similar artists (favorites + play-weight
affinity) and a deterministic, daily-seeded round-robin discovery mix from
the privacy-first `ListeningStats` and favorites. `RecommendationService`
chains providers fail-open so future remote recommenders (extensions,
backend) override the local shelves per section kind. UI: **For You**
(Library + screen), queue integration via `playTrackList`.

### Cloud sync (Phase 6, this pass)
See `docs/CLOUD_SYNC.md`. Repository pattern: `CloudSyncProvider` port +
NoOp default, LWW+tombstone merge orchestrator with offline outbox, settings
page. Firebase/Supabase/self-hosted adapters register by overriding
`cloudSyncBackendProvider`.

### Player-experience details (Phase 8) — pre-existing
Sleep timer (incl. end-of-track), queue savepoint with resume prompt, audio
focus via audio_session, gapless/crossfade policies with tests. Unchanged by
this pass.

## Data flow examples

**Tapping a For You card**
`ForYouScreen` → `playbackProvider.playTrackList` → Smart Play decision
(local file? → stream URL via provider health/failover → optional download)
→ audio_service handler → `PlaybackStatsObserver` → `ListeningStats`
→ (next For You rebuild reflects it).

**Hearting an album**
`AlbumScreen` bookmark → `toggleFavoriteAlbum` → SQLite write (v3) + state
index refresh → UI updates (Library tile, snackbar) *and* sync outbox hook
(no-op while sync disabled) → next `syncNow()` push (when configured).

**Submitting a search**
search bar → `_performSearch` (dedup, live-search lock) → extension provider
→ result buckets/sort UI; in parallel the committed query →
`SearchHistoryStore` → recent-searches chips + fuzzy suggestions next visit.

## Persistence map

| Store | Tech | Contents |
|---|---|---|
| `library_collections.db` | sqflite (v3) | wishlist, loved, playlists, favorite artists + albums |
| `library.db`, `history.db` | sqflite | local scan, download history |
| shared prefs | prefs | settings snapshots, listening stats, search history, sync outbox/watermarks, engine savepoint |
| `secure_store` | keystore/keychain | provider tokens, future sync credentials |

## Testing & gates
- `python3 scripts/local_quality_gate.py` — 64 static checks (structure,
  i18n, hygiene), toolchain-free.
- CI: `flutter analyze` (strict casts/inference/raw types,
  `unreachable_from_main`), `flutter test`, `go vet`, `go test -race`,
  **`staticcheck ./...` (pinned 2026.2.1, zero-findings policy)**,
  gomobile builds, nightly Go fuzzing, weekly emulator smoke.
- `scripts/release_gate.py` — version/feed/i18n debt gates.
- New-code coverage in this pass: fuzzy matcher, recommendation engine +
  profile mapping, sync orchestrator, search history store, favorite-album
  identity/state logic.

## Crash & failure monitoring (Phase 10)

`lib/core/monitoring/crash_reporter.dart` is a dependency-free,
Sentry-envelope-compatible reporter (`package:http` only):

- **Opt-in by DSN** — `--dart-define=SPOTIMUSIC_SENTRY_DSN=…` or the
  remote-config `crash_reporting_dsn` field (cached copy; no network on the
  cold-start path). No DSN → every entry point is a no-op. The DSN never
  ships in the binary.
- **Taxonomy** — events are tagged `playback` / `streaming` / `download` /
  `provider` / `extension` / `library` / `native` / `ui` / `app`; wired
  hooks cover the zone handler, `FlutterError.onError`,
  `platformDispatcher.onError`, player start/runtime failures, full provider
  chain exhaustion, download-queue restore failures and native worker
  crashes.
- **Self-protection** — bounded queue, sliding-window rate limit, retry with
  backoff only for 429/5xx/network, auto-disable on 401/403, per-attempt
  timeout, recursive redaction of token/secret/cookie/credential keys, and
  length caps on every payload string. Reporting can never throw into the
  app; swapping in `sentry_flutter` later is a drop-in (same DSN, tags,
  fingerprints, breadcrumbs).

## Error-handling convention (Phase 9)

- Async paths in `lib/services`, `lib/providers` and the playback surfaces
  **never swallow silently**: best-effort steps log at debug level
  (`_log.d('best-effort step failed: $e')`), user-visible failures log at
  warn/error and are surfaced through the UI's error routes.
- `lib/core` and `lib/engine` stay logger-free (pure Dart, injected ports);
  deliberate swallows there must carry an explanatory comment (rollback
  guards, idempotent deletes, fail-open parsers) — enforced by review, and
  audited in `docs/PRODUCTION_READINESS_2026-09-06.md`.
- Widget `dispose()` guards may swallow quietly (teardown must never throw).

## Provider health persistence (Phase 3)

Streaming provider health metrics (success/failure counts, latency, last
outcome, last error) survive restarts via
`lib/services/provider_health_store.dart` (SharedPreferences, debounced
writes, schema-versioned, corrupt-snapshot tolerant). Circuit-breaker
cooldowns deliberately do **not** survive: a restored provider is always
available in a fresh session so a stale outage flag can never hide a
recovered service. Live in-session observations always beat restored rows.

## i18n pipeline
ARB template (`app_en.arb`) → gen-l10n generated classes (committed) →
Crowdin sync workflow; untranslated keys fall back to English inside the
generated locale classes. English-first *staged* strings
(`staged_strings.dart`) are budget-capped (70) by the release gate; new
surfaces must prefer real ARB keys (this pass added 30, fully generated-
consistent).
