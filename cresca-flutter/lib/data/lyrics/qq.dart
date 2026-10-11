// QQ Music provider (no key): client search + lyric query. Lyric
// payloads are LRC/QRC text, sometimes base64-wrapped depending on
// the `nobase64` flag the CDN honors. Pure parsing; network lives
// in lyrics.dart.

import 'dart:convert';

class QqSong {
  final String mid;
  final String name;
  final String artist;
  final int durationMs;
  const QqSong({
    required this.mid,
    required this.name,
    required this.artist,
    required this.durationMs,
  });
}

String qqSearchUrl(String keyword) =>
    'https://c.y.qq.com/soso/fcgi-bin/client_search_cp?ct=24'
    '&qqmusic_ver=1298&new_json=1&remoteplace=txt.yqq.song&searchid='
    '&t=0&aggr=1&cr=1&catZhida=1&lossless=0&flag_qc=0&p=1&n=8'
    '&w=${Uri.encodeQueryComponent(keyword)}'
    '&g_tk=5381&format=json&inCharset=utf8&outCharset=utf-8'
    '&notice=0&platform=yqq&needNewCode=0';

String qqLyricUrl(String songmid) =>
    'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg'
    '?songmid=${Uri.encodeQueryComponent(songmid)}'
    '&format=json&nobase64=1&g_tk=5381&inCharset=utf8&outCharset=utf-8'
    '&notice=0&platform=yqq&needNewCode=0';

/// y.qq.com Referer keeps the lyric CDN from rejecting the call.
Map<String, String> qqHeaders() => const {
      'Referer': 'https://y.qq.com/portal/player.html',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    };

/// Parses `data.song.list[]` ({songmid/mid, songname, singer[],
/// interval(sec)}), tolerating key renames across CDN versions.
List<QqSong> parseQqSearch(String body) {
  final out = <QqSong>[];
  try {
    final root = jsonDecode(body);
    if (root is! Map) return out;
    final data = root['data'];
    if (data is! Map) return out;
    final song = data['song'];
    if (song is! Map) return out;
    final list = song['list'];
    if (list is! List) return out;
    for (final e in list) {
      try {
        if (e is! Map) continue;
        final mid = (e['songmid'] ?? e['mid'] ?? '').toString();
        if (mid.isEmpty) continue;
        final name = (e['songname'] ??
                e['songName'] ??
                e['title'] ??
                e['name'] ??
                '')
            .toString()
            .trim();
        if (name.isEmpty) continue;
        var artist = '';
        try {
          final singer = e['singer'];
          if (singer is List && singer.isNotEmpty) {
            artist = ((singer.first as Map)['name'] ?? '')
                .toString()
                .trim();
          } else if (e['singerName'] != null) {
            artist = e['singerName'].toString().trim();
          }
        } catch (_) {}
        var durMs = 0;
        try {
          final iv = e['interval'];
          if (iv is num) durMs = (iv * 1000).toInt();
        } catch (_) {}
        out.add(QqSong(
            mid: mid, name: name, artist: artist, durationMs: durMs));
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// Extracts lyric text from the query payload: raw LRC passes through,
/// base64-wrapped payloads are decoded, '' when unusable. Tolerates
/// JSONP-wrapped bodies.
String decodeQqLyric(String body) {
  try {
    var t = body.trim();
    if (t.isEmpty) return '';
    if (!t.startsWith('{')) {
      final s = t.indexOf('(');
      final e = t.lastIndexOf(')');
      if (s >= 0 && e > s) t = t.substring(s + 1, e);
    }
    final root = jsonDecode(t);
    if (root is! Map) return '';
    final lyric = (root['lyric'] ?? '').toString();
    if (lyric.trim().isEmpty) return '';
    if (lyric.contains('[') && lyric.contains(']')) {
      return lyric.trim();
    }
    try {
      var clean = lyric.trim().replaceAll(RegExp(r'\s+'), '');
      final mod = clean.length % 4;
      if (mod != 0) clean += '=' * (4 - mod);
      return utf8.decode(base64.decode(clean)).trim();
    } catch (_) {
      return lyric.trim();
    }
  } catch (_) {
    return '';
  }
}
