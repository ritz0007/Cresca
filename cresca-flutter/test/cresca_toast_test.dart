// U8: showCrescaToast state machine — one at a time, above the
// chrome, auto-dismiss. No pixels asserted, only behavior.
import 'package:cresca_app/app/app.dart';
import 'package:cresca_app/app/widgets/cresca_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness({required void Function(BuildContext) onTap}) {
  return MaterialApp(
    home: Scaffold(
      body: BottomChromeScope(
        chromeHeight: 100,
        bottomInset: 20,
        hasTrack: true,
        child: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => onTap(context),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('toast shows copy above the chrome', (t) async {
    await t.pumpWidget(_harness(
        onTap: (c) => showCrescaToast(c, 'Signed out')));
    await t.tap(find.text('go'));
    await t.pump();
    expect(find.text('Signed out'), findsOneWidget);
    final bar =
        t.widget<SnackBar>(find.byType(SnackBar));
    final margin = bar.margin as EdgeInsets;
    // chromeHeight 100 + 8 clearance pad.
    expect(margin.bottom, 108);
    expect(bar.duration, const Duration(seconds: 3));
  });

  testWidgets('second toast replaces the first (no stacking)',
      (t) async {
    await t.pumpWidget(_harness(onTap: (c) async {
      await showCrescaToast(c, 'first');
      await showCrescaToast(c, 'second');
    }));
    await t.tap(find.text('go'));
    await t.pump();
    await t.pump();
    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('toast auto-dismisses after 3 s', (t) async {
    await t.pumpWidget(_harness(
        onTap: (c) => showCrescaToast(c, 'Signed out')));
    await t.tap(find.text('go'));
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Signed out'), findsOneWidget);
    // 3 s duration (timer starts once the entrance completes) +
    // exit animation; step past both.
    for (var i = 0;
        i < 8 && find.text('Signed out').evaluate().isNotEmpty;
        i++) {
      await t.pump(const Duration(seconds: 1));
    }
    expect(find.text('Signed out'), findsNothing);
  });

  testWidgets('no scope still toasts with legacy clearance',
      (t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () =>
                  showCrescaToast(context, 'Signed out'),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    ));
    await t.tap(find.text('go'));
    await t.pump();
    expect(find.text('Signed out'), findsOneWidget);
    final bar =
        t.widget<SnackBar>(find.byType(SnackBar));
    final margin = bar.margin as EdgeInsets;
    expect(margin.bottom,
        BottomChromeScope.legacyClearance + 8);
  });
}
