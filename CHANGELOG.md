# Changelog — Cresca Music

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
