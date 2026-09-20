# Cresca Music

> **Cresca** — from *crescendo*: music that keeps growing. Your music, flowing.

![release](https://img.shields.io/github/v/release/ritz0007/Cresca)
![downloads](https://img.shields.io/github/downloads/ritz0007/Cresca/total)
![platform](https://img.shields.io/badge/platform-Android%208%2B-green)
![license](https://img.shields.io/badge/license-Private-blue)

A FOSS Apple-Music-style player for Android powered by live YouTube data —
search millions of songs, stream instantly with gapless playback, sing along
with synced karaoke lyrics, build playlists, download for offline, and sign
in with your YouTube session. Everything stays on your device: no account,
no analytics, no server.

## Download ⬇️

Get the APK from [**Releases**](https://github.com/ritz0007/Cresca/releases).
Copy it to your phone, tap it, allow "Install unknown apps". Requires
Android 8.0+.

### Which file should I download?

| Device | File |
|---|---|
| Modern phones (Oppo K13, Pixel, Galaxy S-series, …) | `Cresca-X.Y.Z-arm64.apk` |
| Older 32-bit phones | `Cresca-X.Y.Z-armv7.apk` |
| Emulators / Chromebooks | `Cresca-X.Y.Z-x86_64.apk` |
| Not sure | `Cresca-X.Y.Z-universal.apk` (works everywhere) |

## Screenshots 📸

| Home | Full player |
|---|---|
| ![Home](docs/img/02-home.png) | ![Player](docs/img/03-player.png) |

| Up Next queue | Library |
|---|---|
| ![Queue](docs/img/04-queue.png) | ![Library](docs/img/05-library.png) |

| Splash |
|---|
| ![Splash](docs/img/01-splash.png) |

## Features ✨

- **Listen Now home** — live Top Picks (taste-matched from your last plays),
  Charts, New Releases, moods, endless discovery rails, pull-to-refresh
- **Real YouTube audio** — search + signature-deciphered streams, Media3
  playback with gapless queue, smart shuffle, repeat, 4 GB predictive cache
  (next, previous, charts, search fast-lane) for instant skips
- **Vibe queue** — Up Next matches the song's mood via YouTube's related
  graph, never same-name clones or one-singer loops
- **Full player** — edge-to-edge artwork under the status bar, bokeh lava
  ambience, rolling lyric ticker on the thumbnail, glowing seek bar,
  credits card, 3-dot menu (share, playlist, queue, download)
- **Karaoke lyrics** — fuzzy multi-source search, synced highlighting with
  waiting dots on long breaks, tap-to-seek, manual-scroll friendly
- **Music videos** — embedded player driven by the music transport, title +
  lyrics below the video, 1080p DASH adaptive with quality picker
- **Playlists + Library** — Liked Songs and Recently Played folders,
  2-per-row covers, smart suggestions, Spotify-style screens
- **Downloads** — "Artist - Title" files, in-app or device Music folder,
  offline library, offline-first playback
- **Calls just work** — pause on call, resume after, mid-call taps park and
  start on hang-up (never a crash)
- **System integration** — media notification with Next/Prev/Like, lockscreen
  controls, Android 16+ Live Updates chip with live progress
- **YouTube login** — in-app sign-in, encrypted on-device session
- **Updates** — daily check with banner + notification, manual check in
  Settings, real installed version shown
- **Apple look** — light/dark/system theme, Cresca red, liquid-glass bars,
  animated splash + intro
- **Songs only** — compilations, mixes and hour-long uploads are filtered out

## FAQ ❓

#### 1. Wrong lyrics?
Lyrics come from LRCLIB/lyrics.ovh matched fuzzily by artist, title and
duration. Mismatches happen on covers and remixes — the duration-aware
scoring keeps them rare.

#### 2. Playback blocked (403)?
Sustained 403s mean YouTube is throttling the IP. The app rotates stream
hosts automatically; if blocks persist, wait it out or switch networks.

#### 3. Why the name "Cresca"?
From *crescendo* — music that keeps growing. Short, musical, and ours.

## Build from source 🛠️

Requirements: JDK 17, Android SDK (platform + build-tools 35/36),
Gradle 8.9. Point `local.properties` at your SDK:

```properties
sdk.dir=C\:\\Users\\YOU\\AppData\\Local\\Android\\Sdk
```

```powershell
$env:JAVA_HOME = "C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot"
$env:ANDROID_HOME = "$env:LOCALAPPDATA\Android\Sdk"
C:\Gradle\gradle-8.9\bin\gradle.bat assembleDebug --console=plain
```

APKs (per-device + universal):
`app/build/outputs/apk/debug/app-<abi>-debug.apk`

Unit + stress tests:

```powershell
C:\Gradle\gradle-8.9\bin\gradle.bat ':app:testDebugUnitTest' --console=plain
```

Project structure (`app/src/main/java/com/cresca/app/`):
`MainActivity.kt` (all screens + player), `YoutubeRepository.kt` (search +
streams + vibe autoplay), `PlayerQueue.kt` (queue engine), `PlaybackService.kt`
+ `LiveUpdateProvider.kt` (background + notifications), `LyricsFlow.kt` /
`LyricsRepository.kt` (karaoke), `PlaylistStore.kt`, `DownloadStore.kt`,
`Precache.kt` / `ExoCache.kt` (4 GB cache), `CallGuard.kt` (call safety),
`UpdateCheck.kt` / `UpdateNotify.kt`. Details: [docs/FEATURES.md](docs/FEATURES.md).

## Contributing 🤝

Contributions are welcome — bug reports, ideas, and pull requests!

- **Found a bug?** [Open an issue](https://github.com/ritz0007/Cresca/issues)
  with your device, Android version, app version (Settings → About), and
  steps to reproduce. Crash logs (Settings → Share crash log) help a lot.
- **Want a feature?** Open an issue first so we can agree on scope.
- **Want to code?** Fork, create a topic branch, keep changes focused,
  add/extend unit tests under `app/src/test`, verify
  `:app:testDebugUnitTest` + `assembleDebug` + an emulator run, then open
  a PR against `main`. Never commit `*.log`, `build/`, `.gradle/` or APKs
  (APKs ship via Releases only).

## Privacy 🔒

Login cookies live in EncryptedSharedPreferences on the device. Clearing app
data wipes everything. Release download counts are public on GitHub; the app
itself reports nothing anywhere.

## Changelog 📝

See [CHANGELOG.md](CHANGELOG.md).
