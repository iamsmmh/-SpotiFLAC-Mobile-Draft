# SpotiFLAC Streaming Engine

The unified **Track → Source → Playback Engine** layer. Everything new —
streaming, Smart Play, provider failover, preloading, source ranking, the
Liquid Glass player — builds on this layer instead of becoming separate
systems.

```
        ┌────────────────────────────────────────────────────────────┐
        │            MusicPlayerHandler (audio_service)              │
        │  queue · transport · interrupts · savepoints · metadata    │
        └───────────────▲───────────────────────▲───────────────────┘
                        │ PlayableMedia         │ failure hook
        ┌───────────────┴───────────────────────┴───────────────────┐
        │              StreamingEngineController (Riverpod)         │
        │  decide() → startLocal() / startStream() / download&play  │
        │  preflight · health · failover · refresh · preload        │
        └───────────────▲───────────────────────────────────────────┘
                        │ SmartPlayDecision
        ┌───────────────┴───────────────────────────────────────────┐
        │  SmartPlayEngine (pure)   ←  ladder: local → stream →     │
        │                             download & play → unavailable  │
        │  StreamSourceResolver     ←  health .45 + quality .25 +    │
        │                             latency .20 + priority .10     │
        │  ProviderHealthRegistry   ←  success rate · backoff ·     │
        │                             offline marking                 │
        │  StreamingSessionController← phase machine + retry budget  │
        │  StreamPreloader          ←  next-track URL validation     │
        └────────────────────────────────────────────────────────────┘
                        │ StreamSourceAdapter (extensions)
        ┌───────────────▼───────────────────────────────────────────┐
        │  Track identity (ISRC-first canonical matching)           │
        │  Download history · local library · preview streams       │
        │  Provider extensions (metadata / download / lyrics)       │
        └────────────────────────────────────────────────────────────┘
```

## Decisions are pure; I/O is injected

All policy lives in `lib/engine/` and is 100% unit-testable:

| File | Responsibility |
|---|---|
| `track_identity.dart` | Canonical `TrackIdentityInput` → `CanonicalTrackKey`; ISRC-first matching; fuzzy title/artist/duration scoring; duplicate merging |
| `audio_characteristics.dart` | Quality ladder (Auto → Hi-Res), network profiles, codec/bitrate/sample-rate/bit-depth display model, quality policy, `StreamBufferPolicy`, per-source ReplayGain fields |
| `streaming_engine.dart` | `StreamDescriptor`, provider health + exponential backoff, source ranking, session phase machine, URL-expiry refresh policy, preflight contract, preloader, diagnostics |
| `smart_play.dart` | The Smart Play ladder with decision traces |
| `playback_session.dart` | Queue planner, shuffle/repeat, savepoint + sanitize, listening statistics |
| `replay_gain.dart` | ReplayGain dB↔linear conversion, tag parsing, track/album selection, peak-clipping protection |
| `gapless_policy.dart` | Gapless transition planning (seamless lossless splice vs. pre-buffer vs. disabled) |
| `adaptive_buffer.dart` | Adaptive buffer planner: network profile + throughput → lookahead window and head pre-buffer size |

The Riverpod layer (`lib/providers/streaming_engine_provider.dart`) performs the
actual HTTP work (`HttpStreamPreflightValidator`, `StreamHeadWarmer`,
`NetworkStatusMonitor`) and drives the existing `MusicPlayerHandler` — which
now accepts progressive `UrlSource` playback, exposes a playback-failure hook
for failover, and keeps its original content-URI/local-file behavior untouched.

## Real-time audio pipeline

The handler (`lib/services/music_player_service.dart`) now normalizes both
transports through the same pure `ReplayGain` policy:

* **Local files** — track/album gain and peak tags are probed from the file
  (`replaygain_track_gain`, `replaygain_album_gain`, `replaygain_track_peak`).
* **Progressive streams** — gain metadata rides on the resolved
  `StreamDescriptor` → `AudioCharacteristics` → `PlayableMedia`, so extensions
  can supply ReplayGain for authorized streams without re-probing a URL.
* **Peak-clipping protection** — a reported peak above full scale is attenuated
  back to 1.0; positive gains clamp at unity because the platform volume can
  only attenuate.

Gapless transitions are planned by `GaplessPolicy`: two consecutive items on the
same transport with identical codec/sample rate/bit depth/channels and a
lossless codec (FLAC/ALAC/WAV/AIFF/APE/WavPack) splice seamlessly by skipping
source teardown; every other transition pre-buffers the next head to shrink the
gap. The engine's `StreamHeadWarmer` pulls a bounded ranged-GET prefix of the
next stream (respecting `bufferPreviewStreams` / `cachePermitted`) while the
current track plays, and `AdaptiveBufferPlanner` sizes that prefix from the
network profile and live bandwidth — poor links open a deeper low-bandwidth
lookahead window.

### Crossfade

`CrossfadePolicy` (`lib/engine/crossfade_policy.dart`) is pure and evaluated on
every position tick of the active player. Given the user setting
(`EngineSettings.crossfadeSeconds` 0–12, `crossfadeSmart`), the outgoing
track's duration and both items' `AudioCharacteristics`, it returns the
overlap to use — or none for repeat-one, unknown durations, tracks shorter
than 10 s (30 s in smart mode), and, in smart mode, album-continuous
neighbours and lossless pairs the `GaplessPolicy` would splice instead. The
overlap is capped at a third (smart: an eighth) of the track and clamped to
1–12 s.

When the remaining time drops inside the overlap the handler swaps roles
*synchronously*: the current `AudioPlayer` becomes the outgoing half (its
state/complete/error events are ignored from then on), the standby player
(`music-player-crossfade`, created lazily and reused) takes the next item at
volume 0, and once the source is ready a 60 ms timer ramps both players with
`CrossfadePolicy.equalPowerGains` scaled by each track's normalisation volume,
then stops the outgoing player and parks it as standby. The ramp never runs
past the moment the outgoing track would end by itself, so a slow source
resolve degrades to a shorter fade rather than a stretch of silence. Pause,
seek, skip, stop, audio-focus loss and a failed incoming source all end the
fade immediately (`_endCrossfade`) and restore the active player's full
volume. Crossfade takes precedence over the gapless splice for a transition;
with crossfade off (default) the gapless path is unchanged.

### Equalizer / DSP chain

`AudioEffectsSettings` (`lib/engine/audio_effects.dart`) is the platform-neutral
description of the chain: ten band gains in dB, bass boost / virtualizer
strengths (0–1), enhancer gain, compressor threshold/ratio, limiter ceiling.
`audioEffectsProvider` persists it (`audio_effects_v1`) together with user
presets, debounces changes, and pushes `toPlatformMap()` through
`PlatformBridge.applyAudioEffects`. The handler exposes
`playbackSourceStartedListener`, fired right after `play()` succeeds, because
Android effect objects bind to an *audio session id* that only exists once a
`MediaPlayer` has a source — and changes when audioplayers recreates the
player.

On Android `AudioEffectsController` (a process singleton, since the engine
outlives the Activity) resolves the session ids of `music-player` and
`music-player-crossfade` reflectively from the audioplayers plugin (kept by
ProGuard), then owns one effect chain per session: `DynamicsProcessing`
(API 28+: pre-EQ with exact octave cutoffs, one MBC band as the compressor,
limiter) or `Equalizer` (older devices; `AudioEffectsPolicy.mapToDeviceBands`
projects the ten requested bands onto whatever bands the device has), plus
`BassBoost`, `Virtualizer` and `LoudnessEnhancer`. When the master switch is
off or every stage is neutral the chain is released entirely, so the default
audio path is untouched. Capabilities are reported to the UI so unsupported
stages render disabled with a reason instead of silently doing nothing.

## Smart Play ladder

```
Downloaded?        ── YES ──► local playback (instant, offline-safe)
   │ NO
Streaming ok?      ── YES ──► progressive stream (preflighted, preloaded)
   │ NO
Downloadable?      ── YES ──► queue download → play on completion
   │ NO
Unavailable        ─────────► explicit reason (never a silent spinner)
```

Every decision returns a trace (`SmartPlayStep`) so the UI can explain itself
("Playing from local — offline") and the Diagnostics Center can show why a
particular provider was chosen.

## Source intelligence

Candidates are filtered (expired URLs, offline/backoff providers, missing
authorization) and ranked:

```
score = 0.45 × health + 0.25 × quality-fit + 0.20 × latency + 0.10 × priority
```

Failures feed `ProviderHealthRegistry`: consecutive failures trigger
exponential backoff with full jitter (750 ms → 30 s cap), five consecutive
failures mark the provider offline until it records a fresh success. The audio
engine's runtime failure hook re-resolves the same track to the next ranked
source without losing the queue.

## Terms-of-use guardrails

- The engine never turns protected/authorized streams into permanent
  downloads. `cacheStreams` defaults to **off** and is only enabled per source
  kind when the descriptor says `cachePermitted`.
- Commercial services are integrated through their own authorized APIs/accounts
  (metadata, playback, lyrics), never by extracting DRM audio.
- Preflight performs a single-byte ranged GET and closes the stream after the
  first chunk — no full-file buffering, no hidden downloads.

## Extension adapter API

New streaming providers register a `StreamSourceAdapter`:

```dart
abstract class StreamSourceAdapter {
  String get id;
  Future<List<StreamDescriptor>> candidatesFor(Track track);
}
```

Add the adapter to `streamSourceAdaptersProvider` and the engine ranks, healths,
preflights, and fails over to it automatically. The `preview` adapter ships as
the reference implementation (provider-supplied preview URLs), and the built-in
`MultiProviderStreamAdapter` exposes the app's multi-provider resolver (YouTube
universal fallback, SoundCloud, credential-gated lossless providers) to Smart
Play — so the play path resolves real full streams, not only previews. Previews
are ranked below full streams and are the last resort.

## Queue playback & deferred sources

`StreamingEngineController.playTracks` is the list-play entry point:

1. The tapped track runs the full Smart Play ladder and starts immediately.
2. Remaining tracks are queued behind it — pre-resolved local copies play
   directly, and everything else becomes a **deferred** queue item
   (`deferred-stream://track/<id>`).
3. When playback reaches a deferred item, the player asks the engine to
   resolve it (`resolveDeferredSource`): a *fresh* Smart Play decision runs at
   play time, so stream URLs are never stale, files downloaded in the meantime
   are picked up, and offline/local-only policies apply per track.
4. Deferred items survive session restore (paused) and re-resolve on resume;
   low-confidence or unresolvable items stop playback gracefully with a
   logged reason instead of silently substituting another track.

## Recovery

- The audio service persists its own session and restores **paused** at launch.
- The engine persists an independent `PlaybackSavepoint` (queue, mode, quality,
  volume, rate, balance). `sanitize()` drops dead files and expired stream URLs
  so recovery never presents a dead queue, and it always asks the user before
  resuming.
- Download & Play watches the existing download queue and starts local playback
  when the item completes.

## Seamless failover

When a stream URL expires or breaks mid-playback, the runtime failure hook
re-resolves the same track to the next ranked source **and resumes at the
position where the dead source stopped** (`t`): the handler's
`currentPlaybackPosition()` is captured before the switch and passed through
`replaceCurrentAndPlay(item, resumeAt: t)`, so the listener hears a jump of at
most the resolve/backoff delay instead of a restart from 0:00.

Failover also applies *before* playback: a failed preflight walks the ranked
alternative candidates (bounded by the configured attempt budget and a
tried-URI set), so Provider A → Provider B → Provider C succeeds without
re-trying a URI that already failed.

How a failure reaches the hook:

- **Synchronous** — `play()` throws (audioplayers awaits the platform's
  *prepared* event, so pre-prepare errors fail the future).
- **Runtime** — the platform reports CDN drops, expired signed URLs and decoder
  errors on the player's event-stream *error channel* after `play()` returned.
  `MusicPlayerHandler` listens to it and forwards the current item once per
  play generation (`_handleRuntimePlaybackError`).
- **Proactive** — a resolved `StreamDescriptor.expiresAt` travels on
  `PlayableMedia.expiresAt` (persisted with the queue; deferred items report it
  through `noteDeferredSourceExpiry` at resolve time). The handler arms a timer
  that fires two minutes before expiry (never sooner than 30 s after start,
  never for an already-expired URL) and calls the hook with
  `StreamUrlExpiringSignal`. The engine treats it as a refresh, not a failure:
  same-provider fresh URL first, no health penalty, no backoff.

What the engine does on failure (`_handlePlaybackFailure`):

1. Resolve the *concrete* failed source — for a `deferred-stream://` queue
   item that is the descriptor it resolved to (`_deferredSourceByMediaId`),
   never the placeholder — so the dead URL is excluded and the right provider
   is charged.
2. Invalidate the multi-provider resolver cache for the track and re-query
   every adapter for a fresh candidate set.
3. Pick the next source via the session controller (health-filtered, expiry-
   filtered), preflight it, and try one more alternative if it is dead on
   arrival.
4. `replaceCurrentAndPlay(item, resumeAt: t)` + publish the new play context.
5. If the chain is exhausted and the queue has a later item, skip to it
   instead of leaving playback stopped.

## Lyrics for streamed tracks

Local files use their embedded lyrics. Streamed items have no file, so
`nowPlayingLyricsProvider` (and the classic Now Playing lyrics page) query the
Go lyrics client — LRCLIB, Musixmatch, Apple Music, NetEase, QQ Music,
Paxsenix in the priority/fallback order configured under *Lyrics* settings —
keyed by track id + title + artist so a failover URL swap reuses the entry.
Lookups are memoized per session (bounded LRU, in-flight coalescing, negative
results cached) and skipped entirely in offline mode.

## Match confidence

The anonymous fallback providers (YouTube, SoundCloud) score every candidate
(Topic/official markers, duration drift, cover/karaoke/live penalties) and
**reject low-confidence matches** instead of playing an unrelated track: the
resolution falls through to the next provider or fails with a clear reason.

## Provider health metrics persistence (Phase 3, 2026-09-06)

Health is fed by *real* resolution attempts and now also survives restarts:

- `StreamProviderHealth.toJson()/fromJson()` round-trips per-provider
  metrics (counts, latency, last outcome, last error) with hostile-input
  hardening: unknown provider names dropped, counters clamped to 0…10⁹,
  negative latencies and unparsable dates dropped.
- `StreamProviderHealthRegistry.mergeRestored()` seeds providers that have
  not yet been measured this session; live observations always win.
- **Cooldowns are never restored** — circuit state is per-session by design,
  so a provider that recovered while the app was closed is immediately
  usable (a stale quarantine flag must not outlive the outage).
- `ProviderHealthStore` (`lib/services/provider_health_store.dart`) owns the
  lifecycle: restore on attach, debounced (3 s) best-effort saves on every
  metric change, schema-versioned payload, 32 KB size cap, corrupt-snapshot
  discard, and a final flush on dispose. Persistence failures are logged and
  swallowed — they can never break playback.
- Full-chain resolution failures (every provider exhausted) additionally
  feed the crash reporter as a fingerprint-deduped `provider` event with the
  attempted chain attached.

## Crash & playback telemetry (Phase 10, 2026-09-06)

The playback path emits breadcrumbs and events through
`lib/core/monitoring/crash_reporter.dart` (Sentry-envelope compatible, DSN
opt-in — see `docs/architecture.md`):

| Point | Signal |
|---|---|
| Track start | breadcrumb `playing: <title>` (`playback`) |
| `play()` failure, no-source, runtime engine error | `playback` error event with phase + track context, fingerprinted per phase |
| Provider chain exhausted | `provider` error event + breadcrumb (`streaming`), chain attached |
| Native download worker crash / queue-restore failure | `native` / `download` error events |

All reporting is fire-and-forget, bounded and redacted; it is disabled
entirely unless a DSN was configured.
