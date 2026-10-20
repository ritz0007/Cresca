import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:cresca_app/app/downloads.dart';
import 'package:cresca_app/core/track.dart';
import 'package:cresca_app/data/details.dart';
import 'package:cresca_app/data/streamkit/bundle.dart' as sk;
import 'package:cresca_app/data/streamkit/chunks.dart' as chunks;

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

    test('failed enqueue releases guard: zero-byte retry works', () async {
      var fail = true;
      final bytes = List<int>.generate(512, (i) => i % 256);
      final mock = MockClient((req) async {
        if (fail) return http.Response('no', 403);
        final range = req.headers['Range'] ?? '';
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
        if (m == null) return http.Response.bytes(bytes, 200);
        final s = int.parse(m.group(1)!);
        final e = int.parse(m.group(2)!);
        return http.Response.bytes(bytes.sublist(s, e + 1), 206,
            headers: {'content-range': 'bytes $s-$e/${bytes.length}'});
      });
      final store = DownloadStore(dir, httpClient: mock);
      await store.load();
      const id = 'ZZZZZZZZZZZ';
      final track = YtTrack(
          id: id,
          title: 'T',
          artist: 'A',
          thumbUrl: '',
          watchUrl: 'https://www.youtube.com/watch?v=$id');
      expect(await store.enqueue(track, 'https://cdn/z'), isFalse);
      expect(store.isDownloading(id), isFalse);
      fail = false;
      expect(await store.retry(track, () async => 'https://cdn/z'), isTrue);
      expect(store.isDownloading(id), isFalse);
      expect(store.isDownloaded(id), isTrue);
      expect(store.fileFor(id)!.readAsBytesSync(), bytes);
      store.dispose();
    });
  });

  group('unicode names', () {
    test('non-Latin letters/numbers survive', () {
      expect(sanitizeFileName('बॉलीवुड गाना'), 'बॉलीवुड गाना');
      expect(sanitizeFileName('嵐 - ふるさと'), '嵐 - ふるさと');
      expect(sanitizeFileName('Αθήνα (live) & φίλοι'), 'Αθήνα (live) & φίλοι');
    });

    test('empty/stripped falls back to track id, no collision', () {
      expect(sanitizeFileName('///'), 'track');
      final a = YtTrack(
          id: 'idAAAAA0001',
          title: '🎵',
          artist: '🎶',
          thumbUrl: '',
          watchUrl: '');
      final b = YtTrack(
          id: 'idBBBBB0002',
          title: '🎧',
          artist: '🎤',
          thumbUrl: '',
          watchUrl: '');
      expect(downloadFileName(a), 'idAAAAA0001.m4a');
      expect(downloadFileName(b), 'idBBBBB0002.m4a');
      final uni = YtTrack(
          id: 'idCCCCC0003',
          title: 'गाना',
          artist: 'बॉलीवुड',
          thumbUrl: '',
          watchUrl: '');
      expect(downloadFileName(uni), 'बॉलीवुड - गाना.m4a');
    });
  });

  group('stream to file', () {
    test('52MB segmented streams to disk with byte-exact content',
        () async {
      const total = 52 * 1024 * 1024;
      final mock = MockClient((req) async {
        final m = RegExp(r'bytes=(\d+)-(\d+)')
            .firstMatch(req.headers['Range'] ?? '');
        if (m == null) return http.Response('no', 403);
        final s = int.parse(m.group(1)!);
        final e = int.parse(m.group(2)!);
        return http.Response.bytes(
            List<int>.generate(e - s + 1, (i) => (s + i) % 256), 206,
            headers: {'content-range': 'bytes $s-$e/$total'});
      });
      final dir =
          await Directory.systemTemp.createTemp('cresca-dl-big');
      try {
        final target = File('${dir.path}/big.m4a');
        var lastRx = 0;
        final ok = await chunks.downloadChunked(
            mock, 'https://cdn/big', target, total,
            parts: 4, onProgress: (rx, _) => lastRx = rx);
        expect(ok, isTrue);
        expect(await target.length(), total);
        expect(lastRx, total);
        final raf = await target.open();
        try {
          for (final off in [0, 1, total ~/ 2, total - 1]) {
            await raf.setPosition(off);
            expect((await raf.read(1))[0], off % 256);
          }
        } finally {
          await raf.close();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('details memo', () {
    test('canonical videoId key + LRU cap 200', () async {
      final store = DetailsStore();
      store.rememberMeta(
          'AAAAAAAAAAA',
          const sk.TrackMeta(
              videoId: 'AAAAAAAAAAA',
              title: 'T',
              viewCount: 10,
              description: 'd'));
      // Deep-link form shares the videoId row: zero network.
      final d = await store.load(
          'https://www.youtube.com/watch?v=AAAAAAAAAAA&list=xyz');
      expect(d, isNotNull);
      expect(d!.views, 10);
      // Overflow past cap evicts oldest; recently-loaded survivor stays.
      for (var i = 0; i < DetailsStore.memoCap - 1; i++) {
        final id = 'v${i.toString().padLeft(10, '0')}';
        store.rememberMeta(
            id, sk.TrackMeta(videoId: id, title: 't', viewCount: i));
      }
      expect(store.memo.length, DetailsStore.memoCap);
      expect(store.memo.containsKey('AAAAAAAAAAA'), isTrue);
      // Touch A again so it is newest; the next insert evicts v0, not A.
      final again = await store.load(
          'https://www.youtube.com/watch?v=AAAAAAAAAAA');
      expect(again, isNotNull);
      store.rememberMeta('w0000000000',
          const sk.TrackMeta(videoId: 'w0000000000', title: 't', viewCount: 1));
      expect(store.memo.length, DetailsStore.memoCap);
      expect(store.memo.containsKey('v0000000000'), isFalse);
      expect(store.memo.containsKey('AAAAAAAAAAA'), isTrue);
      store.dispose();
    });
  });
}
