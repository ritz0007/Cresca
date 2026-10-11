// Netease Cloud Music provider (no key): web search API + song lyric
// API. Lyric payloads are LRC; word-synced YRC variants are converted
// to LRC. Pure parsing; network lives in lyrics.dart.

import 'dart:convert';

class NeteaseSong {
  final int id;
  final String name;
  final String artist;
  final int durationMs;
  const NeteaseSong({
    required this.id,
    required this.name,
    required this.artist,
    required this.durationMs,
  });
}

String neteaseSearchUrl(String keyword) =>
    'https://music.163.com/api/search/get/web?csrf_token=&hlpretag='
    '&hlposttag=&s=${Uri.encodeQueryComponent(keyword)}'
    '&type=1&offset=0&total=true&limit=8';

String neteaseLyricUrl(int id) =>
    'https://music.163.com/api/song/lyric?id=$id&lv=1&kv=1&tv=-1';

/// Browser-ish headers: the API 403s bare Dart clients without a
/// music.163.com Referer.
Map<String, String> neteaseHeaders() => const {
      'Referer': 'https://music.163.com/',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    };

/// Parses `result.songs[]` ({id, name, artists[], duration(ms)}).
List<NeteaseSong> parseNeteaseSearch(String body) {
  final out = <NeteaseSong>[];
  try {
    final root = jsonDecode(body);
    if (root is! Map) return out;
    final result = root['result'];
    if (result is! Map) return out;
    final songs = result['songs'];
    if (songs is! List) return out;
    for (final e in songs) {
      try {
        if (e is! Map) continue;
        final id = e['id'];
        if (id is! int) continue;
        final name = (e['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        var artist = '';
        try {
          final artists = e['artists'];
          if (artists is List && artists.isNotEmpty) {
            artist = ((artists.first as Map)['name'] ?? '')
                .toString()
                .trim();
          }
        } catch (_) {}
        var durMs = 0;
        try {
          final d = e['duration'];
          if (d is num) durMs = d.toInt();
        } catch (_) {}
        out.add(NeteaseSong(
            id: id, name: name, artist: artist, durationMs: durMs));
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

final _yrcLine = RegExp(r'^\[(\d+),\d+\](.*)$');
final _yrcWord = RegExp(r'\(\d+,\d+\)');

/// Converts word-synced YRC (`[ms,dur](w0,w1)word…`) to plain LRC.
String convertNeteaseYrc(String yrc) {
  final out = <String>[];
  try {
    for (final raw in yrc.split('\n')) {
      try {
        final m = _yrcLine.firstMatch(raw.trim());
        if (m == null) continue;
        final ms = int.tryParse(m.group(1)!) ?? -1;
        if (ms < 0) continue;
        final text =
            (m.group(2) ?? '').replaceAll(_yrcWord, '').trim();
        if (text.isEmpty) continue;
        final min = ms ~/ 60000;
        final sec = (ms % 60000) ~/ 1000;
        final milli = ms % 1000;
        out.add('[$min:${sec.toString().padLeft(2, '0')}.'
            '${milli.toString().padLeft(3, '0')}]$text');
      } catch (_) {}
    }
  } catch (_) {}
  return out.join('\n');
}

/// Picks the best raw lyric: timestamped LRC first, converted YRC
/// second, plain LRC text last ('' when unusable).
String parseNeteaseLyric(String body) {
  try {
    final root = jsonDecode(body);
    if (root is! Map) return '';
    String lrc = '';
    String yrc = '';
    try {
      lrc = (((root['lrc'] as Map?)?['lyric']) ?? '').toString();
    } catch (_) {}
    try {
      yrc = (((root['yrc'] as Map?)?['lyric']) ?? '').toString();
    } catch (_) {}
    if (lrc.contains('[') && lrc.contains(']')) return lrc.trim();
    if (yrc.trim().isNotEmpty) {
      final conv = convertNeteaseYrc(yrc);
      if (conv.contains('[')) return conv;
    }
    if (lrc.trim().isNotEmpty) return lrc.trim();
    return '';
  } catch (_) {
    return '';
  }
}
