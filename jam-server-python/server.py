"""Cresca JAM server (Python) — listen-together relay.

Same wire protocol as jam-server/server.js (Node), so the Android app
works with either box unchanged.

Tiny on purpose for small Pterodactyl boxes: stdlib + ONE dependency
(`websockets`). No DB, no framework, no audio relay — phones stream
YouTube directly, this box only passes ~200-byte JSON sync notes.

Run:
    pip install -r requirements.txt
    python server.py            # :13009 (set PORT in .env / env to change)

On boot it prints the ws:// endpoint(s) — paste one into the app's
JAM sheet (Player -> JAM) as the server address.
"""
import asyncio
import json
import os
import random
import socket
import string
import time

try:
    from dotenv import load_dotenv
    load_dotenv()  # .env file next to server.py; real env vars still win
except ImportError:
    pass


def cfg_int(name, default):
    try:
        return int(os.environ.get(name, default))
    except Exception:
        return default


# ---- All tunables live in `.env` (see .env.example). Real environment
# ---- variables always override the file (how Pterodactyl injects PORT).
PORT = cfg_int("PORT", 13009)
MAX_ROOMS = cfg_int("JAM_MAX_ROOMS", 100)
MAX_MEMBERS = cfg_int("JAM_MAX_MEMBERS", 12)
MAX_QUEUE = cfg_int("JAM_MAX_QUEUE", 60)

try:
    from websockets.asyncio.server import serve
    from websockets.http11 import Request, Response
    from websockets.datastructures import Headers

    async def health_check(connection, request):
        try:
            # A WebSocket handshake is also plain HTTP on "/" — never eat it.
            if request.headers.get("upgrade", "").lower() == "websocket":
                return None
        except Exception:
            pass
        if request.path in ("/", "/health"):
            body = json.dumps({"ok": True,
                               "rooms": len(rooms)}).encode()
            return Response(200, "OK",
                            Headers([("Content-Type", "application/json")]),
                            body)
        return None
except ImportError:  # older websockets releases
    from websockets import serve

    async def health_check(path, headers):
        try:
            if headers.get("upgrade", "").lower() == "websocket":
                return None
        except Exception:
            pass
        if path in ("/", "/health"):
            body = json.dumps({"ok": True,
                               "rooms": len(rooms)}).encode()
            return (200, [("Content-Type", "application/json")], body)
        return None

PORT = cfg_int("PORT", 13009)
MAX_ROOMS = cfg_int("JAM_MAX_ROOMS", 100)
MAX_MEMBERS = cfg_int("JAM_MAX_MEMBERS", 12)
MAX_QUEUE = cfg_int("JAM_MAX_QUEUE", 60)
ROOM_TTL_S = cfg_int("JAM_ROOM_TTL_HOURS", 3) * 3600
EMPTY_TTL_S = cfg_int("JAM_EMPTY_TTL_S", 60)
CREATE_PER_MIN = cfg_int("JAM_CREATE_PER_MIN", 5)
MAX_MSG = 8 * 1024
MIN_STATE_MS = 0.8      # host state floor (seconds)
MIN_QUEUE_MS = 1.0      # host queue-snapshot floor (seconds)
HEARTBEAT_S = 25        # websocket ping interval (seconds)

# Room codes skip 0/O/1/I so reading them aloud never confuses anyone.
CODE_A = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def make_code():
    return "".join(random.choice(CODE_A) for _ in range(6))


def uid():
    return "".join(random.choice(string.ascii_lowercase + string.digits)
                   for _ in range(8))


def clean_str(v, n):
    try:
        return str(v if v is not None else "")[:n]
    except Exception:
        return ""


def clean_track(t):
    """Keep sync messages tiny + abuse-proof: known fields only, truncated."""
    if not isinstance(t, dict):
        return None
    tid = clean_str(t.get("id"), 16)
    if not tid:
        return None
    return {
        "id": tid,
        "title": clean_str(t.get("title"), 120),
        "artist": clean_str(t.get("artist"), 80),
        "thumb": clean_str(t.get("thumb"), 300),
        "url": clean_str(t.get("url"), 300),
    }


def clean_name(n):
    return clean_str(n, 24).strip() or "Guest"


def lan_ips():
    """Best-effort LAN addresses for the boot print (no traffic sent)."""
    ips = []
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            ips.append(s.getsockname()[0])
        finally:
            s.close()
    except Exception:
        pass
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None,
                                       socket.AF_INET):
            ip = info[4][0]
            if not ip.startswith("127.") and ip not in ips:
                ips.append(ip)
    except Exception:
        pass
    return ips


class Room:
    def __init__(self, code, host_id):
        now = time.time()
        self.code = code
        self.host_id = host_id
        self.created_at = now
        self.last_active = now
        self.empty_at = 0.0
        self.allow_guests = False
        self.last_sync = 0.0
        self.now = None
        self.queue = []
        self.cur_id = ""
        self.members = {}  # websocket -> {"id":..., "name":...}


rooms = {}          # code -> Room
creates_by_ip = {}  # ip -> [timestamps]


async def send(ws, obj):
    try:
        await ws.send(json.dumps(obj, separators=(",", ":")))
    except Exception:
        pass


def member_list(room):
    out = []
    try:
        for m in room.members.values():
            out.append({"id": m["id"], "name": m["name"],
                        "host": m["id"] == room.host_id})
    except Exception:
        pass
    return out


async def broadcast(room, obj, except_ws=None):
    raw = None
    for ws in list(room.members.keys()):
        if ws is except_ws:
            continue
        try:
            if raw is None:
                raw = json.dumps(obj, separators=(",", ":"))
            await ws.send(raw)
        except Exception:
            pass


async def broadcast_members(room):
    await broadcast(room, {"type": "members",
                           "members": member_list(room),
                           "host": room.host_id})


def host_ws(room):
    for ws, m in room.members.items():
        if m["id"] == room.host_id:
            return ws
    return None


async def leave_room(room, ws):
    me = room.members.get(ws)
    room.members.pop(ws, None)
    if not room.members:
        room.empty_at = time.time()
        return
    if me and me["id"] == room.host_id:
        # Oldest remaining member becomes host (room survives).
        try:
            nxt = next(iter(room.members.values()))
            room.host_id = nxt["id"]
        except StopIteration:
            pass
        await broadcast(room, {"type": "host", "host": room.host_id})
    await broadcast_members(room)


async def handle(ws, msg, state):
    """state = per-connection dict: room/me/last_state/last_queue."""
    mtype = msg.get("type")
    room = state["room"]
    if room is not None:
        room.last_active = time.time()

    if mtype == "create":
        if room is not None:
            await send(ws, {"type": "error", "msg": "already in a room"})
            return
        ip = state["ip"]
        now = time.time()
        hits = [t for t in creates_by_ip.get(ip, []) if now - t < 60]
        if len(hits) >= CREATE_PER_MIN:
            await send(ws, {"type": "error",
                            "msg": "slow down, try again soon"})
            return
        hits.append(now)
        creates_by_ip[ip] = hits
        if len(rooms) >= MAX_ROOMS:
            await send(ws, {"type": "error",
                            "msg": "server is full right now"})
            return
        code = make_code()
        guard = 0
        while code in rooms and guard < 20:
            code = make_code()
            guard += 1
        me = {"id": uid(), "name": clean_name(msg.get("name"))}
        room = Room(code, me["id"])
        room.members[ws] = me
        rooms[code] = room
        state["room"], state["me"] = room, me
        await send(ws, {"type": "created", "code": code})
        await send(ws, {"type": "joined", "code": code, "you": me["id"],
                        "host": room.host_id, "name": me["name"]})
        await broadcast_members(room)

    elif mtype == "join":
        if room is not None:
            await send(ws, {"type": "error", "msg": "already in a room"})
            return
        code = clean_str(msg.get("code"), 16).strip().upper()
        r = rooms.get(code)
        if r is None:
            await send(ws, {"type": "error", "msg": "no JAM with that code"})
            return
        if len(r.members) >= MAX_MEMBERS:
            await send(ws, {"type": "error", "msg": "that JAM is full"})
            return
        me = {"id": uid(), "name": clean_name(msg.get("name"))}
        room = r
        room.members[ws] = me
        room.empty_at = 0.0
        state["room"], state["me"] = room, me
        await send(ws, {"type": "joined", "code": code, "you": me["id"],
                        "host": room.host_id, "name": me["name"]})
        if room.now:
            await send(ws, {"type": "state", "state": room.now})
        if room.queue:
            await send(ws, {"type": "queue", "tracks": room.queue,
                            "cur": room.cur_id})
        await send(ws, {"type": "allow", "on": room.allow_guests})
        await broadcast_members(room)

    elif mtype == "state":
        # Host clock only, throttled so a busy host can't melt the box.
        me = state["me"]
        if room is None or me is None or me["id"] != room.host_id:
            return
        now = time.time()
        if now - state["last_state"] < MIN_STATE_MS \
                and msg.get("force") is not True:
            return
        state["last_state"] = now
        track = clean_track(msg.get("track"))
        if track is None:
            return
        try:
            pos = max(0, int(msg.get("pos", 0)))
        except Exception:
            pos = 0
        # `st` is the SERVER clock: the one shared timebase the room
        # measures against, so phone-clock skew can't drift the music.
        room.now = {"track": track, "pos": pos,
                    "playing": msg.get("playing") is True,
                    "at": int(now * 1000), "st": int(now * 1000)}
        await broadcast(room, {"type": "state", "state": room.now},
                        except_ws=ws)

    elif mtype == "queue":
        # Host's queue snapshot (source of truth). Capped + cleaned.
        me = state["me"]
        if room is None or me is None or me["id"] != room.host_id:
            return
        if not isinstance(msg.get("tracks"), list):
            return
        now = time.time()
        if now - state["last_queue"] < MIN_QUEUE_MS:
            return
        state["last_queue"] = now
        clean = []
        seen = set()
        for t in msg["tracks"][:MAX_QUEUE]:
            c = clean_track(t)
            if c and c["id"] not in seen:
                seen.add(c["id"])
                clean.append(c)
        room.queue = clean
        room.cur_id = clean_str(msg.get("cur"), 16)
        await broadcast(room, {"type": "queue", "tracks": clean,
                               "cur": room.cur_id}, except_ws=ws)

    elif mtype == "add":
        # Anyone can suggest a song. Relayed to the host, which appends it
        # to its real queue (its next snapshot syncs everyone).
        me = state["me"]
        if room is None or me is None:
            return
        track = clean_track(msg.get("track"))
        if track is None:
            return
        if me["id"] == room.host_id:
            return  # host adds locally
        hw = host_ws(room)
        if hw is None:
            await send(ws, {"type": "error", "msg": "host is away"})
            return
        await send(hw, {"type": "add", "track": track, "by": me["name"]})

    elif mtype == "control":
        # Guest transport wish (next/prev/play/pause/seek/play_at).
        me = state["me"]
        if room is None or me is None:
            return
        if me["id"] == room.host_id:
            return
        action = clean_str(msg.get("action"), 16)
        if not room.allow_guests and action in ("next", "prev",
                                                "play_at", "seek"):
            await send(ws, {"type": "error",
                            "msg": "only the host controls playback"})
            return
        hw = host_ws(room)
        if hw is None:
            await send(ws, {"type": "error", "msg": "host is away"})
            return
        try:
            pos = max(0, int(msg.get("pos", 0)))
        except Exception:
            pos = 0
        await send(hw, {"type": "control", "action": action,
                        "id": clean_str(msg.get("id"), 16),
                        "pos": pos, "by": me["name"]})

    elif mtype == "allow":
        me = state["me"]
        if room is None or me is None or me["id"] != room.host_id:
            return
        room.allow_guests = msg.get("on") is True
        await broadcast(room, {"type": "allow", "on": room.allow_guests})

    elif mtype == "sync_req":
        # Fresh-state plea (stale join snapshot, guest retry hold).
        # Floored per room so a crowd can't pummel the host.
        me = state["me"]
        if room is None or me is None:
            return
        now = time.time()
        if now - room.last_sync < 2.0:
            return
        room.last_sync = now
        hw = None
        for peer, m in list(room.members.items()):
            if m["id"] == room.host_id:
                hw = peer
                break
        if hw is not None and hw is not ws:
            await send(hw, {"type": "sync_req", "by": me["name"]})

    elif mtype == "ping":
        # Clock sync (works pre-join too). Client pairs `t` with `st` to
        # estimate its offset from the server clock (min-RTT filter).
        try:
            t = int(msg.get("t", 0))
        except Exception:
            t = 0
        await send(ws, {"type": "pong", "t": t,
                        "st": int(time.time() * 1000)})

    elif mtype == "leave":
        if room is None:
            return
        state["room"], state["me"] = None, None
        await leave_room(room, ws)
        await send(ws, {"type": "left"})

    elif mtype == "end":
        me = state["me"]
        if room is None or me is None or me["id"] != room.host_id:
            return
        await broadcast(room, {"type": "ended",
                               "why": "host ended the JAM"}, except_ws=ws)
        for peer in list(room.members.keys()):
            try:
                await peer.close()
            except Exception:
                pass
        rooms.pop(room.code, None)
        state["room"], state["me"] = None, None

    else:
        await send(ws, {"type": "error", "msg": "unknown message"})


async def on_conn(ws):
    try:
        ip = ws.remote_address[0] if ws.remote_address else "x"
    except Exception:
        ip = "x"
    state = {"room": None, "me": None, "ip": ip,
             "last_state": 0.0, "last_queue": 0.0}
    try:
        async for raw in ws:
            try:
                if isinstance(raw, bytes):
                    raw = raw.decode("utf-8", "ignore")
                msg = json.loads(raw)
            except Exception:
                await send(ws, {"type": "error", "msg": "bad message"})
                continue
            if not isinstance(msg, dict) or not isinstance(
                    msg.get("type"), str):
                continue
            try:
                await handle(ws, msg, state)
            except Exception:
                pass
    except Exception:
        pass
    finally:
        try:
            if state["room"] is not None:
                await leave_room(state["room"], ws)
        except Exception:
            pass


async def reaper():
    """Empty rooms after 60s, any room after 3h. Memory stays flat."""
    while True:
        try:
            await asyncio.sleep(30)
            now = time.time()
            for code, r in list(rooms.items()):
                if ((not r.members and now - (r.empty_at or now) > EMPTY_TTL_S)
                        or (now - r.created_at > ROOM_TTL_S)):
                    try:
                        await broadcast(r, {"type": "ended",
                                            "why": "JAM expired"})
                        for peer in list(r.members.keys()):
                            try:
                                await peer.close()
                            except Exception:
                                pass
                    except Exception:
                        pass
                    rooms.pop(code, None)
            for ip, hits in list(creates_by_ip.items()):
                fresh = [t for t in hits if now - t < 60]
                if fresh:
                    creates_by_ip[ip] = fresh
                else:
                    creates_by_ip.pop(ip, None)
        except Exception:
            pass


async def main():
    print("cresca-jam (python) listening on :%d" % PORT, flush=True)
    for ip in lan_ips():
        print("  JAM endpoint:  ws://%s:%d" % (ip, PORT), flush=True)
        print("  Health check:  http://%s:%d/health" % (ip, PORT), flush=True)
    print("  Local endpoint: ws://127.0.0.1:%d" % PORT, flush=True)
    print("Paste a JAM endpoint into the app: Player -> JAM -> server.",
          flush=True)
    asyncio.get_running_loop().create_task(reaper())
    async with serve(on_conn, "0.0.0.0", PORT, max_size=MAX_MSG,
                     ping_interval=HEARTBEAT_S, ping_timeout=20,
                     process_request=health_check):
        await asyncio.Future()  # serve forever


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
