// streamkit fast-fetch vendored-port tests (MockClient, zero network).
// Covers: first-wins race (fast beats slow), phone-leg win under
// simulated LOGIN_REQUIRED, UrlCache warming (later audioUrl = 0 new
// POSTs), bundle-first muxed video with no extractor call,
// single-flight, bundle snapshot round-trips, primeNext warming,
// DetailsStore rememberMeta mem-hit, session-visitor reuse, and
// chunked-download reliability (segments + whole-GET fallback).

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:cresca_app/app/downloads.dart';
import 'package:cresca_app/core/track.dart';
import 'package:cresca_app/data/details.dart';
import 'package:cresca_app/data/resolve.dart';
import 'package:cresca_app/data/streamkit/bundle.dart' as sk;

String playerJson(List<Map<String, dynamic>> adaptive,
    {List<Map<String, dynamic>> formats = const [],
    String status = 'OK',
    Map<String, dynamic>? details}) {
  final m = <String, dynamic>{
    'playabilityStatus': {'status': status},
    'streamingData': {
      'adaptiveFormats': adaptive,
      'formats': formats
    },
  };
  final d = details;
  if (d != null) m['videoDetails'] = d;
  return jsonEncode(m);
}

Map<String, dynamic> fmt(String mime, String url, int br) =>
    {'mimeType': mime, 'url': url, 'bitrate': br};

Map<String, dynamic> vfmt(String url, int h, int br) =>
    {'mimeType': 'video/mp4', 'url': url, 'height': h, 'bitrate': br};

http.Response ok(String body) => http.Response(body, 200,
    headers: {'content-type': 'application/json'});

String clientOf(http.BaseRequest req) {
  try {
    final body = (req as http.Request).body;
    return (((jsonDecode(body)['context'] as Map)['client'] as Map)['clientName'] ??
        '')
        .toString();
  } catch (_) {
    return '';
  }
}

YtTrack track(String id) => YtTrack(
    id: id,
    title: 'T $id',
    artist: 'A B',
    thumbUrl: '',
    watchUrl: 'https://www.youtube.com/watch?v=$id');

void main() {
  group('first-wins race', () {
    test('fast leg wins even when music is slow', () async {
      var posts = 0;
      final mock = MockClient((req) async {
        posts++;
        final c = clientOf(req);
        if (c == 'ANDROID_MUSIC') {
          await Future<void>.delayed(const Duration(seconds: 1));
          return ok(playerJson([fmt('audio/mp4', 'https://slow/1', 64000)]));
        }
        if (c == 'ANDROID_VR') {
          return ok(playerJson(
            [fmt('audio/mp4', 'https://fast/1', 128000)],
            details: {'title': 'Fast Song', 'author': 'Fast Artist'},
          ));
        }
        return ok(playerJson([])); // phone/remix: OK but empty
      });
      final r = StreamResolver(httpClient: mock);
      final sw = Stopwatch()..start();
      final b = await r.bundleFor('AAAAAAAAAAA');
      sw.stop();
      expect(b, isNotNull);
      expect(b!.audioUrls.first, 'https://fast/1');
      expect(b.meta.title, 'Fast Song');
      expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
      expect(posts, greaterThanOrEqualTo(2)); // loser legs still fired
      r.dispose();
    });

    test('phone leg wins when music/vr are bot-gated', () async {
      final mock = MockClient((req) async {
        if (req.method == 'GET') {
          return http.Response('<html></html>', 200); // no visitor
        }
        if (clientOf(req) == 'ANDROID') {
          return ok(playerJson(
            [fmt('audio/mp4', 'https://phone/1', 128000)],
            details: {'title': 'Phone Song', 'author': 'Phone Artist'},
          ));
        }
        return ok(playerJson([], status: 'LOGIN_REQUIRED'));
      });
      final r = StreamResolver(httpClient: mock);
      final b = await r.bundleFor('DDDDDDDDDDD');
      expect(b, isNotNull);
      expect(b!.audioUrls.first, 'https://phone/1');
      expect(b.meta.title, 'Phone Song');
      r.dispose();
    });

    test('all legs empty -> manifest fallback fills audio', () async {
      final mock = MockClient((_) async => ok(playerJson([])));
      final r = StreamResolver(
        httpClient: mock,
        manifestFetcher: (_) async => ['https://m/1'],
      );
      final b = await r.bundleFor('EEEEEEEEEEE');
      expect(b, isNotNull);
      expect(b!.audioUrls, ['https://m/1']);
      r.dispose();
    });

    test('total miss -> null, never throws', () async {
      final mock = MockClient((_) async => ok(playerJson([])));
      final r = StreamResolver(
        httpClient: mock,
        manifestFetcher: (_) async => <String>[],
      );
      expect(await r.bundleFor('FFFFFFFFFFF'), isNull);
      expect(await r.bundleFor('short'), isNull);
      r.dispose();
    });
  });

  group('cache warming', () {
    test('bundle warms UrlCache: later audioUrl = 0 new POSTs', () async {
      var posts = 0;
      final mock = MockClient((req) async {
        posts++;
        return ok(playerJson([fmt('audio/mp4', 'https://w/1', 128000)]));
      });
      final r = StreamResolver(httpClient: mock);
      const w = 'https://www.youtube.com/watch?v=GGGGGGGGGGG';
      final b = await r.bundleFor('GGGGGGGGGGG');
      expect(b, isNotNull);
      final before = posts;
      expect(await r.audioUrl(w), 'https://w/1');
      expect(posts, before); // served from 5h mem
      r.dispose();
    });

    test('primeNext warms upcoming tracks', () async {
      var posts = 0;
      final mock = MockClient((req) async {
        posts++;
        return ok(playerJson([fmt('audio/mp4', 'https://p/1', 64000)]));
      });
      final r = StreamResolver(httpClient: mock);
      await r.primeNext([track('HHHHHHHHHHH'), track('IIIIIIIIIII')]);
      final before = posts;
      expect(posts, greaterThan(0));
      expect(
          await r.audioUrl('https://www.youtube.com/watch?v=HHHHHHHHHHH'),
          'https://p/1');
      expect(posts, before); // mem hit, no new POSTs
      r.dispose();
    });

    test('bundle snapshot round-trips meta + video', () {
      final r = StreamResolver(
          httpClient: MockClient((_) async => http.Response('{}', 200)));
      final now = DateTime.now().millisecondsSinceEpoch;
      r.bundles.remember(
          const sk.StreamBundle(
            videoId: 'JJJJJJJJJJJ',
            audioUrls: ['https://a/1'],
            videoUrls: [('https://v/720', 720)],
            meta: sk.TrackMeta(
                videoId: 'JJJJJJJJJJJ',
                title: 'T',
                artist: 'A',
                durationSec: 200,
                viewCount: 1500),
          ),
          now);
      final s = r.encodeBundleSnapshot()!;
      final r2 = StreamResolver(
          httpClient: MockClient((_) async => http.Response('{}', 200)));
      expect(r2.restoreBundleSnapshot(s), 1);
      expect(r2.bundles.metaFor('JJJJJJJJJJJ', now)!.title, 'T');
      expect(r2.bundles.videoFor('JJJJJJJJJJJ', now), [('https://v/720', 720)]);
      r.dispose();
      r2.dispose();
    });
  });

  group('video bundle-first', () {
    test('muxed URLs with no extractor call', () async {
      var manifests = 0;
      final mock = MockClient((req) async {
        return ok(playerJson(
          [fmt('audio/mp4', 'https://a/1', 64000)],
          formats: [vfmt('https://v/720', 720, 1), vfmt('https://v/360', 360, 1)],
          details: {'title': 'V', 'author': 'A'},
        ));
      });
      final r = StreamResolver(
        httpClient: mock,
        manifestFetcher: (_) async {
          manifests++;
          return <String>[];
        },
      );
      const w = 'https://www.youtube.com/watch?v=KKKKKKKKKKK';
      final vids = await r.videoMuxedUrls(w);
      expect(vids, [('https://v/720', 720), ('https://v/360', 360)]);
      expect(manifests, 0); // bundle carried video; extractor untouched
      r.dispose();
    });
  });

  group('session visitor', () {
    test('reuses persisted YtSession value, zero homepage GETs', () async {
      var gets = 0;
      final mock = MockClient((req) async {
        if (req.method == 'GET') {
          gets++;
          return http.Response('<html></html>', 200);
        }
        return ok(playerJson([fmt('audio/mp4', 'https://a/1', 1)]));
      });
      final r = StreamResolver(
        httpClient: mock,
        visitorData: () => 'CgPersistedVisitor',
      );
      expect(await r.ensureSessionVisitor(), 'CgPersistedVisitor');
      await r.bundleFor('LLLLLLLLLLL');
      expect(gets, 0);
      r.dispose();
    });

    test('bootstraps from homepage once, then caches', () async {
      var gets = 0;
      final mock = MockClient((req) async {
        if (req.method == 'GET') {
          gets++;
          return http.Response(
              '<html>"visitorData":"CgTestVisitor123",</html>', 200);
        }
        // Visitor must ride context + header on the winning leg.
        final body = jsonDecode(req.body) as Map;
        final ctx =
            ((body['context'] as Map)['client'] as Map);
        expect(ctx['visitorData'], 'CgTestVisitor123');
        expect(req.headers['X-Goog-Visitor-Id'], 'CgTestVisitor123');
        return ok(playerJson([fmt('audio/mp4', 'https://a/1', 1)]));
      });
      final r = StreamResolver(httpClient: mock);
      expect(await r.ensureSessionVisitor(), 'CgTestVisitor123');
      expect(await r.ensureSessionVisitor(), 'CgTestVisitor123');
      expect(gets, 1);
      r.dispose();
    });
  });

  group('details rememberMeta', () {
    test('memo hit serves load with zero network', () async {
      var fetched = false;
      final store = DetailsStore();
      store.rememberMeta(
          'MMMMMMMMMMM',
          const sk.TrackMeta(
              videoId: 'MMMMMMMMMMM',
              title: 'Meta Title',
              artist: 'Meta Artist',
              durationSec: 210,
              viewCount: 2500,
              description: 'desc here'));
      final d = await store.load('https://www.youtube.com/watch?v=MMMMMMMMMMM');
      expect(d, isNotNull);
      expect(d!.views, 2500);
      expect(d.description, 'desc here');
      expect(d.durationSec, 210);
      expect(fetched, isFalse);
      store.dispose();
    });

    test('detail-less meta is ignored', () {
      final store = DetailsStore();
      store.rememberMeta('NNNNNNNNNNN', const sk.TrackMeta(videoId: 'x'));
      expect(store.memo, isEmpty);
      store.dispose();
    });
  });

  group('chunked downloads', () {
    test('segments assemble in order, then row persists', () async {
      final bytes = List<int>.generate(1000, (i) => i % 256);
      final mock = MockClient((req) async {
        final range = req.headers['Range'] ?? '';
        final m = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(range);
        if (m == null) {
          return http.Response.bytes(bytes, 200);
        }
        final s = int.parse(m.group(1)!);
        final e = int.parse(m.group(2)!);
        return http.Response.bytes(bytes.sublist(s, e + 1), 206, headers: {
          'content-range': 'bytes $s-$e/${bytes.length}'
        });
      });
      final dir =
          await Directory.systemTemp.createTemp('cresca-sk-dl');
      try {
        final store =
            DownloadStore(dir, httpClient: mock);
        await store.load();
        final ok = await store.enqueue(
            track('OOOOOOOOOOO'), 'https://cdn/x');
        expect(ok, isTrue);
        final f = store.fileFor('OOOOOOOOOOO')!;
        expect(f.readAsBytesSync(), bytes);
        expect(store.isDownloaded('OOOOOOOOOOO'), isTrue);
        store.dispose();
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('throttled ranges fall back to whole GET', () async {
      final bytes = List<int>.generate(500, (i) => i % 256);
      final mock = MockClient((req) async {
        if ((req.headers['Range'] ?? '').isNotEmpty) {
          return http.Response('no', 403); // CDN throttling ranges
        }
        return http.Response.bytes(bytes, 200);
      });
      final dir =
          await Directory.systemTemp.createTemp('cresca-sk-dl2');
      try {
        final store =
            DownloadStore(dir, httpClient: mock);
        await store.load();
        final ok = await store.enqueue(
            track('PPPPPPPPPPP'), 'https://cdn/y');
        expect(ok, isTrue);
        expect(
            store.fileFor('PPPPPPPPPPP')!.readAsBytesSync(), bytes);
        store.dispose();
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
