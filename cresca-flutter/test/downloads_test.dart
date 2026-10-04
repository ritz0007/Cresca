import 'dart:io';

import 'package:test/test.dart';

import 'package:cresca_app/app/downloads.dart';
import 'package:cresca_app/core/track.dart';

YtTrack t(String id, [String artist = 'A B']) => YtTrack(
    id: id,
    title: 'T:t/e?',
    artist: artist,
    thumbUrl: '',
    watchUrl: 'https://www.youtube.com/watch?v=$id');

void main() {
  group('file naming', () {
    test('Artist - Title sanitized + .m4a', () {
      expect(downloadFileName(t('x')), 'A B - Tte.m4a');
      expect(sanitizeFileName('a/b\\c:d*e?f"g<h>i|j'), 'abcdefghij');
      expect(sanitizeFileName(''), 'track');
      expect(sanitizeFileName('   '), 'track');
    });

    test('80-char cap', () {
      expect(sanitizeFileName('x' * 200).length, 80);
    });
  });

  group('rows codec', () {
    test('round-trip native dlmap schema', () {
      final rows = {
        'a': const DownloadEntry(
            trackId: 'a',
            taskId: 'dl_a_1',
            title: 't',
            artist: 'ar',
            name: 'ar - t.m4a',
            isPublic: false),
      };
      final back = downloadRowsFromJson(downloadRowsToJson(rows));
      expect(back['a']!.taskId, 'dl_a_1');
      expect(back['a']!.name, 'ar - t.m4a');
      expect(downloadRowsFromJson(''), isEmpty);
      expect(downloadRowsFromJson('[]'), isEmpty);
    });
  });

  group('store files', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cresca-dl-test');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('listAll scans .m4a + rows, delete cleans', () async {
      final store = DownloadStore(dir);
      await store.load();
      final sub =
          Directory('${dir.path}/Cresca')..createSync();
      final f = File('${sub.path}/A B - Tte.m4a')
        ..writeAsBytesSync(List.filled(2048, 0));
      expect(store.fileFor('whatever'), isNull);
      final listed = store.listAll();
      expect(listed.length, 1);
      expect(listed.first.$1.title, 'A B - Tte');
      expect(listed.first.$3, greaterThan(0));
      expect(f.existsSync(), isTrue);
      await store.delete('A B - Tte');
      expect(f.existsSync(), isFalse);
      expect(store.progressFor('nope'), -1);
    });
  });
}
