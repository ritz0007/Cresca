// U4 contract: the overflow row order + labels are the phase's one
// deliberate visual change. Pin them so a later reorder/rename fails
// loudly instead of silently reshuffling the player.
import 'package:flutter_test/flutter_test.dart';

import 'package:cresca_app/app/widgets/player_menu.dart';

void main() {
  group('PlayerMenu overflow contract', () {
    test('order is Shuffle / Repeat / Like / Download / Video', () {
      expect(playerMenuLabels,
          ['Shuffle', 'Repeat', 'Like', 'Download', 'Video']);
    });

    test('labels are single-line, screen-reader friendly words', () {
      expect(playerMenuLabels, hasLength(5));
      for (final label in playerMenuLabels) {
        expect(label.trim(), isNotEmpty);
        expect(label, isNot(contains('\n')));
      }
      expect(playerMenuLabels.toSet(), hasLength(5));
    });
  });
}
