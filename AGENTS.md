# AGENTS.md — Cresca Music (AI context)

> Read this before modifying code. It captures everything learned building
> this app: architecture contracts, hard-won gotchas, and the verify loop.

## What this is

Cresca Music (`com.cresca.app`) — Android music player, Apple-Music-style
Compose UI, **real YouTube data** (search + audio/video streams via
NewPipeExtractor), Media3 playback with background service, karaoke lyrics,
playlists, downloads, YouTube login, Live Updates. Single module, no
ViewModels, no backend. Everything on-device.

## Toolchain (pinned for reasons — don't drift casually)

- Gradle 8.9 at `C:\Gradle\gradle-8.9`, AGP **8.7.3**, Kotlin **2.2.21**
- `compileSdk 36`, `minSdk 26`, `targetSdk 34`
- Media3 **1.4.1** (exoplayer/session/ui), NewPipeExtractor **v0.26.5**
  (JitPack), Coil 2.6.0, Haze 1.7.2, splashscreen 1.0.1
- `androidx.activity` **pinned to 1.9.3** via `resolutionStrategy`
  (transitives want SDK 36-era activity → AAR metadata failure on AGP 8.7.3)
- Kotlin **must stay >= 2.2**: Haze ships Kotlin 2.2 metadata; older
  compilers crash in FIR with misleading `source must not be null`.
- `android.suppressUnsupportedCompileSdk=36` is set (AGP 8.7.3 tested to 35).
- JDK 17 (`Microsoft\jdk-17.0.20.101-hotspot`), SDK at
  `%LOCALAPPDATA%\Android\Sdk`, `local.properties` points there.
- Emulator: `Pixel_API36` (Android 16, API 36), WHPX acceleration.
  **No audio out** — verify playback via UI state + logcat, never sound.
  Emulator DNS breaks often (`unknown host` — reboot does NOT fix it):
  `adb shell settings put global private_dns_mode hostname` +
  `settings put global private_dns_specifier dns.google`, then relaunch.

## File map (`app/src/main/java/com/cresca/app/`)

| File | Contract |
|---|---|
| `MainActivity.kt` (~3300 lines) | ALL UI + orchestration. Local `fun`s: `play` (offline-first), `togglePlay`, `playList`, `playFile`, `enterVideo`/`exitVideo`/`switchVideoQuality`/`pickQuality`/`playDash`, `openSeeAll`, `openPlaylist`. Sheets: full player, queue, see-all, session, downloads, playlist, picker, new-playlist, profile. |
| `YoutubeRepository.kt` | Extractor facade. `searchSongs` (StreamInfoItem, duration ≤ 600 s), `audioUrl(s)` (5 h cache, ranked hosts), `videoOptions`/`videoUrl` (muxed ≤720p, 5 h cache), `videoDetails` (credits + DASH url), `dropCachedUrl`. Custom OkHttp downloader (25 s timeouts) attaches login cookies. |
| `PlayerQueue.kt` | Queue engine. `order` list (identity/shuffled), manual repeat (player stays un-looped), `resolveAndPlay`, `primeNext` (buffers N+1 behind current), `confirmAdvanced` (adopts gapless flip), `retryWithNextUrl` (403 fallback). |
| `PlaybackService.kt` | MediaSessionService. Owns audio ExoPlayer (1.5 s start buffer). Foregrounds **only when playback starts** (eager foreground = ANR). 10 s progress ticker for Live Updates. |
| `Precache.kt` | BG store for next songs: CacheWriter audio bytes (10 MB cap) into ExoCache + Coil disk-cache artwork warm. Called on every track change for the next 2. |
| `ExoCache.kt` | 300 MB SimpleCache singleton backing the player datasource. |
| `LiveUpdateProvider.kt` | Delegates to Media3 default provider, rebuilds as promoted `ProgressStyle` on API 36+ (`android.requestPromotedOngoing` extra). Fallback elsewhere. |
| `LyricsRepository.kt` | lrclib fuzzy `/api/search` with artist/title cleaning (channel blobs + label blocklist dropped) and scored candidates → `lyrics.ovh` → `NotFound`. |
| `LyricsFlow.kt` | Karaoke view (active red/bold/scaled, auto-scroll). |
| `VideoSheet.kt` | `InlineVideo`: **bare surface on the session player** (no own player, no controller). Only expand + quality buttons. Expanded dialog forces landscape via unwrapped Activity (dialog contexts are wrappers!). |
| `SessionSheet.kt` / `YtSessionManager.kt` | WebView login (**desktop UA**, else Google 403s embedded agents), encrypted prefs session, `loginFailed` hint flow. |
| `DownloadStore.kt` | DownloadManager engine. Filenames `Artist - Title.m4a`; `cresca_prefs/dl_location` = `app` (private) or `device` (public Music); rows keyed by trackId. |
| `PlaylistStore.kt` / `LikedStore.kt` / `SongCache.kt` | JSON in filesDir/cacheDir. SongCache TTLs: home 12 h, search 30 min. |
| `UpdateCheck.kt` | Daily GitHub releases poll (no auth), semver compare, home banner. |
| `ui/theme/` | Apple palette (`AppleRed #FA243C`), heavy type, light/dark. |

## Architecture invariants (do not break)

1. **One player for audio+video**: the session player swaps audio⇄video
   `MediaItem`s at the same position. No second player (old dual-player
   design caused unsynced video). Video items use mediaId `"v:"+id`.
2. **UI never guesses state**: `Player.Listener` mirrors ExoPlayer into
   Compose state. `STATE_ENDED` → `queue.next()`; auto-advance onto a primed
   item → `queue.confirmAdvanced()` via `onMediaItemTransition`.
3. **Gapless model**: player list is `[current]` or `[current, primed-next]`.
   Manual `next()` uses `seekToNext()` when index 1 matches, else resolves.
   Never prime in video mode (would autoplay audio after video).
4. **Repeat is manual**: player `repeatMode` stays OFF; ONE replays,
   ALL wraps. (ExoPlayer auto-loop would break queue advance.)
5. **403 recovery**: `audioUrls` (ranked) + `retryWithNextUrl` + `dropCachedUrl`.
   Sustained 403s = IP throttling → PO-token work (not implemented).
6. **Songs-only**: search drops non-streams and items > 10 min.
7. **No demo data**: empty states are spinners / error + Retry / reconnect
   reload via `NetworkCallback`. Never ship placeholders as content.
8. **Store I/O off main**: all JSON/prefs file work on `Dispatchers.IO`
   (likes/session/playlists/caches). EncryptedSharedPreferences on main
   thread ANRs.
9. **Config changes handled** (`configChanges=...` + portrait lock);
   fullscreen video requests landscape at runtime and restores portrait.

## Kotlin/Compose gotchas hit in this repo

- **Local `fun` forward references are illegal.** Order matters:
  `metaFor` is top-level for this reason; `primeTick`/`videoFollowTick`
  trigger-states decouple callbacks defined before their targets.
- **`SnapshotStateList` is NOT in `androidx.compose.runtime.*`**
  (it's in `.snapshots`). Missing import produces pages of fake
  "stdlib broken" errors (`size`/`!` unresolved).
- **`animateColorAsState` lives in `androidx.compose.animation`**, not
  `.animation.core`.
- **Haze `hazeEffect` needs a separate `hazeSource`**; effect on scrolling
  content is expensive. `Modifier.blur()` is API 31+ only (no-op below).
- **ModalBottomSheet + `containerColor=Transparent`** shows home through
  the sheet — use an opaque container. Default text color inside custom
  containers: force with `Surface(contentColor = White)`, don't trust
  inherited `LocalContentColor`.
- **Dialog/sheet `LocalContext` is a wrapper** — unwrap to Activity via
  baseContext chain before `requestedOrientation` etc.
- **Manifest `screenOrientation="portrait"` does NOT block runtime
  landscape requests** — if rotation fails, suspect the context, not
  the manifest.
- After structural edits, run a brace-balance check before building;
  a single dropped `}` avalanches into hundreds of fake errors.

## Build / verify loop (Windows PowerShell)

```powershell
$env:JAVA_HOME="C:\Program Files\Microsoft\jdk-17.0.20.101-hotspot"
$env:ANDROID_HOME="$env:LOCALAPPDATA\Android\Sdk"
# background build with logs:
Start-Process C:\Gradle\gradle-8.9\bin\gradle.bat `
  -ArgumentList "assembleDebug","--console=plain" -WorkingDirectory <repo> `
  -RedirectStandardOutput build.log -RedirectStandardError build-err.log -WindowStyle Hidden
```

- First failure source: `build-err.log`. AAR metadata errors → SDK/AGP
  pins above. FIR `source must not be null` → stale Kotlin daemon:
  `gradle --stop`, kill zombie `kotlin-daemon` java processes (a 2.0-era
  daemon WILL poison 2.2 builds — check `CommandLine` for version).
- Install/launch: `adb -s emulator-5554 install -r
  app\build\outputs\apk\debug\app-debug.apk`,
  `adb shell monkey -p com.cresca.app -c android.intent.category.LAUNCHER 1`.
- Log tags: `Cresca:I` (app), `VideoSheet:I`, `LiveUpdate:W`.
- Precise taps: `adb shell uiautomator dump`, parse per-`<node>` bounds
  (dumps are single-line XML — regex per node, not per line), tap centers.
- Screenshots: `screencap -p`, `adb pull`, downscale with PIL for reading.
- Emulator losing DNS (`unknown host`) is environmental — see toolchain note
  above, don't chase it as an app bug. System-UI ANRs under host load are
  environmental.
- Playback proof on emulator: logcat `playing <title>`, ⏸ icons,
  advancing seek positions, Opus decoder lines. Media notification:
  expand shade. Media session: `dumpsys media_session`.

## Release flow

1. Bump `versionCode`/`versionName` in `app/build.gradle.kts`.
2. `assembleDebug`, sanity-install on emulator.
3. Curate `docs/img/*.png` screenshots.
4. `git add -A` (never commit `*.log`, `build/`, `.gradle/`, APKs —
   `.gitignore` covers these), commit, `git push`.
5. `gh release create vX.Y.Z <apk> --repo ritz0007/Cresca`
   (gh CLI authenticated; copy APK out, release, delete the copy —
   APKs live on Releases only).
6. Download counts = install stats (release page/API/badges). The app
   reports nothing (privacy promise).

## Known open threads (as of v0.6.0)

- Sustained YouTube 403 throttling → needs PO-token support.
- ChatGPT-generated logo blocked (Cloudflare bot-check vs automation);
  vector crescent-note mark stands in. Drop-in PNG swap is trivial.
- Personalized (logged-in) home feed: session attaches to traffic, but
  liked/history playlists aren't fetched yet.
- Live Updates chip needs a real Android 16 device (emulator is API 34).
