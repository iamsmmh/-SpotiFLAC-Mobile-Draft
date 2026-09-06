# SpotiFLAC Mobile — Stabilization & Hardening Report

**Date:** 2026-09-06
**Branch:** `arena/01a07597-spotiflac-mobile`
**Baseline commit:** `12c9bc25c04ed24ae6fd46e7187c9256669a2b19`
**Scope:** Static audit + targeted hardening of the entire repository (Flutter/Dart UI, core queue/streaming/download layers, Go backend, Android/iOS native shells, CI).
**Environment:** Flutter 3.44.8 / Dart 3.10 / Go toolchains, pub.dev, and Go module proxies are **not reachable from this sandbox** (only `github.com` and `pypi.org` resolve). All Dart/Go analysis below is therefore *static*. The toolchain-free static quality gate (`scripts/local_quality_gate.py`, 64 checks) is the only executable validation available here and it passes 64/64 after the changes. Builds and test suites must run in GitHub Actions (`ci.yml`, `build-mobile.yml`, `release.yml`) — see sections E–J.

---

## A. Executive summary

SpotiFLAC Mobile is an unusually mature codebase. The repository has already been
through several production-hardening passes (documented in `STATUS.md`,
`docs/stage5_production.md`, and `docs/history/`): playback carries generation
guards against stale async completions, the download pipeline is transactional
(temp file → sanity gate → integrity gate → atomic commit), provider failover is
bounded by recovery policies with exponential backoff, search surfaces protect
against stale responses with request IDs, and the app boot path is layered with
graceful degradation (crash reporter, runtime profile, SAF-loss detection,
deferred initialization).

This pass performed a full static re-audit across the modules named in the brief
(startup, navigation, search, streaming, player state machine, downloads,
offline playback, extensions, failover, storage, concurrency, resources, UI,
Android/iOS shells, Go backend, security, dependencies, CI). The audit
**confirmed** that the majority of previously identified bug classes are fixed
and regression-tested. It additionally found and fixed **five** genuine defects
that remained:

| # | Severity | Location | Defect | Fix |
|---|---|---|---|---|
| 1 | MEDIUM | `lib/services/apk_downloader.dart` | In-app APK updater had **no timeout** of any kind (a stalled connection leaves the update dialog spinning forever), **deleted the last good APK before** the replacement download, and left a **truncated/corrupt APK at the final path** on any interruption | Connect timeout (30 s) + stream inactivity timeout (60 s); download into `*.apk.part`; atomic rename only after a complete body; delete partial artifact on every failure path; never remove the previous APK first |
| 2 | MEDIUM | `lib/screens/settings/extension_detail_page.dart` | `_clearCookies()` swallowed bridge failures and always showed **"Imported cookies cleared"** — a false-success message when the clear actually failed | Error is captured and surfaced (`cookiesImportFailed` copy); success copy only shown on success |
| 3 | LOW | `lib/screens/downloaded_album_screen.dart` | SAF "share" failure was swallowed (`catch (_) {}`) — user taps Share, nothing happens, no feedback | Failure now shows the standard `snackbarCannotOpenFile(friendlyError)` snackbar (guarded by `mounted`) |
| 4 | LOW | `lib/screens/queue_tab_batch_actions.dart` | Same silent SAF share failure in the queue-tab batch share | Same fix as #3 |
| 5 | LOW | `lib/screens/home_tab.dart` | Post-await navigation (`_navigateToDetailIfNeeded`) could use a defunct `BuildContext` if the Home tab was disposed while metadata resolution was in flight | `if (!mounted) return;` guard at method entry (covers all call sites) |

None of the five changes alters the architecture, removes functionality, or
changes correct behavior; each is a targeted fix with a documented root cause.

**Verdict:** PASS (with the environment caveat below) for the audit + applied
fixes; production builds/tests are NOT TESTABLE inside this sandbox and must be
confirmed in CI.

---

## B. Bugs discovered

All bugs listed here were found during this pass. Entries marked *fixed* have a
change applied on this branch; entries marked *deferred* are intentional or
require product/UX decisions and are recorded for completeness.

### B1 — APK updater: unbounded wait + corrupt/partial artifact at final path
- **Severity:** MEDIUM (HIGH for a user on a slow/stalled link during forced update)
- **File:** `lib/services/apk_downloader.dart` (`downloadApk`)
- **Root cause:**
  1. `client.send(request)` and the body `await for` had **no timeout**.
     `update_dialog.dart` has no cancel and its own timeout, so a connection
     that accepts TCP then stalls leaves the dialog in "starting download…"
     forever (no error path is ever reached).
  2. The code did `File(filePath).exists() → delete()` **before** downloading,
     then streamed straight to the final `SpotiFLAC-<version>.apk`. Any error
     or interruption (network drop, process kill, storage full) left a
     truncated APK at the installable path and destroyed the previously
     downloaded good copy.
- **Fix:** `getExternalStorageDirectory` resolved up front; connect timeout
  `30 s`; per-chunk inactivity timeout `60 s` on the response stream; body
  streamed into `SpotiFLAC-<version>.apk.part`; on completion the `.part` file
  is atomically `rename`d over the final path (POSIX rename replaces
  atomically); on any non-success the `.part` file is deleted and the previous
  final APK is left untouched.
- **Test:** Not added in-sandbox (no Flutter toolchain). CI `flutter test`
  would need a new unit test with an injected `http.Client`/stream; the change
  keeps the same public contract (`Future<String?>` returning the final path or
  `null`), so existing callers (`update_dialog.dart`) need no change.

### B2 — Extension cookie clear reports false success
- **Severity:** MEDIUM
- **File:** `lib/screens/settings/extension_detail_page.dart` (`_clearCookies`)
- **Root cause:** `try { … } catch (_) {}` followed by an unconditional
  `"Imported cookies cleared"` snackbar. A bridge/platform failure was silently
  swallowed and the user was told the cookies were cleared when they were not
  (privacy-relevant state).
- **Fix:** capture the error; show `cookiesImportFailed: <error>` when the call
  threw, `cookiesCleared` only on success.
- **Test:** widget-level; would require mocking `PlatformBridge`. Recorded for
  CI; no toolchain in sandbox.

### B3/B4 — SAF share failures are silent
- **Severity:** LOW (UX feedback gap)
- **Files:** `lib/screens/downloaded_album_screen.dart` (`_shareSelected`),
  `lib/screens/queue_tab_batch_actions.dart` (`_shareSelected`)
- **Root cause:** `PlatformBridge.shareContentUri` /
  `shareMultipleContentUris` failures were caught and ignored; when no
  share activity exists (or the provider rejects the grant) the user sees
  nothing happen after tapping Share.
- **Fix:** reuse the file's existing error pattern —
  `snackbarCannotOpenFile(context.friendlyError(e))` behind a `mounted` guard.
- **Test:** widget test in CI (needs bridge mock); no sandbox toolchain.

### B5 — Navigation on a defunct context after async resolution
- **Severity:** LOW (latent crash; depends on timing)
- **File:** `lib/screens/home_tab.dart` (`_navigateToDetailIfNeeded`)
- **Root cause:** `_fetchMetadata()` awaits `fetchFromUrl`/`search` and then, on
  success, calls `_navigateToDetailIfNeeded()`, which uses `Navigator.push(context)`
  with no `mounted` check. If the Home tab is disposed while resolution is in
  flight (user switched away, app backgrounded), pushing on a defunct context
  throws.
- **Fix:** `if (!mounted) return;` at the top of `_navigateToDetailIfNeeded`
  (also protects the second call site at line ~173).
- **Test:** widget test in CI; not runnable in sandbox.

### B6 (deferred, observation) — best-effort cleanup catches
- **Severity:** LOW / informational
- **Files:** ~35 remaining `catch (_) {}` sites in `lib/` (list generated this
  pass: `downloaded_album_screen`, `home_tab_import` (dialog close),
  `local_album_screen`/`queue_tab_batch_actions` per-item re-enrich loops,
  `queue_tab_filter_widgets`, `cache_management_page`, `files_settings_page`,
  `ffmpeg_reenrich`, `logger`, `lyrics_metadata_helper`, `path_match_keys`,
  `audio_analysis_widget` temp-file cleanup, `progress_stream_poller` internals,
  etc.)
- **Assessment:** each reviewed site is either (a) temp-file/notification
  cleanup where a log would add noise, or (b) a per-item loop whose failures are
  already aggregated into the final success/failure summary. **No action
  needed**; two user-visible exceptions (share, cookie-clear) are fixed in
  B2–B4.

### B7 (deferred, observation) — `_FileExistsListenableCache` retry timers after dispose
- **Severity:** LOW / informational
- **File:** `lib/screens/queue_tab_helpers.dart` (`_startCheck` timers)
- **Assessment:** `dispose()` cancels notifiers but not the (≤1.4 s) retry
  timers. After dispose the callbacks only mutate private maps of the dead
  object — no notifier writes, no crash, no leak beyond the timer's own
  lifetime. Safe; not changed to keep the diff minimal.

---

## C. Files modified

| File | Change |
|---|---|
| `lib/services/apk_downloader.dart` | Timeouts, `.part` staging, atomic promote, partial cleanup |
| `lib/screens/settings/extension_detail_page.dart` | Honest cookie-clear result surfacing |
| `lib/screens/downloaded_album_screen.dart` | SAF share failure snackbar |
| `lib/screens/queue_tab_batch_actions.dart` | SAF share failure snackbar |
| `lib/screens/home_tab.dart` | `mounted` guard before post-await navigation |
| `docs/stabilization_report_2026-09-06.md` | This report |

Diff: **5 source files, +90/−18** (excluding the new report).

---

## D. Features validated (static audit matrix)

Audit method: full-file reads of the core layers listed below plus targeted
pattern scans across all 396 `lib/**/*.dart` files (empty catches,
UnimplementedError, TODO/FIXME, `!` bangs, timers/subscriptions/Clients/
Completers, `while(true)` loops, `firstWhere/singleWhere/lastWhere`, secret
patterns) and a secret/dependency/native-config sweep. For each feature the
table records whether the implementation is present and sound under static
review, and whether a fix was required.

| Feature | Implementation reviewed | Status | Fix |
|---|---|---|---|
| App startup | `lib/main.dart` (1026 L), `app.dart`, `_EagerInitialization`, `cold_start_policy`, `secure_store`, runtime profile, SAF-loss detection | Sound — layered degradation, deferred providers, bounded waits | — |
| Navigation | `go_router` shell + `Navigator` screens, `shell_navigation_service`, deep links | Sound; share-subscription cancelled in `dispose` | B5 (mounted guard) |
| Home / search | `home_tab.dart`, `home_search_logic.dart`, `track_provider.dart`, `unified_search*.dart`, search history | Sound — debounce + pending-query coalescing + `_currentRequestId` stale-response guards; URL-vs-text routing | B5 |
| Track/artist/album/playlist screens | `album_screen`, `artist_screen`, `playlist_screen`, recent-access | Sound; post-await context guarded by existing `mounted` checks | — |
| Streaming | `engine/streaming_engine.dart`, `providers/streaming_engine_provider.dart`, `services/multi_provider_stream_service.dart`, `core/streaming/*` | Sound — bounded attempt budgets, preflight validation, expiry-refresh policy, stall recovery ladder | — |
| Audio playback | `services/music_player_service.dart` (2500 L) | Sound — generation counters, `active()` player identity, completion suppression during switch/interruption, crossfade ramp/cancel discipline, session persist tail | — |
| Queue | `core/application/queue_engine.dart`, `core/presentation/core_queue_providers.dart` | Sound — priority lanes, bounded retry, drained/armed-retry accounting, idempotent enqueue, batch O(n log n) | — |
| Seek/pause/resume/prev/next | player service methods | Sound; relative seek clamps at zero and defers past-end to completion policy | — |
| Background playback / lock screen / notification | `audio_service` handler, `background_playback_policy`, `notification_service` | Sound | — |
| Downloads | `download_queue_provider*.dart` (single-item 1911 L), `core/application/download_manager.dart`, native Kotlin `DownloadService*` | Sound — transactional stage→sanity→integrity→commit; pause/cancel/resume hooks; foreground-service lifecycle policy | — |
| Download retry | `retry_policy.dart`, `download_verification_retry_guard.dart`, `download_history_provider.dart` orphan paging | Sound — bounded/backed-off; page-cursor handles fully-orphaned pages | — |
| Offline playback | `library_database`, local scan, orphan cleanup at startup, missing-file repair | Sound (multiple repair/cursor mechanisms with regression tests) | — |
| Library/favorites/history | `ecosystem/favorites`, `history_database`, `listening_insights`, `library_collections_database` | Sound | — |
| Extensions | `extension_engine.dart`, `extension_provider.dart`, Go `extension_*` runtime, cookie/security gates | Sound — isolation, health scoring, priority chain, bounded per-provider retry, completer-based init cannot hang callers (callers pass timeouts) | B2 (cookie UI) |
| Provider failover | engine recovery policy (maxAttempts 3, windowed), streaming service ladder, health store | Sound — bounded, no endless loops | — |
| Storage/database | `ecosystem_database`, `library_database`, `sqlite_helpers`, `atomic_file_ops`, `cache_*`, backups | Sound — migrations stepped, atomic writes, corrupt-row skips | — |
| Search stability | request-id guards (track provider), unified search FutureProvider re-keying, debounces | Sound | — |
| Android | Manifest, MainActivity (SAF, secure-store warmup), FGS policies, EQ | Sound (static) | — |
| iOS | Runner config, background audio policy, path validation, iCloud-path fallback | Sound (static) | — |
| Go backend | 39,562 LOC non-test; concurrency/context/cancel patterns spot-checked; `worker_panic_guard`, `bridge_safety`, cancellation registries | Sound by inspection + existing Go test corpus | — |
| Settings | `settings_provider`, theme, engine settings, providers pages | Sound | — |

---

## E. Tests executed

| Test / check | Result |
|---|---|
| `scripts/local_quality_gate.py` (64 checks: YAML, bash -n, toolchain pins, pubspec, CHANGELOG, conflict markers, i18n coverage floor) | **PASS 64/64** (run before and after the changes) |
| `flutter analyze` | NOT TESTABLE — no Flutter SDK / pub.dev in sandbox |
| `flutter test` (124 existing Dart test files, ~22.8 k lines) | NOT TESTABLE — same |
| `dart format --set-exit-if-changed` | NOT TESTABLE — same |
| Go `go vet`, `go test ./…`, `go test -race ./…`, `staticcheck` | NOT TESTABLE — no Go toolchain / module proxy |
| Kotlin unit tests, Android assemble, gomobile AAR/XCFramework | NOT TESTABLE — no JDK/Android SDK |
| Xcode / iOS builds | NOT TESTABLE — no macOS/Xcode |

The changed Dart files were additionally brace/paren/bracket-balanced and
re-read in final form; changed identifiers (`friendlyError`,
`StagedStrings.cookiesCleared/ImportFailed`, `snackbarCannotOpenFile`,
`context.l10n`) were verified to exist with matching signatures at their call
sites.

---

## F. Test results

Executable-in-sandbox: only the local quality gate (PASS, above).
All compiler/test evidence must come from GitHub Actions on this branch; the
report does not claim green results it cannot produce.

---

## G. Android build result

NOT TESTABLE in sandbox (no JDK/Android SDK; `dl.google.com` unreachable).
`android/app/build.gradle.kts` (compileSdk 37 / targetSdk 35 / NDK 29.0.14206865,
R8 keep rules), manifests, and Kotlin unit-test layout were inspected and are
consistent with the pins checked by the passing local quality gate. CI:
`ci.yml`, `build-mobile.yml`, `unsigned-release.yml`.

## H. iOS build result

NOT TESTABLE in sandbox (no macOS/Xcode/CocoaPods). `ios/Podfile` (platform
15.0), deployment target 15.0, background modes (`audio` only) inspected and
consistent. CI: `build-mobile.yml` / `release.yml`.

## I. Flutter analysis result

NOT TESTABLE (no toolchain). The changes follow existing analyzer-clean
patterns in the same files (identical `mounted` + `ScaffoldMessenger` +
`friendlyError` idioms are already used in both edited screens; the downloader
uses only `dart:io`/`http` APIs already imported). A CI `flutter analyze` run is
required to confirm.

## J. Go test result

NOT TESTABLE (no toolchain). No Go source files were modified in this pass.

---

## K. Performance improvements

- **APK updater:** no busy/unbounded network wait; body stream now fails fast
  after 60 s of silence instead of pinning the UI thread's async slot and the
  notification progress indefinitely.
- No other performance-sensitive code was modified; the audit found existing
  mitigations (image budgets per runtime tier, decode caps, cover cache sweep,
  queue batch O(n log n), stream head buffer, connection recycling on network
  switch) already in place.

## L. Security findings

- Secret/credential scan over `lib/`, `go_backend/`, `android/`, `ios/` found
  **no hardcoded credentials** in production code — only key *names* in the
  secure-store layers (`secure_store.dart`, `provider_credentials.dart`,
  `NativeSecureStore.kt`) and test fixtures. No DSN is shipped; crash reporting
  is opt-in and redacts sensitive fields (documented in `crash_reporter.dart`).
- Extension packages are gated (permission confirmation on upgrade, package
  security tests in Go, cookie storage opt-in). No new findings.
- B2 fix removes a false-success message about privacy-relevant state.

## M. Dependency changes

None. `pubspec.yaml`, `go.mod`, Gradle pins, and the iOS toolchain pin were
audited: versions are internally consistent and carry rationale comments (e.g.
xml ^6.1.0 pin for youtube_explode_dart; Go 1.26.5 for cgo crash fixes; SDK 37
for androidx.core 1.18). Per the brief, no mass upgrade was performed.

## N. Remaining known issues

1. **Toolchain validation pending:** the 5 fixes are compile-unverified in this
   sandbox; CI must run `flutter analyze`, `flutter test`, and the platform
   builds before release. (`PASS` above refers to audit + gate only.)
2. Best-effort `catch (_) {}` cleanup sites remain by design (B6).
3. `_FileExistsListenableCache` outlives `dispose()` by ≤1.4 s in rare
   teardown timing (B7) — benign, recorded.
4. In-app updater still relies on the caller (`update_dialog.dart`) for user
   cancellation; downloads aborted by the OS leave only a `.part` file, which
   the next attempt deletes and replaces (no accumulation).
5. Pre-existing: some Settings strings for extension cookies are staged
   constants rather than ARB-localized (unchanged; localization sweep is a
   separate product task).
6. Repo-wide: l10n coverage floor means newer locales trail `app_en.arb` by up
   to 457 keys (enforced by the passing gate; not a regression from this pass).

## O. Production readiness assessment

**PASS** for the audit-defined scope in this environment, with the explicit
caveat that **PASS applies to (a) the static audit, (b) the five applied fixes,
and (c) the 64/64 local quality gate**. The repository is structurally
production-ready: it has bounded retries/failover everywhere, generation-guarded
async state, transactional downloads, atomic state writes, graceful startup
degradation, crash reporting hooks, and a large regression corpus. The
**outstanding gate** is mechanical, not architectural: `flutter analyze`,
`flutter test`, Go `-race`, and the Android/iOS release builds must be executed
in GitHub Actions (or a full local toolchain) and must come back green on this
branch before a release. No feature was removed or replaced in this pass; all
existing streaming, download, extension, provider, library, and player behavior
is preserved.
