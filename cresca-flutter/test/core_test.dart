import 'package:test/test.dart';

import 'package:cresca_app/core/crash_log.dart';
import 'package:cresca_app/core/jam.dart';
import 'package:cresca_app/core/motion.dart';
import 'package:cresca_app/core/theme_accent.dart';
import 'package:cresca_app/core/track.dart';

void main() {
  group('YtTrack', () {
    test('json round-trip keeps schema', () {
      const t = YtTrack(
        id: 'dQw4w9WgXcQ',
        title: 'Neon - Midnight',
        artist: 'Neon',
        thumbUrl: 'https://img/t.jpg',
        watchUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      final back = YtTrack.fromJson(t.toJson());
      expect(back.id, t.id);
      expect(back.title, t.title);
      expect(back.artist, t.artist);
      expect(back.thumbUrl, t.thumbUrl);
      expect(back.watchUrl, t.watchUrl);
      expect(back.localPath, '');
    });

    test('displayArtist prefers real uploader', () {
      const t = YtTrack(
        id: 'a',
        title: 'x',
        artist: 'Arijit Singh',
        thumbUrl: '',
        watchUrl: '',
      );
      expect(t.displayArtist(), 'Arijit Singh');
    });

    test('displayArtist falls back to Artist - Title prefix', () {
      const t = YtTrack(
        id: 'a',
        title: 'Darshan Raval - Hawa Banke',
        artist: 'Song',
        thumbUrl: '',
        watchUrl: '',
      );
      expect(t.displayArtist(), 'Darshan Raval');
    });

    test('displayArtist strips Topic-channel suffix', () {
      const t = YtTrack(
        id: 'a',
        title: 'x',
        artist: 'AP Dhillon - Topic',
        thumbUrl: '',
        watchUrl: '',
      );
      expect(t.displayArtist(), 'AP Dhillon');
    });

    test('displayArtist never blank', () {
      const t = YtTrack(
        id: 'a',
        title: 'zzz',
        artist: 'Video',
        thumbUrl: '',
        watchUrl: '',
      );
      expect(t.displayArtist(), 'Unknown Artist');
    });
  });

  group('S3 gates', () {
    test('junk episodes rejected', () {
      expect(isMusicJunk('Mohini Episode 12', 'T-Series'), isTrue);
      expect(isMusicJunk('Show Ep. 5 live', 'chan'), isTrue);
      expect(isMusicJunk('S01E03 full', 'chan'), isTrue);
      expect(isMusicJunk('Pitch Perfect', 'Trailer'), isTrue);
      expect(isMusicJunk('Tum Hi Ho', 'Arijit Singh'), isFalse);
    });

    test('artist-like labels rejected', () {
      expect(isArtistLike('YouTube'), isFalse);
      expect(isArtistLike('Official Films'), isFalse);
      expect(isArtistLike('T-Series'), isTrue);
      expect(isArtistLike(''), isFalse);
    });

    test('shorts + reel guarded', () {
      expect(isShortsUrl('https://www.youtube.com/shorts/abc'), isTrue);
      expect(isShortsUrl('https://www.youtube.com/watch?v=abc'), isFalse);
      expect(
          passesSongGates(
            title: 'song',
            artist: 'artist',
            watchUrl: 'https://www.youtube.com/shorts/abcdefghijk',
            durationSec: 200,
            isLive: false,
          ),
          isFalse);
    });

    test('duration gate 30..600 strict', () {
      expect(isSongDuration(0), isFalse);
      expect(isSongDuration(29), isFalse);
      expect(isSongDuration(30), isTrue);
      expect(isSongDuration(600), isTrue);
      expect(isSongDuration(601), isFalse);
    });

    test('live + junk fail full gate', () {
      expect(
          passesSongGates(
            title: 'Tum Hi Ho',
            artist: 'Arijit',
            watchUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            durationSec: 240,
            isLive: false,
          ),
          isTrue);
      expect(
          passesSongGates(
            title: 'Concert LIVE',
            artist: 'Arijit',
            watchUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            durationSec: 240,
            isLive: true,
          ),
          isFalse);
    });

    test('ids distinct, video id parse', () {
      expect(extractVideoId('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
          'dQw4w9WgXcQ');
      expect(extractVideoId('https://youtu.be/x'), isNull);
      final dupes = distinctById([
        const YtTrack(
            id: 'a', title: 't', artist: 'ar', thumbUrl: '', watchUrl: ''),
        const YtTrack(
            id: 'a', title: 't2', artist: 'ar', thumbUrl: '', watchUrl: ''),
        const YtTrack(
            id: 'b', title: 't', artist: 'ar', thumbUrl: '', watchUrl: ''),
      ]);
      expect(dupes.map((e) => e.id).toList(), ['a', 'b']);
    });
  });

  group('format helpers', () {
    test('fmtMs m:ss', () {
      expect(fmtMs(0), '0:00');
      expect(fmtMs(-5), '0:00');
      expect(fmtMs(65000), '1:05');
      expect(fmtMs(600000), '10:00');
    });

    test('fmtSubs K/M/B', () {
      expect(fmtSubs(0), '');
      expect(fmtSubs(999), '999');
      expect(fmtSubs(1500), '1.5K');
      expect(fmtSubs(2500000), '2.5M');
      expect(fmtSubs(1200000000), '1.2B');
    });

    test('hdThumb maxres for 11-char ids', () {
      const t = YtTrack(
          id: 'dQw4w9WgXcQ',
          title: 't',
          artist: 'a',
          thumbUrl: 'low.jpg',
          watchUrl: '');
      expect(hdThumb(t),
          'https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg');
      const odd = YtTrack(
          id: 'short', title: 't', artist: 'a', thumbUrl: 'low.jpg', watchUrl: '');
      expect(hdThumb(odd), 'low.jpg');
    });

    test('sharpThumb upscales w/h params', () {
      expect(sharpThumb('https://x/=w120-h120'), 'https://x/=w544-h544');
      expect(sharpThumb('https://x/plain.jpg'), 'https://x/plain.jpg');
    });
  });

  group('accent math', () {
    test('null with no song, red fallback for mono', () {
      expect(songAccentOf(0xFF112233, false), isNull);
      expect(songAccentOf(0xFF000000, true), crescaRed);
      expect(songAccentOf(0xFFFFFFFF, true), crescaRed);
    });

    test('revive lifts brightness, on-color by 0.45', () {
      final accent = songAccentOf(0xFF3A0A12, true)!;
      expect(accent, isNot(crescaRed));
      expect(luminanceOf(accent), greaterThan(luminanceOf(0xFF3A0A12)));
      expect(onColorFor(0xFFFFFFFF), 0xFF1A1A1E);
      expect(onColorFor(0xFF000000), 0xFFFFFFFF);
    });

    test('dominant fallback + 8x8 path', () {
      expect(dominantOfPixels([]), fallbackDom);
      final px = List<int>.filled(64, 0xFF804020);
      final dom = dominantOfPixels(px);
      expect(dom, isNot(fallbackDom));
      expect(dom & 0xFF000000, 0xFF000000);
    });
  });

  group('jam mapping + clock', () {
    test('caps enforced both ways', () {
      final long = 'x' * 400;
      final t = YtTrack(
          id: 'dQw4w9WgXcQ_extra_long_id_here',
          title: long,
          artist: long,
          thumbUrl: long,
          watchUrl: long);
      final j = JamTrack.fromYt(t);
      expect(j.id.length, lessThanOrEqualTo(16));
      expect(j.title.length, lessThanOrEqualTo(120));
      expect(j.artist.length, lessThanOrEqualTo(80));
      expect(j.thumb.length, lessThanOrEqualTo(300));
      expect(j.url.length, lessThanOrEqualTo(300));
      final back = j.toYtTrack();
      expect(back.title.isNotEmpty, isTrue);
    });

    test('expectedPos free-runs, clamps skew', () {
      const now = JamNow(
          track: JamTrack(id: 'a'), pos: 10000, playing: true, at: 0, st: 5000);
      expect(expectedPos(now, 7000), 12000);
      expect(expectedPos(now, 100000), 10000); // >30s dt ignored
      const paused = JamNow(
          track: JamTrack(id: 'a'), pos: 10000, playing: false, at: 0, st: 1);
      expect(expectedPos(paused, 99999), 10000);
    });

    test('room code + deep link', () {
      expect(isValidRoomCode('ABCDEF'), isTrue);
      expect(isValidRoomCode('AB01EF'), isFalse);
      expect(parseJamLink('cresca://jam/ABCDEF'), 'ABCDEF');
      expect(parseJamLink('cresca://jam/bad!!'), isNull);
    });
  });

  group('motion + crash', () {
    test('kill-switch collapses to 1ms', () {
      expect(motionMs(true, artSlideMs), 450);
      expect(motionMs(false, artSlideMs), 1);
      expect(motionPrefKey, 'motion_on');
    });

    test('crash ring of 5 + newest', () {
      final files = [
        'crash/20240101-000001.log',
        'crash/20240101-000002.log',
        'crash/20240101-000003.log',
        'crash/20240101-000004.log',
        'crash/20240101-000005.log',
      ];
      final next = crashRing(files, 'crash/20240101-000006.log');
      expect(next.length, crashRingCap);
      expect(next.contains('crash/20240101-000001.log'), isFalse);
      expect(crashNewest(next), 'crash/20240101-000006.log');
      expect(crashNewest([]), isNull);
      expect(crashShareBytes, 100 * 1024);
    });
  });
}
