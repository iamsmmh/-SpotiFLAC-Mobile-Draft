# FIX_REPORT.md

Scope: complete the existing SpotiFLAC-Mobile (`spotiflac_android`) app and remove
production-blocking defects, **without rewriting the app or redesigning its
architecture**. Every change below is additive or corrective; no working
feature was removed.

Branch: `arena/01a068ad-spotiflac-mobile` (base `404152f`)
PR: https://github.com/iamsmmh/SpotiFLAC-Mobile/pull/34

---

## Verification status legend

| Mark | Meaning |
| --- | --- |
| ✅ verified | Confirmed by a green CI job on this branch |
| ⚠️ fixed, CI pending | Code is in the branch but the confirming job has not run yet |
| 🔍 audited, no change needed | Reviewed; existing implementation already correct |

No Dart/Flutter toolchain exists in the authoring sandbox, so **every** claim of
correctness here comes from GitHub Actions (`ci.yml`, `build-mobile.yml`),
not from a local run.

---

## Priority 1 — Streaming (`streaming_engine.dart`, `multi_provider_stream_service.dart`, `streaming_engine_provider.dart`)

### What was missing before

| Gap | Before | Now |
| --- | --- | --- |
| Apple Music provider | stub — always returned "no token" | `AppleMusicStreamHandler` resolves the AMP/playback API, anonymous public token fetch, track search, 30-second preview, structured "requires developer token" miss |
| Amazon Music provider | stub | `AmazonMusicStreamHandler` (AMAPI: `enqueue`/`mandatory` → HLS/stream URL, anonymous `atv-uts` device token) |
| Deezer provider | stub | `DeezerStreamHandler` (gw-light gateway, `deezer.pageTrack` fallback, ISRC lookup, preview/ARC), with `postJson` support for the GET-refusing endpoints |
| Provider health tracking | none | `StreamProviderHealth` + `StreamProviderHealthRegistry`: success/failure counters, consecutive-failure streak, exponential cooldown (2nd failure onward, capped at 15 min), bounded JSON snapshot for diagnostics |
| Stream validation | none | `StreamValidator` / `HttpStreamValidator`: 1-byte ranged GET, HTML/JSON error-page rejection, latency + content-length reporting, timeout, unsupported-scheme guard |
| Result caching | none | `StreamResolutionCache`: LRU (128 entries), positive entries expire with the signed URL (5-minute lead; 30-minute fallback), 45-second **negative** caching, per-provider invalidation |
| Adaptive bitrate | none | `StreamVariant` + `AdaptiveBitrateMode/Decision/Selector` (balanced / quality-first / data-saver, network-ceiling aware), wired end-to-end: `StreamingEngineController` publishes the selector + live `BandwidthMonitor` bytes/sec into the service on every candidate query |
| Buffering / stall recovery | none | `StreamRecoveryPolicy` / `StreamRecoveryContext` / `StreamRecoveryBudget` (stall timeout 8 s → re-resolve → failover; bounded to 3 attempts inside a 5-minute sliding window), consumed by `MultiProviderPlayer` |
| Stream-expiry recovery | none | `nextRefreshAt` / `forExpiry`: proactive refresh 2 minutes before expiry with a separate, non-consuming refresh budget; `MultiProviderPlayer` schedules it and re-resolves + seeks back to the last position |
| Playback resume | none | `StreamResumePoint` (recorded every 5 s, LRU-capped at 64, 7-day freshness) and `MultiProviderPlayer.play(startAt: …)` |
| Duplicate provider traffic | none | In-flight coalescing map keyed by `provider|isrc-or-query` |

### Bugs found and fixed in the new streaming code

1. **Negative caching was dead code.** `StreamResolutionCache.get()` removed the
   entry from the backing map before checking whether it was a *positive* entry.
   Because `resolveStream()` always calls `get()` first, every lookup destroyed
   the negative entry that `negativeError()` was supposed to read — so a track
   with no source anywhere re-walked the full provider chain on every request
   (a scrolling list hammering dead providers). `get()` now only consumes
   entries it can actually serve. ✅
2. **The cache clock was not injectable.** `_CacheEntry` stamped `storedAt`
   with `DateTime.now()` instead of the cache's clock, so the 30-minute
   "unknown expiry" TTL and the negative TTL were untestable and drifted from
   the injected clock. `put`/`putNegative` now stamp `_clock()`. ✅
3. **`_publishAdaptiveBitrate()` instantiated the provider chain on every
   candidate query**, including queues that never use the ladder adapter. It now
   takes the already-read adapter list and returns early unless a
   `MultiProviderStreamAdapter` is registered. ✅
4. Nullability/format defects reported by the analyzer
   (`return_of_invalid_type_from_closure`, `unnecessary_brace_in_string_interps`)
   fixed. ✅

### Audited, no change needed 🔍

Provider ranking, preflight with bounded failover, bandwidth monitoring,
preloading, head warming, integrity logging, diagnostics, and the playback
failure hook (`_handlePlaybackFailure`: re-resolves candidates, excludes the
failed URI, records integrity, resumes at the last known position) were already
implemented and correct.

---

## Priority 2 — Queue engine (`lib/core/application/queue_engine.dart`)

| Defect | Fix |
| --- | --- |
| `enqueueAll` inserted one-by-one → O(n²) list shifts for large playlists | Batch append + single sort; import of a 5,000-track playlist is O(n log n) |
| `enqueue` could mint a second id for the same spec | The resolved id is pinned with `spec.copyWith(jobId: id)` before the batch call |
| Pending insertion was a linear scan | Binary search over the static `_comparePending` |
| **`drained` and `QueueEmptied` fired while a retry was sitting in its backoff** — a caller awaiting `drained` resumed with zero work in flight and a job still to come | `_armedRetries` counter + `_disarmRetry()`: armed retries count as pending work, so drain/emptiness only fire when the queue is genuinely idle |
| **Queue corruption**: `clearFinished()` and finished-ring eviction removed entries from the id index by id only, so a *stale* terminal row could delete the index entry of a live job that re-used the same id (job becomes invisible to cancel/pause while still running) | `_archiveFinished` / eviction / `clearFinished` are identity-guarded (`identical(_index[id], entry)`), and a terminal row is dropped from the finished ring *before* its replacement is installed |
| Progress could rewind when a worker restarted an internal phase | Progress is monotonic per job |

UI-facing fix in `download_queue_provider.dart`: keeps the engine's retry/queue
state visible instead of collapsing to "empty" mid-backoff.

---

## Priority 3 — Audio playback (`lib/services/music_player_service.dart`)

* **Shuffle cycle never ended** and could crash on single-track queues: a new
  `_shufflePlayed` set is the cycle memory, `_pickNextShuffle()` returns `int?`
  (removing the crash path), and playback stops once every track has played
  unless repeat-all is on.
* Audited 🔍: OS audio session (`AudioSessionConfiguration.music`), interruption
  begin/end handling with resumable vs sticky pause (`BackgroundPlaybackPolicy`),
  `becomingNoisy` (headset/Bluetooth disconnect) handling, session persistence,
  and subscription disposal are all implemented; `dispose()` cancels every
  tracked subscription and the player.

---

## Priority 4 — Download system

* **No corruption gate.** A transport-level success was committed to the library
  even when the payload was an HTML error page, a JSON error body or a truncated
  transfer. `_verifyDownloadedFileIsSane()` now runs after download/decrypt and
  before format handling: it skips SAF `content://`, `http(s)` and pre-existing
  files, then requires `exists()`, `size > 0` and a recognisable audio container.
  On failure `_failAsCorrupt()` deletes the artifact and fails the item with
  `Corrupt download: <reason>` so the queue's retry path fetches it again.
* Container detection (`lib/core/data/audio_sanity.dart`) now recognises
  **WebM/EBML** (`1A 45 DF A3`), which YouTube/Opus streams use — without it the
  gate would reject legitimate Opus downloads.
* Audited 🔍: retry, pause/resume, cancellation, FFmpeg processing, metadata
  writing, ReplayGain, album + playlist downloads all present and wired.

---

## Priority 5 — FFmpeg (`lib/services/ffmpeg_service.dart`)

* **Temp-file leak**: the staged temp file was not cleaned up when writing the
  ReplayGain tags threw inside `onTempReady`. `_deleteTempQuietly()` is now
  called on that path (no orphan files in the temp directory).

---

## Priority 6 — Native Android (`NativeDownloadFinalizer.kt`, `NativeFinalizationPolicy.kt`, `NativeFinalizerFFmpeg.kt`)

Audited 🔍. Native finalization already uses staged outputs, `try/finally`
cleanup, mandatory FFmpeg result delivery and lifecycle-safe error handling;
no TODO/FIXME remains in the Kotlin sources. The 6 JVM policy tests under
`android/app/src/test/kotlin/` pass in CI (job `Android compile & native tests`,
✅ verified on run 33799261394).

---

## Priority 7 — iOS

Verified (not changed):

* **iOS 15+**: `ios/Podfile` declares `platform :ios, '15.0'` and all three
  build configurations in `project.pbxproj` set
  `IPHONEOS_DEPLOYMENT_TARGET = 15.0`.
* **CocoaPods**: the project uses CocoaPods exclusively — no
  `XCRemoteSwiftPackageReference` in the Xcode project, so Swift Package
  Manager compatibility is not a dependency of this build (Flutter's plugin
  toolchain is CocoaPods here; `pod install --repo-update` succeeds in CI).
* **Unsigned IPA**: produced by `build-mobile.yml` (archive with
  `--no-codesign`, `Payload` zip, `_CodeSignature`/provisioning stripped).
  ✅ verified on run 33799261375.
* **UIScene: NOT adopted** — `AppDelegate` is a classic `@main FlutterAppDelegate`
  and there is no `UIApplicationSceneManifest` / `SceneDelegate`. This is only a
  console warning under the iOS 26 SDK (the app launches normally, which the
  green archive confirms), but Apple turns it into a **launch assertion when
  building with the iOS 27 SDK**. Recommended follow-up: re-template the iOS
  folder with the pinned Flutter (3.44.8, which makes UIScene the default) and
  re-apply the project customisations; it was deliberately **not** hand-written
  here because it cannot be validated without a device run.

---

## Priority 8 — Repository cleanup

* No `TODO` / `FIXME` / placeholder / stub remains in `lib/` or `test/`.
* The only intentional placeholders left (both are deliberate extension points,
  not dead code):
  * `UnconfiguredDownloadManager` — the no-backend fallback used until the Go
    backend is bound.
  * `coreBridgePayloadBuilderProvider` returning `null` — disables the optional
    core bridge payload.
* Nothing was deleted without proof of being unused.

---

## Priority 9 — Testing

Seven new test files (see `TEST_REPORT.md`):

`test/streaming_provider_health_test.dart`, `test/streaming_resolution_cache_test.dart`,
`test/streaming_failover_test.dart`, `test/stream_validation_test.dart`,
`test/adaptive_bitrate_test.dart`, `test/queue_engine_regression_test.dart`,
`test/database_migration_policy_test.dart`.

---

## Known remaining gaps (honest list)

1. **No proactive URL-expiry ticker in the Riverpod playback path.**
   `MultiProviderStreamAdapter` emits `kind: httpStream`, and
   `StreamUrlRefreshPolicy.shouldRefresh` only handles
   `authorizedStream` / `extensionStream` — an existing test
   ("never refreshes plain HTTP preview sources") pins that behaviour. Expiry is
   therefore covered reactively instead: the resolution cache expires entries
   5 minutes before the URL dies, each play re-resolves, and the playback
   failure hook re-resolves and resumes at the last position. A proactive
   ticker would require changing that pinned policy.
2. **Stall recovery exists in `MultiProviderPlayer` but the app's own player
   path reacts to failures, not to a silent buffer stall.** Adding a watchdog
   needs a position-stream subscription in the audio service; it was left out
   rather than shipped unverified.
3. Addressed: commit `83b9c28` (the two cache fixes + test corrections) is
   verified green — `flutter analyze` clean and `flutter test` fully passing
   (CI run 33804227296, see `TEST_REPORT.md`).
