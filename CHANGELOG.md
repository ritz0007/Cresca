# Changelog — Cresca Music

## 1.5.1 (Flutter port — unreleased; pubspec still `1.5.0+20`)
- Full Flutter rewrite of the native app per `RESTRUCTURE.md` (catalog
  A1–A9, T1–T2, H1–H11, R1–R3, S1–S4, M1, P1–P16, L1–L6, G1–G2,
  C1–C5, Y1–Y4). 27 commits since `v1.4.1`; commit messages report
  `flutter analyze` clean and 138 dart/flutter tests green, live-verified
  on jam16. Native `app/` still ships until Phase 5 archives it.
- Animations / motion: global kill-switch with per-widget static paths,
  press-scale .94, tab drift+fade, staggered rails, shimmer skeletons
  (`lib/app/design.dart`, `lib/core/motion.dart`, `lib/app/app.dart`).
  Default is currently OFF (`motionOn = false`, persisted in
  `lib/app/state.dart`) — native default was ON (catalog A4); confirm
  the intended default before release.
- Adaptive text: `AdaptiveText` + WCAG luminance/contrast helpers in
  `lib/app/design.dart` (pure/static, compositor-safe, no animation or
  BackdropFilter in the helpers).
- Discovery algorithm: vibe + smart-shuffle scoring
  (`lib/core/discovery.dart`), home-feed model (`lib/core/home_feed.dart`),
  pure-Dart queue engine (`lib/core/queue.dart`), YTM server-driven home
  shelves via `parsePlaylistCards`/`parsePlaylistItems` with cached index
  and post-query enrichment waves.
- Lyrics: 4-leg fetch (YouTube captions → LRCLIB → KuGou → lyrics.ovh) +
  scoring + LRC/VTT/SRT/timedtext parsers (`lib/data/lyrics.dart`),
  karaoke panel with ≥9 s gap dots, 3 s manual-hold, tap-to-seek
  (`lib/app/widgets/lyrics_panel.dart`), KuGou hash/search/download leg
  with provider attribution + Change retry row, translation + Hinglish
  romanization companion (`lib/data/translate.dart`).
- Video: P9 session-driven music-video mode with 1080p DASH + caps +
  muxed fallback + quality picker, fullscreen landscape dialog,
  first-frame gate, next-video prefetch
  (`lib/app/widgets/video_sheet.dart`).
- Search: debounced (250 ms) music-only search with instant cached results
  first, <180 ms suggestions, artist row, S3 song gates (30 s–10 min, no
  Shorts/LIVE/episodes/trailers, junk-title filter) enforced in
  `lib/core/track.dart` + `lib/data/repository.dart`.
- Offline: downloads as `Artist - Title.m4a` via `background_downloader`
  with in-app vs device-Music location switch, MB list, offline-first
  replay (`lib/app/downloads.dart`,
  `lib/app/widgets/downloads_sheet.dart`); TTL caches per C1 numbers
  (`lib/data/cache.dart`); cold-start session restore with no autoplay
  (`lib/core/session.dart`).
- Also in this port: Phase 4 JAM protocol/client/session/sheet/tests,
  Y4 daily update check + banner + download/install
  (`lib/app/updates.dart`), on-device crash ring A9
  (`lib/app/crash.dart`), Y2 Live Updates driver + Y3 notification
  permission (`lib/system/live_updates.dart`), Spotify PKCE auth slice
  (`lib/auth/spotify.dart`), encrypted YouTube session G1
  (`lib/auth/session.dart`, session sheet).
- Fixes since the port began (per commit messages): Range pre-flight skips
  403s in seconds; shell-overlay mini-player Material-wrapper crash fix;
  artist resolve skips YTM type badges + strips "Topic"; endless-scroll
  reentry guard; tab bar pinned to bottom; Glass compositor
  ClipRRect/BackdropFilter paint-bisect fix; NewPipe-equivalent phone
  resolve leg (current ANDROID client + session sts); AudioServiceActivity
  + cleartext-localhost proxy + skip-budget placement fixes.
- Known issues (must clear before release):
  - Release builds still sign with DEBUG keys
    (`cresca-flutter/android/app/build.gradle.kts`:
    `signingConfig = signingConfigs.getByName("debug")`,
    "Signing with the debug keys for now"). No `key.properties` exists
    under `android/` or `cresca-flutter/android/`. Phase 5 requires
    reusing `app/cresca-release.keystore` via a gitignored
    `android/key.properties` — not done.
  - Android build pins AGP 9.1.0 + Kotlin Gradle Plugin
    `org.jetbrains.kotlin.android` 2.4.0 with the
    `kotlin { compilerOptions { jvmTarget = JVM_17 } }` DSL; expect
    KGP/AGP deprecation or migration warnings on the release build —
    capture and record the exact warning text before sign-off.
  - Version bookkeeping: `cresca-flutter/pubspec.yaml` still
    `1.5.0+20`; bump name/code for 1.5.1 at release time.
- Feedback system (U8): one shared toast helper
  (`lib/app/widgets/cresca_toast.dart` — hide-before-show, 3 s,
  maxLines 2, margin above the measured bottom chrome) + crash-log
  breadcrumb on every user-path failure. Wired: sheet open (player,
  queue, downloads, audio output/pipeline, JAM, video, session,
  settings, track menu), logout wipe (incl. PO-token + taste seeds,
  success toast "Signed out"), share, Spotify connect, update
  check/download/install (failed-check banner copy "Update check
  failed — Retry"), downloads delete/restore/offline-play, queue
  reorder/play/add, lyrics retry/translate notices, playlist picker
  save. Background work (prefetch, suggestions, memo probes) stays
  silent with `// silent:` comments. 4 widget tests
  (`test/cresca_toast_test.dart`); 202 tests green.
  - Application ID changed to `com.cresca.cresca_app` (native was
    `com.cresca.app`): side-by-side install, no upgrade path — decide
    the ID story before release.
  - Manifest sets `usesCleartextTraffic="true"` (localhost just_audio
    proxy); scope or document before release.

## 1.4.1
- Updater reliability: verified-complete installs only (partial files no
  longer reach the installer — no more "problem parsing the package"),
  failed downloads are cleaned with their record, unknown-apps permission
  is checked first with a deep-link to the exact settings page + auto-
  continue on return, releases-list fallback + no-cache + manual retry,
  live download % bar in Profile, stale banners cleared
- Library + Profile redesign: gradient hero with counts, quick-action
  tiles, full-bleed overlay playlist cards with stagger, grouped iOS-
  style settings cards with staggered entrances
- Clean artist names everywhere ("Video"/"Song" uploaders resolve to the
  real singer or Unknown Artist, never junk)
- Real artist search (multiple artists with art per query), Artists row
  in search, rich artist pages (stats, Play/Shuffle, favorite heart),
  Favorite Artists strip in Library
- Song Radio rework: radios persist as square cards (like, save as
  playlist, endless songs sheet), player 3-dot menu gains Start radio

## 1.4.0
- Spotify import + live sync: one-tap login (baked client ID, PKCE, no
  secret in repo/APK), background import with live Library growth,
  kill-safe resume, 6-hour mirror sync (adds/removes), taste seeds
- Music-video toggle fix: music→video now resolves the official music
  video (YTM parity) instead of replaying the art-track
- Trending videos: home rail after Top Picks (muted autoplay + mute
  toggle, tap plays the video) + new Trending tab (Top 100 Global,
  Hindi, International, Telugu, Punjabi, weekly cache)
- Song Radio: endless chained radio from any 3-dot menu, lives in the
  Radio tab and grows as you scroll (200/session cap)
- Artist pages: tap any artist name (rows, player, search Artists row)
  for top songs + Play/Shuffle; label-ish names filtered
- Playlist rename + custom gallery covers; Apple-style playlist header
  (big art, round Play, Shuffle, edit)
- Search results now include an Artists row

## 1.3.0
- Player blend rebuild: artwork dissolves into the blurred backdrop (no
  edge, no black boxes), title lives below on the blend, lateral slide
  song changes, 720p-default persisted video quality with all options,
  expand/quality under the picture
- Video reliability: controller-safe surface attach, first-frame spinner,
  live-blur video backdrop, bitmap lifecycle crash fix
- Updater completion: stuck-note cleanup, live % progress, tap-to-install
  states, one-shot installer pop even with notifications off
- Motion pass: directional tab transitions, staggered home rails, press
  physics on every control and card, shimmer skeletons (home + search),
  fading banners/errors, seek-knob growth, queue drag lift, soft
  pull-refresh release — one kill-switch in Profile → Appearance → Motion
  (default ON)
- Seamless updates: notification tap / Settings downloads the APK for your
  exact ABI straight from the release (no browser), tap-to-install on
  completion; release page only as fallback
- Fancy playback motion: bass-driven gentle cover breathe (on-device FFT,
  idle fallback, no permission), spring pop + rolling title swap on every
  song change, mini-player crossfade
- Secure login fix: hardened WebView defeats Google's embedded-browser
  block (device-consistent UA, no package header, synced cookie store)
- New brand: bars-mark launcher icon, Cresca wordmark on boot splash,
  intro and profile
- Instant playback engine: lazy `cresca://` URIs resolve on ExoPlayer's
  loader thread (BitChord pattern) — taps/skips never block on network;
  videoId-keyed 4 GB cache (replays/back-skips hit disk), disk-persisted
  stream-URL cache, single-flight resolve dedup, raced player clients
- Up Next that stays: fixed-20 infinite queue (refills at 15, append-only),
  RDAMVM radio mixes, same-name/episode/Shorts junk dropped everywhere,
  2-per-artist cap, strict 30s–10min song gate, music-only search
- Real history: lifetime 300-song Recently Played (persisted since install);
  YT liked + history pull after login feeds taste rails (never merged into
  local data)
- Released rail: curated playlist shelf, pinned first; rail taps queue the
  whole visible list; video flips pre-resolve the next track
- Karaoke timing fix: mistimed-record rejection, tighter duration bands,
  re-match when stream duration arrives; sharper artwork (YTM w544 +
  maxres fallback)
- Home taste rails (4 personalized, YT seeds) replace filler duplicates

## 0.8.0
- Smoother player: dropped full-screen artwork blur (was re-rendering
  every frame), single-blob ambient wash, animated play/pause morph,
  calmer equalizer bars, crossfading artwork swaps
- Background pre-cache: next 2 songs' bytes (~4 MB each) stored to the
  ExoPlayer disk cache + artwork to Coil disk cache on every track
  change, so skips play instantly on flaky networks
- Home v2, SimpMusic-shaped: Quick/Top Picks first (ROTATED every
  refresh via seed pool), real Charts rail (trending_music kiosk),
  "Because you played" related mixes, endless discovery rails on scroll
- YouTube Music song search (`music_songs`) for picks/suggestions with
  real artist names; true New Releases from artists' channel feeds
  (newest-first) with label-name seed cleaning
- Top Picks as 2-row wide grid; See All is a full page with endless
  continuation pagination (search + charts pagers), play/shuffle-all
- Related autoplay: Up Next tops up to ~20 related tracks on every
  change; skipping past the end autoplays related (endless radio)
- Smart shuffle: shuffle button cycles off -> shuffle -> SMART shuffle
  (2nd click, sparkle icon + "smart" label, preference-scored order)
- Queue sheet split into Previous / Now Playing / Up Next sections,
  opens at Now Playing, manual drag reorder, empty-state hint
- Removed Jump-back-in card and LIVE badge from home
- Top Picks as 2-row wide grid; See All is a full page with endless
  continuation pagination (search + charts pagers), play/shuffle-all
- Related autoplay: Up Next tops up to ~20 related tracks on every
  change; skipping past the end autoplays related (endless radio)
- Smart shuffle: shuffle button cycles off -> shuffle -> SMART shuffle
  (2nd click, sparkle icon + "smart" label, preference-scored order)
- Queue sheet split into Previous / Now Playing / Up Next sections,
  opens scrolled at Now Playing (scroll up/down to explore)
- Manual shuffle: long-press the drag handle on any queue row to reorder
- Related autoplay hardened with artist-search fallback (Up Next fills
  even when related extraction comes back thin)
- Removed Jump-back-in card and LIVE badge from home
- Non-stop playback: unplayable/blocked tracks auto-skip (max 5), then
  surface an error; track-end dead zone fixed (rewinds + pauses on last
  track instead of sticking at ENDED)
- Instant taps: in-flight stream resolves cancel so the last tap always
  wins (generation token); `resolving` can no longer lock out the UI
- YT Music style home: 8 parallel rails (Top Picks, Trending, New,
  Punjabi, Lofi, Workout, Party, Romantic) with per-section cache +
  "More like <artist>" personalized rails from likes/recents
- Spotify-style resume: queue + position + shuffle/repeat persist
  (5 s ticker); cold start restores without autoplaying, primes audio
- Smooth streaming: 300 MB ExoPlayer disk cache, bigger buffers,
  WAKE_LOCK for background play (fixes SecurityException crash)
- No more main-thread store I/O (playlists, session, downloads);
  reconnect reload no longer double-fires home load
- Spotify-style player: blurred artwork background, dominant-color lava wash,
  karaoke ticker above the title, sleek glowing seek bar, credits card
  (plays/likes/release/duration/source via extractor details)
- Karaoke that lands: fuzzy multi-variant lrclib search (channel blobs and
  label names stripped) + lyrics.ovh fallback
- Gapless song change: next track buffered behind current, instant manual
  skip, auto-advance adoption, audio+video URL caches with prefetch
- 1080p video: DASH adaptive manifest with Auto/1080p/720p/480p/360p caps,
  muxed fallback with per-height options
- Downloads saved as "Artist - Title", in-app vs device Music folder choice
- In-app update checker (daily GitHub releases poll + home banner)
- No demo data: loading spinners, offline error + retry, reconnect reload
- Profile page: account, light/dark/system theme, downloads, clear cache
- Login that completes: desktop user-agent defeats the embedded-WebView
  block, failure hint when no session is captured
- Dark-mode status/nav bars follow the theme
- Crash hardening: store I/O off main thread, 25 s network timeouts,
  search auto-retry + manual retry

## 0.5.0
- Background playback service with media session, notification + lockscreen
- Android 16+ Live Updates chip with live progress
- Session-driven embedded video (expand + quality), no separate player
- Fancy mini-player: equalizer bars, red play button, progress bar
- Rotation lock (portrait) with landscape fullscreen video

## 0.4.1
- Instant playback: stream-URL cache, next-track prefetch, tuned buffers, 403 multi-host retry
- Lyrics: fuzzy multi-variant lookup via lrclib search + lyrics.ovh fallback
- Video prefetch cache for faster video open
- Playlists with artist-based suggestions
- YouTube login session (encrypted on-device)
- Downloads via DownloadManager + offline-first playback

## 0.3.0
- Cresca rebrand: `com.cresca.app`, Cresca Music label, crescent-note mark,
  adaptive launcher icon, animated splash + Compose intro
- YouTube login session (WebView sheet, encrypted store, authed requests)
- Downloads via DownloadManager + offline library + offline-first playback
- Playlists: create/add/remove, Spotify-style screen, artist-based suggestions
- Instant playback: stream-URL cache, next prefetch, tuned buffers
- Songs-only filtering (<= 10 min), second New Releases rail
- Liquid-glass bottom bars, double-tap search focus

## 0.2.0
- Full player: shuffle/repeat/queue/video/like, karaoke lyrics
- Up Next queue engine, music video sheet
- Disk cache home/search, boot splash
- Browse/Radio/Library tabs, likes, recents, share/open actions

## 0.1.0
- Apple Music themed shell, live YouTube search + audio playback
- Mini-player, Now Playing sheet, light/dark previews
- SDK/Gradle/Emulator setup from scratch on Windows
