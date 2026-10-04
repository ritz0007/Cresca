import 'package:test/test.dart';

import 'package:cresca_app/data/details.dart';

void main() {
  group('fmtCompact', () {
    test('clustered shorthand 1:1 with native', () {
      expect(fmtCompact(999), '999');
      expect(fmtCompact(1000), '1.0K');
      expect(fmtCompact(123456), '123.4K');
      expect(fmtCompact(2500000), '2.5M');
      expect(fmtCompact(1200000000), '1.2B');
      expect(fmtCompact(-1), '');
    });
  });

  group('detailsFromFields', () {
    test('maps fields, likes optional, raw date wins', () {
      final d = detailsFromFields(
        views: 875000000,
        likes: 17000000,
        uploadDate: DateTime.parse('2020-02-03'),
        uploadDateRaw: '2020-01-01',
        description: 'Never gonna let you down',
        duration: const Duration(seconds: 212),
      )!;
      expect(d.views, 875000000);
      expect(d.likes, 17000000);
      expect(d.uploadDate, '2020-01-01');
      expect(d.durationSec, 212);
      expect(d.description, contains('let you down'));
    });

    test('parsed date fallback + null likes → -1', () {
      final d = detailsFromFields(
        views: 42,
        likes: null,
        uploadDate: DateTime.utc(2019, 6, 5),
        uploadDateRaw: null,
        description: '',
        duration: const Duration(minutes: 3),
      )!;
      expect(d.uploadDate, '2019-06-05');
      expect(d.likes, -1);
      expect(d.durationSec, 180);
    });

    test('totally empty unfetched → null (honest state)', () {
      final d = detailsFromFields(
        views: -1,
        likes: null,
        uploadDate: null,
        uploadDateRaw: null,
        description: '',
        duration: null,
      );
      expect(d, isNull);
    });
  });
}
