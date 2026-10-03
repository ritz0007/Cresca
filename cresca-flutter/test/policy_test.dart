import 'package:test/test.dart';

import 'package:cresca_app/core/call_gate.dart';
import 'package:cresca_app/core/queue.dart';
import 'package:cresca_app/core/session.dart';
import 'package:cresca_app/core/track.dart';

YtTrack t(String id) => YtTrack(
    id: id,
    title: 't',
    artist: 'a',
    thumbUrl: '',
    watchUrl: 'https://www.youtube.com/watch?v=$id');

void main() {
  group('session codec', () {
    test('round-trip with media3 repeat mapping', () {
      final tracks = [t('a'), t('b'), t('c')];
      final root = encodeSession(
        tracks: tracks,
        index: 5, // coerced to 2
        current: tracks[2],
        positionMs: 61000,
        shuffleOn: true,
        repeatModeEngine: repeatAll,
        nowMs: 1000,
      )!;
      expect(root['index'], 2);
      expect(root['repeatMode'], 2); // media3 ALL
      expect(root['trackId'], 'c');
      final back = decodeSession(root)!;
      expect(back.index, 2);
      expect(back.positionMs, 61000);
      expect(back.shuffleOn, isTrue);
      expect(back.repeatMode, repeatAll); // engine ALL
      expect(back.tracks.length, 3);
    });

    test('media3 ONE maps to engine ONE', () {
      final root = encodeSession(
        tracks: [t('a')],
        index: 0,
        current: t('a'),
        positionMs: 0,
        shuffleOn: false,
        repeatModeEngine: repeatOne,
        nowMs: 0,
      )!;
      expect(root['repeatMode'], 1);
      expect(decodeSession(root)!.repeatMode, repeatOne);
    });

    test('trackId reconciles moved queues', () {
      final root = encodeSession(
        tracks: [t('a'), t('b'), t('c')],
        index: 0,
        current: t('c'),
        positionMs: 10,
        shuffleOn: false,
        repeatModeEngine: repeatOff,
        nowMs: 0,
      )!;
      // Queue reshuffled: c now first — index follows the id.
      root['items'] = (root['items'] as List).reversed.toList();
      expect(decodeSession(root)!.index, 0);
    });

    test('empty/corrupt loads null; 200 cap', () {
      expect(
          encodeSession(
              tracks: [],
              index: 0,
              current: null,
              positionMs: 0,
              shuffleOn: false,
              repeatModeEngine: repeatOff,
              nowMs: 0),
          isNull);
      expect(decodeSession({'items': []}), isNull);
      expect(decodeSession({}), isNull);
      final many = List.generate(250, (i) => t('k$i'));
      final root = encodeSession(
        tracks: many,
        index: 0,
        current: many[0],
        positionMs: 0,
        shuffleOn: false,
        repeatModeEngine: repeatOff,
        nowMs: 0,
      )!;
      expect((root['items'] as List).length, 200);
    });
  });

  group('call gate', () {
    test('mode math + tap routing + service rule', () {
      expect(isCallMode(audioModeInCall), isTrue);
      expect(isCallMode(audioModeInCommunication), isTrue);
      expect(isCallMode(audioModeRingtone), isTrue);
      expect(isCallMode(audioModeNormal), isFalse);
      expect(actionForTap(true), CallPlayAction.deferUntilCallEnd);
      expect(actionForTap(false), CallPlayAction.startNow);
      expect(shouldStartForegroundService(true), isFalse);
      expect(shouldStartForegroundService(false), isTrue);
    });

    test('resume only when we paused for the call', () {
      final g = CallResumeGate();
      g.onMode(audioModeInCall, true); // sounding → remember
      expect(g.onMode(audioModeNormal, false), isTrue);
      expect(g.onMode(audioModeNormal, false), isFalse); // one-shot
    });

    test('silent when already paused; user pause wins', () {
      final g = CallResumeGate();
      g.onMode(audioModeInCall, false);
      expect(g.onMode(audioModeNormal, false), isFalse);
      final g2 = CallResumeGate();
      g2.onMode(audioModeInCall, true);
      g2.noteUserPause();
      expect(g2.onMode(audioModeNormal, false), isFalse);
    });
  });

  group('skip budget + end action', () {
    test('5 silent skips then error', () {
      final b = SkipBudget();
      for (var i = 0; i < 5; i++) {
        expect(b.take(), isTrue);
      }
      expect(b.take(), isFalse);
      b.reset();
      expect(b.take(), isTrue);
    });

    test('end: advance vs rewind-pause', () {
      expect(endAction(true), EndAction.advance);
      expect(endAction(false), EndAction.rewindPause);
    });
  });
}
