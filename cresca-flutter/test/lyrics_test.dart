import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'package:cresca_app/data/lyrics.dart';
import 'package:cresca_app/data/lyrics/genius.dart';
import 'package:cresca_app/data/lyrics/html.dart';
import 'package:cresca_app/data/lyrics/memo.dart';
import 'package:cresca_app/data/lyrics/musixmatch.dart';
import 'package:cresca_app/data/lyrics/netease.dart';
import 'package:cresca_app/data/lyrics/qq.dart';
import 'package:cresca_app/data/lyrics/scoring.dart';

void main() {
  group('lrc', () {
    test('parses mm:ss.xx + offset shifts all lines', () {
      const lrc = '[offset:+500]\n[00:12.34]Hello\n[01:02.345]World\n';
      final lines = parseLrc(lrc);
      expect(lines.length, 2);
      expect(lines[0].startMs, 12340 + 500);
      expect(lines[0].text, 'Hello');
      expect(lines[1].startMs, 62345 + 500);
    });

    test('blank text lines dropped, negative shifted out', () {
      const lrc = '[offset:-5000]\n[00:12.34]Hi\n[00:15.00]   \n';
      final lines = parseLrc(lrc);
      expect(lines.map((e) => e.text).toList(), ['Hi']);
      expect(lines.first.startMs, 12340 - 5000);
    });

    test('lastLineMs + consistency penalty', () {
      expect(lastLineMs('[00:10.00]a\n[03:00.00]b'), 180000);
      expect(lastLineMs('nope'), 0);
      expect(consistencyPenalty(400000, 180.0), -8); // over +15s
      expect(consistencyPenalty(60000, 180.0), -4); // under 60%
      expect(consistencyPenalty(170000, 180.0), 0);
      expect(consistencyPenalty(0, 180.0), 0);
    });
  });

  group('captions', () {
    test('vtt cues join wrapped lines', () {
      const vtt = 'WEBVTT\n\n00:01.000 --> 00:04.000\nhello\nworld\n\n'
          '00:05.500 --> 00:07.000\nbye\n';
      final lines = parseVtt(vtt);
      expect(lines.length, 2);
      expect(lines[0].startMs, 1000);
      expect(lines[0].text, 'hello world');
      expect(lines[1].startMs, 5500);
    });

    test('srt numbering skipped, comma timestamps', () {
      const srt = '1\n00:00:01,000 --> 00:00:04,000\nFirst\n\n'
          '2\n00:00:05,000 --> 00:00:06,000\nSecond\n';
      final lines = parseSrt(srt);
      expect(lines.map((e) => e.text), ['First', 'Second']);
      expect(lines[0].startMs, 1000);
    });

    test('timedtext xml entities + music cues dropped', () {
      const xml = '<?xml version="1.0"?><transcript>'
          '<text start="1.2">[Music]</text>'
          '<text start="3.4">Fish &amp; Chips</text></transcript>';
      final lines = parseTimedTextXml(xml);
      expect(lines.length, 1);
      expect(lines[0].startMs, 3400);
      expect(lines[0].text, 'Fish & Chips');
    });

    test('autodetect + sort + dedupe', () {
      const vtt = 'WEBVTT\n\n00:05.000 --> 00:06.000\nB\n\n'
          '00:01.000 --> 00:02.000\nA\n\n'
          '00:01.500 --> 00:02.500\nA\n';
      final lines = parseCaptions(vtt);
      expect(lines.map((e) => e.text), ['A', 'B']);
      expect(parseCaptions('garbage'), isEmpty);
    });

    test('vttTsToMs shapes', () {
      expect(vttTsToMs('01:02.345'), 62345);
      expect(vttTsToMs('01:02:03,456'), 3723456);
      expect(vttTsToMs('bogus'), -1);
    });
  });

  group('query cleaning', () {
    test('artist strips labels/feats, rejects blobs', () {
      expect(cleanArtist('T-Series'), '');
      expect(cleanArtist('Arijit Singh feat. Shreya'), 'Arijit Singh');
      expect(cleanArtist('SonyMusicIndiaOfficial'), '');
      expect(cleanArtist('Pritam'), 'Pritam');
    });

    test('title strips bracket noise + artist prefix', () {
      expect(cleanTitle('Shayad - Love Aaj Kal'), 'Shayad');
      expect(
          cleanTitle('Tum Hi Ho (Official Video) | T-Series'), 'Tum Hi Ho');
    });
  });

  group('lrclib scoring', () {
    test('exact + artist + duration wins, junk gated', () {
      // 4 (synced) + 2 (start-match: hi/ho are 2-letter stopwords) +
      // 1 (partial artist) + 4 (duration) + 0 (consistency).
      final good = scoreLrclibRecord(
        query: 'tum hi ho arijit',
        trackName: 'Tum Hi Ho',
        artistName: 'Arijit Singh',
        hasSynced: true,
        hasPlain: true,
        durSec: 262.0,
        durationMs: 262000,
        synced: '[00:10.00]a\n[04:10.00]b',
      )!;
      expect(good, 11);
      expect(
          scoreLrclibRecord(
            query: 'tum hi ho arijit',
            trackName: 'Completely Different Song',
            artistName: 'Someone Else',
            hasSynced: true,
            hasPlain: true,
            durSec: 200.0,
            durationMs: 262000,
            synced: '[00:10.00]x',
          ),
          isNull);
    });

    test('wrong artist penalized, long duration rejected', () {
      final s = scoreLrclibRecord(
        query: 'tum hi ho arijit',
        trackName: 'Tum Hi Ho',
        artistName: 'Zzz Unknown',
        hasSynced: false,
        hasPlain: true,
        durSec: 400.0,
        durationMs: 262000,
        synced: '',
      )!;
      expect(s, lessThan(4));
    });

    test('caption rank prefers manual en/hi', () {
      const auto = CaptionTrack(
          baseUrl: 'a', lang: 'en', name: 'auto', isAuto: true);
      const manualHi = CaptionTrack(
          baseUrl: 'b', lang: 'hi', name: 'Hindi', isAuto: false);
      const manualFr = CaptionTrack(
          baseUrl: 'c', lang: 'fr', name: 'French', isAuto: false);
      final ranked = rankCaptions([auto, manualFr, manualHi]);
      expect(ranked.first.lang, 'hi');
      expect(ranked.last.isAuto, isTrue);
    });

    test('caption track parse + vtt url swap', () {
      final t = parseCaptionTrack({
        'baseUrl': 'https://x/y?fmt=srv3',
        'languageCode': 'en',
        'kind': 'asr',
        'name': {
          'runs': [
            {'text': 'English auto'}
          ]
        },
      })!;
      expect(t.isAuto, isTrue);
      expect(captionVttUrl(t.baseUrl), contains('fmt=vtt'));
      expect(parseCaptionTrack({'noid': 1}), isNull);
    });

    test('endpoint url shapes', () {
      expect(lrclibSearchUrl('a b'), contains('q=a+b'));
      expect(lrclibExactUrl('a', 't'), contains('artist_name=a'));
      expect(ovhUrl('a', 't'), startsWith('https://api.lyrics.ovh/v1/'));
    });

    test('source attribution names', () {
      expect(lyricSourceName(LyricSource.kugou), 'KuGou');
      expect(lyricSourceName(LyricSource.lrclib), 'LRCLIB');
      expect(
          lyricSourceName(LyricSource.youtubeCaptions), 'YouTube');
      expect(lyricSourceName(LyricSource.none), '');
    });

    test('kugou: hash → candidates → base64 lrc', () async {
      final lrc = '[00:10.00]hello\n[00:15.00]world\n[00:20.00]again\n';
      final mock = MockClient((req) async {
        final u = req.url.toString();
        if (u.contains('mobileservice.kugou.com')) {
          return http.Response(
              jsonEncode({
                'data': {
                  'info': [
                    {'hash': 'ABC123'}
                  ]
                }
              }),
              200);
        }
        if (u.contains('lyrics.kugou.com/search')) {
          expect(u, contains('hash=ABC123'));
          return http.Response(
              jsonEncode({
                'candidates': [
                  {'id': '1', 'accesskey': 'K1'}
                ]
              }),
              200);
        }
        if (u.contains('lyrics.kugou.com/download')) {
          return http.Response(
              jsonEncode({'content': base64.encode(utf8.encode(lrc))}),
              200);
        }
        return http.Response('nope', 404);
      });
      final res = await fetchKugou(mock,
          artist: 'A B', title: 'T', durationMs: 0);
      expect(res, isA<LyricsSynced>());
      final synced = res as LyricsSynced;
      expect(synced.source, LyricSource.kugou);
      expect(synced.lines.map((e) => e.text),
          ['hello', 'world', 'again']);
    });

    test('kugou: empty candidates → null (falls through)', () async {
      final mock = MockClient((_) async =>
          http.Response(jsonEncode({'candidates': []}), 200));
      expect(
          await fetchKugou(mock, artist: 'A', title: 'T'),
          isNull);
    });
  });

  group('qq', () {
    test('search parses list, lyric raw + base64 + jsonp', () {
      final body = jsonEncode({
        'data': {
          'song': {
            'list': [
              {
                'songmid': 'MID1',
                'songname': 'Tum Hi Ho',
                'singer': [
                  {'name': 'Arijit Singh'}
                ],
                'interval': 262,
              },
              {'songmid': '', 'songname': 'junk'},
            ]
          }
        }
      });
      final songs = parseQqSearch(body);
      expect(songs.length, 1);
      expect(songs.first.mid, 'MID1');
      expect(songs.first.artist, 'Arijit Singh');
      expect(songs.first.durationMs, 262000);
      expect(parseQqSearch('garbage'), isEmpty);

      const lrc = '[00:10.00]hello\n[00:15.00]world\n';
      expect(decodeQqLyric(jsonEncode({'lyric': lrc})), lrc.trim());
      final b64 = base64.encode(utf8.encode(lrc));
      expect(decodeQqLyric(jsonEncode({'lyric': b64})), lrc.trim());
      expect(
          decodeQqLyric('callback(${jsonEncode({'lyric': lrc})})'),
          lrc.trim());
      expect(decodeQqLyric(jsonEncode({'lyric': ''})), isEmpty);
    });

    test('search → lyric download returns synced', () async {
      const lrc =
          '[00:10.00]hello\n[00:15.00]world\n[00:20.00]again\n';
      final mock = MockClient((req) async {
        final u = req.url.toString();
        if (u.contains('client_search_cp')) {
          return http.Response(
              jsonEncode({
                'data': {
                  'song': {
                    'list': [
                      {
                        'songmid': 'MID1',
                        'songname': 'Tum Hi Ho',
                        'singer': [
                          {'name': 'Arijit Singh'}
                        ],
                        'interval': 262,
                      }
                    ]
                  }
                }
              }),
              200);
        }
        if (u.contains('fcg_query_lyric_new')) {
          expect(u, contains('songmid=MID1'));
          return http.Response(
              jsonEncode({'lyric': base64.encode(utf8.encode(lrc))}),
              200);
        }
        return http.Response('nope', 404);
      });
      final res = await fetchQq(mock,
          artist: 'Arijit Singh',
          title: 'Tum Hi Ho',
          durationMs: 262000);
      expect(res, isA<LyricsSynced>());
      expect((res as LyricsSynced).source, LyricSource.qq);
    });

    test('empty search → null', () async {
      final mock = MockClient(
          (_) async => http.Response(jsonEncode({}), 200));
      expect(await fetchQq(mock, artist: 'A', title: 'T'), isNull);
    });
  });

  group('netease', () {
    test('search parses songs, yrc converts, lrc preferred', () {
      final body = jsonEncode({
        'result': {
          'songs': [
            {
              'id': 11,
              'name': 'Tum Hi Ho',
              'artists': [
                {'name': 'Arijit Singh'}
              ],
              'duration': 262000,
            }
          ]
        }
      });
      final songs = parseNeteaseSearch(body);
      expect(songs.length, 1);
      expect(songs.first.id, 11);
      expect(songs.first.durationMs, 262000);
      expect(parseNeteaseSearch('garbage'), isEmpty);

      const yrc = '[12340,2000](0,500)hel(500,500)lo\n[18000,1500]world\n';
      final conv = convertNeteaseYrc(yrc);
      expect(conv, contains('[0:12.340]hello'));
      expect(conv, contains('[0:18.000]world'));

      const lrc = '[00:10.00]a\n[00:15.00]b\n';
      expect(parseNeteaseLyric(jsonEncode({'lrc': {'lyric': lrc}})),
          lrc.trim());
      expect(
          parseNeteaseLyric(
              jsonEncode({'lrc': {'lyric': ''}, 'yrc': {'lyric': yrc}})),
          contains('[0:12.340]'));
      expect(parseNeteaseLyric(jsonEncode({})), isEmpty);
    });

    test('search → lyric returns synced', () async {
      const lrc =
          '[00:10.00]hello\n[00:15.00]world\n[00:20.00]again\n';
      final mock = MockClient((req) async {
        final u = req.url.toString();
        if (u.contains('/api/search/get/web')) {
          return http.Response(
              jsonEncode({
                'result': {
                  'songs': [
                    {
                      'id': 42,
                      'name': 'Tum Hi Ho',
                      'artists': [
                        {'name': 'Arijit Singh'}
                      ],
                      'duration': 262000,
                    }
                  ]
                }
              }),
              200);
        }
        if (u.contains('/api/song/lyric')) {
          expect(u, contains('id=42'));
          return http.Response(
              jsonEncode({'lrc': {'lyric': lrc}}), 200);
        }
        return http.Response('nope', 404);
      });
      final res = await fetchNetease(mock,
          artist: 'Arijit Singh',
          title: 'Tum Hi Ho',
          durationMs: 262000);
      expect(res, isA<LyricsSynced>());
      expect((res as LyricsSynced).source, LyricSource.netease);
    });
  });

  group('musixmatch', () {
    test('search dedupes + caps, subtitle + plain parse', () {
      const html = '<a href="/lyrics/A/Song">x</a>'
          '<a href="/lyrics/A/Song">dup</a>'
          '<a href="/lyrics/B/Other">y</a>';
      final urls = parseMusixmatchSearch(html);
      expect(urls, [
        'https://www.musixmatch.com/lyrics/A/Song',
        'https://www.musixmatch.com/lyrics/B/Other',
      ]);
      expect(parseMusixmatchSearch(html, 1).length, 1);

      const sub = r'{"subtitle_list":[{"subtitle":{"subtitle_body":"[00:10.00]hi"}}}]}';
      expect(parseMusixmatchSubtitle(sub), '[00:10.00]hi');

      const plain =
          r'{"lyrics":{"lyrics_body":"line one\nline two\n*** This Lyrics is NOT for Commercial use ***"}}';
      expect(parseMusixmatchPlain(plain), 'line one\nline two');
      expect(parseMusixmatchPlain('{}'), isEmpty);
    });

    test('json subtitle array converts to lrc', () {
      const body =
          '[{"time":{"total":12.34},"text":"hello"},'
          '{"time":{"total":18.0},"text":"world"}]';
      final lrc = musixmatchSubtitleToLrc(body);
      final lines = parseLrc(lrc);
      expect(lines.map((e) => e.text), ['hello', 'world']);
      expect(lines.first.startMs, 12340);
      expect(musixmatchSubtitleToLrc('[00:10.00]raw'), isEmpty);
    });

    test('search → track subtitle returns synced', () async {
      final mock = MockClient((req) async {
        final u = req.url.toString();
        if (u.contains('musixmatch.com/search')) {
          return http.Response(
              '<a href="/lyrics/A/Song">x</a>', 200);
        }
        return http.Response(
            r'{"subtitle_list":[{"subtitle":{"subtitle_body":"[00:10.00]a\n[00:15.00]b\n[00:20.00]c"}}]}',
            200);
      });
      final res = await fetchMusixmatch(mock,
          artist: 'A', title: 'Song');
      expect(res, isA<LyricsSynced>());
      expect((res as LyricsSynced).source, LyricSource.musixmatch);
    });
  });

  group('genius', () {
    test('search extracts song urls, containers to text', () {
      const html = '<a href="https://genius.com/A-song-lyrics">a</a>'
          '<a href="https://genius.com/A-song-lyrics">dup</a>'
          '<a href="https://genius.com/albums">not a song</a>';
      expect(parseGeniusSearch(html),
          ['https://genius.com/A-song-lyrics']);

      const page = '<div data-lyrics-container="true">'
          'First line<br>Second <i>emph</i></div>'
          '<div data-lyrics-container="true"><p>Third</p></div>';
      final text = parseGeniusLyrics(page);
      expect(text, contains('First line'));
      expect(text, contains('Second emph'));
      expect(text, contains('Third'));
      expect(parseGeniusLyrics('<div>nothing</div>'), isEmpty);
    });

    test('fragment helper strips tags + entities', () {
      expect(lyricFragmentToText('a<br>b</p><b>c</b>'), 'a\nb\nc');
      expect(lyricFragmentToText('Fish &amp; Chips'), 'Fish & Chips');
    });

    test('search → song returns plain', () async {
      final mock = MockClient((req) async {
        final u = req.url.toString();
        if (u.contains('genius.com/search')) {
          return http.Response(
              '<a href="https://genius.com/A-song-lyrics">a</a>',
              200);
        }
        return http.Response(
            '<div data-lyrics-container="true">line one<br>'
            'line two<br>line three<br>line four</div>',
            200);
      });
      final res =
          await fetchGenius(mock, artist: 'A', title: 'Song');
      expect(res, isA<LyricsPlain>());
      expect((res as LyricsPlain).source, LyricSource.genius);
    });
  });

  group('scoring + memo', () {
    test('duration bonus tiers at ±3s top', () {
      expect(
          lyricDurationBonus(durationMs: 262000, durSec: 263.0), 5);
      expect(
          lyricDurationBonus(durationMs: 262000, durSec: 270.0), 3);
      expect(
          lyricDurationBonus(durationMs: 262000, durSec: 280.0), 1);
      expect(
          lyricDurationBonus(durationMs: 262000, durSec: 400.0), -6);
      expect(lyricDurationBonus(durationMs: 0, durSec: 200.0), 0);
    });

    test('candidate: synced beats plain, junk gated', () {
      const q = 'tum hi ho arijit';
      final synced = scoreLyricCandidate(
        query: q,
        trackName: 'Tum Hi Ho',
        artistName: 'Arijit Singh',
        hasSynced: true,
        hasPlain: true,
        durSec: 262.0,
        durationMs: 262000,
      )!;
      final plain = scoreLyricCandidate(
        query: q,
        trackName: 'Tum Hi Ho',
        artistName: 'Arijit Singh',
        hasSynced: false,
        hasPlain: true,
        durSec: 262.0,
        durationMs: 262000,
      )!;
      expect(synced, greaterThan(plain));
      expect(
          scoreLyricCandidate(
            query: q,
            trackName: 'Completely Different Song',
            artistName: 'Someone Else',
            hasSynced: true,
            hasPlain: true,
            durSec: 200.0,
            durationMs: 262000,
            consistency: 0,
          ),
          isNull);
    });

    test('memo is a 128-entry lru', () {
      final m = LruMemo<String, int>(2);
      m.put('a', 1);
      m.put('b', 2);
      expect(m.get('a'), 1); // refreshes a
      m.put('c', 3); // evicts b
      expect(m.get('b'), isNull);
      expect(m.length, 2);
      expect(lyricsMemoKey('A ', ' T', 1), contains('a'));
    });

    test('pipeline prefers synced qq over lrclib plain', () async {
      clearLyricsMemo();
      const lrc =
          '[00:10.00]hello\n[00:15.00]world\n[00:20.00]again\n';
      final mock = MockClient((req) async {
        final u = req.url.toString();
        if (u.contains('lrclib.net')) {
          return http.Response(
              jsonEncode([
                {
                  'trackName': 'Tum Hi Ho',
                  'artistName': 'Arijit Singh',
                  'syncedLyrics': '',
                  'plainLyrics': 'plain fallback text here yes',
                  'duration': 262.0,
                }
              ]),
              200);
        }
        if (u.contains('client_search_cp')) {
          return http.Response(
              jsonEncode({
                'data': {
                  'song': {
                    'list': [
                      {
                        'songmid': 'MID1',
                        'songname': 'Tum Hi Ho',
                        'singer': [
                          {'name': 'Arijit Singh'}
                        ],
                        'interval': 262,
                      }
                    ]
                  }
                }
              }),
              200);
        }
        if (u.contains('fcg_query_lyric_new')) {
          return http.Response(
              jsonEncode({'lyric': lrc}), 200);
        }
        return http.Response('nope', 404);
      });
      final res = await fetchLrclib(mock,
          artist: 'Arijit Singh',
          title: 'Tum Hi Ho',
          durationMs: 262000);
      expect(res, isA<LyricsSynced>());
      expect((res as LyricsSynced).source, LyricSource.qq);
      // Success memoized: a second call hits no network.
      final fail = MockClient(
          (_) async => http.Response('nope', 500));
      final again = await fetchLrclib(fail,
          artist: 'Arijit Singh',
          title: 'Tum Hi Ho',
          durationMs: 262000);
      expect(again, isA<LyricsSynced>());
      clearLyricsMemo();
    });

    test('new source attribution names', () {
      expect(lyricSourceName(LyricSource.qq), 'QQ Music');
      expect(lyricSourceName(LyricSource.netease), 'NetEase');
      expect(lyricSourceName(LyricSource.musixmatch), 'Musixmatch');
      expect(lyricSourceName(LyricSource.genius), 'Genius');
    });
  });
}
