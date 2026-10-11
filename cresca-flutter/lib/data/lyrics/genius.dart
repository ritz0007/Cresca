// Genius provider (no key, plain-only): web search + song-page
// scrape. Song pages render lyric lines inside
// `div[data-lyrics-container="true"]` blocks. Pure parsing; network
// lives in lyrics.dart.

import 'html.dart';

/// Tokenless search page (server-ranked; first hit wins).
String geniusSearchUrl(String query) =>
    'https://genius.com/search?q=${Uri.encodeQueryComponent(query)}';

/// Browser-ish headers: the site 403s bare Dart clients.
Map<String, String> geniusHeaders() => const {
      'Referer': 'https://genius.com/',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    };

final _geniusSongHref = RegExp(
    r'href="(https://genius\.com/[A-Za-z0-9][^"]*?-lyrics[^"]*)"',
    caseSensitive: false);

/// Song URLs from a search page, deduped, order preserved,
///
/// capped at [max].
List<String> parseGeniusSearch(String html, [int max = 3]) {
  final out = <String>[];
  try {
    for (final m in _geniusSongHref.allMatches(html)) {
      try {
        var url = m.group(1)!;
        final amp = url.indexOf('&amp;');
        if (amp >= 0) url = url.substring(0, amp);
        if (!out.contains(url)) out.add(url);
        if (out.length >= max) break;
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

final _geniusContainer = RegExp(
    r'<div[^>]*data-lyrics-container="true"[^>]*>(.*?)</div\s*>',
    dotAll: true,
    caseSensitive: false);

/// Plain lyric text from a song page: every lyrics container is
/// fragment-converted ([lyricFragmentToText]) and joined in order.
/// '' when the page carries no containers (instrumental / miss).
String parseGeniusLyrics(String html) {
  try {
    final blocks = <String>[];
    for (final m in _geniusContainer.allMatches(html)) {
      try {
        final text = lyricFragmentToText(m.group(1) ?? '');
        if (text.isNotEmpty) blocks.add(text);
      } catch (_) {}
    }
    if (blocks.isEmpty) return '';
    return blocks.join('\n').trim();
  } catch (_) {
    return '';
  }
}
