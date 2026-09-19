# Changelog — Cresca Music

## 0.6.0
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
