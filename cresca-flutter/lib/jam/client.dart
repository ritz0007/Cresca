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
  const JamRoomEnded(this.why);
}

class JamSocketError extends JamUiEvent {
  final String msg;
  const JamSocketError(this.msg);
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
  int _retryAttempt = 0;
  bool wantConnected = false;
  String _name = 'Guest';
  String _code = '';
  String _myId = '';
  bool _isHost = false;
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
      {bool force = false}) {
    if (!connected || !_isHost) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force && !_stateT.admit(now)) return;
    _sendRaw(protocol.state(
        track: t, pos: pos, playing: playing, force: force));
  }

  void sendQueue(List<JamTrack> tracks, String curId) {
    if (!connected || !_isHost) return;
    if (!_queueT.admit(DateTime.now().millisecondsSinceEpoch)) return;
    _sendRaw(protocol.queue(tracks, curId));
  }

  void sendAllow(bool on) {
    if (!connected || !_isHost) return;
    _sendRaw(protocol.allow(on));
  }

  void sendAdd(JamTrack t) {
    if (!connected) return;
    _sendRaw(protocol.add(t));
  }

  void sendControl(String action, {String id = '', int pos = 0}) {
    if (!connected || _isHost) return;
    _sendRaw(protocol.control(action, id: id, pos: pos));
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
    _openSocket();
  }

  void _openSocket() {
    if (!wantConnected) return;
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
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 10), (_) => _ping());
    _ping();
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
      case JamJoined(:final code, :final you, :final host):
        _code = code;
        _myId = you;
        _isHost = you.isNotEmpty && you == host;
        _retryAttempt = 0;
        _events.add(JamConnected(code, _isHost, you));
      case JamMembers(:final host):
        if (host.isNotEmpty && _myId.isNotEmpty) {
          final was = _isHost;
          _isHost = host == _myId;
          if (was != _isHost) _events.add(JamHostPromoted(_isHost));
        }
        _events.add(JamWire(e));
      case JamAdd(:final track, :final by):
        _events.add(JamAddWish(track, by));
      case JamControlMsg(:final control):
        _events.add(JamControlWish(control));
      case JamSyncReq(:final by):
        _events.add(JamSyncRequest(by));
      case JamEnded(:final why):
        wantConnected = false;
        _teardown('ended');
        _events.add(JamRoomEnded(why));
      case JamErr(:final msg):
        if (!connected) wantConnected = false;
        _events.add(JamSocketError(msg));
      case JamState():
      case JamQueue():
      case JamAllow():
        _events.add(JamWire(e));
      case JamLeftAck():
        break;
    }
  }

  void _scheduleRetry(String msg) {
    if (!wantConnected) return;
    if (_retryAttempt >= 4) {
      _events.add(JamDisconnect('$msg — tap Retry'));
      wantConnected = false;
      return;
    }
    _events.add(JamDisconnect('$msg — retrying…'));
    final wait = const [1, 2, 4, 8][_retryAttempt.clamp(0, 3)];
    _retryAttempt++;
    _retryTimer = Timer(Duration(seconds: wait), _openSocket);
  }

  void _sendRaw(String frame) {
    try {
      _ws?.sink.add(frame);
    } catch (_) {}
  }

  void _teardown(String cause) {
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
  }

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

