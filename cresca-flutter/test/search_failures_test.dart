import 'package:test/test.dart';

import 'package:cresca_app/core/search_failures.dart';

// U6 transport-failure ledger: the search screen raises Retry (not
// "No results") exactly when the last fetch for a query failed.
void main() {
  group('SearchFailureLedger', () {
    test('unknown and empty keys never fail', () {
      final l = SearchFailureLedger();
      expect(l.failed('q:arijit|15'), isFalse);
      expect(l.failed(''), isFalse);
      l.noteFailure('');
      expect(l.failed(''), isFalse);
    });

    test('failure marks, success clears (even genuine empty)', () {
      final l = SearchFailureLedger();
      l.noteFailure('q:arijit|15');
      expect(l.failed('q:arijit|15'), isTrue);
      // A later successful fetch — even one that parses to [] —
      // supersedes the old failure: true empty must stay empty.
      l.noteSuccess('q:arijit|15');
      expect(l.failed('q:arijit|15'), isFalse);
    });

    test('unrelated keys are independent', () {
      final l = SearchFailureLedger();
      l.noteFailure('q:a|15');
      expect(l.failed('q:b|15'), isFalse);
      l.noteSuccess('q:b|15');
      expect(l.failed('q:a|15'), isTrue);
    });

    test('re-failure refreshes recency past the cap', () {
      final l = SearchFailureLedger(cap: 3);
      l.noteFailure('q:a|15');
      l.noteFailure('q:b|15');
      l.noteFailure('q:c|15');
      l.noteFailure('q:a|15'); // a is newest again
      l.noteFailure('q:d|15'); // evicts b, not a
      expect(l.failed('q:a|15'), isTrue);
      expect(l.failed('q:b|15'), isFalse);
      expect(l.failed('q:c|15'), isTrue);
      expect(l.failed('q:d|15'), isTrue);
    });

    test('never throws on degenerate input', () {
      final l = SearchFailureLedger(cap: 0);
      l.noteFailure('q:a|15');
      expect(l.failed('q:a|15'), isFalse); // cap 0 evicts immediately
      expect(l.failed(''), isFalse);
    });
  });
}
