// U3: see_all transport-error Retry is pinned, not assumed.
//
// Simulates airplane-mode paging: the first page fails the way a
// swallowed transport error surfaces ([] without flipping exhausted),
// so [_moreError] + Retry must appear — never a silent empty list.
// Tapping Retry then recovers into content (airplane off).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'package:cresca_app/app/app.dart';
import 'package:cresca_app/app/screens/see_all.dart';
import 'package:cresca_app/app/state.dart';
import 'package:cresca_app/core/track.dart';
import 'package:cresca_app/data/repository.dart';
import 'package:cresca_app/data/resolve.dart';

YtTrack track(String id) => YtTrack(
      // 11-char alnum ids: the pager output passes through the
      // production songs-only gate, so probe rows must be playable.
      id: 'probe$id'.padRight(11, '0'),
      title: 'Song $id',
      artist: 'Probe Artist',
      thumbUrl: '',
      watchUrl: 'https://www.youtube.com/watch?v=${'probe$id'.padRight(11, '0')}',
    );

/// Scripted pager: fails the first page like a swallowed transport
/// error (empty + not exhausted), then serves recovery rows.
class FlakyPager extends SearchPager {
  bool failNext;
  final List<YtTrack> recovery;
  FlakyPager({required this.failNext, required this.recovery})
      : super(YoutubeExplode(), 'retry-probe');

  @override
  Future<List<YtTrack>> loadMore() async {
    if (failNext) {
      failNext = false;
      return [];
    }
    exhausted = true;
    return recovery;
  }
}

class FlakyRepo extends YoutubeRepository {
  final SearchPager pager;
  FlakyRepo(this.pager);

  @override
  SearchPager searchPager(String query, {int pageSize = 20}) => pager;
}

void main() {
  testWidgets('page failure shows Retry, Retry recovers into content',
      (tester) async {
    // Real async work (temp dir, state construction) must run outside
    // the fake-async widget zone, or its futures never complete.
    late Directory dir;
    late AppState state;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('see-all-retry');
      state = AppState(dir)
        ..repo = FlakyRepo(FlakyPager(
          failNext: true,
          recovery: [track('r1'), track('r2')],
        ))
        ..resolver = StreamResolver();
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      });
    });

    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state,
          child: const SeeAllScreen(title: 'Probe', query: 'retry-probe'),
        ),
      ),
    );
    // Bounded pumps, not pumpAndSettle: the loading footer is a shimmer
    // with a repeating controller, so pumpAndSettle would never settle.
    // Poll until the expected copy lands instead.
    Future<void> pumpUntil(Finder f) async {
      for (var i = 0; i < 100 && f.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await pumpUntil(find.text('Retry'));

    // Airplane-mode shape: error copy + Retry, never a silent empty.
    expect(
      find.text('Couldn\u2019t load more \u2014 check your connection.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Song r1'), findsNothing);

    // Airplane off: Retry recovers into rows, error state clears.
    await tester.tap(find.text('Retry'));
    await pumpUntil(find.text('Song r1'));
    expect(find.text('Song r1'), findsOneWidget);
    expect(find.text('Song r2'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(
      find.text('Couldn\u2019t load more \u2014 check your connection.'),
      findsNothing,
    );
  });
}
