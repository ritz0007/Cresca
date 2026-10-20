# Podcast Research — Flutter music app (read-only, 2026-10-11)

Scope: RESEARCH ONLY. No code edited. All claims about existing code cite `file:line`.

## 1. Native Kotlin reference — does it handle podcasts at all?

**Answer: no. The native app is explicitly music-only; podcast/episode shapes are dropped at every layer. There is no podcast tab, no podcast browse path, no episode model.**

- `app/src/main/java/com/cresca/app/YoutubeRepository.kt:43-56` — doc comment "Songs + music videos ONLY. Drops podcast/TV episodes, trailers, Shorts"; `isMusicJunk()` returns true on episode-shaped titles (`ep|episode|eps +\d+`, `S01E03`) and on artist first-segment in `{episode, episodes, podcast, podcasts, trailer, trailers, teaser, shorts}`, plus `full episode` / `episode recap` substrings.
- `app/src/main/java/com/cresca/app/YoutubeRepository.kt:63-77` — `isArtistLike()` returns false for `episode/episodes/podcast`, so podcast uploaders never become display artists.
- `app/src/main/java/com/cresca/app/YoutubeRepository.kt:390-417` — library pulls only `FEmusic_liked` / `FEmusic_history`; `FEmusic_home` home shelves (`:409-417`); charts via `FEmusic_charts` (`:604-610`, `:724`, `:753`). No `FEmusic_podcasts` or any podcast browseId anywhere in `app/src`.
- `app/src/main/java/com/cresca/app/innertube/InnerTubeApi.kt:533-565` — `browseShelves(browseId)` only ever called with `FEmusic_home` / `FEmusic_charts`; body shape is `{"context": contextJson(WEB_REMIX, visitorData), "browseId": browseId}` (`:546-549`). No podcast endpoint.
- `app/src/main/java/com/cresca/app/innertube/InnerTubeApi.kt:100-114` — `searchMusic()` posts `{"context","query"}` with NO `params` on the native side (Flutter added the songs-only `params` later); comment at `MainActivity.kt:3360` and `:8214` says "Music-only: plain search leaks episodes/random videos" — i.e. episodes are treated as contamination, not content.
- `app/src/main/java/com/cresca/app/HomeFeed.kt:98-106` — `LABEL_WORDS` includes `episode, episodes, podcast`, so artist-seed extraction drops podcast words.
- `app/src/main/java/com/cresca/app/spotify/SpotifyApi.kt:126-127` — `if (type == "episode") return null`, explicit podcast-episode drop on import.
- `app/src/test/java/com/cresca/app/InnerTubeTest.kt:106-111` — `isMusicJunk_episodesAndShorts` pins the drop behavior as tested.
- `app/src/test/java/com/cresca/app/SpotifyParseTest.kt:41-54` — `parseTrack_playlistWrapperAndEpisodeDropped` pins episode drop on Spotify import.
- NewPipe paths: `YoutubeRepository.kt:106-137` (`OkHttpDownloader`) wires NewPipeExtractor fetches, but every NewPipe-mapped row funnels through the same `isMusicJunk` gate (`:47` doc: "Shared by the NewPipe mappers here and the InnerTube parsers"). No separate podcast/show mapper exists.

## 2. InnerTube API surface — what exists vs what is missing

### Exists today (Flutter, mirrors native)

| Call | Request shape | File:line |
|---|---|---|
| search (songs-only) | `POST https://music.youtube.com/youtubei/v1/search?key=<WEB_REMIX key>` body `{"context": contextMap(WEB_REMIX, visitorData), "query": q, "params": "EgWKAQIIAWoQEAMQBBAJEAoQEBAQFQ"}` | `cresca-flutter/lib/data/innertube.dart:144-146` (tubeUrl), `:171-185` (searchSongsParams + searchBody) |
| search (unfiltered, video leg) | same endpoint, `searchBody(q, vd, songsOnly: false)` omits `params` | `innertube.dart:179-185`; used by music-video resolve `repository.dart:871-879` |
| suggestions | `POST .../music/get_search_suggestions` body `{"context","input"}` | `innertube.dart:187-192`, `repository.dart:229-242` |
| browse (home/charts/liked/history/playlist) | `POST .../browse` body `{"context": contextMap(WEB_REMIX, visitorData), "browseId": id}` | `innertube.dart:194-199`; callers `repository.dart:202-226` (liked/history), `:246-262` (FEmusic_home), `:291-304` (FEmusic_charts), `:407-427` (VL playlist) |
| next / radio | `POST .../next` body `{"context","videoId", ["playlistId": "RDAMVM<id>"]}` | `innertube.dart:201-209`, `repository.dart:431-467` |
| player (stream URLs) | per-client `playerBody()` in resolve leg, race across VISIONOS/VR/MUSIC/REMIX/PHONE | `cresca-flutter/lib/data/resolve.dart:32-58` |
| client specs | WEB_REMIX 1.20260707.12.00, ANDROID_MUSIC 6.42.55, ANDROID_VR 1.65.10, IOS 21.26.4, VISIONOS 1.02, WEB 2.20260708.00.00, ANDROID 21.26.364 | `innertube.dart:20-142` |
| auth headers | SAPISIDHASH + Origin/X-Origin/Referer/X-Goog-Visitor-Id/X-Goog-EOM-Visitor-Id | `innertube.dart:211-261` |

### Podcast-adjacent parsing that exists (all of it is *exclusion*, not support)

- `innertube.dart:357-391` (`_artistSeg` badge set) and `:398-420` (`_nonSongBadges` incl. `podcast/podcasts/episode/episodes/ep/audiobook/audiobooks`) + `:423-439` (`_isNonSongRow`: first-segment badge check) + `:486-488` (parse drops `_isNonSongRow` rows).
- `innertube.dart:505-513` (`parseMusicItem` duration gates), `:541-549` (`parseVideoItem`: null/`<30s`/`>600s` → null), `:777-784` (`parseRadioPanels` length gate), `:678-706` (`parseSearch`: `requireDuration: true` for music rows + bounded two-kind collector `:633-669` that never collects playlist/album/artist/podcast/channel renderers).
- `repository.dart:1001-1027` (`trackFromExplodeVideo`: `secs < 30 || secs > 600 → null`, `isLive → null`, `isMusicJunk → null`).
- `repository.dart:510-527` (`autoplayFor` labelish set includes `episode/episodes/podcast` + `music/official/films/records` so podcast seeds get no artist-radio filler).
- `core/track.dart:89-115` (`isMusicJunk`), `:176-178` (`isSongDuration` 30–600), `:182-196` (`passesSongGates`), `core/home_feed.dart:354-356` (label-word filter), `app/state.dart:50-93` (`isPlayableSongTrack` + `songsOnlyTracks`, applied to every home/see-all list at `:949`, `:976-1004`, `:1064`, `:1078`, `:1099`, `:1141`, `:1229-1276`, `:1380`, `:1394`, `:1431`), `app/screens/search_screen.dart:198-220` (junk re-filter), `auth/spotify.dart:384-391` (episode drop on Spotify import).

### Missing — endpoint catalog for podcasts (needs live probes; none are wired)

YTM serves podcasts through the same `youtubei/v1` host with different `browseId`s / `params` / renderers. Candidates below are **UNVERIFIED against this codebase's traffic** — each needs a live `curl`/probe before implementation:

1. `browse` with podcast kiosk id — hypothesized `FEmusic_podcasts` by analogy with `FEmusic_home/charts/liked/history` (`repository.dart:202-304`). Verify by browsing YTM Podcasts tab and copying `browseId` (community knowledge says podcast shelves also surface inside `FEmusic_home` for logged-in users as "New episodes" / "Your shows" shelves — check first; that would be cheaper than a new kiosk).
2. `search` with podcast filter `params` — the songs chip is `EgWKAQIIAWoQEAMQBBAJEAoQEBAQFQ` (`innertube.dart:177`). The Episodes/Shows chips use different base64 `params` (ytmusicapi documents `search` filter params per category). Capture from a YTM `search` request with the Podcasts chip active.
3. `browse` show-detail: `MPREb_<id>`-style browseIds (YTM podcast-show pages; exact prefix must be captured live — do NOT hardcode from memory). Response carries `musicResponsiveListItemRenderer` episode rows with `lengthText` of 20–90 min, `subtitle` runs like `Show • Episode title • date • duration`, and `watchEndpoint` videoIds.
4. `next` for episode autoplay: `RDAMVM` radio on an episode id likely returns more episodes; verify.
5. New renderers to expect: `musicTwoRowItemRenderer` with `subtitleBadge` of type `PODCAST`/`EPISODE`, `podcastShowRenderer`/`episodeRenderer` (names TBC on probe) — current `_collectSongRenderers` (`innertube.dart:633-669`) and `parsePlaylistCards` (`:843-886`, skips `FE/SP/UC` and only keeps VL/PL/RD) will skip all of these, so a parallel `parsePodcast*` collector is needed rather than widening the song path.
6. `youtube_explode_dart` (`pubspec.yaml:19`, used in `repository.dart:139-159`, `:469-490`, `:906-935`) has no podcast/show API — it stays the *song* fallback only; podcast fetch must ride InnerTube browse/search directly.

## 3. Data-model gaps

`YtTrack` today (`core/track.dart:9-24`): `{id, title, artist, thumbUrl, watchUrl, localPath}` + JSON keys `{id,title,artist,thumbUrl,watchUrl,localPath}` (`:26-42`). Serialized variants also exist: session items `{id,title,artist,thumb,watch}` (`core/session.dart:131-140`), song-cache `{id,title,artist,thumb,watch}` (`data/cache.dart:235-247`), library rows `{id,title,artist,thumb,watch}` (`app/library.dart:21-27`), download rows `{downloadId,title,artist,name,public}` (`app/downloads.dart:102-111`).

What an episode needs (diff):

| Field | Why | Notes |
|---|---|---|
| `showTitle` (String) | episodes display "Show — Ep title"; `displayArtist()` (`track.dart:46-67`) + `isArtistLike` (`:118-143`) would mangle show names into `Unknown Artist` | additive nullable; default `''` keeps old JSON decodable |
| `durationSec` (int, -1 unknown) | parsers currently *discard* duration after gating (`parseMusicItem` keeps it only as a local, `track.dart` stores nothing); episodes (20 min–3 h) need it for progress bars, remaining-time, sort | -1 = unknown preserves song behavior |
| `publishDate` (String/int) | episode ordering + "new episodes" badges; `VideoDetails.uploadDate` (`data/details.dart:16-31`) is a separate memo store, not on the track | ISO string or epoch ms |
| `resumePositionMs` (int) | per-episode bookmark; session file stores ONE global `positionMs` (`session.dart:42,128`) — insufficient for a show queue | needs `episode_progress.json`-style map `videoId → ms`, not the single-cursor session |
| `kind` enum (`song`/`episode`) or `isEpisode` bool | every gate branches on it: `isMusicJunk`, `isSongDuration`, `songsOnlyTracks`, lyrics, autoplay, downloads | default `song` = zero behavior change for existing rows |
| `description` (String, optional) | show notes; `VideoDetails.description` (`details.dart:20`) exists but is fetched lazily per-track — episodes want it inline from browse | cap length (e.g. 2 KB) to protect caches |

Interaction audit (factual):

- **Duration caps** hit in 6 places, all songs-only 30 s–10 min: `track.dart:178` (`isSongDuration`), `:189` (`passesSongGates`), `innertube.dart:505-513` (search require + known-duration gate), `:545-546` (video backfill), `:780-783` (radio panels), `repository.dart:1008-1009` (extractor). Episodes must BYPASS these via the `kind` flag — never by widening the constants (widening re-opens the "Mohini episodes" leak pinned by `test/core_test.dart:74-79` and `test/data_test.dart:252,402`).
- **Lyrics**: `fetchLrclib` + QQ/Kugou/Netease/Musixmatch/Genius + captions legs (`data/lyrics.dart:680-1167`), memoized per track id (`app/state.dart:231-232`), panel seeks the player (`app/widgets/lyrics_panel.dart:1164`, `player_sheet.dart:312`). Episodes must SKIP lyrics (spoken word has no lyrics; lrclib exact-match would attach wrong song lyrics to an episode title). Gate on `kind == episode → LyricsNotFound`/hidden tab.
- **Queue**: `QueueEngine` (`core/queue.dart:40-583`) is type-agnostic (operates on `YtTrack`), so episodes ride it unchanged; but `rankSuggestions` (`:684-828`) mood/type-first scoring, `autoplayFor`/`endlessRefillFor` (`repository.dart:500-681`) song-graph ranking, and `noteSkipped` decay (`queue.dart:57-69`) are song-taste tuned — episode autoplay should be show-sequential (oldest-unplayed → newest), not mood-ranked.
- **Downloads**: `DownloadStore.enqueue` (`app/downloads.dart:348-463`) does a 4-part chunked fetch with 15-min timeout (`:380-390`), zero-byte validation (`:408-416`), `downloads.json` rows (`:78-111`); `controller.localFileFor = downloads.fileFor` (`app/state.dart:302`) gives offline-first playback. Works for episodes mechanically, but: size math assumes ~10 MB songs (`totalBytes` at `:224-234`, per-track cache cap 10 MB in `data/cache.dart:158` is stream-cache not download, still indicative); a 1 h episode at 128 kbps ≈ 55 MB, a 3 h ≈ 165 MB — the 15-min timeout and `totalBytes` UI need episode-sized budgets, plus per-show grouping in `listAll()` (`:469-535`, currently flat + unknown-origin rows).

## 4. Playback gaps

Runtime: `just_audio ^0.10.5` + `audio_service ^0.18.17` (`pubspec.yaml:20-21`).

- **Long files**: just_audio/ExoPlayer handle 1–3 h files; no code caps track length at playback (`audio/playback.dart` has no duration check; `_loadCurrent` at `:689-794` resolves any `YtTrack` with a URL). Gapless 2-ahead window (`_fillWindow` `:930-966`, `_slideWindow` `:972-998`, prefetch count `audioPrefetchCount = 2` in `data/cache.dart:162`) will prefetch episode-sized streams — acceptable but wasteful on metered data; consider window=0/1 for episodes.
- **Resume-from-position**: PARTIAL. Cold restore seeks once (`playback.dart:566-577` `restore()` → `_loadCurrent(autoplay:false, seekMs: s.positionMs)`; `_setCurrent` `:912-923` and `_setFileWindow` `:895-906` honor `seekMs`), and the 5 s position ticker persists the single cursor (`:526-547`, `sessionTick` `:36`, policy `core/session.dart:63-107`). Missing: per-episode bookmarks (only one global cursor exists), resume prompt UI ("Resume from 23:41?"), and `savePositionTick` writes only when a session file already exists (`:537-538`) — episode progress needs its own store + write path.
- **Playback speed**: MISSING. `playback.dart` only *broadcasts* `p.speed` to the OS (`:98`, `:112`); no `setSpeed`/`setPlaybackRate` call, no UI control, no persistence anywhere in `lib/`. just_audio exposes `player.setSpeed(double)` (plugin capability, not yet wired in this codebase) and audio_service forwards `speed` in `PlaybackState` — so this is pure app-layer wiring: rate button (0.8/1.0/1.2/1.5/1.8/2.0) + `MediaItem`-safe seek + persisted per-episode or global rate.
- **Silence trimming / skip-silence**: MISSING. No `setSkipSilenceEnabled` / loudness-trim API is referenced anywhere in `lib/`; `audio/effects.dart:1-208` is EQ + LoudnessEnhancer via `cresca.audiofx` channel only. just_audio 0.10 has no built-in silence removal; this would need ExoPlayer `SilenceSkippingAudioProcessor` natively or a "skip-forward-30s / back-15s" podcast button set as the pragmatic substitute.
- **Sleep timer**: MISSING. No timer, no `Timer`-based pause, no `stop()` scheduling anywhere in `lib/audio` or `lib/app`. Straightforward additive feature (durations 5/10/15/30/45/60 min + end-of-episode; cancel on manual pause-toggle is a UX decision).
- **Seek UX**: `CrescaAudioHandler.seek` exists (`playback.dart:156-160`, `systemActions: {MediaAction.seek}` at `:94`, `:106`) and lyrics/player sheets seek directly (`lyrics_panel.dart:1164`, `player_sheet.dart:312`) — fine for episodes, but the seekbar/fmt helpers assume song lengths (`fmtMs` in `track.dart:221-227` prints `m:ss` without hours — `3661s` renders `61:01`; needs `h:mm:ss` for episodes).
- **Caches**: stream-URL mem 5 h / disk 6 h (`data/cache.dart:13-20`); bundle memo 24 h (`:22-25`); 4 GB LRU audio budget + 10 MB per-track cap (`:157-159`, planner `:199-230`, sweep `playback.dart:1169-1199`). A 10 MB single-file cap EVICTS long-episode stream-cache files immediately (`planCacheEviction` oversize-first at `:206-214`) — episodes need either an exemption or a larger cap for `kind == episode`, else every replay re-downloads.
- **Notifications for new episodes**: infra exists but is update-only. `flutter_local_notifications ^19.4.0` (`pubspec.yaml:32`) is used by `app/updates.dart:12` for app-update progress; Live Updates cards ride `system/live_updates.dart` via `app/state.dart:434-488` (track-changed/progress). No show-subscription store, no background poller, no episode notification path. Android background limits apply (WorkManager-style periodic poll, not implemented; battery-kind rules used everywhere else in this codebase argue for daily-on-open check first, push later/never).

## 5. UI gaps

- **Home Podcasts tab**: `app/screens/home_screen.dart:167-174` routes `_filter == 'Podcasts'` to `_PodcastsEmpty` (`:326-348`: "No podcasts here / Cresca is music-only — your songs live under All."), chips defined at `:270-324` ("All / Music / Podcasts"). Replacing the empty state with show rails + episode rows is the visible MVP surface; `_filter` is local state (no persistence needed).
- **Library**: `app/screens/library_screen.dart:20-80` (counts, quick tiles, folders, fav artists); stores in `app/library.dart:1-120` (liked 10k cap, recent 300 cap, playlists 200 lists × 2000 tracks). Podcasts need: Subscribed Shows section (new store `podcast_subs.json`), per-show episode lists, "New episodes" virtual folder. Reuse `UserPlaylist` shape or add `PodcastShow`/`PodcastEpisode` types.
- **Player sheet**: needs episode affordances — show title line, rate button, ±15/30 s buttons, sleep-timer entry, speed-persistent `MediaItem`, chapter/description tab instead of lyrics. Current sheets: `app/widgets/player_sheet.dart`, `mini_player.dart`, `queue_sheet.dart`, `track_menu.dart`, `track_row.dart`.
- **Search**: `app/screens/search_screen.dart:198-220` junk-filters everything; podcast search needs a parallel Shows/Episodes result section bypassing `songsOnlyTracks`.
- **Downloads sheet**: `app/widgets/downloads_sheet.dart` + `app/downloads.dart` flat list; episodes need per-show grouping + size display that tolerates 50–200 MB files + `pruneMissing` (`:239-263`) awareness of large files on storage-constrained devices.
- **Offline**: `controller.localFileFor` (`app/state.dart:302`) already routes downloaded episodes to file playback with zero playback-layer changes; the gap is only download budgeting/grouping, not playback.

## 6. Test inventory (files that need new cases)

In `cresca-flutter/test/` (13 files observed):

| File | Why it needs podcast cases |
|---|---|
| `core_test.dart` (`:74-79` junk-episode pins) | `isEpisodeJunk` vs `isMusicJunk` split: songs still reject episodes, episodes accept them; `fmtMs` hours format |
| `data_test.dart` (`:252`, `:402` episode-drop fixtures) | `parsePodcastShow`/`parsePodcastEpisodes` fixtures; `requireDuration` bypass for episodes; `_isNonSongRow` NOT applied to episode rows |
| `home_test.dart` | Podcasts-tab rail assembly, show-shelf titles kept, `minRailTracks` for thin episode shelves |
| `queue_test.dart` | show-sequential autoplay (oldest-unplayed first), episode `kind` surviving `snapshot()`/session round-trip |
| `downloads_test.dart` | 100 MB+ episode enqueue/progress/`totalBytes`, per-show grouping, `.part` sweep for killed episode fetches |
| `session_test.dart` | per-episode `resumePositionMs` map encode/decode; global cursor untouched for songs |
| `policy_test.dart` (`:23-118` ticker/call gates) | 5 s ticker writing episode progress; sleep-timer policy (pure countdown); speed persistence |
| `details_test.dart` | show-notes/description mapping, publish-date parsing |
| `lyrics_test.dart` | episodes skip lyrics (no provider hit for `kind == episode`) |
| `discovery.dart`-adjacent (`core_test`/`data_test` rankers) | episode results excluded from song taste/affinity (`affinityFor`), no mood-rank pollution |
| `updates_test.dart` / `live_test.dart` | episode "new episode available" notification payload shape (once built) |
| `jam_test.dart`, `streamkit_test.dart`, `policy_test` (call gate) | no changes expected — JAM stays song-scoped; document exclusion |

Native `app/src/test/` mirrors to update: `InnerTubeTest.kt:106-111` (junk pins stay for songs), `SpotifyParseTest.kt:41-54` (episode drop stays for Spotify import path).

## 7. Phased implementation plan

**Phase P0 — probes (0.5–1 day, no UI).** Capture live `browseId`s + search `params` + renderer JSON for: YTM Podcasts tab, one show page, one episode list, Episodes/Shows search chips. Save as canned fixtures in `test/` (repo pattern: parsers are fixture-tested, `innertube.dart:8-10`). Decide: new kiosk vs `FEmusic_home` shelves reuse. Go/no-go on bot-gating (see risks).

**Phase MVP — browse + play one episode (3–5 days).**
1. `YtEpisode` (or `kind` on `YtTrack`) + `showTitle/durationSec/publishDate/resumeMs` fields, JSON-compatible defaults.
2. `parsePodcastShelves/parseShowEpisodes` (parallel to `parseShelves`, `innertube.dart:889-937`) + `podcastShow()/showEpisodes()` in `repository.dart` next to `homeShelves`/`playlistTracks`; episode rows BYPASS `isMusicJunk`/`isSongDuration` via `kind` check, never by loosening song gates.
3. Podcasts tab replaces `_PodcastsEmpty` (`home_screen.dart:167-174`) with show rails; episode tap → existing `controller.playQueue` (no playback change; speed 1.0).
4. `h:mm:ss` in `fmtMs` (`track.dart:221-227`); lyrics skipped for episodes.

**Phase P1 — podcast-grade playback (3–4 days).** Rate control (0.8–2.0×, persisted) via `player.setSpeed` + `MediaAction.setPlaybackSpeed` in `CrescaAudioHandler` (`playback.dart:67-184`); ±15/30 s skip buttons; per-episode resume store + "Resume from HH:MM:SS" prompt; sleep timer (5–60 min + end-of-episode); stream-cache cap exemption for episodes (`cache.dart:199-230`).

**Phase P2 — library + offline (3–5 days).** `podcast_subs.json` subscriptions store; per-show episode lists + "New episodes" virtual folder (`library_screen.dart`, `library.dart`); download grouping/sizing for 50–200 MB files (`downloads.dart:348-535`); daily-on-open new-episode check reusing `flutter_local_notifications` (`updates.dart:12` pattern); silence-trim substitute (±30 s + speed covers 90% of need; true DSP trimming deferred).

**Phase FULL — parity extras (5–8 days).** Chapter list from description/MR, show-notes tab, background periodic check (WorkManager, Android limits apply), OPML import, per-show autoplay settings, download-all-new, storage quotas per show.

## 8. Risks

1. **Bot-gating on podcast endpoints.** Stream/player legs already fight the GVS poToken rollout — VISIONOS is the reliable leg (`innertube.dart:101-118`), ANDROID legs 403/Login-required (`resolve.dart:10-13`). Podcast `browse` may gate harder (logged-out podcast shelves are historically thinner than song shelves); authed `cookies/visitorData/poToken` plumbing exists (`tubeHeaders`, `innertube.dart:235-261`) but every new endpoint must be probed logged-out AND logged-in.
2. **Storage.** 1 h ≈ 55 MB, 3 h ≈ 165 MB at 128 kbps; the 4 GB LRU (`cache.dart:157`) holds ~70 episodes max, and the 10 MB per-track stream-cache cap (`:158`) actively evicts episodes today. Episode downloads bypass stream cache (file playback via `localFileFor`) but the cap fix is still required for streaming replays.
3. **Background limits.** Android Doze/background-service limits: periodic new-episode polling needs WorkManager or FCM; the codebase has neither for content (only update APK + live cards). Ship on-open check first.
4. **Gate erosion.** The #1 regression risk is loosening `isMusicJunk`/`isSongDuration`/`songsOnlyTracks` to admit episodes and re-leaking episodes into song rails ("Mohini episodes" bug, pinned by `core_test.dart:74-79`, `data_test.dart:252,402`, `InnerTubeTest.kt:106-111`). All episode paths must branch on `kind`, never widen song constants.
5. **Lyrics mismatch.** Episode titles will exact-match wrong songs on lrclib if the lyrics path isn't gated — must skip before any provider call.
6. **Show-art/copyright.** Podcast art URLs ride different thumbnail hosts/sizes than `sharpThumb`'s `=wX-hY` rewrite (`track.dart:243-252`); verify art sizing per show.

## 9. Effort estimates

| Phase | Scope | Estimate |
|---|---|---|
| P0 probes + fixtures | live capture, canned JSON, go/no-go | 0.5–1 day |
| MVP browse + play | model, 2 parsers, 2 repo methods, Podcasts tab, h:mm:ss, lyrics skip | 3–5 days |
| P1 playback | rate, skip buttons, resume store, sleep timer, cache-cap fix | 3–4 days |
| P2 library/offline | subs store, show pages, download grouping, on-open new-episode check | 3–5 days |
| FULL parity | chapters, notes tab, background poll, OPML, quotas | 5–8 days |
| **Total MVP→FULL** | | **~15–23 days solo** |
