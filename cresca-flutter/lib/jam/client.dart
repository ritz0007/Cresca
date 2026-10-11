// JAM client (Phase 4): socket lifecycle + clock + throttles + floors +
// pending code + bounded retry (1/2/4/8 s ×4 then Manual) + leave/end.
// Native ref: JamClient.kt (event-only sync; host is the only clock;
// guests send wishes). Typed JamUiEvents stream to the app layer.

import 'dart:async';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'protocol.dart';

sealed class JamUiEvent {
  const JamUiEvent();
}

class JamConnected extends JamUiEvent {
  final String code;
  final bool isHost;
  final String myId;
  const JamConnected(this.code, this.isHost, this.myId);
}

class JamDisconnect extends JamUiEvent {
  final String reason;
  const JamDisconnect(this.reason);
}

class JamHostPromoted extends JamUiEvent {
  final bool isHost;
  const JamHostPromoted(this.isHost);
}

class JamSyncRequest extends JamUiEvent {
  final String by;
  const JamSyncRequest(this.by);
}

class JamAddWish extends JamUiEvent {
  final JamTrack track;
  final String by;
  const JamAddWish(this.track, this.by);
}

class JamControlWish extends JamUiEvent {
  final JamControl control;
  const JamControlWish(this.control);
}

class JamRoomEnded extends JamUiEvent {
  final String why;
  final String code;
  const JamRoomEnded(this.why, {this.code = ''});
}

class JamSocketError extends JamUiEvent {
  final String msg;
  final String code;
  const JamSocketError(this.msg, {this.code = ''});
}

class JamPong extends JamUiEvent {
  final int t;
  final int st;
  const JamPong(this.t, this.st);
}

/// Wire event straight from the box (state/queue/members/allow…).
class JamWire extends JamUiEvent {
  final JamEvent event;
  const JamWire(this.event);
}

/// Host-handoff / degraded-mode signal (advance mode `handoff` cap).
class JamHandoffNotice extends JamUiEvent {
  final String hostId;
  final bool degraded;
  const JamHandoffNotice(this.hostId, {this.degraded = false});
}

class JamClient {
  final JamProtocol protocol = JamProtocol();
  final JamClock clock;

  /// Injectable dial stub for tests; null = real dial to the box.
  final WebSocketChannel? Function()? dial;
  JamClient({this.dial, JamClock? clock})
      : clock = clock ?? JamClock();

  WebSocketChannel? _ws;
  StreamSubscription? _sub;
  Timer? _retryTimer;
  Timer? _pingTimer;
  int _pingGen = 0;
  int _retryAttempt = 0;
  bool wantConnected = false;
  String _name = 'Guest';
  String _code = '';
  String _myId = '';
  bool _isHost = false;
  int serverV = 1;
  List<String> serverCaps = const [];
  bool degraded = false;
  final Set<String> _seenOps = {};
  bool _needsResync = false;
  final JamThrottle _stateT = JamThrottle(jamStateFloorMs);
  final JamThrottle _queueT = JamThrottle(jamQueueFloorMs);
  final JamThrottle _syncT = JamThrottle(jamSyncFloorMs);
  final List<JamUiEvent> _events = [];

  // ---- public snapshot getters (cheap; app layer re-reads) ----
  bool get connected => _ws != null && wantConnected;
  bool get isHost => _isHost;
  String get code => _code;
  String get myId => _myId;
  String get name => _name;
  int get retryAttempt => _retryAttempt;

  List<JamUiEvent> drain() {
    final out = List<JamUiEvent>.of(_events);
    _events.clear();
    return out;
  }

  String _pendingCode = '';
  String consumePendingCode() {
    final c = _pendingCode;
    _pendingCode = '';
    return c;
  }

  void openLink(String code) =>
      _pendingCode = code.trim().toUpperCase().substring(
          0, code.trim().length > 6 ? 6 : code.trim().length);

  void create(String name) => _connect(name, '', create: true);
  void join(String code, String name) =>
      _connect(name, code.trim().toUpperCase(), create: false);

  void retry() {
    if (wantConnected) return;
    _retryAttempt = 0;
    wantConnected = true;
    _openSocket();
  }

  void leave() {
    wantConnected = false;
    _sendRaw(protocol.leave());
    _teardown('left');
  }

  void endJam() {
    wantConnected = false;
    _sendRaw(protocol.end());
    _teardown('ended');
  }

  // ---- host throttled sends ----
  void sendState(JamTrack t, int pos, bool playing,
      {bool force = false, int gen = 0, String? opId}) {
    if (!connected || !_isHost) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && !_stateT.admit(now)) return;
    _sendRaw(protocol.state(
        track: t, pos: pos, playing: playing, force: force, gen: gen));
  }

  void sendQueue(List<JamTrack> tracks, String curId, {int gen = 0}) {
    if (!connected || !_isHost) return;
    if (!_queueT.admit(DateTime.now().millisecondsSinceEpoch)) return;
    _sendRaw(protocol.queue(tracks, curId, gen: gen));
  }

  void sendAllow(bool on) {
    if (!connected || !_isHost) return;
    _sendRaw(protocol.allow(on));
  }

  void sendAdd(JamTrack t, {String? opId}) {
    if (!connected) return;
    _sendRaw(protocol.add(t, opId: opId ?? jamNewOpId()));
  }

  void sendControl(String action,
      {String id = '', int pos = 0, String? opId}) {
    if (!connected || _isHost) return;
    _sendRaw(protocol.control(action,
        id: id, pos: pos, opId: opId ?? jamNewOpId()));
  }

  bool sendSyncRequest() {
    if (!connected || _isHost) return false;
    final ok = _syncT.admit(DateTime.now().millisecondsSinceEpoch);
    if (!ok) return false;
    _sendRaw(protocol.syncReq());
    return true;
  }

  // ---- lifecycle ----
  void _connect(String name, String code, {required bool create}) {
    _name = name.isEmpty ? 'Guest' : _cap(name);
    _code = create ? '' : code;
    wantConnected = true;
    _retryAttempt = 0;
    _needsResync = code.isNotEmpty; // rejoin path wants a fresh snapshot
    _openSocket();
  }

  void _openSocket() {
    if (!wantConnected) return;
    // A fresh dial supersedes any parked retry (native connect cancels
    // retryJob 1:1) — otherwise overlapping timers storm the box.
    try {
      _retryTimer?.cancel();
    } catch (_) {}
    _retryTimer = null;
    try {
      _sub?.cancel();
    } catch (_) {}
    try {
      _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    try {
      final uri = Uri.parse(jamServerUrl
          .replaceFirst('http://', 'ws://')
          .replaceFirst('https://', 'wss://'));
      _ws = dial?.call() ?? WebSocketChannel.connect(uri);
      _onOpen();
      _sub = _ws!.stream.listen(
        (m) {
          final frame = jamSanitizeFrame(m.toString());
          if (frame == null) return;
          _onFrame(frame);
        },
        onDone: () => _scheduleRetry('Connection closed'),
        onError: (_) => _scheduleRetry('Connection lost'),
      );
    } catch (_) {
      _scheduleRetry("Can't reach server");
    }
  }

  void _onOpen() {
    _sendRaw(_code.isEmpty
        ? protocol.create(_name)
        : protocol.join(_code, _name));
    _startPings();
  }

  void _startPings() {
    // Fast converge on (re)join, then a cheap steady keep-warm (native
    // startPingLoop 1:1: burst, best-RTT sample reset per connection so
    // a stale offset never poisons the new socket). Sips battery:
    // 5 × 400 ms then one frame per 10 s (~6/min idle).
    _pingGen++;
    final g = _pingGen;
    try {
      clock.reset();
    } catch (_) {}
    _pingTimer?.cancel();
    _ping();
    var burst = 0;
    _pingTimer = Timer.periodic(Duration(milliseconds: jamPingBurstMs),
        (t) {
      try {
        if (g != _pingGen || !connected) {
          t.cancel();
          if (g == _pingGen) _startSteady();
          return;
        }
        burst++;
        _ping();
        if (burst >= jamPingBurstN - 1) {
          t.cancel();
          if (g == _pingGen) _startSteady();
        }
      } catch (_) {}
    });
  }

  void _startSteady() {
    try {
      if (!connected) return;
      _pingTimer?.cancel();
      _pingTimer = Timer.periodic(
          Duration(seconds: jamPingSteadySec), (_) => _ping());
    } catch (_) {}
  }

  void _ping() {
    if (!connected) return;
    final t = clock.now();
    clock.pingSentAt = t;
    _sendRaw(protocol.ping(t));
  }

  void _onFrame(String frame) {
    if (frame.startsWith('{"type":"pong"')) {
      final t = _num(frame, '"t":');
      final st = _num(frame, '"st":');
      clock.notePong(t.toInt(), st.toInt());
      _events.add(JamPong(t.toInt(), st.toInt()));
      return;
    }
    final e = protocol.parse(frame);
    if (e == null) return;
    switch (e) {
      case JamCreated(:final code):
        _code = code;
        _events.add(JamWire(e));
      case JamJoined(
          :final code,
          :final you,
          :final host,
          :final v,
          :final caps
        ):
        _code = code;
        _myId = you;
        _isHost = you.isNotEmpty && you == host;
        serverV = v;
        serverCaps = caps;
        degraded = false;
        _retryAttempt = 0;
        _events.add(JamConnected(code, _isHost, you));
        // Fast hello: a rejoin lands with a possibly stale snapshot —
        // ask the host for a forced fresh state (floored server-side).
        if (_needsResync && !_isHost) {
          _needsResync = false;
          try {
            _syncT.reset();
          } catch (_) {}
          _sendRaw(protocol.syncReq());
        } else {
          _needsResync = false;
        }
      case JamMembers(:final host):
        if (host.isNotEmpty && _myId.isNotEmpty) {
          final was = _isHost;
          _isHost = host == _myId;
          if (was != _isHost) _events.add(JamHostPromoted(_isHost));
        }
        _events.add(JamWire(e));
      case JamAdd(:final track, :final by, :final opId):
        if (!_noteOp(opId)) break; // dedupe replays (idempotent ops)
        _events.add(JamAddWish(track, by));
      case JamControlMsg(:final control):
        if (!_noteOp(control.opId)) break;
        _events.add(JamControlWish(control));
      case JamSyncReq(:final by):
        _events.add(JamSyncRequest(by));
      case JamEnded(:final why, :final code):
        wantConnected = false;
        degraded = false;
        _teardown('ended');
        _events.add(JamRoomEnded(why, code: code));
      case JamErr(:final msg, :final code):
        if (!connected) wantConnected = false;
        _events.add(JamSocketError(
            code.isEmpty ? msg : '[$code] $msg',
            code: code));
      case JamState():
      case JamQueue():
      case JamAllow():
        degraded = false;
        _events.add(JamWire(e));
      case JamHandoff(:final host, :final degraded):
        this.degraded = degraded;
        if (host.isNotEmpty && _myId.isNotEmpty) {
          final was = _isHost;
          _isHost = host == _myId;
          if (was != _isHost) _events.add(JamHostPromoted(_isHost));
        }
        _events.add(JamHandoffNotice(host, degraded: degraded));
      case JamLeftAck():
        break;
    }
  }

  void _scheduleRetry(String msg) {
    if (!wantConnected) return;
    // One parked retry at a time (native retryJob single-flight 1:1).
    try {
      _retryTimer?.cancel();
    } catch (_) {}
    _retryTimer = null;
    if (_retryAttempt >= jamRetryMax) {
      _events.add(JamDisconnect('$msg — tap Retry'));
      wantConnected = false;
      return;
    }
    _events.add(JamDisconnect('$msg — retrying…'));
    final wait = jamRetryLadderSec[_retryAttempt.clamp(0, 3)];
    _retryAttempt++;
    _needsResync = true; // reconnected socket wants a fresh snapshot
    _retryTimer = Timer(Duration(seconds: wait), _openSocket);
  }

  void _sendRaw(String frame) {
    try {
      _ws?.sink.add(frame);
    } catch (_) {}
  }

  void _teardown(String cause) {
    _pingGen++; // stop the clock-sync burst loop
    try {
      _sub?.cancel();
    } catch (_) {}
    try {
      _ws?.sink.close();
    } catch (_) {}
    _ws = null;
    _retryTimer?.cancel();
    _pingTimer?.cancel();
    _sub = null;
    _myId = '';
    _isHost = false;
    degraded = false;
  }

  /// Op-id dedupe (idempotent queue ops): true on first sight, false on
  /// replay. Empty op = legacy frame, always admitted. Bounded LRU-ish.
  bool _noteOp(String opId) {
    try {
      if (opId.isEmpty) return true;
      if (_seenOps.contains(opId)) return false;
      _seenOps.add(opId);
      if (_seenOps.length > 200) _seenOps.remove(_seenOps.first);
      return true;
    } catch (_) {
      return true;
    }
  }

  bool testNoteOp(String opId) => _noteOp(opId);

  // ---- test shims (21-check port) ----
  void testIngest(String frame) => _onFrame(frame);

  /// Simulates one retry attempt without sockets.
  void testRetryOnce(String msg) => _scheduleRetry(msg);

  bool testStateThrottleAt(int t) => _stateT.admit(t);
  bool testQueueThrottleAt(int t) => _queueT.admit(t);
  bool testSyncThrottleAt(int t) => _syncT.admit(t);

  String _cap(String s) => s.length > 24 ? s.substring(0, 24) : s;

  int _num(String src, String key) {    final i = src.indexOf(key);
    if (i < 0) return 0;
    var j = i + key.length;
    while (j < src.length) {
      final c = src.codeUnitAt(j);
      final isDigit = c >= 0x30 && c <= 0x39;
      final isMinus = c == 0x2D;
      if (!isDigit && !isMinus) break;
      j++;
    }
    return (num.tryParse(src.substring(i + key.length, j)) ?? 0)
        .toInt();
  }
}

