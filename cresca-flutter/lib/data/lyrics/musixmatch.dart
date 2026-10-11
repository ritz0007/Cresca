// Musixmatch provider (no key, tokenless): web search + track-page
// scrape. Track pages embed `__mxmState` JSON carrying either
// `subtitle_list` (synced) or `lyrics_body` (plain). Pure parsing;
// network lives in lyrics.dart.

/// Tokenless search: the `/search/<query>/tracks` page ranks tracks
/// server-side, so first-hit order is already relevance order.
String musixmatchSearchUrl(String query) =>
    'https://www.musixmatch.com/search/${Uri.encodeComponent(query)}/tracks';

/// Browser-ish headers: the site 403s bare Dart clients.
Map<String, String> musixmatchHeaders() => const {
      'Referer': 'https://www.musixmatch.com/',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    };

final _mxmTrackHref =
    RegExp(r'href="(/lyrics/[^"]+)"', caseSensitive: false);

/// First track hrefs from a search page (`/lyrics/Artist/Title`),
/// deduped, order preserved, capped at [max].
List<String> parseMusixmatchSearch(String html, [int max = 3]) {
  final out = <String>[];
  try {
    for (final m in _mxmTrackHref.allMatches(html)) {
      try {
        final href = m.group(1)!;
        final url = 'https://www.musixmatch.com$href';
        if (!out.contains(url)) out.add(url);
        if (out.length >= max) break;
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

final _mxmSubtitle =
    RegExp(r'"subtitle_body"\s*:\s*"((?:[^"\\]|\\.)*)"', dotAll: true);
final _mxmLyricsBody =
    RegExp(r'"lyrics_body"\s*:\s*"((?:[^"\\]|\\.)*)"', dotAll: true);

/// Unescapes a JSON string payload (\\\" \\n \\uXXXX …) without a
/// full JSON decode, so pre/post garbage on the page never matters.
String _unescapeJsonString(String s) {
  try {
    // Backslash pairs first: subtitle payloads are often double-nested
    // JSON, so `\\n` must collapse to `\n` before newline handling.
    var r = s.replaceAll('\\\\', '\\');
    r = r
        .replaceAll(r'\"', '"')
        .replaceAll(r'\/', '/')
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\r', '\r')
        .replaceAll(r'\t', '\t');
    r = r.replaceAllMapped(RegExp(r'\\u([0-9a-fA-F]{4})'), (m) {
      try {
        return String.fromCharCode(int.parse(m.group(1)!, radix: 16));
      } catch (_) {
        return m.group(0)!;
      }
    });
    return r;
  } catch (_) {
    return s;
  }
}

/// Raw `subtitle_body` from a track page ('' when absent). The body is
/// either LRC text or a JSON array of {time,text} subtitle cues.
String parseMusixmatchSubtitle(String html) {
  try {
    final m = _mxmSubtitle.firstMatch(html);
    if (m == null) return '';
    return _unescapeJsonString(m.group(1) ?? '').trim();
  } catch (_) {
    return '';
  }
}

/// Raw plain `lyrics_body` from a track page with the Musixmatch
/// disclaimer tail stripped ('' when absent).
String parseMusixmatchPlain(String html) {
  try {
    final m = _mxmLyricsBody.firstMatch(html);
    if (m == null) return '';
    var body = _unescapeJsonString(m.group(1) ?? '').trim();
    if (body.isEmpty) return '';
    final cut = body.indexOf('***');
    if (cut > 0) body = body.substring(0, cut).trim();
    return body;
  } catch (_) {
    return '';
  }
}

final _mxmCueTime = RegExp(
    r'"total"\s*:\s*([\d.]+)|"time"\s*:\s*([\d.]+)|\bstartTime\b"\s*:\s*"?([\d.]+)');
final _mxmCueText = RegExp(r'"text"\s*:\s*"((?:[^"\\]|\\.)*)"');

/// Converts a JSON subtitle array (`[{"time":…,"text":"…"} …]`) to LRC.
/// Returns '' when the body is not JSON-shaped (callers then try it
/// as raw LRC instead).
String musixmatchSubtitleToLrc(String body) {
  try {
    final t = body.trim();
    if (t.isEmpty || !t.startsWith('[')) return '';
    final texts = _mxmCueText
        .allMatches(t)
        .map((m) => _unescapeJsonString(m.group(1) ?? '').trim())
        .toList();
    final times = _mxmCueTime
        .allMatches(t)
        .map((m) => double.tryParse(
            m.group(1) ?? m.group(2) ?? m.group(3) ?? ''))
        .toList();
    if (texts.isEmpty || times.length != texts.length) return '';
    final out = <String>[];
    for (var i = 0; i < texts.length; i++) {
      try {
        final sec = times[i];
        if (sec == null || sec.isNaN || sec < 0) continue;
        if (texts[i].isEmpty) continue;
        final ms = (sec * 1000).toInt();
        final min = ms ~/ 60000;
        final rem = ms % 60000;
        final s = rem ~/ 1000;
        final milli = rem % 1000;
        out.add('[$min:${s.toString().padLeft(2, '0')}.'
            '${milli.toString().padLeft(3, '0')}]${texts[i]}');
      } catch (_) {}
    }
    return out.join('\n');
  } catch (_) {
    return '';
  }
}
