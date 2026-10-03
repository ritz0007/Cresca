# JAM — listen-together skill

How to work on the JAM feature: read this file first. Protocol changes
go to **both** servers (`jam-server/`, `jam-server-python/`), the app
client (`JamClient.kt`), and the suites in `C:\Users\Rish\AppData\Local\Temp\opencode\jamtest`
— then rebuild + emulator-test. Never ship a one-sided protocol change.

## 1. Architecture diagram

```
HOST PHONE                      JAM BOX (Node or Python)          GUEST PHONE
 (the clock)                    (dumb relay, ~200B msgs)          (mirror)
┌──────────────┐                ┌──────────────────┐              ┌──────────────┐
│ PlayerQueue  │──state───────▶│ rooms: code →    │──state─────▶│ PlayerQueue  │
│  (owns audio)│  on: track /  │  {host, members, │  (same msg)  │  := host     │
│              │  play/pause / │   now{track,pos, │              │  queue       │
│  ExoPlayer   │  seek/queue   │   playing,st},   │              │              │
│  streams YT  │  add wish ───▶│   queue[], allow}│◀──control─── │ ExoPlayer    │
│  DIRECT (no  │◀─control/add─ │                  │──sync_req──▶ │ streams YT   │
│  audio relay)│  (executes)   │  st = server     │  (answers    │ DIRECT       │
└──────────────┘               │  clock stamped   │   state)     └──────────────┘
                               │  on every state  │
                               └──────────────────┘
```

Rules that must never break:

1. **Audio never touches the server.** Every phone resolves + streams
   YouTube itself. The box only passes sync notes (~200 bytes).
2. **Host is the only clock.** Guests never broadcast state. Guest taps
   become `control`/`add` wishes the host executes.
3. **Event-only sync.** No heartbeats, no drift correction, no speed
   nudging. Once a song plays, every device free-runs uninterrupted
   until the next transport event (track / play / pause / seek).
4. **Server is stateless-ish.** It stores the last host snapshot per
   room (for late joiners) and relays; it never interprets playback.

## 2. Requirements

### Functional

| # | Requirement |
|---|---|
| F1 | Host: Start JAM from the player → 6-letter code (no 0/O/1/I). |
| F2 | Guest: join by code, QR scan, or `cresca://jam/<CODE>` deep link (auto-join). |
| F3 | Guest's local queue IS the host queue: on snapshot, adopt tracks + current index silently (never restart audio). Autoplay/vibe top-ups disabled while guesting. |
| F4 | Transport events mirror: track change (start at host pos), play, pause, seek. Nothing in between. |
| F5 | Guest WITH host-granted control: taps send wishes (next/prev/play/pause/seek/play_at/add); host executes for the room. |
| F6 | Guest WITHOUT control: may pause LOCALLY for self (solo-pause); resume jumps to host's current position. Any song change attempt (next/prev/seek/queue tap/search play/radio) → toast "Only the host controls the JAM". |
| F7 | Solo-pause clears on: user resume, host track change (applies paused), host pause event, leaving. |
| F8 | Host leaves → oldest member promoted, room survives. Host Ends → room dies with `ended`. |
| F9 | Share sheet: QR code + `cresca://jam/<CODE>` link + plain code fallback. Server address never shown or shared (internal constant). |
| F10 | Fresh guest (join) with stale snapshot: send `sync_req`, host answers with a forced fresh `state`. |

### Non-functional

| # | Requirement |
|---|---|
| N1 | Server idle ≈ bare runtime; per room a few KB; worst-case room traffic ≈ 4 KB/s. |
| N2 | Message cap 8 KB; queue cap 60; members cap 12; rooms cap 100. |
| N3 | State floor 800 ms, queue floor 1 s, create rate-limit 5/min/IP (both servers). |
| N4 | No new heavy dependencies (zxing-core for QR is the only allowed one). |
| N5 | Every failure surfaces a human string in the sheet; socket retries bounded (4 rounds, then manual Retry). |

## 3. Fallback table (ENUMERATED — implement all)

| Situation | Behavior |
|---|---|
| Guest track 403/unresolvable | App's normal auto-skip runs LOCALLY once; next host event re-syncs. Never loop: generation counter cancels stale applies. |
| Host track dies mid-song | Host auto-skips per existing rules → new track event syncs room. |
| YouTube throttles a region/IP | Per-phone problem; room continues for others. No server involvement. |
| Socket drops mid-song | Bounded auto-retry; guest keeps playing locally; on rejoin, `sync_req` re-syncs. |
| Host app killed | Server promotes oldest guest in `members`; new host's next event becomes the clock. |
| Guest joins stale room (>30 s) | `sync_req` → fresh forced state → clean take-over. |
| Oversize/spam frames | Dropped (8 KB cap, floors); sender gets `error`, room unaffected. |
| Room expired (3 h) / empty (60 s) | `ended`, clients show reason, keep local playback. |
| Deep link with bad code | Sheet opens, code prefilled, server rejects with `error`, user retries. |
| QR scan on device without Cresca | Link is `cresca://…` (no web fallback by design — no domain owned). Sheet text explains manual code entry. |

## 4. Message catalog (both servers + client MUST match)

Client→server: `create{name}` `join{code,name}` `state{track,pos,playing[,force]}`
(host) `queue{tracks[≤60],cur}` (host) `add{track}` `control{action,id?,pos?}`
`allow{on}` (host) `sync_req` `ping{t}` `leave` `end` (host).

Server→client: `created{code}` `joined{code,you,host,name}` `members[]`
`state{track,pos,playing,at,st}` (`st` = server ms) `queue{tracks,cur}`
`add{track,by}` (host only) `control{…}` (host only) `sync_req` (host only)
`allow{on}` `pong{t,st}` `ended{why}` `error{msg}` `left`.

`sync_req` relay has a 2 s/room floor (many guests must not pummel host).

## 5. Test plan (run every change)

1. `node jamtest.js` (Node box) and `node jamtest_py.js` (Python box):
   19 checks incl. throttle floors, caps, gating, migration, end, oversize.
2. `node jamlat.js`: wire latency + offset math under simulated +5 s skew.
3. Emulator (Android 16, `jam16`): install `app-x86_64-debug.apk`,
   permission dialog → play song → player → JAM → start/join → screenshots.
   Drive via `uiautomator dump` (never blind-tap); assert with logcat
   (`playing <title>`, `Jam` tag has no `FATAL`).
4. Live cross-check against the hosted box when reachable.

## 6. Skill operating instructions

1. Draw/refresh the diagram above before touching code.
2. Enumerate fallbacks for every new message or state FIRST (table §3).
3. Change protocol in Node + Python + client + suites together.
4. Verify: `node --check` / `py_compile`, both suites green, rebuild APK,
   emulator drive with screenshots, logcat clean.
5. Keep the sheet truthful: every error as text, every denial as toast,
   never a silent dead tap.
