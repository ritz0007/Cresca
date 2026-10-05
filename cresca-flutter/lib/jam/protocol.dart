// JAM listen-together protocol (Phase 4). Native ref: JamClient.kt —
// message catalog 1:1 (create/join/state/queue/add/control/allow/
// sync_req/ping/leave/end + created/joined/members/state/queue/add/
// control/sync_req/allow/pong/ended/error/left), caps 60 tracks / 12
// members / 8 KB frames, floors 800 ms state / 1 s queue / 2 s sync_req.
// Pure functions only so `flutter test` covers the wire without sockets.

import 'dart:convert';

/// The JAM box. Internal constant — never surfaced in the UI.
/// http/https normalize to ws/wss at connect time.
const String jamServerUrl = 'http://209.126.81.22:13009';

const int jamMaxQueue = 60;
const int jamMaxMembers = 12;
const int jamMaxFrame = 8 * 1024;
const int jamMaxRoomsClient = 100;
const int jamStateFloorMs = 800;
const int jamQueueFloorMs = 1000;
const int jamSyncFloorMs = 10 * 1000;

/// 6-letter room code (no 0/O/1/I in the generator alphabet).
const String jamCodeAlphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
const String jamDigitsAlphabet = '23456789';

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
        'thumb':
            thumb.substring(0, thumb.length > 300 ? 300 : thumb.length),
        'url': url.substring(0, url.length > 300 ? 300 : url.length),
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
  const JamControl({
    required this.action,
    this.id = '',
    this.pos = 0,
    this.by = '',
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
  const JamJoined(this.code, this.you, this.host, {this.name = ''});
}

class JamMembers extends JamEvent {
  final String host;
  final List<JamMember> members;
  const JamMembers(this.host, this.members);
}

class JamState extends JamEvent {
  final JamNow now;
  final bool force;
  const JamState(this.now, {this.force = false});
}

class JamQueue extends JamEvent {
  final List<JamTrack> tracks;
  final String cur;
  const JamQueue(this.tracks, this.cur);
}

class JamAdd extends JamEvent {
  final JamTrack track;
  final String by;
  const JamAdd(this.track, this.by);
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
  const JamEnded(this.why);
}

class JamErr extends JamEvent {
  final String msg;
  const JamErr(this.msg);
}

class JamLeftAck extends JamEvent {
  const JamLeftAck();
}

class JamProtocol {
  /// Outgoing helper — one send per frame; oversized handled by caller.
  String create(String name) => jsonEncode({
        'type': 'create',
        'name': _cap(name, 24),
      });

  String join(String code, String name) => jsonEncode({
        'type': 'join',
        'code': code.trim().toUpperCase(),
        'name': _cap(name, 24),
      });

  String state({
    required JamTrack track,
    required int pos,
    required bool playing,
    bool force = false,
  }) =>
      jsonEncode({
        'type': 'state',
        if (force) 'force': true,
        'track': track.toJson(),
        'pos': pos < 0 ? 0 : pos,
        'playing': playing,
      });

  String queue(List<JamTrack> tracks, String curId) => jsonEncode({
        'type': 'queue',
        'tracks': [for (final t in tracks.take(jamMaxQueue)) t.toJson()],
        'cur': _cap(curId, 16),
      });

  String add(JamTrack t) =>
      jsonEncode({'type': 'add', 'track': t.toJson()});

  String control(String action, {String id = '', int pos = 0}) =>
      jsonEncode({
        'type': 'control',
        'action': _cap(action, 16),
        'id': _cap(id, 16),
        'pos': pos < 0 ? 0 : pos,
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
            return JamQueue(out, (o['cur'] ?? '').toString());
          }
        case 'add':
          {
            final t = o['track'];
            if (t is! Map) return null;
            final track = JamTrack.fromJson(t.cast<String, dynamic>());
            if (track == null) return null;
            return JamAdd(track, (o['by'] ?? 'Guest').toString());
          }
        case 'control':
          return JamControlMsg(JamControl(
            action: (o['action'] ?? '').toString(),
            id: (o['id'] ?? '').toString(),
            pos: _int(o['pos']),
            by: (o['by'] ?? 'Guest').toString(),
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
                  : (o['why'] ?? '').toString());
        case 'error':
          return JamErr((o['msg'] ?? 'Server error').toString());
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

