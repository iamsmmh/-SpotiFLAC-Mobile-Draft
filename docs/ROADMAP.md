# Feature Roadmap — Track → Source → Playback Engine

Legend: ✅ exists in this repo · 🚀 shipped in this upgrade · 🧱 scaffolded (API/UI ready, provider required) · ⏳ planned

## 1. Core music playback
✅ Play/pause/next/previous/seek · ✅ shuffle/repeat/favorite/queue/playlist/notifications
🚀 resume position (existing audio-service savepoint + new engine savepoint) · 🚀 playback history & statistics
✅ recently played / most played aggregation UI (Settings → Streaming & Glass → Listening Statistics)

## 2. Streaming engine
🚀 instant progressive playback (`UrlSource` in MusicPlayerHandler) · 🚀 source ranking & quality ladder
🚀 provider health + backoff + offline marking · 🚀 auto source selection / provider fallback
🚀 preflight validation · 🚀 URL-expiry refresh policy · 🚀 next-track preloading / adaptive quality / network profiles
🚀 manual quality selection · 🚀 stream state monitoring (phase machine + diagnostics)
🧱 multiple streaming providers via `StreamSourceAdapter` (extensions)
✅ Wi-Fi/mobile/poor/roaming quality profiles UI

## 3. Smart playback
🚀 Smart Play ladder (local → stream → download&play → unavailable) with decision traces

## 4. Professional player
🚀 Liquid Glass mini player (artwork, title/artist, controls, progress, source badge)
🚀 Liquid Glass full player (large artwork, visualizer, seek, queue, lyrics, sleep timer, quality/source chips, volume/speed/balance)
✅ classic Now Playing retained (settings toggle: glass off → classic mini player)

## 5. Background playback
✅ existing audio_service handler, lock screen, Control Center / MediaSession, audio focus, interruptions,
becoming-noisy, route changes (unchanged and verified)
✅ Android foreground service, notification player, Bluetooth/headset controls

## 6. Advanced download manager
✅ full existing queue (single/album/playlist/batch, concurrent, priority, retry, history, failed history)
🚀 Smart-Play "download & play" integration hooks (watch queue completion)
🚀 approximate result-size estimate per quality in the picker (#550)
🚀 offline download registry: export/import + missing diff (#516)

## 7. Smart download
✅ Wi-Fi-only mode exists · ✅ time-window download scheduling (pause/resume) · 🧱 charging hooks · ⏳ provider failover download ranking (engine-side ranking reusable)

## 8. Audio quality
🚀 Auto/Low/Normal/High/Lossless/Hi-Res ladder + per-network profiles + `AudioCharacteristics`
(codec, bitrate, sample rate, bit depth, channels, size, lossless, source) — used by the glass player chips

## 9. Gapless & advanced
🚀 ReplayGain normalization in the built-in player (local tag probe + stream
gain metadata + peak-clipping protection) · 🚀 gapless transition planning
(lossless splice via `GaplessPolicy`, source-teardown skip) ·
🚀 playback rate + balance controls (audioplayers) · ⏳ crossfade knobs

## 10. Equalizer / DSP
🚀 UI/Settings scaffold (more controls sheet, presets enumerated) · ⏳ platform DSP plugin integration

## 11. Visualizer
🚀 spectrum / waveform / circular / bars, performance & battery modes in the glass player

## 12. Lyrics
✅ LRCLIB / Paxsenix / Netease / QQ / Apple / Musixmatch pipeline; synced scroll; copy/share
🚀 lyrics entry point from the glass player → existing track metadata screen

## 13. Unified search
✅ existing home search + provider search · 🧱 engine identity layer ready for cross-source aggregation

## 14. Smart metadata matching
🚀 canonical identity (`track_identity.dart`): ISRC-first, fuzzy title/artist/duration/album/year scoring,
provider-id map, duplicate merging — the "ONE TRACK" backbone

## 15–17. Library, local manager, duplicates
✅ folder scanner, integrity checks, metadata/artwork extraction, duplicate review sheet (existing)
🚀 identity layer feeds canonical dedupe decisions

## 18. Artwork
✅ embedded/provider artwork, caching, extraction · 🧱 replacement UI (existing metadata editor)

## 19–20. Playlists & sync
✅ create/rename/delete/reorder, import/export M3U/M3U8/JSON/CSV (existing)
🧱 Spotify-style authorized import adapter (permitted APIs only)

## 21–23. Radio, recommendations, Discover
✅ explore/home feed, genre browsing, recently played (existing)
🚀 recommendation engine: provider port + on-device engine (recently/frequently
played, artist affinity, daily discovery mix) + For You screen (stats privacy-first, fully local)
🧱 remote/extension-backed recommendation providers (port is ready, none bundled)

## 24. Listening statistics
🚀 `ListeningStats` (plays, skips, listened time, per-day buckets, streak) persisted locally
✅ per-track plays/listened time + Recently Played / Most Played (Listening Statistics page)

## 25. Privacy
✅ no account, local-only data, logging toggle · 🚀 stats opt-out, savepoint opt-out ✅ history clearing UI wiring (clear restore memory + reset statistics)

## 26. Sleep timer
🚀 15/30/45/60 + end-of-track + stop, in the glass player

## 27. Network management
🚀 Wi-Fi/mobile/roaming/poor/offline profiles with quality policies (latency-aware "poor" detection)

## 28. Smart cache
✅ existing cover/metadata cache · 🧱 streaming cache gated by provider `cachePermitted` (default off — terms guardrail)

## 29. Adaptive streaming
🚀 quality step policy + preflight latency + preloading ·
🚀 adaptive buffer planner (low-bandwidth lookahead window + bounded head
pre-buffer) · ✅ live bandwidth sampling (preflight + head-warmup estimates in Diagnostics)

## 30–32. Provider system / failover / source intelligence
✅ extension manager, priority, health checks (existing Go runtime)
🚀 engine-side health scoring, failover chains, ranking weights (extension adoption via adapter)

## 33–35. Extension manager & security
✅ store, install/remove, enable/disable, versioning, signed sessions, permissions (existing)
🚀 permission-expansion confirmation on upgrades · 🚀 user-imported session cookies per extension

## 36–37. Queue management & smart queue
✅ existing queue tab + audio-service queue · 🚀 engine queue planner (shuffle seed, savepoint)
🧱 smart-queue auto-extension (recommendation source pending)

## 38–39. Performance & stability
✅ runtime profile tiers, lazy loading, request dedupe, cache limits (existing)
🚀 engine-level event log bounded at 64 entries, preloader dedupe, savepoint sanitize

## 40. Playback recovery
✅ existing paused-restore after kill · 🚀 engine savepoint + sanitize + "resume?" semantics

## 41. Download recovery
✅ resume/retry/partial cleanup/checksums (existing)

## 42–43. Diagnostics & logs
🚀 Diagnostics Center section in Streaming & Glass settings (provider health, success rates, latency, event log) · ✅ Streaming integrity (per-URL success/failure/fallback reasons)

## 44–45. Backup/restore & import/export
✅ backup/restore, M3U/M3U8/JSON/CSV (existing) · ✅ queue share/import (portable JSON)

## 46–47. Sharing & deep links
✅ share_plus, receive_sharing_intent, SongLink (existing) · 🚀 `spotiflac://` deep-link routes (open / search / provider-entity forms)

## 48. UI/UX
✅ Material 3, dark/light/AMOLED/dynamic color, bottom nav, mini player, full player
🚀 Liquid Glass system: frosted surfaces, edge highlights, pointer glow, sheen, aurora scrim, glass sheets/chips/buttons/sliders
🚀 visualizer, large artwork mode, glass settings page

## 49. Accessibility
✅ tooltip-backed icon buttons (test-enforced), touch ≥48dp, AppSliverHeader type ramp
🚀 glass surfaces honor reduce-motion (no sheen/aurora), high contrast (tinted fallback), no-blur devices get opaque glass

## 50. Internationalization
✅ 12 locales + RTL-ready infrastructure · ⏳ new glass/engine strings staged for Crowdin (English first)

## 51–52. Hardware & car mode
✅ AirPods/Bluetooth/headset/media buttons via audio_service · ⧉ existing UI supports large touch targets
⏳ dedicated car mode layout

## 53. AI features
⧉ optional; statistics + identity + playlist layers make recommendations feasible without telemetry

## 54. Advanced library search
🧱 metadata filters (codec/bitrate/bit depth/format) supported by existing library metadata model · ⏳ filter UI

## 55–57. Fingerprinting / metadata editor / auto-repair
✅ metadata editor + batch re-enrich (existing) · 🧱 fingerprinting via identity matching

## 58–59. Storage & battery
✅ cache management, duplicate review (existing) · 🚀 visualizer battery mode, adaptive art resolution hints
✅ storage breakdown UI (per-format/artist/album disk usage)

## 60. Quality assurance
🚀 engine unit tests (identity, smart play, failover, refresh, savepoint, stats, preloader)
🚀 liquid glass widget smoke tests · ✅ existing provider/stream/download/queue suites

## 61. Security
✅ secure storage (Keychain/Keystore), HTTPS, signed extension sessions, credential isolation (existing)

## 62. Platform
✅ AVAudioSession, Now Playing, Remote Command Center, MediaSession, foreground service, audio focus (existing)

## 63. Streaming services
🚀 adapter architecture ready (authorized integrations only; no DRM extraction)

## 64. Navigation
✅ tab shell (Home/Search/Discover/Library/Downloads/Settings) · 🚀 Settings → **Streaming & Glass**
