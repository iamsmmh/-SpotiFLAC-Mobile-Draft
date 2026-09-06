# SpotiFLAC Mobile — Current Status

**Last updated:** 2026-09-06 · **App version:** 5.0.0+142 · **Branch:** `arena/01a0750a-spotiflac-mobile`

This is the single current-state document. It supersedes the historical
session reports now archived under `docs/history/` (`AUDIT_REPORT.md`,
`PRODUCTION_READINESS_AUDIT.md`, `FINAL_AUDIT_2026-09-02.md`, `FIX_REPORT.md`,
`BUILD_FIXES.md`, `RELEASE_GATE_VERIFICATION_2026-09-02.md`),
which are kept for archaeology but contain stale claims (e.g. "no green run
exists", "cover/sidecar writes are non-atomic" — both fixed since).
CI/build evidence lives in `docs/testing.md` and `BUILD_REPORT.md`; the
2026-09-06 production-readiness audit is
`docs/PRODUCTION_READINESS_2026-09-06.md`.

## What works out of the box (fresh install)

| Capability | State |
|---|---|
| Local file playback, queue, background audio, notifications | ✅ complete |
| First-run setup (language, permissions, folder) | ✅ complete |
| Official extension registry pre-configured + recommended starter set auto-install (search/metadata, lossless + fallback downloads) | ✅ complete |
| Store tab with one-tap **Install recommended** | ✅ complete |
| YouTube / SoundCloud anonymous fallback streaming, 30s previews | ✅ complete |
| Lossless streaming with user tokens (Tidal, Qobuz, Apple, Deezer, Amazon) via **Settings → Provider accounts** (encrypted keystore) | ✅ complete |
| No-provider failures route to the Store (queue banner, error dialog, empty search) instead of dead ends | ✅ complete |
| Lyrics (LRCLIB/Paxsenix/NetEase/QQ/Apple/Musixmatch), synced scroll, per-track .lrc save | ✅ complete |
| Metadata/tag editing (FLAC/MP3/AAC/M4A/OGG/OPUS/WAV/AIFF), Deezer metadata, ISRC identity | ✅ complete |
| Library scan, duplicates, playlists (M3U/CSV/JSON), backup/restore, queue share | ✅ complete |
| Android EQ/DSP (DynamicsProcessing / Equalizer) | ✅ complete |
| AltStore/SideStore feed (`apps.json`) auto-updated by the unsigned-release pipeline | ✅ complete |
| Approximate result size in the download quality picker (#550) | ✅ **new in this pass** |
| Offline download registry: export/import + missing-track diff (#516) | ✅ **new in this pass** |
| Per-extension imported session cookies (opt-in, for CF challenges / own account) (#479/#499) | ✅ **new in this pass** |
| Extension upgrades that expand permissions require explicit confirmation (Store + sideload) | ✅ **new in this pass** |
| Opt-in read-only **LAN web player** for the download folder (Settings → Files) | ✅ **new in this pass** |
| `spotimusic://` deep links (open/search/track-id forms, Android + iOS) | ✅ **new in this pass** |
| Re-enrich never re-embeds filesystem artifacts (issue #562 hardening) | ✅ **new in this pass** |
| Favorite albums (album page bookmark, Library folder, DB v3, backup) | ✅ **new in this pass** |
| For You: on-device recommendation engine + Library tile/screen (Phase 7) | ✅ **new in this pass** |
| Search history + fuzzy local suggestions on Home (Phase 9) | ✅ **new in this pass** |
| Cloud sync architecture: provider port, merge orchestrator, Settings page, adapter docs (Phase 6) | ✅ complete (interfaces + local machinery; backend adapters pluggable) |
| Provider health metrics persist across sessions (counts/latency/last error; cooldowns deliberately reset) | ✅ **new in this pass** |
| Crash & failure monitoring: dependency-free Sentry-compatible reporter (opt-in DSN, playback/download/provider/native events, breadcrumbs, redaction) | ✅ **new in this pass** (needs a Sentry DSN to activate — by design none ships) |
| 126 previously-silent `catch (_) {}` paths now log (services, providers, metadata screens) | ✅ **new in this pass** |
| `staticcheck ./...` (pinned 2026.2.1) added as a hard CI gate | ✅ **new in this pass** |
| Docs consolidated: `docs/{architecture,streaming,extensions,testing,changelog}.md` (root docs are pointer stubs) | ✅ **new in this pass** |

## Engineering gates

- `python3 scripts/local_quality_gate.py` — 50 static checks, toolchain-free, must be green.
- `python3 scripts/release_gate.py` — pre-release gate (tag↔pubspec, AltStore feed integrity
  incl. bundle-ID match with Android/iOS config and RFC3339 `date`, CHANGELOG coverage,
  staged-strings budget, locale coverage floor). Wired into both release pipelines.
- CI: `flutter analyze`, `flutter test` (+coverage summary), `go vet`,
  **`staticcheck` (pinned 2026.2.1, zero-findings policy)**, `go test` with
  **`-race`** (+coverage summary), Android compile & native tests,
  gomobile AAR/XCFramework builds (via `Build Mobile`). (`-shuffle` stays off
  until follow-up 5 lands; `-race` is always on.)
- Nightly `fuzz.yml`: bounded Go fuzzing of filename/template/manifest/CUE parsing;
  failed inputs are archived as artifacts and must land in `testdata/fuzz/` with the fix.
- Weekly `emulator-smoke.yml`: boots a debug build on an emulator, grants runtime
  permissions, asserts process aliveness and captures logcat + screenshot (informational).
- `pubspec-lock.yml` regenerates and commits `pubspec.lock` when `pubspec.yaml`
  changes (lockfile is committed and no longer gitignored).
- `crowdin-sync.yml`: uploads the English template on main changes and can open a
  translations PR on demand; opt-in via the `CROWDIN_ENABLED` repo variable so forks
  skip cleanly.

## What still needs the user / provider side

- **Cloud sync** ships as the adapter architecture (orchestrator, outbox,
  settings page). Enabling it requires registering a `CloudSyncProvider`
  (Firebase/Supabase/self-hosted) with real project credentials —
  intentionally not bundled.
- **Persistent stream-byte caching** (play counts as offline copy) is designed
  in `ARCHITECTURE.md` but deferred: it must be validated against the
  verified audio pipeline with device coverage before shipping.

- **Downloads** require at least one download extension (now one tap away via
  setup or the Store card). There is intentionally no built-in download
  provider — the backend fails loudly (`Extension providers are disabled…`)
  and the UI routes that error to the Store.
- **Lossless streams** require the user's own account tokens (provider
  accounts page) or provider extensions. Without them the engine falls back
  to YouTube/SoundCloud/previews by design.
- **iOS equalizer** stays unavailable (AVPlayer cannot host AudioUnit
  effects without an AVAudioEngine re-route); the UI reports this honestly.
- **CI APKs are debug-signed.** Play-Store artifacts need `key.properties` /
  signing secrets (documented in `BUILD_REPORT.md`).
- The **upstream `spotiflacapp` repository** still needs
  `ci-patches/0001-github-workflow-fixes.patch` applied by a human account
  (a GitHub App without the `workflows` scope cannot push workflow files).

## Known follow-ups (scoped, not started)

1. **Crowdin backfill** for the English-first strings (`lib/l10n/staged_strings.dart`)
   + `es`/`pt` catch-up. `scripts/translation_coverage.py` tracks progress; the
   release gate caps the staged backlog at 70 entries.
2. **God-file splits** (`track_metadata_edit_sheet`, `ffmpeg_service`,
   `platform_bridge`, `music_player_service`) — maintainability only.
3. **Android 15 `dataSync` budget strategy** (WorkManager migration) for very
   long queues; denial is currently handled gracefully, not scheduled around.
4. Executed DB-migration tests (`sqflite_common_ffi`) to replace the current
   source-contract assertions; iOS EQ engine; car mode.
5. Make the Go suite order-independent enough to enable `-shuffle=on` (a
   first attempt in CI exposed shared package-level state between tests);
   `-race` stays on regardless.
6. **LAN web player**: currently serves the download folder read-only; pairing /
   HTTPS / per-device PIN would be needed before this could ever leave the LAN
   scope. Extension-side audio for non-local files is not exposed.
