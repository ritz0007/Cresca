# Changelog — Cresca Music

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
