# Privacy Policy — Cresca Music

**Effective date:** October 11, 2026
**Applies to:** Cresca Music for Android (Flutter app under `cresca-flutter/`; the retired native Kotlin player is archived on branch `archive/native-kotlin`).

## TL;DR

Cresca has no account, no analytics, no ads, no trackers, and no Cresca server that collects your data. Your library, likes, playlists, history, downloads, and login session stay on your device. The app talks directly from your phone to YouTube, lyrics providers, GitHub (update check), and Spotify (only if you use import) to fetch the content you request. Those third parties see standard network data (e.g. IP address, requested song titles) under their own policies.

## 1. Data we do NOT collect

- No analytics, crash auto-upload, telemetry, or fingerprinting. Verified: no Firebase / Crashlytics / Sentry / Amplitude in `cresca-flutter/pubspec.yaml`.
- No Cresca backend that stores your listening, identity, or contacts.
- No advertising identifiers, location, contacts, camera, or microphone access.
- The only aggregate counts that exist are GitHub's public release download counts on the Releases page. That comes from GitHub, not the app.

## 2. Data that stays on your device

Stored locally via `SharedPreferences`, app files / cache, `path_provider` storage, and encrypted storage (`flutter_secure_storage` / `EncryptedSharedPreferences`):

- Library: liked songs, playlists (incl. Spotify IDs for synced playlists), recently played, favorite artists, home-feed / discovery state.
- Playback state: queue, positions, podcast subscriptions, episode resume positions, sleep-timer and speed settings.
- Downloads and artwork / stream cache (predictive cache, lyrics memo).
- Settings: theme, motion switch, lyric offsets, notification / Live Updates prefs.
- Login secrets (only if you sign in):
  - YouTube session cookies (`lib/auth/session.dart`), encrypted on device. Sign-out wipes them.
  - Spotify tokens + PKCE verifier/state (`lib/auth/spotify.dart`), encrypted on device. Only created if you use Spotify import.

Clearing app data or uninstalling deletes all of the above. Sign-out / Spotify disconnect deletes the respective session without affecting the rest of the library.

## 3. Android permissions

Declared in `cresca-flutter/android/app/src/main/AndroidManifest.xml`:

| Permission | Why |
|---|---|
| `INTERNET` | Stream audio/video, artwork, lyrics, update check. |
| `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` | Background audio via `audio_service` (`mediaPlayback` type). |
| `POST_NOTIFICATIONS` (runtime-prompted, Android 13+) | Player controls, download / updater progress, Live Updates card. |

Not requested: storage (`READ/WRITE_EXTERNAL_STORAGE`), location, contacts, camera, microphone, phone state. Device-Music downloads use scoped `MediaStore` via `background_downloader`. Phone-call pause/resume uses the audio-focus path, not call-log permissions.

## 4. Third parties your phone contacts directly

Cresca has no proxy server — your device contacts these services itself when you use the related feature. They receive what is needed for the request (typically your IP, song title/artist, video ID, or app version) under their own privacy policies:

| Feature | Service | What is sent |
|---|---|---|
| Search, streams, artwork, music videos, captions | YouTube / YouTube Music (Google) | Search text, video IDs, caption-track URLs |
| Synced / plain lyrics (`lib/data/lyrics.dart`) | LRCLIB, QQ Music, NetEase, KuGou, Musixmatch, Genius, lyrics.ovh | Artist + title (+ duration for scoring); standard HTTP headers |
| Update check (`lib/app/updates.dart`) | `api.github.com` (`<owner>/<repo>/releases`) | App version / repo name to compare releases |
| Spotify import (opt-in only, `lib/auth/spotify.dart`) | `accounts.spotify.com`, `api.spotify.com` | OAuth PKCE flow, read-only library scopes; tokens stay on device |
| Fonts / images | Google Fonts, CDN artwork hosts | Font / image fetch for rendering |
| iOS stopgap only (`ios-sideload/`) | Invidious | Stream lookup for the self-built Swift player |

No lyrics, search, or playback request is logged by Cresca itself. Memoized lyrics (`128-entry LRU`) exist only to avoid repeat network hits.

## 5. Group listening (JAM)

JAM (`docs/JAM.md`, `lib/jam/`, `jam-server/`, `jam-server-python/`) is opt-in per session:

- Audio **never** goes through the JAM relay. Each phone streams YouTube directly; the relay only passes ~200-byte sync notes (room code, display name, track IDs / queue, play/pause/seek positions, control wishes).
- Rooms are ephemeral: capped at 12 members / 60 queued tracks / 8 KB messages, expire after ~3 h idle or 60 s empty, and store only the last host snapshot for late joiners.
- If you self-host the relay, its operator (you or whoever hosts it) can see room traffic while it runs. The default experimental box is not a data store.
- Join codes, QR codes, and `cresca://jam/<CODE>` links are shared by you via the system share sheet.

## 6. Sharing you initiate

- Share actions (track / video / JAM invite) use the Android share sheet (`share_plus`, `url_launcher`). Nothing is sent until you tap share.
- "Share crash log" (Settings) opens the share sheet with a local log file — you choose where it goes. Cresca never uploads it automatically.

## 7. Security

- Login cookies and Spotify tokens use encrypted on-device storage. Transport is HTTPS for API traffic (`usesCleartextTraffic=true` is retained only for CDN/artwork host compatibility).
- No method of transmission or storage is 100% secure; protect your device lock screen and OS updates.

## 8. Retention and your choices

- Retention: local data persists until you delete it (in-app delete / sign-out / disconnect), clear app data, or uninstall.
- Access / deletion: everything is on your phone — view it in Library / Settings, delete playlists / downloads / history in-app, wipe sessions via Sign out / Spotify disconnect.
- Opt-outs: don't sign in to YouTube or Spotify, decline notifications, skip JAM, or stay offline after downloading to minimize network requests.

## 9. Children

Cresca is a general-audience music player with no age gate and no parental-control bypass. It does not knowingly collect children's personal data because it collects no personal data at all. Content comes from YouTube and third-party lyrics services, which may contain explicit material — supervise minors' use.

## 10. Changes and contact

This policy may change with app updates; the current version lives in `PRIVACY.md` in the repo and will note a new effective date. Questions or deletion help: open a GitHub issue on the Cresca repository with your app version (Settings → About), device, and Android version. Do not paste login cookies or tokens in issues.
