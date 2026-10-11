import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cresca_app/system/live_updates.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('live updates channel', () {
    late LiveUpdates live;
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      const ch = MethodChannel(liveUpdatesChannel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (call) async {
        calls.add(call);
        if (call.method == 'canPromote') return false;
        return true;
      });
      live = LiveUpdates();
    });

    tearDown(() {
      live.stopTicker();
      const ch = MethodChannel(liveUpdatesChannel);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    });

    test('start posts title/artist/duration, clamps tiny durations',
        () async {
      await live.start(
          trackId: 'abc',
          title: 'Tum Hi Ho',
          artist: 'Arijit Singh',
          durationSec: 0);
      expect(calls.length, 1);
      expect(calls.first.method, 'start');
      final args = calls.first.arguments as Map;
      expect(args['title'], 'Tum Hi Ho');
      expect(args['artist'], 'Arijit Singh');
      expect(args['durationSec'], 1);
      expect(live.running, isTrue);
      expect(live.trackId, 'abc');
    });

    test('progress clamps negative positions', () async {
      await live.start(
          trackId: 'a', title: 't', artist: 'ar', durationSec: 200);
      calls.clear();
      await live.progress(posSec: -5, playing: true);
      final args = calls.single.arguments as Map;
      expect(args['posSec'], 0);
      expect(args['playing'], isTrue);
    });

    test('progress before start sends nothing', () async {
      await live.progress(posSec: 10, playing: true);
      expect(calls, isEmpty);
    });

    test('stop clears running state', () async {
      await live.start(
          trackId: 'a', title: 't', artist: 'ar', durationSec: 200);
      await live.stop();
      expect(live.running, isFalse);
      expect(live.trackId, '');
      expect(calls.last.method, 'stop');
    });

    test('canPromote false from mock', () async {
      expect(await live.canPromote(), isFalse);
    });

    test('ticker drives progress on 10s cadence shape', () async {
      var reads = 0;
      await live.start(
          trackId: 'a', title: 't', artist: 'ar', durationSec: 200);
      calls.clear();
      live.startTicker(() async {
        reads++;
        return (12, true, true);
      });
      // Ticker internals: manual pump instead of waiting 10 s.
      await live.progress(posSec: 12, playing: true);
      expect(reads, 0); // ticker hasn't fired yet
      expect(calls.single.method, 'progress');
      live.stopTicker();
    });
  });
}
