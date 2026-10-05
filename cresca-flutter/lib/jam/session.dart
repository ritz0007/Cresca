// JAM session controller (Phase 4): wires the wire layer onto the
// player. Native ref: docs/JAM.md F1–F10 + MainActivity JAM glue.
//
// Rules that never break:
// 1. HOST = the only clock: broadcasts throttled state/queue; executes
//    guest wishes. 2. Guest adopt replaces the queue silently (no audio
//    restart on plain position ticks); autoplay disabled while
//    guesting. 3. Guest solo-pause: pause locally; resume jumps to the
//    host's fresh expectedPos; host track change while paused applies
//    + stays paused; denial toast on next/prev/seek (F6/F7). 4. Stale
//    join → sync_req (10 s floor) → host answers forced state. Guest
//    JAM-hold retry: 3 × 2.5 s then 20 s sync_req cadence.

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/playback.dart';
import '../core/track.dart';
import 'client.dart';
import 'protocol.dart';

/// Narrow app callbacks (keeps this file decoupled from state.dart).
class JamAppHooks {
  final List<YtTrack> Function() queueSnapshot;
  final int Function() currentIndex;
  final bool Function() isPlaying;
  final int Function() positionMs;
  final YtTrack? Function() currentTrack;
  final void Function(String msg) toast;
  final void Function() poke;
  const JamAppHooks({
    required this.queueSnapshot,
    required this.currentIndex,
    required this.isPlaying,
    required this.positionMs,
    required this.currentTrack,
    required this.toast,
    required this.poke,
  });
}

class JamSession extends ChangeNotifier {
  final PlayerController controller;
  final JamAppHooks hooks;
  final JamClient client = JamClient();
  final JamThrottle queueT = JamThrottle(jamQueueFloorMs);
  Timer? _pump;
  Timer? _holdTimer;
  Timer? _holdSync;
  int _hostQueueStamp = 0;

  // ---- mirrored room state (sheet reads + ChangeNotifier via poke) ----
  String code = '';
  bool isHost = false;
  bool connected = false;
  bool guestAllowed = false;
  bool soloPaused = false;
  int membersCount = 1;
  List<JamMember> members = const [];
  JamNow? now;
  List<JamTrack> snapshotQueue = const [];
  String statusLine = '';
  int _holdAttempts = 0;

  /// Deep-link landing code (sheet prefills; auto-join consumes).
  String _pendingCode = '';
  String get pendingCode => _pendingCode;
  set pendingCode(String v) =>
      _pendingCode = jamValidCode(v) ? v.toUpperCase() : '';

  JamSession(this.controller, this.hooks);

  // ---- lifecycle (F1/F2) ----
  Future<void> createJam(String name) async {
    client.create(name);
    _startPump();
  }

  Future<void> joinJam(String name, String code) async {
    if (!jamValidCode(code)) {
      hooks.toast('JAM code is 6 letters');
      return;
    }
    client.join(code, name);
    _startPump();
  }

  void leaveJam() {
    client.leave();
    _stopEverything(resumeRoom: false);
    notifyListeners();
  }

  void endJam() {
    client.endJam();
    _stopEverything(resumeRoom: false);
    notifyListeners();
  }

  void setGuestAllowed(bool on) {
    client.sendAllow(on);
    guestAllowed = on;
    notifyListeners();
  }

  void _startPump() {
    _pump?.cancel();
    _pump = Timer.periodic(const Duration(milliseconds: 150), (_) => _pumpCycle());
  }

  void _stopEverything({required bool resumeRoom}) {
    _pump?.cancel();
    _holdTimer?.cancel();
    _holdSync?.cancel();
    code = '';
    connected = false;
    isHost = false;
    guestAllowed = false;
    soloPaused = false;
    members = const [];
    membersCount = 1;
    now = null;
    snapshotQueue = const [];
    statusLine = '';
  }

  // ---- event pump (wire → room state → player) ----
  void _pumpCycle() {
    try {
      var dirty = false;
      void mark() => dirty = true;
      for (final e in client.drain()) {
        switch (e) {
          case JamConnected(:final code, :final isHost):
            this.code = code;
            connected = true;
            this.isHost = isHost;
            statusLine = isHost
                ? 'Hosting $code'
                : 'Joined $code';
            if (isHost) _broadcastAsHost(force: true);
            mark();
          case JamHostPromoted(:final isHost):
            this.isHost = isHost;
            if (isHost) _broadcastAsHost(force: true);
            mark();
          case JamDisconnect(:final reason):
            statusLine = reason;
            mark();
          case JamSocketError(:final msg):
            statusLine = msg;
            mark();
          case JamRoomEnded(:final why):
            _stopEverything(resumeRoom: false);
            statusLine = why;
            mark();
          case JamSyncRequest():
            // Host answers guests asking for a fresh state.
            if (isHost && connected) {
              _broadcastAsHost(force: true);
            }
          case JamAddWish(:final track, :final by):
            if (isHost && connected) {
              try {
                final q = [...hooks.queueSnapshot()];
                if (q.any((t) => t.id == track.id)) {
                  hooks.toast('$by added a song already in queue');
                } else {
                  q.add(_toYt(track));
                  controller.engine
                      .setQueue(q, hooks.currentIndex());
                  _broadcastAsHost(force: true);
                  hooks.toast('$by added ${track.title}');
                }
              } catch (_) {}
            }
            mark();
          case JamControlWish(:final control):
            unawaited(_executeWish(control));
          case JamWire(:final event):
            _applyWire(event);
            mark();
          case JamPong():
            break;
        }
      }
      // Guest liveness: host stale hold logic.
      _guestHoldCheck();
      if (dirty) notifyListeners();
    } catch (_) {}
  }

  // ---- host broadcast path ----
  void _broadcastAsHost({bool force = false}) {
    try {
      final cur = hooks.currentTrack();
      if (cur == null) return;
      final t = JamTrack(
        id: cur.id,
        title: cur.title,
        artist: cur.artist,
        thumb: cur.thumbUrl,
        url: cur.watchUrl,
      );
      client.sendState(
          t, hooks.positionMs(), hooks.isPlaying(),
          force: force);
      final stamp = DateTime.now().millisecondsSinceEpoch;
      if (force || stamp - _hostQueueStamp >= jamQueueFloorMs) {
        _hostQueueStamp = stamp;
        client.sendQueue(
            [for (final t in hooks.queueSnapshot()) _toJam(t)],
            cur.id);
      }
    } catch (_) {}
  }

  JamTrack _toJam(YtTrack t) => JamTrack(
        id: t.id,
        title: t.title,
        artist: t.artist,
        thumb: t.thumbUrl,
        url: t.watchUrl,
      );

  /// Host executes a guest's transport wish (F5).
  Future<void> _executeWish(JamControl c) async {
    try {
      if (!isHost || !connected) return;
      final who = c.by.isEmpty ? 'Guest' : c.by;
      final allowed =
          guestAllowed; // host toggle for guest control (allow).
      if (!allowed) {
        // Without control the wish is discarded — room continues
        // untouched (guest sees the denial toast on their side).
        return;
      }
      switch (c.action) {
        case 'next':
          await controller.next();
        case 'prev':
          await controller.previous();
        case 'pause':
          try {
            await controller.player.pause();
          } catch (_) {}
        case 'play':
          try {
            await controller.player.play();
          } catch (_) {}
        case 'seek':
          try {
            await controller.player.seek(
                Duration(milliseconds: c.pos < 0 ? 0 : c.pos));
          } catch (_) {}
        default:
          return;
      }
      _broadcastAsHost(force: true);
      hooks.toast('$who pressed $c'.replaceFirst('JamControl', ''));
    } catch (_) {}
  }

  /// App calls on every player event (track/play/pause/seek/queue).
  void onPlayerEvent() {
    try {
      if (!connected) return;
      if (isHost) {
        _broadcastAsHost();
      } else {
        // Guest actions that CHANGE nothing are ignored; the mirror
        // does not broadcast. Denial UX lives in gate* helpers.
      }
    } catch (_) {}
  }

  /// Host answers a forced state (sync_req / late join / retry hold).
  void answerSyncRequest() {
    if (isHost && connected) _broadcastAsHost(force: true);
  }

  // ---- guest mirror ----
  void _applyWire(JamEvent e) {
    switch (e) {
      case JamState(:final now, :final force):
        this.now = now;
        connected = true;
        if (!isHost) {
          unawaited(_applyHostState(now, force: force));
        }
        notifyListeners();
      case JamQueue(:final tracks) when !isHost:
        snapshotQueue = tracks;
        notifyListeners();
      case JamMembers(:final members) when members.isNotEmpty:
        this.members = members;
        membersCount = members.length;
        notifyListeners();
      case JamAllow(:final on):
        guestAllowed = on;
        notifyListeners();
      default:
        break;
    }
  }

  /// Adopt + follow (F3/F4/F6/F7, F10).
  Future<void> _applyHostState(JamNow s, {required bool force}) async {
    try {
      final cur = hooks.currentTrack();
      final sameTrack = cur != null && cur.id == s.track.id;
      final expected = client.clock.expectedPos(
          s, DateTime.now().millisecondsSinceEpoch);
      if (!sameTrack) {
        // New track: adopt queue snapshot + jump. When the host is
        // paused, land paused at the host pos (stays paused, F7).
        final queue = [for (final j in snapshotQueue) _toYt(j)];
        var idx = queue.indexWhere((t) => t.id == s.track.id);
        if (idx < 0) {
          final at = (hooks.currentIndex() + 1)
              .clamp(0, queue.length);
          queue.insert(at, _toYt(s.track));
          idx = queue.indexWhere((t) => t.id == s.track.id);
        }
        soloPaused = !s.playing;
        await controller.playQueue(queue, idx);
        if (!s.playing) {
          try {
            await controller.player.pause();
            await controller.player.seek(
                Duration(milliseconds: s.pos < 0 ? 0 : s.pos));
          } catch (_) {}
          soloPaused = true;
        }
        notifyListeners();
        return;
      }
      // Same track: follow position only when meaningfully behind.
      if (s.playing && !soloPaused) {
        final pos = hooks.positionMs();
        final drift = (pos - expected).abs();
        if (drift > 800) {
          try {
            await controller.player.seek(
                Duration(milliseconds: expected < 0 ? 0 : expected));
          } catch (_) {}
        }
      }
      // Host pause while guest not solo-paused: follow pause (F4).
      if (!s.playing && !soloPaused && hooks.isPlaying()) {
        soloPaused = true;
        try {
          await controller.player.pause();
        } catch (_) {}
      }
      if (s.playing && soloPaused && !force) {
        // Host resumed after our solo pause: un-pause silently (F7).
        soloPaused = false;
        try {
          await controller.player.seek(
              Duration(milliseconds: expected < 0 ? 0 : expected));
          await controller.player.play();
        } catch (_) {}
      }
    } catch (_) {}
    return;
  }

  YtTrack _toYt(JamTrack t) => YtTrack(
        id: t.id,
        title: t.title.isEmpty ? 'Unknown' : t.title,
        artist: t.artist.isEmpty ? 'YouTube' : t.artist,
        thumbUrl: t.thumb,
        watchUrl: t.url.isEmpty
            ? 'https://music.youtube.com/watch?v=${t.id}'
            : t.url,
      );

  // ---- guest tasteful gates (F5/F6) ----
  /// @returns true when the guest may touch transport (host granted).
  bool guestGate() => !connected || isHost || guestAllowed;

  Future<void> guestNext() async {
    if (guestGate()) {
      await controller.next();
      onPlayerEvent();
      return;
    }
    hooks.toast('Only the host controls the JAM');
  }

  Future<void> guestPrev() async {
    if (guestGate()) {
      await controller.previous();
      onPlayerEvent();
      return;
    }
    hooks.toast('Only the host controls the JAM');
  }

  Future<void> guestSeek(int ms) async {
    if (guestGate()) {
      try {
        unawaited(controller.player.seek(
            Duration(milliseconds: ms)));
        onPlayerEvent();
      } catch (_) {}
      return;
    }
    hooks.toast('Only the host controls the JAM');
  }

  Future<void> guestTogglePlay() async {
    try {
      if (hooks.isPlaying()) {
        // F6: guest with (or without) control pauses LOCALLY.
        soloPaused = true;
        await controller.player.pause();
        notifyListeners();
        return;
      }
      if (soloPaused) {
        // F7: resume = jump to host's fresh pos.
        soloPaused = false;
        final host = now;
        if (host != null) {
          final expected = client.clock.expectedPos(
              host, DateTime.now().millisecondsSinceEpoch);
          try {
            await controller.player.seek(
                Duration(milliseconds: expected < 0 ? 0 : expected));
          } catch (_) {}
        }
        await controller.player.play();
        notifyListeners();
        return;
      }
      await controller.togglePlay();
      onPlayerEvent();
    } catch (_) {}
  }

  /// Guest adds a song to the shared queue (wish; host executes).
  Future<bool> guestQueueAdd(YtTrack t) async {
    try {
      if (!connected) return false;
      if (isHost) {
        final q = [...hooks.queueSnapshot()];
        if (q.any((x) => x.id == t.id)) return false;
        q.add(t);
        controller.engine.setQueue(q, hooks.currentIndex());
        _broadcastAsHost(force: true);
        notifyListeners();
        return true;
      }
      client.sendAdd(JamTrack(
        id: t.id,
        title: t.title,
        artist: t.artist,
        thumb: t.thumbUrl,
        url: t.watchUrl,
      ));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// JAM-hold retry: when a guest stops tracking the host (3 × 2.5 s),
  /// ask for a fresh state every 20 s while the room lives (F10).
  void _guestHoldCheck() {
    try {
      if (!connected || isHost) return;
      final hostNow = now;
      if (hostNow == null) return;
      final expected = client.clock.expectedPos(
          hostNow, DateTime.now().millisecondsSinceEpoch);
      final drifting = hostNow.playing &&
          !soloPaused &&
          (hooks.positionMs() - expected).abs() > 2500;
      if (drifting) {
        _holdTimer ??=
            Timer.periodic(const Duration(milliseconds: 2500), (_) {
          _holdAttempts++;
          client.sendSyncRequest();
          if (_holdAttempts >= 3) {
            _holdTimer?.cancel();
            _holdTimer = null;
            _holdSync ??= Timer.periodic(
                const Duration(seconds: 20), (_) {
              client.sendSyncRequest();
            });
          }
        });
      } else {
        _holdTimer?.cancel();
        _holdTimer = null;
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _pump?.cancel();
    _holdTimer?.cancel();
    _holdSync?.cancel();
    super.dispose();
  }
}

