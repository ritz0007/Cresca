// Pure-Dart JAM track mapping + clock math.
// Native refs: JamClient.kt (JamTrack caps, expectedPos, server clock),
// docs/JAM.md section 4 (message catalog constants).

import 'track.dart';

/// JAM wire track. Caps mirror native take(): id 16, title 120,
/// artist 80, thumb/url 300.
class JamTrack {
  final String id;
  final String title;
  final String artist;
  final String thumb;
  final String url;

  const JamTrack({
    this.id = '',
    this.title = '',
    this.artist = '',
    this.thumb = '',
    this.url = '',
  });

  factory JamTrack.fromYt(YtTrack t) => JamTrack(
        id: t.id.length > 16 ? t.id.substring(0, 16) : t.id,
        title: t.title.length > 120 ? t.title.substring(0, 120) : t.title,
        artist: t.artist.length > 80 ? t.artist.substring(0, 80) : t.artist,
        thumb: t.thumbUrl.length > 300
            ? t.thumbUrl.substring(0, 300)
            : t.thumbUrl,
        url: t.watchUrl.length > 300
            ? t.watchUrl.substring(0, 300)
            : t.watchUrl,
      );

  YtTrack toYtTrack() => YtTrack(
        id: id,
        title: title.isEmpty ? 'Unknown' : title,
        artist: artist.isEmpty ? 'YouTube' : artist,
        thumbUrl: thumb,
        watchUrl: url.isEmpty ? 'https://music.youtube.com/watch?v=$id' : url,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'thumb': thumb,
        'url': url,
      };

  factory JamTrack.fromJson(Map<String, dynamic> j) => JamTrack(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        artist: (j['artist'] ?? '').toString(),
        thumb: (j['thumb'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
      );
}

class JamNow {
  final JamTrack track;
  final int pos;
  final bool playing;
  final int at;
  final int st;
  const JamNow({
    required this.track,
    required this.pos,
    required this.playing,
    required this.at,
    this.st = 0,
  });
}

/// Expected room position: host pos + elapsed on the SHARED server clock.
/// Phone-clock skew drops out. Mirrors JamClient.expectedPos.
int expectedPos(JamNow s, int serverNowMs) {
  try {
    if (!s.playing) return s.pos;
    final st = s.st > 0 ? s.st : s.at;
    final dt = serverNowMs - st;
    if (dt < 0 || dt > 30000) return s.pos;
    return s.pos + dt;
  } catch (_) {
    return s.pos;
  }
}

/// JAM room code: 6 letters, no 0/O/1/I ( unambiguous).
bool isValidRoomCode(String code) {
  try {
    if (code.length != 6) return false;
    return RegExp(r'^[A-HJ-NP-Z]{6}$').hasMatch(code.toUpperCase());
  } catch (_) {
    return false;
  }
}

/// Deep-link parse: cresca://jam/<CODE>.
String? parseJamLink(String link) {
  try {
    final m = RegExp(r'cresca://jam/([A-Za-z0-9]{4,8})',
            caseSensitive: false)
        .firstMatch(link.trim());
    if (m == null) return null;
    final code = m.group(1)!.toUpperCase();
    return isValidRoomCode(code) ? code : null;
  } catch (_) {
    return null;
  }
}
