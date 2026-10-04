import 'package:test/test.dart';

import 'package:cresca_app/data/lyrics.dart';

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
  });
}
