# Ecosystem API contracts

Every backend is reached over plain HTTPS with JSON. There is no SDK, no
protobuf and no native plugin, so the same contract works for Firebase,
Supabase and a self-hosted server — and the app can be pointed at a different
backend without a rebuild.

Common rules for **all** endpoints:

* `Authorization: Bearer <access token>` when the user is signed in;
  401/403 from the server maps to `AuthUnauthorizedException` /
  `SyncAuthException` and triggers a refresh or a re-login, never a retry loop.
* Errors are JSON: `{"error": {"message": "…"}}` or `{"message": "…"}` or
  `{"error_description": "…"}`. Anything else is treated as a transport error.
* Timeouts default to 15 s (auth) / 8 s (recommendations).

---

## 1. Authentication

### 1.1 Firebase (built-in)

| Operation | Request |
|---|---|
| Sign in | `POST https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=<apiKey>` — `{email, password, returnSecureToken: true}` |
| Sign up | `POST …/accounts:signUp?key=<apiKey>` — same body |
| Refresh | `POST https://securetoken.googleapis.com/v1/token?key=<apiKey>` — form `grant_type=refresh_token&refresh_token=…` |
| Google/Apple | `POST …/accounts:signInWithIdp?key=<apiKey>` — `{postBody: "id_token=<token>&providerId=google.com|apple.com", requestUri, returnSecureToken: true}` |

OAuth client ids are supplied by configuration (`googleClientId`,
`appleClientId`); without them the corresponding button is hidden.

### 1.2 Supabase (built-in)

| Operation | Request |
|---|---|
| Password grant | `POST {base}/auth/v1/token?grant_type=password` — `{email, password}` |
| Sign up | `POST {base}/auth/v1/signup` — `{email, password}` |
| OAuth start | `GET {base}/auth/v1/authorize?provider=google|apple&redirect_to=<uri>` |
| OAuth exchange | `POST {base}/auth/v1/token?grant_type=pkce` — `{auth_code}` **or** `?grant_type=id_token` — `{provider, id_token}` |
| Refresh | `POST {base}/auth/v1/token?grant_type=refresh_token` — `{refresh_token}` |
| Profile | `GET {base}/auth/v1/user` |
| Sign out | `POST {base}/auth/v1/logout` |

Requests carry the `apikey` header (anon key).

### 1.3 Self-hosted (reference contract)

Paths are configurable via `SelfHostedAuthConfig`; defaults below.

```http
POST /v1/auth/email
{ "email": "user@example.com", "password": "…" }
```
```http
POST /v1/auth/register
{ "email": "…", "password": "…" }
```
```http
POST /v1/auth/oauth
{ "provider": "google", "code": "…", "redirect_uri": "spotiflac://oauth" }
```
```http
POST /v1/auth/refresh
{ "refreshToken": "…" }
```
```http
GET  /v1/auth/me
POST /v1/auth/logout
```

All of them answer with the same session object:

```json
{
  "accessToken": "…",
  "refreshToken": "…",
  "expiresIn": 3600,
  "user": {
    "id": "…",
    "email": "…",
    "displayName": "…",
    "avatarUrl": "…"
  }
}
```

The client also accepts flat variants (`{id, email, name, photoUrl}`) and
Firebase-style field names (`idToken`, `localId`) so a thin shim in front of an
existing identity provider is enough.

#### Devices (Phase 3, reference backend)

```http
POST   /v1/auth/devices            { "deviceId": "…", "name": "…", "platform": "android" }
GET    /v1/auth/devices            → { "devices": [ { "id", "name", "platform", "lastSeenAt" } ] }
DELETE /v1/auth/devices/{deviceId}
```

Registration is an upsert keyed by `deviceId`; a deployment keeps at most 32
devices per user (LRU eviction). Revoking a device also invalidates its
refresh tokens.

---

## 2. Synchronization

A sync record is identical across backends:

```json
{
  "scope": "favorites",
  "recordId": "isrc:USRC17607839",
  "revision": 7,
  "updatedAt": "2026-09-05T12:00:00.000Z",
  "deleted": false,
  "payload": { }
}
```

Conflict rule (deterministic on every device, implemented by
`SyncOrchestrator.resolve`):

1. a tombstone wins over a live record when its `updatedAt` is newer or equal;
2. otherwise the newer `updatedAt` wins;
3. equal timestamps → the higher `revision` wins;
4. still equal → the records are identical by contract.

### 2.1 Self-hosted

```http
POST /v1/sync/pull
{ "scope": "favorites", "sinceRevision": 42 }

200 { "records": [ { …SyncRecord… } ] }
```

```http
POST /v1/sync/push
{ "scope": "favorites", "records": [ { …SyncRecord… } ] }

200 { "revisions": { "isrc:USRC17607839": 8 } }
```

```http
GET  /v1/sync/me   →  { "userId": "…", "providerId": "selfhosted" }
```

`push` must be idempotent per `recordId` — the client re-sends the same
revisions after a network failure.

### 2.2 Supabase

Table `sync_records` (see `server/schema.sql`):

```http
GET  {base}/rest/v1/sync_records?select=*&user_id=eq.<uid>&scope=eq.favorites&revision=gt.<since>&order=revision.asc&limit=1000
POST {base}/rest/v1/sync_records      # Prefer: resolution=merge-duplicates,return=representation
```

### 2.3 Firebase

Collection `users/{uid}/sync_{scope}` via the Firestore REST API:

```http
GET  https://firestore.googleapis.com/v1/projects/<p>/databases/(default)/documents/users/<uid>/sync_favorites?pageSize=500&orderBy=revision
POST https://firestore.googleapis.com/v1/…/sync_favorites?documentId=<recordId>
```

Values use Firestore's typed wire format (`stringValue`, `integerValue`, …);
the adapter encodes and decodes it (`_encodeValue` / `_decodeValue`).

---

## 3. Recommendations

```http
POST /v1/recommendations
{
  "dailySeed": 20671,
  "maxItemsPerSection": 20,
  "plays":          [ { "trackId": "…", "title": "…", "artist": "…", "album": "…", "playCount": 12, "listenedMs": 1234567, "lastPlayedAt": "…" } ],
  "favoriteArtists":[ { "id": "…", "name": "…", "kind": "artist" } ],
  "lovedTracks":    [ { "trackId": "…", "title": "…", "artist": "…", "album": "…" } ]
}

200 {
  "sections": [
    {
      "kind": "similarTracks",            // recentlyPlayed | frequentlyPlayed |
                                          // similarArtists | similarTracks |
                                          // discoveryMix | trending
      "title": "Because you like…",
      "items": [
        { "itemKind": "track", "id": "…", "title": "…", "subtitle": "…",
          "imageUrl": "…", "providerId": "…", "score": 0.87 }
      ]
    }
  ]
}
```

Anything else (non-2xx, malformed body, timeout) is treated as "this provider
has nothing right now": the app silently falls through to the on-device
engines. A recommendation service can therefore be deployed, crashed or
unconfigured without ever producing an error dialog.

---

## 4. SpotiFLAC Cloud services (Phase 3, reference backend)

Implemented by the Go module in `backend/` (in-memory reference) and expected
of any durable deployment backed by `server/schema.sql`. All responses use the
common error envelope `{"error":{"message":"…"}}`.

### 4.1 Playlist sharing

```http
POST   /v1/playlists/share          { "recordId": "pl-1", "payload": { …playlists record… } }
200/201  →  { "share": { "slug": "pl_…", "urlPath": "/s/pl_…", "recordId": "pl-1" } }
DELETE /v1/playlists/share/{slug}                     (owner only)
GET    /v1/playlists/shared/{slug}                    (public; QR / deep link)
200    →  { "share": { "slug", "views", "payload": { …playlist… } } }
```

`slug` matches `^pl_[A-Za-z0-9_-]{20,64}$`. Publishing requires the playlists
record to carry `isPublic: true`; resolving re-verifies that the record still
exists and is public, so unpublishing propagates instantly.

### 4.2 Listening-history summary

```http
GET  /v1/history/summary?limit=50     →  { "totalPlays": 123, "tracks": [ … ] }
POST /v1/history/invalidate           (drop the server-side aggregate cache)
```

Tracks merge by stable `trackKey` (`playCount`/`skipCount`/`totalPlayedMs` are
summed, `averageCompletion` keeps the max) and rank by `playCount` desc.
`limit` defaults to 50 and caps at 500.

### 4.3 Settings validation

```http
GET  /v1/settings/schema   →  { "keys": [ …allowlist… ], "maxRecordBytes": 16384 }
POST /v1/settings/validate  { "key": "theme.mode", "value": "dark" }
                            | { "theme.mode": "dark", … }
200 → { "records": [ { "key", "value" } ] }
422 on unknown keys or oversized payloads
```

### 4.4 Backups

```http
PUT    /v1/backup?deviceId=…    raw body (≤ 8 MiB) → 201 { "backup": { "id", "deviceId", "sizeBytes", "sha256", "createdAt" } }
GET    /v1/backup?deviceId=…    →  { "backups": [ … newest first … ] }
GET    /v1/backup/{id}          →  application/octet-stream (+ `X-Backup-SHA256`)
DELETE /v1/backup/{id}
```

A deployment keeps the newest three backups per device; the id embeds the
SHA-256 of the content.

---

## 5. Reserved for follow-ups

These contracts are not implemented yet; they are published here so the storage
and sync layers already match them.

| Group | Endpoint sketch |
|---|---|
| Podcasts (9) | `GET /v1/podcasts/search?q=…`, RSS fetched client-side |
| Identification (10) | `POST /v1/identify` — `{audio, mimeType}` → `{title, artist, album, confidence}` |
| Social (11) | `GET /v1/social/profile/{id}`, `POST /v1/social/playlists`, `GET /v1/social/feed` |
