# Phase 3 — Library & extras

Covers: P7–P9, P16, R2–R3, L1–L6, G1–G2, Y2–Y4 (+ P5 repeat wiring if open).

## Steps

- [ ] Radio (R2–R3): saved cards + 6 stations; song radio endless (200 cap),
  extend-on-scroll, Save-as-playlist, like (RadioStore port: 30/200 caps,
  liked-first sort, atomic json)
- [ ] Library (L1–L3): hero counts, quick tiles, 2-col folders
  (Liked/Recent/user), fav artists, new-playlist dialog, virtual folders
- [ ] Stores (L6): LikedStore / RecentStore (300) / LikedArtists (500) /
  PlaylistStore (2000/200, mosaic+custom cover, Suggested, rename/delete) /
  PlaybackStateStore (200, trackId reconcile, 5 s ticker) — SAME json
  schemas (compatible with native data)
- [ ] Downloads (L5): `background_downloader`, `Artist - Title.m4a`,
  in-app vs device-Music switch, MB list, offline-first, delete, replay-file
- [ ] Lyrics (P7): lrclib/lyrics.ovh/captions fetch + scoring + parsers port;
  karaoke view (9 s dots, 3 s hold, tap-seek, plain/empty states)
- [ ] Video (P9): video_player (.mpd DASH + muxed), quality picker + caps,
  audio/video toggle, fullscreen landscape, first-frame gate, N+1 prefetch
- [ ] Credits card (P8) + artist page (P15) + playlist screen (P16)
- [ ] YouTube login (G1): webview_flutter, UA/header tricks, secure session,
  logout wipe, taste seeds
- [ ] Spotify (G2): PKCE connect, import mirrors + resume + pacing + caps,
  taste seeds, 6 h sync (no-delete-on-failure)
- [ ] Profile sheet (L4): account, Spotify, engine Fast/Stable, appearance,
  motion, download loc, clear cache, about, crash share, updates UI
- [ ] Updates (Y4): daily check, banner + once-per-tag notification,
  ABI APK pick, downloader + tap-install + unknown-apps settings + progress
- [ ] Live Updates (Y2): method-channel ProgressStyle chip (API36-gated) +
  10 s ticker; permissions (Y3)

## Exit

Cold restore ✓ · airplane-mode offline play ✓ · karaoke in time ✓ ·
video+quality ✓ · login/import/sync ✓ · update flow ✓ · screenshots.
