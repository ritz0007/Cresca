// JAM listen-together protocol (Phase 4). Native ref: JamClient.kt —
// message catalog 1:1 (create/join/state/queue/add/control/allow/
// sync_req/ping/leave/end + created/joined/members/state/queue/add/
// control/sync_req/allow/pong/ended/error/left), caps 60 tracks / 12
// members / 8 KB frames, floors 800 ms state / 1 s queue / 2 s sync_req.
// Pure functions only so `flutter test` covers the wire without sockets.

import 'dart:convert';

/// The JAM box. Internal constant — never surfaced in the UI.
/// http/https normalize to ws/wss at connect time.
const String jamServerUrl = String.fromEnvironment(
  'JAM_SERVER_URL',
  defaultValue: 'http://209.126.81.22:13009',
);

const int jamMaxQueue = 60;
const int jamMaxMembers = 12;
const int jamMaxFrame = 8 * 1024;
const int jamMaxRoomsClient = 100;
const int jamStateFloorMs = 800;
const int jamQueueFloorMs = 1000;
const int jamSyncFloorMs = 10 * 1000;
const int jamMaxPosMs = 24 * 3600 * 1000;

// ---- Advance mode (v2): tight host↔guest sync, version-gated ----
//
// Wire compat: v1 clients send no `v`/`caps` and ignore unknown fields.
// v2 clients send `v`+`caps` in create/join; servers echo negotiated
// `v`+`caps` in joined. All new fields are optional on parse.
const int jamProtoV = 2;
const List<String> jamAdvanceCaps = [
  'clock2', // ping burst + best-sample, reset per connection
  'ease', // drift chase/ease bands (no rubber-banding)
  'opid', // idempotent queue/control ops
  'qgen', // server-authoritative queue/state generation counters
  'ecodes', // explicit error codes with readable reasons
  'handoff', // graceful host-handoff + degraded-mode signals
];

/// Drift bands (ms): |drift| <= ease → hold; <= chase → ease via
/// speed nudge; beyond → hard chase (seek). No rubber-banding.
const int jamEaseMs = 350;
const int jamChaseMs = 2000;

/// Ping cadence: fast burst on (re)connect, then cheap steady keep-warm.
const int jamPingBurstN = 5;
const int jamPingBurstMs = 400;
const int jamPingSteadySec = 10;

/// Reconnect ladder: 1/2/4/8 s ×4 then manual (single-flight).
const List<int> jamRetryLadderSec = [1, 2, 4, 8];
const int jamRetryMax = 4;

/// Op-id / generation helpers (idempotent queue ops).
int _jamOpSeq = 0;
String jamNewOpId() =>
    '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-${(_jamOpSeq++ & 0xffff).toRadixString(36)}';

/// Drift action for a guest: hold (in band), ease (speed nudge), or
/// chase (seek). Pure so tests pin the bands without audio.
String jamDriftAction(int driftMs,
    {int easeMs = jamEaseMs, int chaseMs = jamChaseMs}) {
  final d = driftMs.abs();
  if (d <= easeMs) return 'hold';
  if (d <= chaseMs) return 'ease';
  return 'chase';
}

/// Speed nudge for the ease band: ±6%, sign follows drift (guest behind
/// → speed up slightly, ahead → slow down). Clamped, never throws.
double jamEaseSpeed(int driftMs) {
  try {
    if (driftMs > 0) return 0.94; // guest ahead → ease back
    if (driftMs < 0) return 1.06; // guest behind → catch up
    return 1.0;
  } catch (_) {
    return 1.0;
  }
}

/// 6-letter room code (no 0/O/1/I in the generator alphabet).
const String jamCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
const String jamDigitsAlphabet = '23456789';

String jamHttpsOrEmpty(String u, int n) {
  final s = u.length > n ? u.substring(0, n) : u;
  return s.startsWith('https://') ? s : '';
}

int jamClampPos(int pos) => pos < 0 ? 0 : (pos > jamMaxPosMs ? jamMaxPosMs : pos);

bool jamValidCode(String code) {
  try {
    final c = code.trim().toUpperCase();
    if (c.length != 6) return false;
    for (final ch in c.runes) {
      final s = String.fromCharCode(ch);
      if (!jamCodeAlphabet.contains(s) &&
          !jamDigitsAlphabet.contains(s)) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Trims + caps incoming frame text; null when oversize/spam.
String? jamSanitizeFrame(String raw) {
  if (raw.length > jamMaxFrame) return null;
  return raw;
}

class JamTrack {
  final String id;
  final String title;
  final String artist;
  final String thumb;
  final String url;
  const JamTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.thumb = '',
    this.url = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id.substring(0, id.length > 16 ? 16 : id.length),
        'title': title.substring(
            0, title.length > 120 ? 120 : title.length),
        'artist': artist.substring(
            0, artist.length > 80 ? 80 : artist.length),
        'thumb': jamHttpsOrEmpty(thumb, 300),
        'url': jamHttpsOrEmpty(url, 300),
      };

  static JamTrack? fromJson(Map<String, dynamic> o) {
    try {
      final id = (o['id'] ?? '').toString();
      if (id.isEmpty) return null;
      return JamTrack(
        id: id,
        title: (o['title'] ?? '').toString(),
        artist: (o['artist'] ?? '').toString(),
        thumb: (o['thumb'] ?? '').toString(),
        url: (o['url'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

class JamMember {
  final String id;
  final String name;
  final bool host;
  const JamMember(this.id, this.name, {this.host = false});
}

class JamNow {
  final JamTrack track;
  final int pos;
  final bool playing;
  final int at;
  final int st;
  const JamNow({
    required this.track,
    required this.pos,
    required this.playing,
    required this.at,
    this.st = 0,
  });
}

/// Outgoing wishes (guest → host): transport/seek/add.
class JamControl {
  final String action;
  final String id;
  final int pos;
  final String by;
  final String opId;
  const JamControl({
    required this.action,
    this.id = '',
    this.pos = 0,
    this.by = '',
    this.opId = '',
  });
}

/// Last-measured ping budget snapshot (offset + bestRTT). The local
/// clock is injectable so tests script deterministically.
class JamClock {
  int offsetMs = 0;
  int bestRttMs = 1 << 30;
  int pingSentAt = -1;

  /// Wall clock seam (tests inject a scripted counter).
  final int Function() localNow;
  JamClock({int Function()? localNow})
      : localNow = localNow ?? _real;

  static int _real() => DateTime.now().millisecondsSinceEpoch;

  /// Resets the offset estimate for a fresh connection (advance mode:
  /// a stale offset must never poison the new socket).
  void reset() {
    offsetMs = 0;
    bestRttMs = 1 << 30;
    pingSentAt = -1;
  }

  int serverNowMs([int? localNowMs]) =>
      (localNowMs ?? localNow()) + offsetMs;

  /// Expected room position on the SHARED server clock: host pos +
  /// elapsed since the stamp. Skew drops out; guard fake future stamps.
  int expectedPos(JamNow s, [int? localNowMs]) {
    if (!s.playing) return s.pos;
    final stamp = s.st > 0 ? s.st : s.at;
    final dt = serverNowMs(localNowMs) - stamp;
    if (dt < 0 || dt > 30000) return s.pos;
    return s.pos + dt;
  }

  int now() => localNow();

  void notePong(int t, int st) {
    if (t != pingSentAt) return;
    final nowMs = localNow();
    final rtt = (nowMs - t).clamp(0, 1 << 30);
    final off = st - (t + rtt ~/ 2);
    if (rtt < bestRttMs) {
      bestRttMs = rtt;
      offsetMs = off;
    }
  }

  bool withinSkew(JamNow s, [int? localNowMs, int skewMs = 400]) {
    final stamp = s.st > 0 ? s.st : s.at;
    final expected = stamp;
    return (serverNowMs(localNowMs) - expected).abs() <= skewMs;
  }
}

class JamThrottle {
  final int floorMs;
  int _lastAt = -1 << 62;
  JamThrottle(this.floorMs);

  /// True when this send is allowed (floor elapsed). Advances the clock
  /// even when rejected? No — natives only advance on admit.
  bool admit(int nowMs) {
    if (nowMs - _lastAt < floorMs) return false;
    _lastAt = nowMs;
    return true;
  }

  void reset() => _lastAt = -1 << 62;
}

/// Wire: builds outgoing JSON and parses server frames into typed
/// events. Null event = frame dropped (plain/oversize/bad).
sealed class JamEvent {
  const JamEvent();
}

class JamCreated extends JamEvent {
  final String code;
  const JamCreated(this.code);
}

class JamJoined extends JamEvent {
  final String code;
  final String you;
  final String host;
  final String name;
  final int v;
  final List<String> caps;
  const JamJoined(this.code, this.you, this.host,
      {this.name = '', this.v = 1, this.caps = const []});
}

class JamMembers extends JamEvent {
  final String host;
  final List<JamMember> members;
  const JamMembers(this.host, this.members);
}

class JamState extends JamEvent {
  final JamNow now;
  final bool force;
  final int gen;
  const JamState(this.now, {this.force = false, this.gen = 0});
}

class JamQueue extends JamEvent {
  final List<JamTrack> tracks;
  final String cur;
  final int gen;
  const JamQueue(this.tracks, this.cur, {this.gen = 0});
}

class JamAdd extends JamEvent {
  final JamTrack track;
  final String by;
  final String opId;
  const JamAdd(this.track, this.by, {this.opId = ''});
}

class JamControlMsg extends JamEvent {
  final JamControl control;
  const JamControlMsg(this.control);
}

class JamSyncReq extends JamEvent {
  final String by;
  const JamSyncReq(this.by);
}

class JamAllow extends JamEvent {
  final bool on;
  const JamAllow(this.on);
}

class JamEnded extends JamEvent {
  final String why;
  final String code;
  const JamEnded(this.why, {this.code = ''});
}

class JamErr extends JamEvent {
  final String msg;
  final String code;
  const JamErr(this.msg, {this.code = ''});
}

class JamHandoff extends JamEvent {
  final String host;
  final bool degraded;
  const JamHandoff(this.host, {this.degraded = false});
}

class JamLeftAck extends JamEvent {
  const JamLeftAck();
}

class JamProtocol {
  /// Outgoing helper — one send per frame; oversized handled by caller.
  /// v2 clients advertise version + caps (version-gated; v1 servers
  /// and clients ignore unknown fields).
  String create(String name, {int v = jamProtoV, List<String>? caps}) =>
      jsonEncode({
        'type': 'create',
        'name': _cap(name, 24),
        'v': v,
        'caps': caps ?? jamAdvanceCaps,
      });

  String join(String code, String name,
          {int v = jamProtoV, List<String>? caps}) =>
      jsonEncode({
        'type': 'join',
        'code': code.trim().toUpperCase(),
        'name': _cap(name, 24),
        'v': v,
        'caps': caps ?? jamAdvanceCaps,
      });

  String state({
    required JamTrack track,
    required int pos,
    required bool playing,
    bool force = false,
    int gen = 0,
    String opId = '',
  }) =>
      jsonEncode({
        'type': 'state',
        if (force) 'force': true,
        if (gen > 0) 'gen': gen,
        if (opId.isNotEmpty) 'op': opId,
        'track': track.toJson(),
        'pos': jamClampPos(pos),
        'playing': playing,
      });

  String queue(List<JamTrack> tracks, String curId, {int gen = 0}) =>
      jsonEncode({
        'type': 'queue',
        'tracks': [for (final t in tracks.take(jamMaxQueue)) t.toJson()],
        'cur': _cap(curId, 16),
        if (gen > 0) 'gen': gen,
      });

  String add(JamTrack t, {String opId = ''}) => jsonEncode({
        'type': 'add',
        'track': t.toJson(),
        if (opId.isNotEmpty) 'op': opId,
      });

  String control(String action,
          {String id = '', int pos = 0, String opId = ''}) =>
      jsonEncode({
        'type': 'control',
        'action': _cap(action, 16),
        'id': _cap(id, 16),
        'pos': jamClampPos(pos),
        if (opId.isNotEmpty) 'op': opId,
      });

  String allow(bool on) => jsonEncode({'type': 'allow', 'on': on});

  String syncReq() => jsonEncode({'type': 'sync_req'});

  String ping(int t) => jsonEncode({'type': 'ping', 't': t});

  String leave() => jsonEncode({'type': 'leave'});

  String end() => jsonEncode({'type': 'end'});

  String _cap(String s, int n) =>
      s.length > n ? s.substring(0, n) : s;

  /// Server frame → event (null = drop).
  JamEvent? parse(String raw) {
    final clean = jamSanitizeFrame(raw);
    if (clean == null) return null;
    try {
      final o = jsonDecode(clean);
      if (o is! Map) return null;
      final type = (o['type'] ?? '').toString();
      switch (type) {
        case 'created':
          return JamCreated((o['code'] ?? '').toString().toUpperCase());
        case 'joined':
          return JamJoined(
            (o['code'] ?? '').toString().toUpperCase(),
            (o['you'] ?? '').toString(),
            (o['host'] ?? '').toString(),
            name: (o['name'] ?? '').toString(),
            v: _int(o['v']) == 0 ? 1 : _int(o['v']),
            caps: o['caps'] is List
                ? [for (final c in (o['caps'] as List)) c.toString()]
                : const [],
          );
        case 'members':
          {
            final host = (o['host'] ?? '').toString();
            final out = <JamMember>[];
            final arr = o['members'];
            if (arr is List) {
              for (final e in arr) {
                if (e is! Map) continue;
                final id = (e['id'] ?? '').toString();
                if (id.isEmpty) continue;
                out.add(JamMember(
                    id, (e['name'] ?? 'Guest').toString(),
                    host: id == host));
              }
            }
            if (out.length > jamMaxMembers) {
              out.removeRange(jamMaxMembers, out.length);
            }
            return JamMembers(host, out);
          }
        case 'host':
          // Legacy host notice → handoff event (graceful promotion).
          // Empty member list variant (old server) still parses as
          // JamMembers for back-compat; the handoff flag rides below.
          if (o['handoff'] == true || o['degraded'] == true) {
            return JamHandoff((o['host'] ?? '').toString(),
                degraded: o['degraded'] == true);
          }
          return JamMembers(
            (o['host'] ?? '').toString(),
            const [],
          ); // carry through; client refills flag.
        case 'state':
          {
            final s = o['state'];
            if (s is! Map) return null;
            final t = s['track'];
            if (t is! Map) return null;
            final track = JamTrack.fromJson(t.cast<String, dynamic>());
            if (track == null) return null;
            return JamState(
              JamNow(
                track: track,
                pos: _int(s['pos']),
                playing: s['playing'] == true,
                at: _int(s['at']),
                st: _int(s['st']),
              ),
              force: o['force'] == true || s['force'] == true,
              gen: _int(o['gen'] ?? s['gen']),
            );
          }
        case 'queue':
          {
            final arr = o['tracks'];
            final out = <JamTrack>[];
            if (arr is List) {
              for (final e in arr) {
                if (e is! Map) continue;
                final t =
                    JamTrack.fromJson(e.cast<String, dynamic>());
                if (t == null || out.any((x) => x.id == t.id)) continue;
                out.add(t);
              }
            }
            if (out.length > jamMaxQueue) {
              out.removeRange(jamMaxQueue, out.length);
            }
            return JamQueue(out, (o['cur'] ?? '').toString(),
                gen: _int(o['gen']));
          }
        case 'add':
          {
            final t = o['track'];
            if (t is! Map) return null;
            final track = JamTrack.fromJson(t.cast<String, dynamic>());
            if (track == null) return null;
            return JamAdd(track, (o['by'] ?? 'Guest').toString(),
                opId: (o['op'] ?? o['opId'] ?? '').toString());
          }
        case 'control':
          return JamControlMsg(JamControl(
            action: (o['action'] ?? '').toString(),
            id: (o['id'] ?? '').toString(),
            pos: _int(o['pos']),
            by: (o['by'] ?? 'Guest').toString(),
            opId: (o['op'] ?? o['opId'] ?? '').toString(),
          ));
        case 'allow':
          return JamAllow(o['on'] == true);
        case 'sync_req':
          return JamSyncReq((o['by'] ?? 'Guest').toString());
        case 'pong':
          return const JamLeftAck(); // handled below via clock.
        case 'ended':
          return JamEnded(
              (o['why'] ?? '').toString().isEmpty
                  ? 'JAM ended'
                  : (o['why'] ?? '').toString(),
              code: (o['code'] ?? '').toString());
        case 'error':
          return JamErr((o['msg'] ?? 'Server error').toString(),
              code: (o['code'] ?? '').toString());
        case 'left':
          return const JamLeftAck();
        default:
          return null;
      }
    } catch (_) {
      return null;
    }
  }

  int _int(dynamic v) {
    try {
      if (v is int) return v;
      if (v is num) return v.toInt();
      if (v is String) return int.tryParse(v) ?? 0;
    } catch (_) {}
    return 0;
  }
}

