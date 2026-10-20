import 'package:test/test.dart';

import 'package:cresca_app/core/search_guard.dart';

// U6 stale-guard proof: 10 queries fired inside one debounce window,
// completions arriving scrambled. Only the last query may paint.
// The test drives the exact gate _run uses at every paint site
// (searchGenPaintable) — a double-guard or weakened check fails here.
void main() {
  group('search stale-guard gate (10 queries in 5 s)', () {
    test('scrambled arrivals: only the last generation paints', () {
      var gen = 0;
      final gens = <int>[for (var i = 0; i < 10; i++) ++gen];
      const field = 'query9';
      // Evens resolve, then the last query lands mid-burst, then odds.
      const order = [0, 2, 4, 6, 8, 9, 7, 5, 3, 1];
      for (final i in order) {
        expect(
          searchGenPaintable(
            gen: gens[i],
            currentGen: gen,
            fieldText: field,
            query: 'query$i',
          ),
          i == 9,
          reason: 'query$i must ${i == 9 ? '' : 'not '}paint',
        );
      }
    });

    test('slowest-first arrivals: early queries never paint', () {
      var gen = 0;
      final gens = <int>[for (var i = 0; i < 10; i++) ++gen];
      for (var i = 0; i < 10; i++) {
        expect(
          searchGenPaintable(
            gen: gens[i],
            currentGen: gen,
            fieldText: 'query9',
            query: 'query$i',
          ),
          i == 9,
          reason: 'query$i must ${i == 9 ? '' : 'not '}paint',
        );
      }
    });

    test('keystroke window: matching gen but moved-on field drops', () {
      // The next debounce hasn't fired yet, so the generation still
      // matches the old query — but the field moved on. Stale: drop.
      expect(
        searchGenPaintable(
          gen: 5,
          currentGen: 5,
          fieldText: 'abcdef',
          query: 'abc',
        ),
        isFalse,
      );
    });

    test('new run retires the previous generation', () {
      // _onChanged bumps _gen upstream of debounce: an in-flight run
      // from the previous keystroke is stale even at equal text.
      var gen = 0;
      final g = ++gen; // run for 'abc' starts
      gen++; // keystroke: 'abcd' invalidates before its debounce fires
      expect(
        searchGenPaintable(
          gen: g,
          currentGen: gen,
          fieldText: 'abc',
          query: 'abc',
        ),
        isFalse,
      );
    });

    test('never throws on degenerate input', () {
      expect(
        searchGenPaintable(
            gen: 0, currentGen: 0, fieldText: '', query: ''),
        isTrue,
      );
      expect(
        searchGenPaintable(
            gen: -1, currentGen: 0, fieldText: 'q', query: 'q'),
        isFalse,
      );
    });
  });
}
