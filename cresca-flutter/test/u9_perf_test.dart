// U9 performance budgets: blur count, image LRU caps, prefetch picker.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cresca_app/app/artwork_cache.dart';
import 'package:cresca_app/app/design.dart';
import 'package:cresca_app/core/track.dart';
import 'package:cresca_app/data/cache.dart';

YtTrack art(String id, [String thumb = '']) => YtTrack(
      id: id,
      title: 'Title $id',
      artist: 'A',
      thumbUrl: thumb.isEmpty ? 'https://x/$id.jpg' : thumb,
      watchUrl: 'https://www.youtube.com/watch?v=$id',
    );

void main() {
  group('pickArtworkPrefetch', () {
    test('first non-blank thumbs, deduped, order preserved', () {
      final blank = YtTrack(
        id: 'blank',
        title: 'Blank',
        artist: 'A',
        thumbUrl: '',
        watchUrl: 'https://www.youtube.com/watch?v=blank',
      );
      final tracks = [art('a'), art('b'), art('a'), blank];
      expect(pickArtworkPrefetch(tracks),
          ['https://x/a.jpg', 'https://x/b.jpg']);
      expect(pickArtworkPrefetch([blank]), isEmpty);
    });

    test('caps at artworkPrefetchMax', () {
      final tracks = [
        for (var i = 0; i < artworkPrefetchMax + 4; i++) art('t$i')
      ];
      final out = pickArtworkPrefetch(tracks);
      expect(out.length, artworkPrefetchMax);
      expect(out.first, 'https://x/t0.jpg');
    });

    test('empty and non-positive max give empty', () {
      expect(pickArtworkPrefetch(const []), isEmpty);
      expect(pickArtworkPrefetch([art('a')], max: 0), isEmpty);
    });
  });

  group('image LRU caps', () {
    test('count + byte caps documented and sane', () {
      expect(artworkMemCountCap, artworkMemCacheSize);
      expect(artworkMemCountCap, 200);
      expect(artworkMemByteCap, 48 * 1024 * 1024);
    });

    test('initArtworkCache pins the ImageCache caps', () {
      initArtworkCache();
      final c = PaintingBinding.instance.imageCache;
      expect(c.maximumSize, 200);
      expect(c.maximumSizeBytes, 48 * 1024 * 1024);
    });
  });

  group('blur budget', () {
    testWidgets('Glass blur 0 builds no BackdropFilter', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Glass(blur: 0, child: Text('x')),
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.text('x'), findsOneWidget);
    });

    testWidgets('Glass default blur keeps its single filter', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Glass(child: Text('x')),
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsOneWidget);
    });

    testWidgets('settled MeshBackdrop drops the AnimatedBuilder',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MeshBackdrop(motionOn: false),
          ),
        ),
      );
      // motionOff settles synchronously: no AnimatedBuilder remains
      // inside the backdrop itself (the route owns one above us).
      expect(
        find.descendant(
          of: find.byType(MeshBackdrop),
          matching: find.byType(AnimatedBuilder),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(MeshBackdrop),
          matching: find.byType(CustomPaint),
        ),
        findsOneWidget,
      );
    });
  });
}
