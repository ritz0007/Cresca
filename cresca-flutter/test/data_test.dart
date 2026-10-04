import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:cresca_app/core/discovery.dart';
import 'package:cresca_app/core/track.dart';
import 'package:cresca_app/data/cache.dart';
import 'package:cresca_app/data/innertube.dart';
import 'package:cresca_app/data/resolve.dart';

Map<String, dynamic> musicItem({
  String videoId = 'dQw4w9WgXcQ',
  String title = 'Tum Hi Ho',
  String sub = 'Arijit Singh • Album • 4:22',
  bool live = false,
  bool reel = false,
}) {
  final m = <String, dynamic>{
    'flexColumns': [
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {'text': title}
            ]
          }
        }
      },
      {
        'musicResponsiveListItemFlexColumnRenderer': {
          'text': {
            'runs': [
              {'text': sub}
            ]
          }
        }
      },
    ],
    'playlistItemData': {'videoId': videoId},
    'thumbnail': {
      'musicThumbnailRenderer': {
        'thumbnail': {
          'thumbnails': [
            {'url': 'https://i.ytimg.com/vi/x/hqdefault.jpg'}
          ]
        }
      }
    },
  };
  if (live) {
    m['badges'] = [
      {
        'metadataBadgeRenderer': {'label': 'LIVE'}
      }
    ];
  }
  if (reel) {
    m['navigationEndpoint'] = {
      'reelEndpoint': {'payload': 'x'}
    };
  }
  return m;
}

void main() {
  group('url cache', () {
    test('5h hit, stale evicted, 403 drop', () {
      final c = UrlCache();
      const now = 1000000000000;
      c.remember('w1', 'https://g/u1', now);
      expect(c.getFresh('w1', now + 1000), 'https://g/u1');
      expect(c.getFresh('w1', now + urlMemTtlMs + 1), isNull);
      c.remember('w2', 'https://g/u2', now);
      c.drop('w2');
      expect(c.getFresh('w2', now), isNull);
    });

    test('disk snapshot schema + throttle + restore', () {
      final c = UrlCache();
      const now = 1000000000000;
      c.remember('w1', 'https://g/u1', now);
      c.remember('stale', 'https://g/old', now - urlDiskTtlMs - 1);
      final snap = c.snapshotForDisk(now)!;
      expect(snap['savedAt'], now);
      final items = snap['items'] as Map;
      expect(items.containsKey('w1'), isTrue);
      expect(items.containsKey('stale'), isFalse); // skipped at write
      expect((items['w1'] as Map)['u'], 'https://g/u1');
      expect(c.snapshotForDisk(now + 1000), isNull); // 30s floor
      final c2 = UrlCache();
      expect(c2.restoreFromDisk(snap, now), 1);
      expect(c2.getFresh('w1', now), 'https://g/u1');
    });
  });

  group('song disk cache', () {
    test('native schema round-trip + TTLs', () {
      const tracks = [
        YtTrack(
            id: 'a',
            title: 't',
            artist: 'ar',
            thumbUrl: 'th',
            watchUrl: 'w'),
      ];
      const now = 2000000000000;
      final json = songListToJson(tracks, now);
      expect((json['items'] as List).first['thumb'], 'th');
      expect((json['items'] as List).first['watch'], 'w');
      expect(songListFromJson(json, homeCacheTtlMs, now)?.length, 1);
      expect(songListFromJson(json, homeCacheTtlMs, now + homeCacheTtlMs + 1),
          isNull);
      expect(songCacheFile('home_top'), 'yt_home_top.json');
      expect(searchCacheTtlMs, 30 * 60 * 1000);
      expect(trendingCacheTtlMs, 7 * 24 * 60 * 60 * 1000);
    });

    test('empty id rows + empty lists load null', () {
      const now = 2000000000000;
      final bad = {
        'savedAt': now,
        'items': [
          {'id': '', 'title': 'x'}
        ]
      };
      expect(songListFromJson(bad, homeCacheTtlMs, now), isNull);
      expect(
          songListFromJson(
              {'savedAt': now, 'items': []}, homeCacheTtlMs, now),
          isNull);
    });
  });

  group('tube protocol', () {
    test('search body shape', () {
      final b = searchBody('dil', 'VIS123');
      expect(b['query'], 'dil');
      final ctx = b['context'] as Map;
      final client = ctx['client'] as Map;
      expect(client['clientName'], 'WEB_REMIX');
      expect(client['hl'], 'en');
      expect(client['visitorData'], 'VIS123');
      expect(tubeUrl(TubeClient.webRemix, 'search'),
          contains('youtubei/v1/search?key='));
    });

    test('next + browse bodies', () {
      final n = nextBody('dQw4w9WgXcQ', '', playlistId: 'RDAMVMdQw4w9WgXcQ');
      expect(n['playlistId'], 'RDAMVMdQw4w9WgXcQ');
      expect(browseBody('FEmusic_charts', '')['browseId'], 'FEmusic_charts');
    });

    test('sapisid hash format + determinism', () {
      final h1 = sapisidHash('SID=x; SAPISID=abc123; X=y', 1700000000)!;
      final h2 = sapisidHash('SID=x; SAPISID=abc123; X=y', 1700000000)!;
      expect(h1, h2);
      expect(h1, matches(RegExp(r'^1700000000_[0-9a-f]{40}$')));
      expect(sapisidHash('SID=x; noauth=1', 1), isNull);
    });

    test('headers carry client + session', () {
      final h = tubeHeaders(TubeClient.webRemix,
          cookies: 'SAPISID=abc123', visitorData: 'V', poToken: 'P');
      expect(h['X-YouTube-Client-Name'], 'WEB_REMIX');
      expect(h['X-Goog-Visitor-Id'], 'V');
      expect(h['Cookie'], contains('SAPISID='));
      expect(h['Authorization'], startsWith('SAPISIDHASH '));
      expect(h['X-Goog-EOM-Visitor-Id'], 'P');
      expect(h['Referer'], 'https://music.youtube.com/');
    });
  });

  group('parsers', () {
    test('music item happy path + gates', () {
      final t = parseMusicItem(musicItem())!;
      expect(t.id, 'dQw4w9WgXcQ');
      expect(t.title, 'Tum Hi Ho');
      expect(t.artist, 'Arijit Singh');
      expect(t.watchUrl, contains('watch?v='));
      expect(parseMusicItem(musicItem(live: true, sub: 'Chan • LIVE')),
          isNull);
      expect(parseMusicItem(musicItem(reel: true)), isNull);
      expect(
          parseMusicItem(musicItem(
              title: 'Mohini Episode 12', sub: 'Chan • A • 4:00')),
          isNull);
      expect(parseMusicItem(musicItem(sub: 'Chan • A • 1:05:00')), isNull);
      expect(parseMusicItem(musicItem(videoId: 'short')), isNull);
    });

    test('video item gates', () {
      Map<String, dynamic> v(String len) => {
            'videoId': 'dQw4w9WgXcQ',
            'title': {
              'runs': [
                {'text': 'Song Title'}
              ]
            },
            'ownerText': {
              'runs': [
                {'text': 'Artist'}
              ]
            },
            'lengthText': {
              'runs': [
                {'text': len}
              ]
            },
          };
      expect(parseVideoItem(v('4:12'))?.id, 'dQw4w9WgXcQ');
      expect(parseVideoItem(v('0:12')), isNull);
      expect(parseVideoItem(v('1:05:00')), isNull);
    });

    test('search prefers music, falls back to video, dedupes', () {
      final root = {
        'contents': {
          'm': musicItem(),
          'm2': musicItem(),
          'v': {
            'videoRenderer': {
              'videoId': 'AAAAAAAAAAA',
              'title': {
                'runs': [
                  {'text': 'Vid Song'}
                ]
              },
              'shortBylineText': {
                'runs': [
                  {'text': 'Singer'}
                ]
              },
              'lengthText': {
                'runs': [
                  {'text': '3:30'}
                ]
              },
              'thumbnail': {
                'thumbnails': [
                  {'url': 'https://i.ytimg.com/t.jpg'}
                ]
              },
            }
          },
        }
      };
      final out = parseSearch(root, 10);
      expect(out.map((e) => e.id).toSet().length, out.length);
      expect(out.any((e) => e.id == 'AAAAAAAAAAA'), isTrue);
    });

    test('suggestions cap 8 + dedupe', () {
      Map<String, dynamic> sug(String s) => {
            'searchSuggestionRenderer': {
              'suggestion': {
                'runs': [
                  {'text': s}
                ]
              }
            }
          };
      final root = {
        'contents': {
          'searchSuggestionsSectionContents': [
            sug('dil'),
            sug('DIL'),
            sug('diljit'),
            for (var i = 0; i < 10; i++) sug('song $i'),
          ]
        }
      };
      final out = parseSuggestions(root);
      expect(out.length, lessThanOrEqualTo(8));
      expect(out.where((s) => s.toLowerCase() == 'dil').length, 1);
    });

    test('shelves title→tracks with caps', () {
      Map<String, dynamic> wrap(Map<String, dynamic> inner) => inner;
      final shelf = {
        'musicCarouselShelfRenderer': {
          'header': {
            'musicCarouselShelfBasicHeaderRenderer': {
              'title': {
                'runs': [
                  {'text': 'Trending'}
                ]
              }
            }
          },
          'contents': {
            'contents': [
              wrap({
                'musicResponsiveListItemRenderer': musicItem(
                    videoId: 'AAAAAAAAAAA',
                    title: 'Hit One',
                    sub: 'Star • A • 3:00'),
              }),
              wrap({
                'musicResponsiveListItemRenderer':
                    musicItem(videoId: 'BBBBBBBBBBB'),
              }),
            ]
          }
        }
      };
      final out = parseShelves({'s': shelf}, 8, 1);
      expect(out.keys, ['Trending']);
      expect(out['Trending']!.length, 1); // per-shelf cap
    });

    test('radio panels gate seed/junk/duration', () {
      Map<String, dynamic> p(String id, String title, String len) => {
            'playlistPanelVideoRenderer': {
              'videoId': id,
              'title': {
                'runs': [
                  {'text': title}
                ]
              },
              'shortBylineText': {
                'runs': [
                  {'text': 'Singer'}
                ]
              },
              'lengthText': {
                'runs': [
                  {'text': len}
                ]
              },
            }
          };
      final root = {
        'a': p('SEEDSEEDSE1', 'Seed Song', '3:00'),
        'b': p('AAAAAAAAAAA', 'Good Song', '4:00'),
        'c': p('BBBBBBBBBBB', 'Show Episode 3', '4:00'),
        'd': p('CCCCCCCCCCC', 'Mix Hour', '1:05:00'),
      };
      final out = parseRadioPanels(root, 'SEEDSEEDSE1', 10);
      expect(out.map((e) => e.id).toList(), ['AAAAAAAAAAA']);
    });
  });

  group('autoplay fill rules', () {
    YtTrack n(String id, String title, String artist) => YtTrack(
        id: id,
        title: title,
        artist: artist,
        thumbUrl: '',
        watchUrl: 'https://www.youtube.com/watch?v=$id');

    test('seed + same-name out, max 2/artist', () {
      final seed = n('SEEDSEEDSE1', 'Diamond Dreams', 'Ava');
      final rel = [
        n('SEEDSEEDSE1', 'Diamond Dreams', 'Ava'),
        n('AAAAAAAAAAA', 'Diamond Dreams (Official Video)', 'Ava'),
        n('BBBBBBBBBBB', 'Midnight Run', 'Ava'),
        n('CCCCCCCCCCC', 'Neon Sky', 'Ava'),
        n('DDDDDDDDDDD', 'Paper Hearts', 'Ava'),
        n('EEEEEEEEEEE', 'Wild Fire', 'Rex'),
      ];
      final out = buildAutoplay(seed, rel, [], max: 20, random: FakeRandom());
      expect(out.any((t) => t.id == 'SEEDSEEDSE1'), isFalse);
      expect(out.any((t) => t.id == 'AAAAAAAAAAA'), isFalse);
      expect(out.where((t) => t.artist == 'Ava').length,
          lessThanOrEqualTo(2));
      expect(out.any((t) => t.id == 'EEEEEEEEEEE'), isTrue);
    });

    test('thin graph pulls filler once', () {
      final seed = n('SEEDSEEDSE1', 'Lonely Star', 'Nova');
      final out = buildAutoplay(seed, [], [n('FFFFFFFFFFF', 'Nova Hit', 'Nova')],
          max: 20, random: FakeRandom());
      expect(out.map((e) => e.id), ['FFFFFFFFFFF']);
    });

    test('round-robin interleave represents all', () {
      YtTrack k(String id) => n(id, 't', 'a');
      final out = interleaveRoundRobin([
        [k('a1'), k('a2'), k('a3')],
        [k('b1')],
        [k('c1'), k('c2')],
      ], max: 5);
      expect(out.map((e) => e.id).toList(), ['a1', 'b1', 'c1', 'a2', 'c2']);
    });
  });

  group('resolve race', () {
    test('player body shape', () {
      final b = playerBody(
          TubeClient.androidMusic, 'dQw4w9WgXcQ', 'V', poToken: 'P');
      expect(b['videoId'], 'dQw4w9WgXcQ');
      expect(b['racyCheckOk'], true);
      expect(b['contentCheckOk'], true);
      expect(((b['context'] as Map)['client'] as Map)['clientName'],
          'ANDROID_MUSIC');
      expect(
          (b['serviceIntegrityDimensions'] as Map)['poToken'], 'P');
      expect(
          playerBody(TubeClient.androidMusic, 'x', '')
              .containsKey('serviceIntegrityDimensions'),
          isFalse);
    });

    test('player body context follows the calling client', () {
      for (final c in [
        TubeClient.webRemix,
        TubeClient.androidMusic,
        TubeClient.androidVr,
        TubeClient.web,
      ]) {
        final b = playerBody(c, 'dQw4w9WgXcQ', '');
        expect(((b['context'] as Map)['client'] as Map)['clientName'],
            c.name);
        expect(((b['context'] as Map)['client'] as Map)['clientVersion'],
            c.version);
      }
    });

    test('player parse: status/mime/cipher/sort/dedupe', () {
      expect(
          parsePlayerUrls(jsonDecode(_playerJson([], status: 'LOGIN_REQUIRED'))
              .cast<String, dynamic>()),
          isEmpty);
      final root = jsonDecode(_playerJson([
        _fmt('video/mp4', 'https://v/1', 999999),
        _fmt('audio/mp4', 'https://a/low', 48000),
        _fmt('audio/mp4', '', 999), // cipher-shaped: no direct url
        _fmt('audio/webm', 'https://a/hi', 160000),
        _fmt('audio/webm', 'https://a/hi', 160000),
      ])).cast<String, dynamic>();
      expect(parsePlayerUrls(root),
          ['https://a/hi', 'https://a/low']);
    });

    test('fast path remembers best; mem serves second call', () async {
      var posts = 0;
      final mock = MockClient((req) async {
        posts++;
        return _playerResponse(_playerJson([
          _fmt('audio/mp4', 'https://a/best', 128000),
          _fmt('audio/mp4', 'https://a/low', 48000),
        ]));
      });
      final r = StreamResolver(httpClient: mock);
      const w = 'https://www.youtube.com/watch?v=dQw4w9WgXcQ';
      expect(await r.audioUrl(w), 'https://a/best');
      final before = posts;
      expect(await r.audioUrl(w), 'https://a/best');
      expect(posts, before); // served from 5h mem
    });

    test('single-flight joins concurrent callers', () async {
      var posts = 0;
      final mock = MockClient((req) async {
        posts++;
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return _playerResponse(_playerJson([
          _fmt('audio/mp4', 'https://a/1', 64000),
        ]));
      });
      final r = StreamResolver(httpClient: mock);
      const w = 'https://www.youtube.com/watch?v=AAAAAAAAAAA';
      final results = await Future.wait([r.audioUrl(w), r.audioUrl(w)]);
      expect(results, ['https://a/1', 'https://a/1']);
      expect(posts, 2); // one race (music+vr legs), shared by both callers
    });

    test('403 everywhere falls back to manifest; drop refetches', () async {
      var posts = 0;
      final mock = MockClient((req) async {
        posts++;
        return _playerResponse('forbidden', 403);
      });
      final r = StreamResolver(
        httpClient: mock,
        manifestFetcher: (_) async => ['https://m/1'],
      );
      const w = 'https://www.youtube.com/watch?v=BBBBBBBBBBB';
      expect(await r.audioUrl(w), 'https://m/1');
      r.dropCachedUrl(w);
      expect(await r.audioUrl(w), 'https://m/1');
      expect(posts, greaterThan(2)); // refetched after drop
    });

    test('snapshot round-trips through resolver', () {
      final r = StreamResolver(
          httpClient: MockClient((_) async => _playerResponse('{}')));
      r.urlCache.remember('w', 'https://g/u', 3000000000000);
      r.urlCache.lastDiskSaveMs = 0;
      final s = r.encodeUrlSnapshot()!;
      final r2 = StreamResolver(
          httpClient: MockClient((_) async => _playerResponse('{}')));
      expect(r2.restoreUrlSnapshot(s), 1);
      r.dispose();
      r2.dispose();
    });
  });
}

class FakeRandom implements Random {
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => 0.0;
}

http.Response _playerResponse(String body, [int code = 200]) =>
    http.Response(body, code,
        headers: {'content-type': 'application/json'});

String _playerJson(List<Map<String, dynamic>> formats,
        {String status = 'OK'}) =>
    jsonEncode({
      'playabilityStatus': {'status': status},
      'streamingData': {'adaptiveFormats': formats, 'formats': []},
    });

Map<String, dynamic> _fmt(String mime, String url, int br) =>
    {'mimeType': mime, 'url': url, 'bitrate': br};
