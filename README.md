<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/readme/banner-readme-dark.png">
  <source media="(prefers-color-scheme: light)" srcset="assets/readme/banner-readme-light.png">
  <img alt="SpotiFLAC Mobile" src="assets/readme/banner-readme-light.png" width="650" height="auto">
</picture>

<p align="center">
  <a href="https://trendshift.io/repositories/25971" target="_blank">
    <img src="https://trendshift.io/api/badge/repositories/25971" alt="spotiflacapp%2FSpotiFLAC-Mobile | Trendshift" width="250" height="55">
  </a>
</p>

</div>

<div align="center">

[![GitHub Release](https://img.shields.io/github/v/release/spotiflacapp/SpotiFLAC-Mobile?style=for-the-badge&logo=github)](https://github.com/spotiflacapp/SpotiFLAC-Mobile/releases)
[![Crowdin](https://img.shields.io/badge/HELP%20TRANSLATE%20ON-CROWDIN-%2321252b?style=for-the-badge&logo=crowdin)](https://crowdin.com/project/spotiflac-mobile)

[![Telegram Channel](https://img.shields.io/badge/CHANNEL-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/spotiflac)
[![Telegram Community](https://img.shields.io/badge/COMMUNITY-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)](https://t.me/spotiflac_chat)

</div>

## Screenshots

<p align="center">
  <img src="assets/readme/1.jpg?v=2" width="200" />
  <img src="assets/readme/2.jpg?v=2" width="200" />
  <img src="assets/readme/3.jpg?v=2" width="200" />
  <img src="assets/readme/4.jpg?v=2" width="200" />
</p>

---

## What is SpotiFLAC Mobile?

**SpotiFLAC Mobile** is the Android/iOS edition of SpotiFLAC: an open-source,
extension-driven music client written in Flutter with a Go backend compiled via
`gomobile`. Everything below is present in this repository:

| Area | What it does |
| --- | --- |
| **Music discovery** | Paste or share a Spotify / Deezer / Tidal / YouTube Music link, or search by text; metadata is resolved through installed extensions (Home tab). |
| **Streaming** | Multi-provider streaming engine with per-provider health scoring and an ordered failover chain (`lib/engine/`, `lib/services/multi_provider_stream_service.dart`), progressive playback through `audio_service` + `audioplayers`. |
| **Downloads** | Lossless FLAC (and other formats via extensions) with a native foreground `DownloadService`, background finalisation, ReplayGain, cover/lyrics embedding, SAF or app-private storage, scheduling and queue transfer. |
| **Local library & offline playback** | Downloaded and locally indexed tracks (SQLite `library_database`), albums/artists/playlists, M3U import/export, offline network profile gating, playback of local files without a network. |
| **Player** | Full player + mini player, queue, seek, background/lock-screen playback and media buttons, Smart Play (local → stream → download), gapless/crossfade policies, equaliser and advanced audio effects, optional Liquid Glass UI. |
| **Extensions** | Installable `.spotiflac-ext` / `.sflx` packages (JavaScript, run in the Go backend), a decentralised Store with an official registry, provider priority, OAuth/signed-session callbacks, cross-extension sharing. |
| **Ecosystem** | Podcasts, self-hosted servers (Subsonic / Jellyfin / Plex), favourites, listening history, smart playlists, optional cloud sync and music recognition (`lib/ecosystem/`). |
| **Platforms** | Android (arm64, arm32, x86_64 APKs + AAB) and iOS (unsigned IPA for sideloading), both built by GitHub Actions. |

### Installation

- **Android** – download `SpotiFLAC-<version>-arm64.apk` (or `arm32` / `x86_64`)
  from the [Releases](https://github.com/spotiflacapp/SpotiFLAC-Mobile/releases)
  page and install it. The in-app updater fetches the matching artefact for
  your device.
- **iOS** – sideload `SpotiFLAC-<version>-ios-unsigned.ipa` with AltStore,
  SideStore or Sideloadly, or add the AltStore source listed in the FAQ.
- **From source** – see [Development](#development) and
  [CONTRIBUTING.md](CONTRIBUTING.md).

### Configuration

First-run setup installs the recommended starter extensions from the official
registry. Everything else lives under **Settings**: download folder and
format, provider priority, streaming quality per network profile, Liquid Glass
on/off, lyrics/metadata providers, notifications, backup & restore.

---

## Streaming Engine & Liquid Glass

SpotiFLAC Mobile now ships a unified **Track → Source → Playback Engine**
(`lib/engine/`): canonical track identity (ISRC-first), Smart Play
(local → stream → download & play), provider health scoring with failover,
next-track preloading, and per-network quality profiles — all feeding the
existing audio_service player (progressive `UrlSource` playback included).

The UI adds an Apple-style **Liquid Glass** layer: frosted mini player,
full glass player with a procedural visualizer, glass sheets/chips/sliders,
aurora scrim, and pointer-reactive highlights. It degrades cleanly on
low-end devices and respects reduce-motion / high-contrast settings, and can
be switched off (Settings → Streaming & Glass) to return to the classic
player.

See [`docs/streaming.md`](docs/streaming.md) for the
architecture and [`docs/ROADMAP.md`](docs/ROADMAP.md) for the full feature
map. Community-suggested improvements are catalogued in
[`docs/SUGGESTED_FEATURES.md`](docs/SUGGESTED_FEATURES.md). Streaming provider
integrations are extensions implementing the `StreamSourceAdapter` API — the
engine never extracts DRM audio from commercial services (authorized
APIs/accounts only).

---

## Extensions

Extensions let the community add new music sources and features without waiting for app updates. When a streaming service API changes or a new source becomes available, extensions can be updated independently.

### Installing Extensions

1. Open the **Store** tab in the app
2. On first launch, enter an **Extension Repository URL** when prompted
3. Browse and install extensions with one tap
4. Or download a `.spotiflac-ext` file and install manually via **Settings > Extensions**
5. Configure extension settings if needed
6. Set provider priority under **Settings > Extensions > Provider Priority**

### Developing Extensions

> [!NOTE]
> Want to build your own extension? Start with the
> [Extension Development Guide](docs/extensions.md). The
> [documentation site](https://spotiflac.zarz.moe/docs) contains the expanded
> API reference.

---

## Development

SpotiFLAC Mobile combines a Flutter/Dart UI, a Go backend compiled with
`gomobile`, and thin Android/iOS platform bridges. Toolchain versions are
pinned in [`.fvmrc`](.fvmrc), [`go_backend/go.mod`](go_backend/go.mod), and the
GitHub Actions workflows.

Start with the [Contributing Guide](CONTRIBUTING.md) for the development setup,
project boundaries, validation commands, and pull request checklist.

---

## Related Projects

### [SpotiFLAC (Desktop)](https://github.com/afkarxyz/SpotiFLAC)
Download music in true lossless FLAC from extension-provided sources on Windows, macOS & Linux.

### [SpotiFLAC (Python Module)](https://github.com/ShuShuzinhuu/SpotiFLAC-Module-Version)
Python library for SpotiFLAC integration, maintained by [@ShuShuzinhuu](https://github.com/ShuShuzinhuu).

---

## FAQ

<details>
<summary><b>Why does the Store tab ask me to enter a URL?</b></summary>
<br>

It shouldn't anymore: current versions ship with the official community
registry pre-configured
(`spotiflacapp/SpotiFLAC-Extension`), and first-run setup installs the
recommended starter set automatically.

The underlying system is still decentralized (since 3.8.0): extensions are
hosted independently rather than on a built-in server, so anyone can create
and host a compatible repository. To switch registries, tap the link icon in
the Store tab and enter a repository URL. If you removed the registry URL
entirely, the prompt returns — re-enter a URL (or reinstall) to restore it.

</details>

<details>
<summary><b>Why is my download failing with "Song not found"?</b></summary>
<br>

The track may not be available from your enabled providers. Try enabling more providers under **Settings > Extensions > Provider Priority**, or install additional download extensions from the Store.

</details>

<details>
<summary><b>Why are some tracks downloading in lower quality?</b></summary>
<br>

Quality depends on what's available from the source and the installed download extension. Check each extension's quality options and service notes in the app.

</details>

<details>
<summary><b>Can I download playlists?</b></summary>
<br>

Yes! Just paste the playlist URL in the search bar. The app will fetch all tracks and queue them for download.

</details>

<details>
<summary><b>Why do I need to grant storage permission?</b></summary>
<br>

The app needs a writable destination for downloaded files. On Android, choose a
folder with the system folder picker (SAF), or use the app-specific folder. If
Android revokes a saved folder grant, select the folder again in Settings.

</details>

<details>
<summary><b>Is this app safe?</b></summary>
<br>

SpotiFLAC Mobile is open source, so its code and build workflows can be
inspected directly in this repository. Release binaries are produced entirely by
GitHub Actions — see [docs/UNSIGNED_BUILDS.md](docs/UNSIGNED_BUILDS.md) for the
unsigned APK/IPA pipeline.

</details>

<details>
<summary><b>Why is downloading not working in my country?</b></summary>
<br>

Some countries have restricted access to certain streaming service APIs. If downloads are failing, try using a VPN to connect through a different region.

</details>

<details>
<summary><b>Can I add SpotiFLAC Mobile to AltStore or SideStore?</b></summary>
<br>

Yes! Add the official source to receive updates directly within the app. Copy this link:

```
https://raw.githubusercontent.com/spotiflacapp/SpotiFLAC-Mobile/refs/heads/main/apps.json
```

In AltStore/SideStore, go to **Browse > Sources**, tap **+**, and paste the link.

</details>

> [!NOTE]
> If SpotiFLAC Mobile is useful to you, consider supporting development:
>
> [![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/zarzet)

---

## Contributors

Thanks to everyone who has contributed to SpotiFLAC Mobile!

<a href="https://github.com/spotiflacapp/SpotiFLAC-Mobile/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=spotiflacapp/SpotiFLAC-Mobile" />
</a>

We also appreciate everyone who helped with [translations on Crowdin](https://crowdin.com/project/spotiflac-mobile), reported bugs, suggested features, and spread the word.

Interested in contributing? Check out the [Contributing Guide](CONTRIBUTING.md) to get started!

---

## API Credits

| | | | | |
|---|---|---|---|---|
| [MusicDL](https://www.musicdl.me) | [LRCLib](https://lrclib.net) | [Paxsenix](https://lyrics.paxsenix.org) | [Cobalt](https://cobalt.tools) | [Song.link](https://song.link) |
| [IDHS](https://github.com/sjdonado/idonthavespotify) |  |  |  |  |

---

## Disclaimer

This repository and its contents are provided strictly for educational and research purposes. The software is provided "as-is" without warranty of any kind, express or implied, as stated in the [MIT License](LICENSE).

- No copyrighted content is hosted, stored, mirrored, or distributed by this repository.
- Users must ensure that their use of this software is properly authorized and complies with all applicable laws, regulations, and third-party terms of service.
- This software is provided free of charge by the maintainer. If you paid a third party for access to this software in its original form from this repository, you may have been misled or scammed. Any redistribution or commercial use by third parties must comply with the terms of the repository license. No affiliation, endorsement, or support by the maintainer is implied unless explicitly stated in writing.
- SpotiFLAC Mobile is an independent project. It is not affiliated with, endorsed by, or connected to any other project or version on other platforms that may share a similar name. The maintainer of this repository has no control over or responsibility for third-party projects.
- The author(s) disclaim all liability for any direct, indirect, incidental, or consequential damages arising from the use or misuse of this software. Users assume all risk associated with its use.
- If you are a copyright holder or authorized representative and believe this repository infringes upon your rights, please contact the maintainer with sufficient detail (including relevant URLs and proof of ownership). The matter will be promptly investigated and appropriate action will be taken, which may include removal of the referenced material.

> [!TIP]
> **Star the repo** to get notified about all new releases directly from GitHub.
