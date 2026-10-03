# Cresca JAM server (Python)

Same listen-together relay as `../jam-server` (Node), rewritten for the
**Python** egg on Pterodactyl. Same wire protocol — the Android app works
with either box unchanged, and both stay tiny (stdlib + ONE dependency,
no DB, no audio: phones stream YouTube directly, this box only passes
~200-byte JSON sync notes).

## Run locally

```bash
cd jam-server-python
pip install -r requirements.txt
cp .env.example .env   # optional: tweak port/limits (env vars override it)
python server.py        # :13009
```

Config lives in `.env` (see `.env.example`): `PORT` (default 13009),
`JAM_MAX_ROOMS`, `JAM_MAX_MEMBERS`, `JAM_MAX_QUEUE`, `JAM_ROOM_TTL_HOURS`,
`JAM_EMPTY_TTL_S`, `JAM_CREATE_PER_MIN`. Real environment variables
always win over the file — that is how Pterodactyl injects `PORT`.

On boot it prints the endpoint(s), e.g.:

```
cresca-jam (python) listening on :13009
  JAM endpoint:  ws://192.168.1.20:13009
  Health check:  http://192.168.1.20:13009/health
  Local endpoint: ws://127.0.0.1:13009
```

**Send the `ws://…` line to whoever needs it** — paste it into the app:
Player → JAM button → server field → Start/Join.

## Pterodactyl deploy

1. Create a server with the **Python** egg.
2. Upload `server.py` + `requirements.txt` + your `.env` (or set
   variables in the panel — they override `.env`).
3. Startup command: `python server.py`
4. Install step: `pip install -r requirements.txt`
5. Add **one allocation** for port **13009** and set the `PORT`
   environment variable to `13009` (or just rely on `.env`).
6. Memory limit: **128–256 MB** is plenty (CPython + one lib).
7. The app ships pointed at this box internally — nothing to paste
   anywhere. Friends join from inside the app with the 6-letter code,
   a QR scan, or a `cresca://jam/<CODE>` link.

## Protocol (v3 event-only — see docs/JAM.md skill)

Same wire as the Node box: `create` `join` `state{track,pos,playing}`
(host, transport events only) `queue` (host) `add` `control` `allow`
(host) `sync_req` (fresh-state plea, 2 s/room floor) `ping` `leave`
`end` (host) → `created` `joined` `members` `state{…,st}` `queue`
`add`/`control`/`sync_req` (host only) `allow` `pong` `ended` `error`.

## How sync stays tight (v3)

Event-only: the host emits on transport events (track/play/pause/seek),
never a heartbeat. Once a song plays, every device free-runs
uninterrupted — no drift correction, no speed tricks. Guests adopt the
host queue wholesale, and the shared server clock (`st` + `ping`/`pong`
offset) places late joiners and resume-from-pause exactly.

Guards: 100 rooms max, 12 members/room, 60-track queue cap, 8 KB message
cap, 800 ms host-state floor, 5 creates/min/IP, 3 h room TTL, empty rooms
reaped after 60 s.
