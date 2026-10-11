# JAM Advance Mode

Tight host↔guest sync for listen-together. Wire-compatible with v1:
old clients/servers ignore unknown fields; new caps are negotiated,
never required.

## 1. Protocol (v2, version-gated)

- Version: `jamProtoV = 2` (Dart), `PROTO_V = 2` (both servers).
- Caps: `clock2 ease opid qgen ecodes handoff` (see `jamAdvanceCaps` /
  `SERVER_CAPS`). Clients send `v`+`caps` in `create`/`join`; servers
  echo negotiated `v`+`caps`+`st` (server ms) in `joined`.
- v1 clients (no `v`) get the legacy shape plus harmless extras.
- Health (`/` and `/health`) reports `{ok, rooms, v, caps}`.

### Message catalog deltas (all optional, additive)

| Direction | Message | New fields |
|---|---|---|
| C→S | `create{name,v,caps}` `join{code,name,v,caps}` | `v`, `caps` |
| S→C | `joined{…,v,caps,st}` | negotiated version, caps, server time |
| S→C/host | `state{state,gen}` | `gen`: authoritative state generation |
| S→C/host | `queue{tracks,cur,gen}` | `gen`: authoritative queue generation |
| both | `add{track,by,op}` `control{…,op}` | `op`: idempotency key (echoed on relay) |
| S→C | `error{msg,code}` | `code`: machine-readable reason |
| S→C | `ended{why,code}` | `code` (e.g. `EXPIRED`) |
| S→C | `host{host,handoff:true}` | graceful promotion flag (legacy shape) |

### Error codes (`ecodes`)

`BAD_MSG ALREADY_IN_ROOM NO_ROOM ROOM_FULL SERVER_FULL RATE_LIMIT
NOT_HOST HOST_AWAY NO_CONTROL UNKNOWN`. Every error still carries a
human `msg` — the sheet never shows a silent stall; clients render
`[CODE] msg` when a code is present so logs stay greppable.

### Sync math

- Clock: `offset = st - (t + rtt/2)`, best-RTT sample wins, never
  backslides. `serverNow = local + offset`.
  `expectedPos = pos + (serverNow - st)` while playing, clamped to
  `0 ≤ dt ≤ 30 s` (else hold `pos`).
- Ping burst per connection: `5 × 400 ms`, then steady `1 / 10 s`
  (~6 frames/min idle). `JamClock.reset()` runs on every (re)connect
  so a stale offset never poisons the new socket.
- Drift bands: `|drift| ≤ 350 ms` → hold; `≤ 2000 ms` → ease via
  `±6%` speed nudge (`jamEaseSpeed`); beyond → hard chase (seek).
  Pure helpers: `jamDriftAction()`, `jamEaseSpeed()`
  (mirrored in `lib/core/jam.dart` as `jamCoreDriftAction`).

## 2. Advance-mode behaviors

1. **Clock-offset per connection** — burst + best-sample + reset
   (`JamClient._startPings`, `JamClock.reset/notePong`).
2. **No rubber-banding** — chase past 2000 ms, speed-nudge the middle
   band (auto-restores to 1.0× after 4 s, or immediately on
   hold/chase/track-change), hold inside 350 ms
   (`JamSession._applyHostState`, `_nudgeSpeed`, `_restoreSpeed`).
3. **Single-flight reconnect** — one parked retry timer, ladder
   `1/2/4/8 s ×4` then manual (`jamRetryLadderSec`, `jamRetryMax`);
   every reconnect sets `_needsResync` so the rejoined socket sends
   `sync_req` for a forced fresh state (fast hello + snapshot).
4. **Idempotent queue ops** — `op` ids on `add`/`control`
   (`jamNewOpId`), dedupe on relay (server `seenOps`, bounded 500)
   and on ingest (client `_seenOps`, bounded 200). Replays ack-and-drop.
5. **Authoritative generations** — `stateGen`/`queueGen` per room,
   echoed in every broadcast; guests drop `gen < current` snapshots.
   Stale async applies die via `_applyGen` (fallback-table rule).
6. **Host-handoff / degraded** — host socket close promotes the oldest
   member and broadcasts `host{handoff:true}` + `members`; guests show
   "handing off / holding locally", keep playing, and re-sync via the
   `sync_req` floor. `HOST_AWAY` carries an explicit code.
7. **Reconnect-storm guards** — per-IP join throttle (`20/min`) next to
   the existing create throttle (`5/min`); `sync_req` keeps its `2 s`
   per-room floor; broadcast skips non-OPEN and backpressured sockets
   (`bufferedAmount > 64 KB`), serializing one JSON string per fan-out.

## 3. Tuning knobs

| Knob | Where | Default |
|---|---|---|
| `jamEaseMs` / `jamChaseMs` | `lib/jam/protocol.dart` | 350 / 2000 ms |
| `jamEaseSpeed` ± | `protocol.dart` | 0.94 / 1.06, restore 4 s |
| `jamPingBurstN/Ms`, `jamPingSteadySec` | `protocol.dart` | 5 × 400 ms, 10 s |
| `jamRetryLadderSec`, `jamRetryMax` | `protocol.dart` | 1/2/4/8 s, 4 |
| `jamStateFloorMs/Queue/Sync` | `protocol.dart` | 800 / 1000 / 10000 ms |
| `MAX_ROOMS/MEMBERS/QUEUE/MSG` | both servers | 100 / 12 / 60 / 8 KB |
| `JOIN_PER_MIN` | both servers | 20/min/IP |
| `MAX_BUF_BYTES` | both servers | 64 KB |
| `MIN_STATE_MS`, `sync_req` floor | both servers | 800 ms, 2 s/room |
| `HEARTBEAT` | both servers | 25 s ws ping |

## 4. Test plan

1. `flutter test test/jam_test.dart` (cresca-flutter) — existing
   19-check suite: frames/caps, floors, NTP math, retry ladder, wire flow.
2. New-behavior katas (extend the suite next): drift bands
   (`jamDriftAction` hold/ease/chase), op dedupe replay drop,
   stale-gen queue drop, `joined` v/caps parse, error-code parse,
   handoff parse.
3. `flutter analyze` on touched files — must stay clean.
4. `node --check jam-server/server.js`; `python -m py_compile
   jam-server-python/server.py`.
5. Live: two-device join → kill host app → guest promotes + follows;
   airplane-toggle guest → auto-retry ladder → resync without double
   queue adds; drift the guest clock → ease (no seeks) then chase.
