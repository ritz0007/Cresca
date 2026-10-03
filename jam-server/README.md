# Cresca JAM server

Tiny listen-together relay for the JAM feature (Spotify-Jam-style).
One dependency (`ws`). No database, no audio — phones stream YouTube
directly, this box only passes ~200-byte JSON sync notes.

Idle use is a bare Node process (~30–45 MB RSS, almost all of it the
Node runtime itself — the JAM state per room is a few KB) and ~0% CPU.
A full room of 12 people costs a handful of small messages per track change.

## Run locally

```bash
cd jam-server
npm install
node server.js          # listens on :3781 (set PORT=xxxx to change)
```

Health check: `GET /health` → `{"ok":true,"rooms":N}`

## Pterodactyl deploy

1. Create a server with the **NodeJS** egg.
2. Upload `server.js` + `package.json` (or git-pull this repo and set the
   working dir to `jam-server`).
3. Startup command: `node server.js`
4. Add **one allocation** (e.g. port `3781`) and set the `PORT`
   environment variable to match it.
5. Memory limit: **64–128 MB** is plenty. CPU: 25–50% of one core.
6. Install step (`npm install`) runs once; restarts are instant.

In the app: open the player → **JAM** → enter
`ws://YOUR.PANEL.IP:3781` (or `wss://` behind your reverse proxy),
Start a JAM, share the 6-letter code.

## Protocol (for reference, v3 event-only — see docs/JAM.md skill)

Client → server: `create{name}` `join{code,name}` `state{track,pos,playing}`
(host, on transport events, ≥800 ms apart) `queue{tracks[],cur}` (host)
`add{track}` (guest song suggestion) `control{action,id?,pos?}` (guest
transport wish) `allow{on}` (host) `sync_req` (fresh-state plea)
`ping{t}` `leave` `end` (host).

Server → client: `created{code}` `joined{code,you,host,name}` `members[]`
`state{track,pos,playing,at,st}` (`st` = server clock) `queue{tracks[],cur}`
`add{track,by}` (host only) `control{...}` (host only) `sync_req`
(host only, 2 s/room floor) `allow{on}` `pong{t,st}` `ended{why}` `error{msg}`.

Guards: 100 rooms max, 12 members/room, 60-track queue cap, 8 KB message
cap, 5 creates/min/IP, 3 h room TTL, empty rooms reaped after 60 s.

## How sync stays tight (v3 event-only)

Sample-accurate audio sync across different phones over the internet is
physically impossible (each phone fetches YouTube independently, buffers
differ, audio hardware differs) — so JAM syncs on EVENTS and then gets
out of the way:

1. **Transport events only.** The host emits `state` on track change,
   play, pause and seek — never a heartbeat. Once a song plays, every
   device free-runs uninterrupted.
2. **One shared clock.** Every `state` carries `st` (server time). Guests
   sync their offset NTP-style (`ping`/`pong`, min-RTT wins), so
   take-overs, late joins and resume-from-pause land exactly.
3. **Room queue is the queue.** Guests adopt the host snapshot wholesale;
   no local autoplay, no divergence.

Client → server also accepts `ping{t}` → server replies `pong{t, st}`,
and `sync_req` → relayed to the host (2 s/room floor), which answers
with a forced fresh `state`.
