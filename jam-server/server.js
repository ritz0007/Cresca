'use strict';
/*
 * Cresca JAM server — listen-together relay.
 *
 * Deliberately tiny for small Pterodactyl boxes:
 *  - ONE dependency (ws). No DB, no framework, no audio relay.
 *  - Each phone streams YouTube directly; this box only passes
 *    ~200-byte JSON sync messages (track id + position + play/pause).
 *  - Idle footprint is ~15 MB RAM. Per room is a few KB.
 *  - Host-authoritative: host's player is the clock, guests mirror it.
 *    Guests send control wishes (next/pause/seek/add); the HOST executes
 *    them, so there are no fights and no server-side player logic.
 *
 * Limits (all cheap, all in RAM):
 *  MAX_ROOMS=100, MAX_MEMBERS=12/room, MAX_QUEUE=60, 8KB msg cap,
 *  host state broadcasts min-interval 2500ms, room TTL 3h,
 *  empty rooms destroyed after 60s, create rate-limit 5/min/IP.
 */

const http = require('http');
const WebSocket = require('ws');

const PORT = parseInt(process.env.PORT || '3781', 10);
const MAX_ROOMS = 100;
const MAX_MEMBERS = 12;
const MAX_QUEUE = 60;
const MAX_MSG = 8 * 1024;
// Host state floor: 800ms. Still pocket change bandwidth-wise (a 12-person
// room peaks around 4 KB/s total), but tight enough that guests can hold
// sub-second sync with speed-nudging instead of jumpy seeks.
const MIN_STATE_MS = 800;
const HEARTBEAT_MS = 25000;
const ROOM_TTL_MS = 3 * 3600 * 1000;
const EMPTY_TTL_MS = 60 * 1000;
const CREATE_PER_MIN = 5;
const JOIN_PER_MIN = 20; // reconnect-storm guard per IP
const MAX_BUF_BYTES = 64 * 1024; // backpressure: skip laggy sockets
const PROTO_V = 2;
const SERVER_CAPS = ['clock2', 'ease', 'opid', 'qgen', 'ecodes', 'handoff'];

// Room codes skip 0/O/1/I so reading them aloud never confuses anyone.
const CODE_A = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
function makeCode() {
  let s = '';
  for (let i = 0; i < 6; i++) s += CODE_A[(Math.random() * CODE_A.length) | 0];
  return s;
}
const uid = () => Math.random().toString(36).slice(2, 10);

// rooms: code -> { code, hostId, createdAt, lastActive, emptyAt,
//                  allowGuests, now, queue, members: Map(ws -> {id,name}),
//                  stateGen, queueGen, seenOps:Set, lastSync }
const rooms = new Map();
const createsByIp = new Map(); // ip -> [timestamps]
const joinsByIp = new Map(); // ip -> [timestamps] (reconnect-storm guard)

function err(ws, code, msg) {
  // Explicit error codes with client-readable reasons (advance mode
  // `ecodes` cap). v1 clients ignore `code` and read `msg` as before.
  send(ws, { type: 'error', code, msg });
}

function send(ws, obj) {
  try {
    if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj));
  } catch (e) { /* dead socket, cleanup handles it */ }
}

function memberList(room) {
  const out = [];
  try {
    for (const m of room.members.values()) {
      out.push({ id: m.id, name: m.name, host: m.id === room.hostId });
    }
  } catch (e) { /* ignore */ }
  return out;
}

function broadcast(room, obj, except) {
  let raw = null;
  try {
    for (const [ws] of room.members) {
      if (ws === except || ws.readyState !== WebSocket.OPEN) continue;
      try {
        // Backpressure guard: never buffer into a laggy socket; its
        // next heartbeat/fork re-syncs it (sync_req floor is cheap).
        if (ws.bufferedAmount > MAX_BUF_BYTES) continue;
      } catch (e) { /* ignore */ }
      if (raw === null) raw = JSON.stringify(obj);
      try { ws.send(raw); } catch (e) { /* skip dead */ }
    }
  } catch (e) { /* ignore */ }
}

function broadcastMembers(room) {
  broadcast(room, { type: 'members', members: memberList(room), host: room.hostId });
}

function hostWs(room) {
  try {
    for (const [ws, m] of room.members) {
      if (m.id === room.hostId) return ws;
    }
  } catch (e) { /* ignore */ }
  return null;
}

/// Version-gated hello: v1 clients (no `v`) get the legacy shape plus
/// harmless extras they ignore; v2 clients get negotiated caps. Old
/// clients keep working — new caps are negotiated, never required.
function negotiatedHello(code, me, room) {
  return {
    type: 'joined', code, you: me.id, host: room.hostId, name: me.name,
    v: PROTO_V, caps: SERVER_CAPS, st: Date.now(),
  };
}

/// Idempotent op relay: first sight returns true (relay it), replays
/// return false (ack-and-drop). Bounded so memory stays flat.
function noteOp(room, op) {
  try {
    if (!op) return true; // legacy frame without op id: always relay
    if (!room.seenOps) room.seenOps = new Set();
    if (room.seenOps.has(op)) return false;
    room.seenOps.add(op);
    if (room.seenOps.size > 500) {
      const first = room.seenOps.values().next().value;
      room.seenOps.delete(first);
    }
    return true;
  } catch (e) {
    return true;
  }
}

// Keep sync messages tiny + abuse-proof: only known string fields,
// hard-truncated. A track is ~150 bytes on the wire.
function cleanTrack(t) {
  if (!t || typeof t !== 'object') return null;
  const s = (v, n) => String(v == null ? '' : v).slice(0, n);
  const id = s(t.id, 16);
  if (!id) return null;
  return {
    id,
    title: s(t.title, 120),
    artist: s(t.artist, 80),
    thumb: s(t.thumb, 300),
    url: s(t.url, 300),
  };
}

function cleanName(n) {
  return String(n == null ? '' : n).trim().slice(0, 24) || 'Guest';
}

function leaveRoom(room, ws, reason) {
  let me = null;
  try { me = room.members.get(ws) || null; } catch (e) { /* ignore */ }
  try { room.members.delete(ws); } catch (e) { /* ignore */ }
  if (room.members.size === 0) {
    room.emptyAt = Date.now();
    return;
  }
  // Host left: oldest remaining member becomes host (room survives).
  if (me && me.id === room.hostId) {
    try {
      const next = room.members.values().next().value;
      if (next) room.hostId = next.id;
    } catch (e) { /* ignore */ }
  }
  broadcastMembers(room);
  if (reason === 'host-gone' && me) {
    // Graceful handoff: new host id + flag (v2 guests show a notice,
    // v1 guests read it as the legacy `host` frame — same shape).
    broadcast(room, { type: 'host', host: room.hostId, handoff: true });
  }
}

const server = http.createServer((req, res) => {
  // Health check for Pterodactyl / uptime monitors. Costs nothing.
  try {
    if (req.url === '/health' || req.url === '/') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true, rooms: rooms.size, v: PROTO_V, caps: SERVER_CAPS }));
      return;
    }
  } catch (e) { /* ignore */ }
  res.writeHead(404);
  res.end();
});

const wss = new WebSocket.Server({ server, maxPayload: MAX_MSG });

wss.on('connection', (ws, req) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  let room = null;
  let me = null;
  let lastStateAt = 0;
  let lastQueueAt = 0;

  ws.on('message', (buf) => {
    let m = null;
    try { m = JSON.parse(buf.toString()); } catch (e) {
      return err(ws, 'BAD_MSG', 'bad message');
    }
    if (!m || typeof m.type !== 'string') return;
    try { if (room) room.lastActive = Date.now(); } catch (e) { /* ignore */ }

    switch (m.type) {
      case 'create': {
        if (room) return err(ws, 'ALREADY_IN_ROOM', 'already in a room');
        const ip = (req.socket && req.socket.remoteAddress) || 'x';
        const nowT = Date.now();
        const hits = (createsByIp.get(ip) || []).filter((t) => nowT - t < 60000);
        if (hits.length >= CREATE_PER_MIN) {
          return err(ws, 'RATE_LIMIT', 'slow down, try again soon');
        }
        hits.push(nowT);
        createsByIp.set(ip, hits);
        if (rooms.size >= MAX_ROOMS) {
          return err(ws, 'SERVER_FULL', 'server is full right now');
        }
        let code = makeCode();
        let guard = 0;
        while (rooms.has(code) && guard++ < 20) code = makeCode();
        me = { id: uid(), name: cleanName(m.name) };
        room = {
          code, hostId: me.id, createdAt: nowT, lastActive: nowT,
          emptyAt: 0, allowGuests: false, now: null, queue: [],
          members: new Map(), stateGen: 0, queueGen: 0,
          seenOps: new Set(), lastSync: 0,
        };
        room.members.set(ws, me);
        rooms.set(code, room);
        send(ws, { type: 'created', code });
        send(ws, negotiatedHello(code, me, room));
        broadcastMembers(room);
        break;
      }

      case 'join': {
        if (room) return err(ws, 'ALREADY_IN_ROOM', 'already in a room');
        const jip = (req.socket && req.socket.remoteAddress) || 'x';
        const jnow = Date.now();
        const jhits = (joinsByIp.get(jip) || []).filter((t) => jnow - t < 60000);
        if (jhits.length >= JOIN_PER_MIN) {
          return err(ws, 'RATE_LIMIT', 'slow down, try again soon');
        }
        jhits.push(jnow);
        joinsByIp.set(jip, jhits);
        const code = String(m.code || '').trim().toUpperCase();
        const r = rooms.get(code);
        if (!r) return err(ws, 'NO_ROOM', 'no JAM with that code');
        if (r.members.size >= MAX_MEMBERS) {
          return err(ws, 'ROOM_FULL', 'that JAM is full');
        }
        me = { id: uid(), name: cleanName(m.name) };
        room = r;
        room.members.set(ws, me);
        room.emptyAt = 0;
        // Fast hello + snapshot: one joined frame (with negotiated caps)
        // then the authoritative state/queue so join latency is a single
        // round trip even on a cold socket.
        send(ws, negotiatedHello(code, me, room));
        if (room.now) send(ws, { type: 'state', state: room.now, gen: room.stateGen });
        if (room.queue && room.queue.length) {
          send(ws, { type: 'queue', tracks: room.queue, cur: room.curId || '', gen: room.queueGen });
        }
        send(ws, { type: 'allow', on: !!room.allowGuests });
        broadcastMembers(room);
        break;
      }

      case 'state': {
        // Host clock only. Throttled so a busy host can't melt the box.
        if (!room || !me || me.id !== room.hostId) return;
        const t = Date.now();
        if (t - lastStateAt < MIN_STATE_MS && m.force !== true) return;
        lastStateAt = t;
        const track = cleanTrack(m.track);
        if (!track) return;
        // `st` is the SERVER clock: every guest measures position against
        // this one shared timebase, so phone-clock skew can't drift the room.
        // `gen` is the authoritative state generation (guests drop stale).
        room.stateGen = (room.stateGen || 0) + 1;
        room.now = {
          track,
          pos: Math.max(0, parseInt(m.pos, 10) || 0),
          playing: m.playing === true,
          at: t,
          st: t,
        };
        broadcast(room, { type: 'state', state: room.now, gen: room.stateGen }, ws);
        break;
      }

      case 'ping': {
        // Clock sync (works pre-join too). Client pairs `t` with `st` to
        // estimate its offset from the server clock (min-RTT filter).
        send(ws, { type: 'pong', t: m.t | 0, st: Date.now() });
        break;
      }

      case 'queue': {
        // Host's queue snapshot (source of truth). Capped + cleaned.
        if (!room || !me || me.id !== room.hostId) return;
        if (!Array.isArray(m.tracks)) return;
        const tq = Date.now();
        if (tq - lastQueueAt < 1000) return;
        lastQueueAt = tq;
        const clean = [];
        for (const t of m.tracks.slice(0, MAX_QUEUE)) {
          const c = cleanTrack(t);
          if (c && !clean.some((x) => x.id === c.id)) clean.push(c);
        }
        room.queue = clean;
        room.curId = String(m.cur || '').slice(0, 16);
        room.queueGen = (room.queueGen || 0) + 1;
        broadcast(room, { type: 'queue', tracks: clean, cur: room.curId, gen: room.queueGen }, ws);
        break;
      }

      case 'add': {
        // Anyone can suggest a song. Relayed to the host, which appends
        // it to its real queue (then its next snapshot syncs everyone).
        // Idempotent: replayed op ids ack-and-drop (no double adds).
        if (!room || !me) return;
        const track = cleanTrack(m.track);
        if (!track) return;
        if (me.id === room.hostId) return; // host adds locally
        const op = String(m.op || m.opId || '');
        if (!noteOp(room, op)) return;
        const hw = hostWs(room);
        if (hw) send(hw, { type: 'add', track, by: me.name, ...(op ? { op } : {}) });
        else return err(ws, 'HOST_AWAY', 'host is away');
        break;
      }

      case 'control': {
        // Guest transport wish (next/prev/play/pause/seek/play_at).
        // Host executes it; guests never touch the clock directly.
        if (!room || !me) return;
        if (me.id === room.hostId) return;
        if (!room.allowGuests && (m.action === 'next' || m.action === 'prev' ||
            m.action === 'play_at' || m.action === 'seek')) {
          return err(ws, 'NO_CONTROL', 'only the host controls playback');
        }
        const op = String(m.op || m.opId || '');
        if (!noteOp(room, op)) return;
        const hw = hostWs(room);
        if (!hw) return err(ws, 'HOST_AWAY', 'host is away');
        send(hw, {
          type: 'control',
          action: String(m.action || '').slice(0, 16),
          id: String(m.id || '').slice(0, 16),
          pos: Math.max(0, parseInt(m.pos, 10) || 0),
          by: me.name,
          ...(op ? { op } : {}),
        });
        break;
      }

      case 'allow': {
        if (!room || !me || me.id !== room.hostId) return;
        room.allowGuests = m.on === true;
        broadcast(room, { type: 'allow', on: room.allowGuests });
        break;
      }

      case 'sync_req': {
        // Fresh-state plea (stale join snapshot, guest retry hold).
        // Floored per room so a crowd can't pummel the host.
        if (!room || !me) return;
        const t = Date.now();
        if (t - (room.lastSync || 0) < 2000) return;
        room.lastSync = t;
        const hw = hostWs(room);
        if (hw && hw !== ws) send(hw, { type: 'sync_req', by: me.name });
        break;
      }

      case 'leave': {
        if (!room) return;
        const r = room;
        room = null;
        me = null;
        leaveRoom(r, ws);
        send(ws, { type: 'left' });
        break;
      }

      case 'end': {
        if (!room || !me || me.id !== room.hostId) return;
        broadcast(room, { type: 'ended', why: 'host ended the JAM' }, ws);
        try {
          for (const [peer] of room.members) {
            try { peer.close(); } catch (e) { /* ignore */ }
          }
        } catch (e) { /* ignore */ }
        rooms.delete(room.code);
        room = null;
        me = null;
        break;
      }

      default:
        err(ws, 'UNKNOWN', 'unknown message');
    }
  });

  ws.on('close', () => {
    try {
      if (room) {
        const wasHost = me && me.id === room.hostId;
        const r = room;
        room = null;
        me = null;
        leaveRoom(r, ws, wasHost ? 'host-gone' : undefined);
      }
    } catch (e) { /* ignore */ }
    room = null;
    me = null;
  });
  ws.on('error', () => { /* cleanup runs on close */ });
});

// Heartbeat: drop dead sockets so they stop costing us anything.
const heartbeat = setInterval(() => {
  try {
    wss.clients.forEach((ws) => {
      if (ws.isAlive === false) {
        try { ws.terminate(); } catch (e) { /* ignore */ }
        return;
      }
      ws.isAlive = false;
      try { ws.ping(); } catch (e) { /* ignore */ }
    });
  } catch (e) { /* ignore */ }
}, HEARTBEAT_MS);

// Reaper: empty rooms after 60s, any room after 3h. Memory stays flat.
const reaper = setInterval(() => {
  const t = Date.now();
  try {
    for (const [code, r] of rooms) {
      if ((r.members.size === 0 && t - (r.emptyAt || t) > EMPTY_TTL_MS) ||
          (t - r.createdAt > ROOM_TTL_MS)) {
        try {
          broadcast(r, { type: 'ended', why: 'JAM expired', code: 'EXPIRED' });
          for (const [peer] of r.members) {
            try { peer.close(); } catch (e) { /* ignore */ }
          }
        } catch (e) { /* ignore */ }
        rooms.delete(code);
      }
    }
    // Prune create + join rate-limit rows (they're tiny, but stay tidy).
    for (const [ip, hits] of createsByIp) {
      const fresh = hits.filter((x) => t - x < 60000);
      if (fresh.length) createsByIp.set(ip, fresh);
      else createsByIp.delete(ip);
    }
    for (const [ip, hits] of joinsByIp) {
      const fresh = hits.filter((x) => t - x < 60000);
      if (fresh.length) joinsByIp.set(ip, fresh);
      else joinsByIp.delete(ip);
    }
  } catch (e) { /* ignore */ }
}, 30000);

server.listen(PORT, () => {
  console.log('cresca-jam listening on :' + PORT + ' (' + rooms.size + ' rooms)');
});

process.on('SIGTERM', () => {
  clearInterval(heartbeat);
  clearInterval(reaper);
  server.close(() => process.exit(0));
});
