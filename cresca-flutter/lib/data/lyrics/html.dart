// Shared HTML helpers for lyric scrapers (pure, dependency-free).

/// Minimal entity unescape for scraped lyric fragments.
String unescapeLyricEntities(String s) {
  try {
    var r = s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ');
    r = r.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
      try {
        return String.fromCharCode(int.parse(m.group(1)!));
      } catch (_) {
        return m.group(0)!;
      }
    });
    r = r.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
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

/// Turns an HTML lyric fragment into plain text: <br>/</p> become line
/// breaks, remaining tags are stripped, entities unescaped, blank lines
/// dropped, order preserved.
String lyricFragmentToText(String fragment) {
  try {
    var s =
        fragment.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'<[^>]*>'), '');
    s = unescapeLyricEntities(s);
    final lines = s
        .split('\n')
        .map((e) => e.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return lines.join('\n');
  } catch (_) {
    return '';
  }
}
