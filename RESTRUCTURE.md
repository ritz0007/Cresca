# Cresca → Flutter RESTRUCTURE — master plan

Sources inventoried line-by-line: `MainActivity.kt` (9372 lines),
all 45 support files, `docs/FEATURES.md`, `docs/JAM.md`.
Native `app/` stays shippable until Phase 5. Flutter app: `cresca-flutter/`.

## 1. Full feature catalog (nothing omitted)

Notation: `[ID] feature — key params (native ref)`.

### APP SHELL + THEME + MOTION

- [A1] Splash + animated intro: logo spring 0.5→1 (damping .55/stiff 260),
  tagline fade 600 ms + 250 ms delay, holds 1.2 s after data ready, fade out 400 ms
- [A2] Edge-to-edge, portrait locked, no restart on rotate; landscape only for fullscreen video
- [A3] Theme light/dark/system + song accent: artwork dominant color
  (8×8 avg, saturation boost, ×0.5 darkened, fallback `0xFF3A0A12`)
  revived ×1.8 → `primary`/`primaryContainer`, on-color by luminance>0.45,
  animated between songs; null (no song) = Cresca red `#FA243C`
- [A4] Motion kill-switch (default ON, persisted): tab drift+fade,
  art slide 450 ms, title slide 320 ms, lyric roll 280 ms, press-scale .94,
  shimmer/skeletons; OFF = 1 ms fades, static placeholders
- [A5] Liquid-glass bottom bar (blur + hairline edge) over blurred content
- [A6] Typography scale: displaySmall 34/40 XB, titleLarge 22 B,
  titleMedium 17 SB, titleSmall 13 SB, body 17/15/13, labelSmall 11 SB
- [A7] No haptics anywhere (visual/Toast feedback only) — keep it so
- [A8] System bars follow theme; full player immersive with
  artwork-luminance icon tone (>0.45)
- [A9] Crash log on-device only: `crash/<stamp>.log`, ring of 5, share
  newest (100 KB cap) via system sheet

### TABS (bottom nav: Listen Now, Trending, Radio, Library, Search)

- [T1] Double-tap Search icon (<350 ms) focuses search with keyboard open
- [T2] Tab switch lateral-drift + fade in swipe direction

### HOME (Listen Now)

- [H1] Header `Listen Now` + spinner + `Pull down hard to refresh` hint
- [H2] Custom hard-pull refresh (>200 px release, pinned list, 3-state indicator)
- [H3] Top Picks (taste vibe from last 10 related, else home tracks) + Play-all + Shuffle + See All
- [H4] Rails: Released playlist rail, Charts/Trending/Punjabi/Lofi/Workout/Party/Romantic,
  `Because you played X` (2 seeds), personalized `More like <artist>`, discovery endless rails
- [H5] Trending Videos rail: 16:9 cards, first-card muted autoplay preview, mute toggle, See All → Trending tab
- [H6] Moods dotted tiles (Hindi Love, Workout, Lofi Chill, Party) → deep-search
- [H7] Hero card with working Play/Shuffle (whole list = queue)
- [H8] Skeleton shimmer first load; honest offline error + Retry; silent reload on reconnect; never demo data
- [H9] Update banner (red card → tap downloads) when newer GitHub release exists
- [H10] Staged paint (10→25, breathers), 4-way parallel rails, incremental waves +120 ms
- [H11] See All = full page (not sheet): endless pagination (search/kiosk continuations),
  Play-all + Shuffle-play, `N loaded — tap for more`, warms next-8 on open

### TRENDING / RADIO

- [R1] Trending: Top 100 Global + Hindi/International/Telugu/Punjabi rails (7-day cache, parallel refresh)
- [R2] Radio: saved radio cards (150dp, like-heart overlay, N songs) + 6 static station gradients
- [R3] Song radio: seed + endless chained autoplay (200 cap), Save as playlist, like, auto-extend on scroll

### SEARCH

- [S1] Debounced (250 ms) music-only search + instant cached results first
- [S2] Suggestions (<180 ms, fast engine only) + artist row (real channels, track-derived fallback)
- [S3] Song-only gates everywhere: 30 s–10 min duration, no Shorts/LIVE/episodes/trailers, junk-title filter, distinct IDs
- [S4] Per-row overflow menu (see row menu)

### ROW MENU (everywhere: Play, Play next, Add to queue, Add to playlist→picker+inline create, Download, Like, Share sheet, Start radio, Open in YouTube)

- [M1] All 9 actions with identical behavior on every screen

### PLAYER (full sheet + mini + queue)

- [P1] Full-bleed artwork (maxres for YT IDs), bottom-fade mask, blurred-zoom backdrop, beat breathe 1.2% (bass FFT, idle sine fallback, no mic permission)
- [P2] Rolling lyric ticker on art + dots on interludes
- [P3] Title/artist below art with shadow; artist tap → artist page (when sane)
- [P4] Glowing seek bar: tap + drag scrub, knob swell, time labels; lyric tap-to-seek
- [P5] Transport: shuffle OFF→ON→SMART (smart = preference-scored, current first) + prev/play/next + repeat OFF→ALL→ONE; error line + buffering spinner
- [P6] Actions: Video/Audio toggle, Like, Download, Queue, JAM (dot when active), 3-dot More (8 items + playlist picker)
- [P7] Karaoke lyrics 420dp: synced highlight+scale, dots on ≥9 s gaps, auto-scroll + 3 s manual hold, tap-to-seek, plain fallback, honest empty state
- [P8] Credits card: artist/plays/likes/upload/duration/description/source
- [P9] Video mode: session-driven embed, name+lyric below video, 1080p DASH + caps + muxed fallback + quality picker, fullscreen landscape dialog, first-frame gate, prefetch next video
- [P10] Mini-player: swipe L/R = next/prev (glide + snap-back + peek chevrons), tap opens sheet, equalizer bars, red play button, progress bar, loading/error states
- [P11] Queue sheet: prev/Now/next split, opens at Now, tap-to-play, per-row remove, long-press drag reorder, smart-shuffle label, gapless auto-advance + instant skip, repeat-one replays, end rewinds to 0 + pauses (no dead-end)
- [P12] Queue engine: generation-cancel taps, lazy resolve + videoId cache keys, 2-ahead priming, call-gate (prepare+pause, never play mid-call), 403 host-rotation + 3 retries, auto-skip ≤5 then error, infinite fixed-20 autoplay (≤5 remain, max 2/artist, no same-name, mood-ranked)
- [P13] Session restore: cold start queue + position, no autoplay; 5 s position ticker
- [P14] Calls: pause on call, resume after (only if we paused), mid-call taps park
- [P15] Artist page: hero + top songs + Play/Shuffle + fav-heart
- [P16] Playlist screen: mosaic cover (+custom cover w/ picker), Play/Shuffle/Edit/Delete, removable rows, Suggested from playlist artists

### LIBRARY / PROFILE / DOWNLOADS

- [L1] Hero (counts), quick tiles (Profile, YouTube session, Downloads N)
- [L2] Folders 2-col (Liked heart-gradient, Recent mosaic/history, user mosaics), scrim titles
- [L3] Favorite artists row; New playlist dialog; Liked/Recent virtual folders
- [L4] Profile sheet: account, Spotify (client-ID setup + connect/disconnect + import status),
  engine Fast/Stable, appearance, motion, download location, clear cache, about,
  crash-log share, update rows + install permission
- [L5] Downloads: DownloadManager `Artist - Title.m4a`, in-app vs device-Music switch,
  list with MB, offline-first playback, clean delete, replay prefers file
- [L6] Liked/recent persist (300 cap recent); YT taste seeds (liked+history) for recommendations only

### LOGIN / SYNC

- [G1] YouTube in-app WebView login (undetectable UA, cookie sync), encrypted session,
  logout wipes; session attached to all extractor traffic
- [G2] Spotify PKCE (no secret): client-ID setup, connect, import mirrors
  `Spotify • …` (resume flags, 250 ms pacing, caps 50/500/2500), taste seeds,
  6 h throttled live sync (no-delete-on-failure)

### SPEED / CACHE NUMBERS (must match)

- [C1] Home 12 h / browse-keys / search 30 min / trending 7 d disk caches; stream URLs 5 h mem + 6 h disk (≤1 write/30 s); TLS prewarm
- [C2] 4 GB LRU audio cache (videoId keys), 10 MB per-track cap; art disk cache
- [C3] Timeouts: connect 10 s, read/write 12 s (player 4/6/6 s); pool 12 conns; HTTP/2
- [C4] Resolve: 45 s cap, single-flight join, InnerTube race (music+VR 8 s, web fallback),
  audio-only direct URLs, bitrate sort; 403 → drop URL + retry ×3 → skip
- [C5] 150 ms position clock; 10 s Live-Update ticker; precache waves (next5/prev3/charts6/taste3, top-4 search)

### SYSTEM INTEGRATION

- [Y1] Background playback + media notification (artwork/title/controls) + lockscreen; always-visible prev/like/next
- [Y2] Android 16+ Live Update chip + drawer + lockscreen progress (gated, fallback older)
- [Y3] Notifications permission (33+) + promoted permission (36+)
- [Y4] Updates: daily check, banner + notification once per tag, ABI-picked APK,
  DownloadManager + tap-to-install, unknown-apps settings deep-link, progress UI

### JAM — see docs/JAM.md skill (F1–F10, fallbacks, protocol, tests). Flutter target: Phase 4.

## 2. Native → Flutter mapping

| Native | Flutter |
|---|---|
| NewPipeExtractor + InnerTubeApi/Auth/Client (hand JSON) | `youtube_explode_dart` + `http` custom InnerTube client (port specs/headers/shapes 1:1) |
| Media3 ExoPlayer + ResolvingDataSource + ExoCache | `just_audio` (LockCachingAudioSource, custom resolve via stream API) + `audio_service` session |
| PlaybackService + LiveUpdateProvider + NextActionReceiver | `audio_service` handler + method-channel Live Updates (API36 `ProgressStyle`, custom action receiver) |
| Coil + TrackArt/MosaicArt | `cached_network_image` + same mosaic/gradient fallbacks |
| Haze glass | `BackdropFilter`/`ImageFiltered` |
| EncryptedSharedPreferences / SharedPreferences / files JSON | `flutter_secure_storage` / `shared_preferences` / same JSON schemas (compatible!) |
| DownloadManager (UpdateDownload/DownloadStore) | `background_downloader` |
| WebView login + CookieManager | `webview_flutter` + CookieManager, same UA/header tricks |
| LRCLIB/lyrics.ovh/captions + LyricsFlow/Repository | `http` + ported parsers/scorers + custom karaoke view (same 9 s/2 s/1 s constants) |
| video_player path (ExoPlayer DASH) | `video_player` (.mpd works via ExoPlayer) + quality via track URLs |
| BeatSync Visualizer | adaptation: idle-sine breathe only (no FFT API) — documented deviation |
| Spotify (Auth/Api/Import/Sync) | `url_launcher` + `app_links` + `flutter_secure_storage` + ported import/sync |
| UpdateCheck/Download/Install/Notify | `http` + `package_info_plus` + `background_downloader` + `open_file`/install intent via channel |
| CrashLog | file logger, same ring/format |
| JamClient/Sheet/protocol | `web_socket_channel` + `qr_flutter` + `app_links` + `share_plus` (protocol identical) |
| splash/intro, icons, motion, type scale | `flutter_native_splash` + intro overlay + `flutter_launcher_icons` + global motion flag + TextTheme port |
| Gradle signing | same keystore via `android/key.properties` |

## 3. Cross-cutting numbers (single source of truth)

Duration gate 30–600 s · recents 300 · playlists 2000 tracks/200 lists ·
artists 500 · radios 30/200 · radio session 200 · JAM queue 60 / members 12 /
rooms 100 · skips ≤5 · retries 3 · resolve 45 s · state floor 800 ms · queue
1 s · sync_req 10 s client / 2 s room · creates 5/min/IP · room TTL 3 h /
empty 60 s · session tick 5 s · live tick 10 s · buffers 1500/30000/500/1000 ·
timeouts 10/12/12 (player 4/6/6) · pool 12 · per-track cap 10 MB · caches
4 GB / 12 h / 30 min / 7 d / 5 h+6 h · update 24 h · spotify sync 6 h ·
import pace 250 ms · caps 50/500/2500/1500 · debounce 250/180 ms · pull 200 px ·
double-tap 350 ms · hold 3 s · dots ≥9 s · QR 512 · keystore translations above.

## 4. Phases (detail files in phases/)

1. Foundation → phases/phase-01-foundation.md
2. YouTube core + player → phases/phase-02-youtube-player.md
3. Library & extras → phases/phase-03-library-extras.md
4. JAM parity → phases/phase-04-jam.md
5. Release → phases/phase-05-release.md

Rules: pure-Dart logic + `dart test` first; every network call timeout +
fallback + silent catch; JAM changes follow docs/JAM.md skill (both servers
+ suites); live-verify on jam16 with screenshots; `app/` untouched until P5.
