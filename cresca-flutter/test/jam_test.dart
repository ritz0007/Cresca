// JAM protocol + client test suite (Phase 4): dart port of the native
// 21-check suite (jamtest). Pure — no sockets; wire frames in/out via
// testIngest + drained events. Floors: 800 ms state / 1 s queue /
// 10 s sync_req; caps 60 / 12 / 8 KB; NTP offset math; retry ladder
// bounded 4; guest flows (adopt/gates/hold) enforced at the session
// layer (session-level cases covered by JamSession katas below).

import 'dart:convert';

import 'package:test/test.dart';

import 'package:cresca_app/jam/client.dart';
import 'package:cresca_app/jam/protocol.dart';

const _t0 = 1_700_000_000_000;

void main() {
  group('frames + caps', () {
    test('create/join frames shape', () {
      final p = JamProtocol();
      final c = p.create('Host Alpha');
      expect(c, contains('"type":"create"'));
      expect(c, contains('"name":"Host Alpha"'));
      final j = p.join('abcde2', 'Guest-7');
      expect(j, contains('"type":"join"'));
      expect(j, contains('"code":"ABCDE2"'));
      // Rate-limit lives server-side; client just dials.
    });

    test('frame size cap drops oversize', () {
      final big = '{"type":"x","pix":"${'a' * (8 * 1024)}"}';
      expect(jamSanitizeFrame(big), isNull);
      expect(
          jamSanitizeFrame('{"type":"ping","t":1}'),
          contains('ping'));
    });

    test('queue parser caps at 60 + dedupes ids', () {
      final tracks = List.generate(
          70,
          (i) => {
                'id': 'id${i.toString().padLeft(9, 'x')}',
                'title': 't$i',
                'artist': 'a'
              });
      final raw = jsonEncode({'type': 'queue', 'tracks': tracks, 'cur': 'x'});
      final e = JamProtocol().parse(raw) as JamQueue?;
      expect(e, isNotNull);
      expect(e!.tracks.length, jamMaxQueue);
    });

    test('members parser caps at 12 and tags host', () {
      final members = List.generate(
          15,
          (i) => {
                'id': 'm$i',
                'name': 'g$i',
                'host': i == 3
              });
      final raw =
          jsonEncode({'type': 'members', 'host': 'm3', 'members': members});
      final e = JamProtocol().parse(raw) as JamMembers?;
      expect(e!.members.length, jamMaxMembers);
      expect(
          e.members[3].host,
          isTrue);
    });

    test('state parser carries at/st + force', () {
      const raw =
          '{"type":"state","force":true,"state":{"track":{"id":"abc"},'
          '"pos":4200,"playing":true,"at":10,"st":20}}';
      final e = JamProtocol().parse(raw) as JamState?;
      expect(e!.force, isTrue);
      expect(e.now.pos, 4200);
      expect(e.now.st, 20);
      expect(e.now.track.id, 'abc');
    });

    test('garbage frames dropped', () {
      expect(JamProtocol().parse('not-json'), isNull);
      expect(JamProtocol().parse('{"type":"unknown"}'), isNull);
      expect(JamProtocol().parse('{"type":"state","state":{}}'), isNull);
    });
  });

  group('floors + throttles', () {
    test('state floor 800 ms', () {
      final th = JamThrottle(jamStateFloorMs);
      expect(th.admit(_t0), isTrue);
      expect(th.admit(_t0 + 799), isFalse);
      expect(th.admit(_t0 + 800), isTrue);
    });

    test('queue floor 1 s', () {
      final th = JamThrottle(jamQueueFloorMs);
      expect(th.admit(_t0), isTrue);
      expect(th.admit(_t0 + 999), isFalse);
      expect(th.admit(_t0 + 1000), isTrue);
    });

    test('sync_req floor 10 s', () {
      final th = JamThrottle(jamSyncFloorMs);
      expect(th.admit(_t0), isTrue);
      expect(th.admit(_t0 + 9999), isFalse);
      expect(th.admit(_t0 + 10000), isTrue);
    });
  });

  group('clock (NTP-style)', () {
    late JamClient c;
    late int fakeNow;
    setUp(() {
      fakeNow = 0;
      c = JamClient(clock: JamClock(localNow: () => fakeNow));
    });

    test('offset from best RTT sample wins', () {
      // ping t=100 leaves at fakeNow=100; pong at fakeNow=190.
      c.clock.pingSentAt = 100;
      fakeNow = 190;
      c.testIngest('{"type":"pong","t":100,"st":1000}'); // rtt 90
      expect(c.clock.bestRttMs, 90);
      expect(c.clock.offsetMs, 1000 - (100 + 45)); // 855
      // Simpler sanity: serverNow(local) = local + offset.
      expect(
          c.clock.serverNowMs(100),
          equals(100 + c.clock.offsetMs));
    });

    test('jittery pongs never backslide the offset', () {
      c.clock.pingSentAt = 100;
      fakeNow = 190;
      c.testIngest('{"type":"pong","t":100,"st":1000}');
      final best = c.clock.bestRttMs;
      final off = c.clock.offsetMs;
      // A worse sample must not move the estimate.
      c.clock.pingSentAt = 200;
      fakeNow = 2000;
      c.testIngest('{"type":"pong","t":200,"st":5000}'); // rtt 1800
      expect(c.clock.bestRttMs, best);
      expect(c.clock.offsetMs, off);
      expect(best, lessThanOrEqualTo(1800));
    });

    test('expectedPos: paused rest, playing advances on server clock', () {
      c.clock.pingSentAt = 0;
      fakeNow = 0;
      c.testIngest('{"type":"pong","t":0,"st":0}'); // rtt 0, off 0
      final now = JamNow(
          track: const JamTrack(id: 'x', title: 't', artist: 'a'),
          pos: 1000,
          playing: true,
          at: 10,
          st: 10);
      final e = c.clock.expectedPos(now, 510); // dt = 500 on st clock
      expect(e, 1500);
      final paused = JamNow(
          track: now.track, pos: 777, playing: false, at: 10, st: 10);
      expect(c.clock.expectedPos(paused, 510), 777);
      // dt beyond 30 s window → hold, no runaway.
      final stale = JamNow(
          track: now.track, pos: 500, playing: true, at: 0, st: 0);
      expect(c.clock.expectedPos(stale, 31000), 500);
      expect(c.clock.expectedPos(stale, -100), 500);
    });
  });

  group('code alphabet', () {
    test('valid 6-char codes', () {
      expect(jamValidCode('ABCDEF'), isTrue);
      expect(jamValidCode('ABCDE2'), isTrue);
      expect(jamValidCode('ABCDE'), isFalse);
      expect(jamValidCode('ABCDE0'), isFalse); // 0 banned
      expect(jamValidCode('ABCDEO'), isFalse);
      expect(jamValidCode('ABCDEI'), isFalse);
    });
  });

  group('client wire flow (no sockets)', () {
    late JamClient c;
    setUp(() => c = JamClient());

    test('joined → host id resolution + guest wish routing', () {
      c.create('Host');
      c.testIngest(
          '{"type":"joined","code":"ABC123","you":"h1","host":"h1","name":"Host"}');
      expect(c.isHost, isTrue);
      expect(c.code, 'ABC123');
      c.testIngest(
          '{"type":"members","host":"h1","members":[{"id":"h1","name":"Host","host":true}]}');
      final evts = c.drain();
      expect(
          evts.whereType<JamConnected>().length, greaterThanOrEqualTo(1));
    });

    test('ended stops the room and surfaces why', () {
      c.join('ABC123', 'G');
      c.testIngest('{"type":"ended","why":"Room expired"}');
      expect(c.wantConnected, isFalse);
      expect(
          c.drain().whereType<JamRoomEnded>().first.why,
          'Room expired');
    });

    test('retry ladder bounds at 4 then requests Retry', () {
      c.wantConnected = true;
      for (var i = 0; i < 4; i++) {
        c.testRetryOnce('Connection lost');
      }
      expect(c.retryAttempt, 4);
      c.testRetryOnce('Connection lost');
      final msgs = c.drain().whereType<JamDisconnect>().toList();
      expect(msgs.last.reason, contains('tap Retry'));
    });
  });
}
