import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cresca_app/app/state.dart';

// U1 foundation: motion ships ON. Regression pin — if this fails,
// someone reintroduced the old `motionOn = false` default.
void main() {
  test('motionOn defaults true (fresh installs animate)', () {
    final state = AppState(Directory.systemTemp);
    expect(state.motionOn, isTrue);
    expect(state.motionMs(180), 180);
  });
}
