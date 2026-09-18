# Features — Cresca Music

## Listen Now
Live rails from YouTube: Top Picks, Recently Played (last 12 on device),
New Releases (second cached query), Moods pattern tiles (deep-search on tap).
Hero card with working Play / Shuffle (whole list becomes the queue).
Every "See All" opens the full list. Splash + animated intro on launch.

## Search
Debounced live search with instant cached results, song-only results,
per-row overflow menu. Double-tap the Search tab icon to focus with the
keyboard open.

## Row menu (everywhere)
Play, Play next, Add to queue, Add to playlist, Download, Like, Share
(system sheet), Open in YouTube.

## Full player
Artwork, seek bar with times, shuffle / prev / play / next / repeat
(off/all/one), Video toggle, Like, Queue, Download, karaoke lyrics with
auto-scroll. Mini-player mirrors honest ExoPlayer state (loading spinner,
error text, progress hairline) and opens the sheet on tap.

## Up Next queue
Shuffle keeps the current song first; repeat one replays; repeat all wraps;
auto-advance on track end; tap-to-play; remove per row.

## Video
Audio-to-video toggle opens the music video (muxed mp4 <= 720p) in a
fullscreen player with controller. Audio pauses underneath.

## Lyrics
Synced LRC from lrclib, active line highlighted + scaled, auto-scroll,
plain-lyrics fallback, honest empty state for compilations.

## Playlists
Library -> New (dialog) or any row menu -> Add to playlist (picker with
inline create). Playlist screen: mosaic cover, Play/Shuffle, removable rows,
delete playlist, and **Suggested** at the bottom computed from the
playlist's own artists (tap + to add, tap row to preview).

## Downloads
Row menu / player button enqueues via system DownloadManager into
`Music/Cresca`. Library shows the count; Downloads sheet lists size,
plays offline (no network), deletes cleanly. Replay prefers the file.

## Library
YouTube session card (sign in/out), Downloads entry, Playlists, Liked Songs
(heart anywhere), Recently Played. Liked + recents persist on device.

## YouTube login
In-app WebView sign-in; session (cookies + visitor data) stored encrypted;
attached to extractor traffic. Sign out wipes cookies. Nothing leaves
the device.

## Speed
Disk cache home (12 h) / search (30 min); 5 h stream-URL memory cache;
next-track prefetch; 1.5 s initial buffer; Coil artwork cache.

## Look
Apple Music light/dark theme, Cresca red `#FA243C`, liquid-glass bottom
bars (Haze), adaptive launcher icon, animated splash + intro.

## System integration
- Media notification with artwork/title/controls + lockscreen controls
  (MediaSessionService, background playback).
- Android 16+ Live Updates: promoted ongoing chip in the status bar,
  top-ranked drawer entry and lockscreen, live song progress bar
  (`LiveUpdateProvider`, `ProgressStyle`, 10 s ticker). Older Android
  versions keep the standard media notification.
