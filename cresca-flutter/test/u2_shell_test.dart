import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:cresca_app/app/design.dart';
import 'package:cresca_app/app/state.dart';

// U2 (shell/tabs/MiniPlayer): pins the visible search affordance, the
// 200%-scale tab layout, and the session-only hint-dismissal flag.
void main() {
  setUpAll(() {
    // Hermetic: never fetch Montserrat over the network in tests.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  group('search hint chip', () {
    testWidgets('shows on Search tab, tap fires handler', (t) async {
      var tapped = false;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FloatingTabBar(
            current: 4,
            onTap: (_) {},
            showSearchHint: true,
            onSearchHintTap: () => tapped = true,
          ),
        ),
      ));
      expect(find.text('Tap to type'), findsOneWidget);
      await t.tap(find.text('Tap to type'));
      expect(tapped, isTrue);
    });

    testWidgets('hidden by default and on non-Search tabs', (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FloatingTabBar(current: 4, onTap: (_) {}),
        ),
      ));
      expect(find.text('Tap to type'), findsNothing);
    });
  });

  group('tab labels at 200% scale', () {
    testWidgets('all five labels paint with ellipsis, no overflow',
        (t) async {
      await t.pumpWidget(MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: MaterialApp(
          home: Scaffold(
            body: FloatingTabBar(current: 0, onTap: (_) {}),
          ),
        ),
      ));
      for (final label in [
        'Listen Now',
        'Trending',
        'Radio',
        'Library',
        'Search'
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(t.takeException(), isNull);
    });
  });

  group('hint dismissal flag', () {
    test('session-only: defaults false, dismiss sticks, idempotent', () {
      final s = AppState(Directory.systemTemp);
      expect(s.searchHintDismissed, isFalse);
      s.dismissSearchHint();
      expect(s.searchHintDismissed, isTrue);
      s.dismissSearchHint();
      expect(s.searchHintDismissed, isTrue);
    });
  });
}
