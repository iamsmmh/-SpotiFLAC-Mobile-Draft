# SpotiFLAC Ecosystem

This document describes the **ecosystem layer**: the optional features that turn
SpotiFLAC from a downloader/player into a complete music platform, and — just as
importantly — how they are layered so that none of them can break the parts the
app already does well.

Everything here is **additive**:

* no existing download, streaming, playback, metadata, lyrics, library or
  extension flow was rewritten;
* no new runtime dependency was added to `pubspec.yaml` (all backends are plain
  REST over `package:http`, so there is no Firebase/Supabase native SDK in the
  Android or iOS build);
* with no backend configured the app behaves exactly as before — accounts fall
  back to guest mode, recommendations fall back to the on-device engine, and
  history/favorites/insights keep working locally.

---

## 1. Layering

```
lib/screens/ecosystem/*        UI (hub + account, favorites, history,
                                analytics, sync console)
        │  Riverpod
lib/providers/ecosystem_providers.dart
        │
lib/ecosystem/**               domain + data + application
   ├── account/                Group 1  – accounts
   ├── sync/                   Group 2  – synchronization
   ├── favorites/              Group 3  – favorites ecosystem
   ├── history/                Group 4  – listening history (+ Group 12
   │                                      insights/recap)
   └── recommendations/        Group 5  – recommendation providers
        │
lib/core/sync/**               pre-existing ports (CloudSyncProvider,
                               SyncOrchestrator, SyncRecord) — reused, extended
```

Dependencies point inward, exactly like `lib/core`:

| Layer | Knows about | Never knows about |
|---|---|---|
| `ecosystem/*_models.dart` | Dart only | Flutter, I/O, HTTP |
| adapters (`auth_adapters.dart`, `cloud_sync_adapters.dart`) | HTTP + their backend | Riverpod, widgets |
| services (`account_service.dart`, `sync_engine.dart`) | ports | concrete backends |
| providers | Riverpod + services | platform channels |
| screens | providers | SQL |

New tables live in their own SQLite file (`ecosystem.db`) so a migration can
never lock or corrupt `app_state.db`, `library.db`, `collections.db` or
`history.db`. See [SCHEMA.md](SCHEMA.md).

---

## 2. Feature groups

| # | Feature | Status | Where |
|---|---|---|---|
| 1 | Cloud account system | ✅ core done | `ecosystem/account/*`, `screens/ecosystem/account_page.dart` |
| 2 | Cloud synchronization | ✅ core done | `ecosystem/sync/*`, `screens/ecosystem/cloud_sync_console_page.dart` |
| 3 | Favorites ecosystem | ✅ done | `ecosystem/favorites/*`, `screens/ecosystem/favorites_page.dart` |
| 4 | Listening history | ✅ done | `ecosystem/history/*`, `screens/ecosystem/history_page.dart` |
| 5 | Recommendation engine | ✅ extended | `ecosystem/recommendations/*`, `engine/recommendations.dart` (pre-existing) |
| 6 | Smart playlists | ⏳ designed | schema + codec shipped; builder pending |
| 7 | Streaming cache | ⏳ designed | `ec_stream_cache` schema shipped; manager pending |
| 8 | Smart offline mode | ⏳ designed | `ec_offline_collections` schema shipped; manager pending |
| 9 | Podcast platform | ⏳ designed | `ec_podcast_*` schema + sync payload shipped; RSS/service pending |
| 10 | Music identification | ⏳ designed | `ec_recognition_history` schema shipped; providers pending |
| 11 | Social features | ⏳ designed | `ec_social_cache` schema + shared-playlist codec shipped; provider pending |
| 12 | Analytics dashboard | ✅ done | `ecosystem/history/listening_insights.dart`, `screens/ecosystem/analytics_page.dart` |

Groups 6–11 have their storage, wire contracts and conflict-handling story in
place (so nothing has to be migrated later); their application services and UI
are the remaining work and are tracked as follow-ups.

---

## 3. Group 1 — accounts

One port, four adapters:

```dart
abstract interface class AuthProvider {
  String get id;                       // firebase | supabase | selfhosted | anonymous
  Set<AuthMethod> get supportedMethods;// email | google | apple | anonymous
  bool get isConfigured;
  Future<AccountSession> signInWithEmail(...);
  Future<AccountSession> signUpWithEmail(...);
  Uri? oauthStartUrl(AuthMethod, {required String redirectUri});
  Future<AccountSession> completeOAuth(AuthMethod, Uri callback);
  Future<AccountSession> signInAnonymously();
  Future<AccountSession> restoreSession(StoredCredentials);
  Future<AccountSession> refreshSession(AccountSession);
  Future<void> signOut(AccountSession?);
}
```

* **`AnonymousAuthAdapter`** — always registered. Local guest profile, no
  network, full functionality. This is what makes every other account surface
  optional.
* **`FirebaseAuthAdapter`** — Identity Toolkit + Secure Token REST. Needs only
  the web API key. Google/Apple mint an ID token in the browser, then post to
  `accounts:signInWithIdp`.
* **`SupabaseAuthAdapter`** — GoTrue REST (`/auth/v1/token`, `/auth/v1/signup`,
  `/auth/v1/authorize`).
* **`SelfHostedAuthAdapter`** — every path is configurable
  (`SelfHostedAuthConfig`), implementing the contract in
  [API_CONTRACTS.md](API_CONTRACTS.md).

**Token handling.** Access/refresh tokens and the encoded profile go to the
platform keystore through the existing `SecureStore`
(`spotiflac.token.account.<provider>.<field>`, so `SecureStorePolicy` accepts
them). A non-secret profile mirror is written to `ec_account_state` so the
account page can paint before a locked keystore unlocks. Nothing is ever written
to `SharedPreferences` or SQLite in clear text.

**Session persistence.** `AccountService.restoreSession()` runs once at startup
(`main.dart`) and silently restores the last session; expired credentials
refresh; a refresh failure degrades to signed-out with a re-login prompt rather
than an error screen.

> Registering a backend is a one-line change at composition time:
> `ref.read(accountServiceProvider).register(FirebaseAuthAdapter(apiKey: …))`.

---

## 4. Group 2 — synchronization

The pre-existing `core/sync` primitives are reused, not replaced:

* `SyncOrchestrator` — deterministic conflict resolution + offline outbox;
* `CloudSyncProvider` — the backend port;
* `SyncRecord` — the wire record.

Added on top:

* **scopes** — `favorites`, `playlists`, `settings`, `history` (pre-existing)
  plus `queueState`, `downloadPreferences`, `podcasts`, `social`
  (`SyncScopeDescriptor` carries the UI copy and the defaults; `social` is off
  by default);
* **payload codecs** — `sync/sync_payloads.dart` (favorites, history, queue
  snapshot, podcasts, shared playlists);
* **backend adapters** — `FirebaseSyncAdapter` (Firestore REST),
  `SupabaseSyncAdapter` (PostgREST upsert), `SelfHostedSyncAdapter`;
* **the engine** — `sync/sync_engine.dart`:

```
runCycle(trigger)
  ├─ network gate (offline / metered policy)
  ├─ for each enabled scope:
  │     pull(since watermark) → orchestrator.mergeRemote → apply
  │     orchestrator.pendingPush → push → acknowledgePush
  │     on transient failure: capped exponential backoff, then give up
  │     on SyncAuthException: abort the cycle (retrying cannot help)
  └─ stats: cycles, pushed, pulled, conflicts, consecutive failures, next retry
```

Scheduling: periodic `Timer` (default 15 min), a connectivity listener that
fires when the link comes back, and a debounce for local writes
(`notifyLocalChange()`). Failure is never fatal — the outbox is durable, so a
failed cycle only costs a retry.

---

## 5. Group 3 — favorites

`FavoritesIndex` is a **read-only projection** over the existing collections
store (loved tracks, favorite albums, favorite artists) plus the new
favorite-playlists table. Nothing is duplicated, so the hearts everywhere in the
app keep writing to one place.

The projection buys:

* one search box over all four kinds (token-indexed, not a per-keystroke scan);
* sorting by recently added / oldest / title / artist / most played;
* filtering by kind;
* a single sync identity (`FavoriteEntry.key` is the same key the sync layer
  already uses).

---

## 6. Groups 4 & 12 — history, insights, recap

* `ec_listening_events` — append-only events (played ms, duration, skipped,
  source, timestamps);
* `ec_track_history` — per-track aggregate maintained in the **same
  transaction** as the event (play count, skip count, total played, completion
  average, first/last played).

Aggregation uses read-modify-write rather than `ON CONFLICT … DO UPDATE`, because
Android API 24 ships SQLite 3.9 which predates upsert (3.24).

`InsightsCalculator` is pure: it turns a window of events into totals, top
artists/albums/tracks, minutes per day, an hourly histogram, streaks, and a
yearly recap (milestones + minutes per month). The analytics page renders it;
the recap reuses the same code with a 365-day window.

---

## 7. Group 5 — recommendations

The pre-existing `RecommendationProvider` port and `LocalRecommendationEngine`
are untouched. New providers chain ahead of them
(`RecommendationRegistry.build()`):

1. **`CloudRecommendationProvider`** — POSTs the profile to a configurable
   endpoint; fails open (an empty list means "nothing right now", not an error).
2. **`SimilarityRecommendationProvider`** — on-device content similarity: every
   track becomes a TF-weighted feature vector (artist, album, title, genre,
   decade, duration bucket) and neighbours are ranked by cosine similarity;
   artist similarity is centroid-to-centroid.
3. **`DailyMixProvider`** — deterministic per-day rotation
   (`rotationFor(dailySeed, mixIndex)`), stable within a day.
4. **`LocalRecommendationEngine`** — always last, always available.

---

## 8. Testing

`flutter test` covers the pure layers without touching SQLite or a platform
channel:

| Test | Covers |
|---|---|
| `test/ecosystem_migrations_test.dart` | migration plan, statement shape, schema completeness |
| `test/ecosystem_favorites_test.dart` | index build, search, filtering, all five sort orders, JSON |
| `test/ecosystem_insights_test.dart` | completion rules, aggregation, streaks, recap, trends |
| `test/ecosystem_account_test.dart` | session expiry, credential round-trip, keystore namespacing, guest mode, sign-out |
| `test/ecosystem_sync_engine_test.dart` | offline/metered gating, retries with backoff, auth abort, scope filtering, overlap guard |

## 9. Follow-ups (Groups 6–11)

Each remaining group has its tables, wire codecs and conflict handling already
shipped; what is left is the application service plus its page:

1. **Smart playlists (6)** — `SmartPlaylistEngine` materializing definitions
   (`ec_smart_playlist_state`) from history + favorites on a cache-invalidation
   signal.
2. **Streaming cache (7)** — `StreamCacheManager` over `ec_stream_cache`:
   write-through on stream completion, LRU eviction under a byte cap, format
   aware (FLAC/AAC/MP3/Opus), plus an optional localhost proxy for players that
   only accept HTTP sources.
3. **Smart offline (8)** — `OfflineManager` over `ec_offline_collections`:
   per-collection auto-sync, network-aware re-download of missing tracks through
   the existing download queue.
4. **Podcasts (9)** — RSS parsing (`package:xml` is already a dependency),
   iTunes search, episode playback through `PlayableMedia` (which already
   accepts remote URLs), progress sync.
5. **Identification (10)** — `RecognitionProvider` chain (remote fingerprint
   service + on-device fallback) writing to `ec_recognition_history`, then
   "open in app" through the existing search pipeline.
6. **Social (11)** — `SocialProvider` port with a disabled default; sharing a
   playlist works today through `share_plus` + the existing `spotiflac://`
   deep-link handling, and the follower/activity surfaces plug into the same
   port once a backend exists.
