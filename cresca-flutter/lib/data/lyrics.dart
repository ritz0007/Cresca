// Lyrics: fetch (captions → lrclib → qq → netease → kugou →
// musixmatch → genius → ovh) + scoring + parsers.
// Provider order mirrors BitChord's repository (word-synced Apple-Music
// sources need native TTML; line-synced LRCLIB/QQ/NetEase/KuGou carry
// the weight, Musixmatch/Genius cover the Western long tail).
// Native refs: LyricsRepository.kt (pipeline, scoring, LRC/VTT/SRT/
// timedtext parsers, 128-entry memo), InnerTubeApi captionTracks/
// fetchCaptionText (track parse, rank, fmt=vtt).
// Every network call: timeout + fallback + silent catch; pure parts
// unit-tested below in spirit (see test/lyrics_test.dart).

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'lyrics/genius.dart' as genius;
import 'lyrics/memo.dart' as lyric_memo;
import 'lyrics/musixmatch.dart' as mxm;
import 'lyrics/netease.dart' as ne;
import 'lyrics/qq.dart' as qq;
import 'lyrics/scoring.dart' as scoring;

/// Unified lyric line (captions + LRCLIB normalize here).
class LyricLine {
  final int startMs;
  final String text;
  const LyricLine(this.startMs, this.text);
}

enum LyricSource {
  youtubeCaptions,
  lrclib,
  qq,
  netease,
  kugou,
  musixmatch,
  genius,
  ovh,
  none
}

/// Human attribution per source (player "Lyrics by X" row, BitChord parity).
String lyricSourceName(LyricSource s) => switch (s) {
      LyricSource.youtubeCaptions => 'YouTube',
      LyricSource.lrclib => 'LRCLIB',
      LyricSource.qq => 'QQ Music',
      LyricSource.netease => 'NetEase',
      LyricSource.kugou => 'KuGou',
      LyricSource.musixmatch => 'Musixmatch',
      LyricSource.genius => 'Genius',
      LyricSource.ovh => 'lyrics.ovh',
      LyricSource.none => '',
    };

/// Unified result across providers.
class LyricsResult {
  final bool isSynced;
  final List<LyricLine> lines;
  final LyricSource source;
  const LyricsResult({
    required this.isSynced,
    required this.lines,
    required this.source,
  });
}

abstract class LyricsState {
  const LyricsState();
  LyricsResult toResult() {
    final s = this;
    if (s is LyricsSynced) {
      return LyricsResult(
          isSynced: true, lines: s.lines, source: s.source);
    }
    if (s is LyricsPlain) {
      return LyricsResult(
          isSynced: false,
          lines: [LyricLine(0, s.text)],
          source: s.source);
    }
    return const LyricsResult(
        isSynced: false, lines: [], source: LyricSource.none);
  }
}

class LyricsLoading extends LyricsState {
  const LyricsLoading();
}

class LyricsSynced extends LyricsState {
  final List<LyricLine> lines;
  final LyricSource source;
  const LyricsSynced(this.lines,
      [this.source = LyricSource.lrclib]);
}

class LyricsPlain extends LyricsState {
  final String text;
  final LyricSource source;
  const LyricsPlain(this.text, [this.source = LyricSource.lrclib]);
}

class LyricsNotFound extends LyricsState {
  const LyricsNotFound();
}

class CaptionTrack {
  final String baseUrl;
  final String lang;
  final String name;
  final bool isAuto;
  const CaptionTrack({
    required this.baseUrl,
    required this.lang,
    required this.name,
    required this.isAuto,
  });
}

// ---------- pure parsers (regex/string ops only) ----------

final _lrcLine =
    RegExp(r'\[(\d+):(\d+)[.:](\d+)\](.*)');
final _cueTs = RegExp(
    r'(\d{2,}:\d{2}:\d{2}[.,]\d{1,3}|\d{2}:\d{2}[.,]\d{1,3})\s*-->\s*(\d{2,}:\d{2}:\d{2}[.,]\d{1,3}|\d{2}:\d{2}[.,]\d{1,3})');
final _xmlText = RegExp(r'<text\b([^>]*)>(.*?)</text>', dotAll: true);
final _xmlStart = RegExp(r'start="([\d.]+)"');
final _bracketOnly =
    RegExp(r'^[\s♪♫\[\(（].*[\]）\)\s♪♫]*$');

int vttTsToMs(String ts) {
  try {
    final norm = ts.trim().replaceAll(',', '.');
    final parts = norm.split(':');
    final secParts = parts.last.split('.');
    final sec = int.parse(secParts[0]);
    var frac = secParts.length > 1 ? secParts[1] : '0';
    frac = '${frac}000'.substring(0, 3);
    final ms = int.parse(frac);
    final min =
        parts.length == 3 ? int.parse(parts[1]) : int.parse(parts[0]);
    final hour = parts.length == 3 ? int.parse(parts[0]) : 0;
    return ((hour * 3600 + min * 60 + sec) * 1000) + ms;
  } catch (_) {
    return -1;
  }
}

String unescapeEntities(String s) {
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

/// Shared caption hygiene: strip tags, collapse space, drop blanks and
/// [Music]-style bracket cues.
String cleanCaptionText(String raw) {
  try {
    var s = raw.replaceAll(RegExp(r'<[^>]*>'), ' ');
    s = unescapeEntities(s);
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.isEmpty) return '';
    if (s.length <= 40 && _bracketOnly.hasMatch(s)) return '';
    return s;
  } catch (_) {
    return '';
  }
}

List<LyricLine> _parseCueBlock(
    List<String> lines, bool srtNumbered) {
  final out = <LyricLine>[];
  try {
    int? pendingMs;
    final buf = StringBuffer();
    void flush() {
      try {
        if (pendingMs != null && pendingMs! >= 0) {
          final text = cleanCaptionText(buf.toString());
          if (text.isNotEmpty) {
            out.add(LyricLine(pendingMs!, text));
          }
        }
      } catch (_) {}
      pendingMs = null;
      buf.clear();
    }

    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) {
        flush();
        continue;
      }
      if (line.startsWith('WEBVTT') ||
          line.startsWith('NOTE') ||
          line.startsWith('STYLE') ||
          line.startsWith('REGION')) {
        continue;
      }
      if (srtNumbered && RegExp(r'^\d+$').hasMatch(line)) continue;
      final m = _cueTs.firstMatch(line);
      if (m != null) {
        flush();
        pendingMs = vttTsToMs(m.group(1)!);
        continue;
      }
      if (pendingMs != null) {
        if (buf.isNotEmpty) buf.write(' ');
        buf.write(line);
      }
    }
    flush();
  } catch (_) {}
  return out;
}

List<LyricLine> parseVtt(String vtt) =>
    _parseCueBlock(vtt.split('\n'), false);

List<LyricLine> parseSrt(String srt) =>
    _parseCueBlock(srt.split('\n'), true);

List<LyricLine> parseTimedTextXml(String xml) {
  final out = <LyricLine>[];
  try {
    for (final m in _xmlText.allMatches(xml)) {
      try {
        final startM =
            _xmlStart.firstMatch(m.group(1) ?? '');
        final start =
            double.tryParse(startM?.group(1) ?? '') ?? -1;
        if (start < 0) continue;
        final text = cleanCaptionText(m.group(2) ?? '');
        if (text.isEmpty) continue;
        out.add(LyricLine((start * 1000).toInt(), text));
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// Auto-detect caption format (VTT / SRT / timedtext XML) and parse.
/// Post pass: time-sorted, consecutive duplicates collapsed.
List<LyricLine> parseCaptions(String raw) {
  try {
    final t = raw.trim();
    if (t.isEmpty) return [];
    List<LyricLine> parsed;
    if (t.startsWith('WEBVTT')) {
      parsed = parseVtt(t);
    } else if (t.contains('<text') ||
        t.contains('<transcript') ||
        t.contains('<timedtext')) {
      parsed = parseTimedTextXml(t);
    } else if (_cueTs.hasMatch(t)) {
      parsed = RegExp(r'\d{2}:\d{2}:\d{2},\d{3}\s*-->')
              .hasMatch(t)
          ? parseSrt(t)
          : parseVtt(t);
    } else {
      return [];
    }
    if (parsed.isEmpty) return [];
    final sorted = parsed
        .where((e) => e.text.isNotEmpty)
        .toList()
      ..sort((a, b) => a.startMs.clamp(0, 1 << 62).compareTo(
          b.startMs.clamp(0, 1 << 62)));
    final out = <LyricLine>[];
    for (final l in sorted) {
      if (l.startMs < 0) continue;
      if (out.isNotEmpty && out.last.text == l.text) continue;
      out.add(l);
    }
    return out;
  } catch (_) {
    return [];
  }
}

List<LyricLine> parseLrc(String lrc) {
  // Global offset tag shifts every line ([offset:+500] / [offset:-200]).
  var shift = 0;
  try {
    final offMatch =
        RegExp(r'\[offset:\s*([+-]?\d+)\]').firstMatch(lrc);
    if (offMatch != null) {
      shift = int.tryParse(offMatch.group(1)!) ?? 0;
    }
  } catch (_) {}
  final out = <LyricLine>[];
  try {
    for (final raw in lrc.split('\n')) {
      try {
        final m = _lrcLine.firstMatch(raw.trim());
        if (m == null) continue;
        final text = (m.group(4) ?? '').trim();
        if (text.isEmpty) continue;
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        var frac = m.group(3)!;
        final int ms;
        if (frac.length == 2) {
          ms = int.parse(frac) * 10;
        } else if (frac.length == 3) {
          ms = int.parse(frac);
        } else {
          frac = '${frac}000'.substring(0, 3);
          ms = int.parse(frac);
        }
        final at = (min * 60 + sec) * 1000 + ms + shift;
        if (at < 0) continue;
        out.add(LyricLine(at, text));
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// Last timestamp in synced LRC (0 when unparseable).
int lastLineMs(String synced) {
  try {
    var last = 0;
    for (final m in _lrcLine.allMatches(synced)) {
      try {
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        var frac = m.group(3)!;
        final int ms;
        if (frac.length == 2) {
          ms = int.parse(frac) * 10;
        } else if (frac.length == 3) {
          ms = int.parse(frac);
        } else {
          frac = '${frac}000'.substring(0, 3);
          ms = int.parse(frac);
        }
        final at = (min * 60 + sec) * 1000 + ms;
        if (at > last) last = at;
      } catch (_) {}
    }
    return last;
  } catch (_) {
    return 0;
  }
}

/// Timestamp-consistency penalty: lines must live inside the record's
/// own duration (kills mistimed records text scoring cannot catch).
int consistencyPenalty(int lastMs, double durSec) {
  try {
    if (lastMs <= 0 || durSec.isNaN || durSec <= 0) return 0;
    final durMs = (durSec * 1000).toInt();
    if (lastMs > durMs + 15000) return -8;
    if (lastMs < (durMs * 0.6).toInt()) return -4;
    return 0;
  } catch (_) {
    return 0;
  }
}

// ---------- query cleaning (pure) ----------

const _labelWords = {
  't series',
  'tseries',
  'tips',
  'zee music',
  'saregama',
  'sony music',
  'universal',
  'yrf',
  'eros',
  'ipop',
  'times music',
  'maddock',
  'tips official',
  'melody',
  'records',
};

String cleanArtist(String raw) {
  try {
    var s = raw.split(RegExp(r'[|｜•]')).first.trim();
    s = s
        .split(RegExp(
            r'\s+(and|&|\+|,|x|with|feat\.?|ft\.?)\s+',
            caseSensitive: false))
        .first
        .trim();
    s = s.replaceAll(
        RegExp(
            r'\b(vevo|official|music|records|films|company|studios?|superhits|entertainment|media|productions?|originals|topic|channel)\b',
            caseSensitive: false),
        ' ');
    s = s.replaceAll(RegExp(r'[^A-Za-z ]'), ' ');
    s = s
        .split(RegExp(r'\s+'))
        .where((e) => e.isNotEmpty)
        .take(3)
        .join(' ')
        .trim();
    if (s.isEmpty) return '';
    final low = s.toLowerCase();
    for (final w in _labelWords) {
      if (low.contains(w)) return '';
    }
    if (!s.contains(' ') && s.length > 10) return '';
    return s;
  } catch (_) {
    return '';
  }
}

String cleanTitle(String raw) {
  try {
    var s = raw
        .replaceAll(
            RegExp(
                r'\s*[\(\[].*?(official|video|audio|lyric|visualizer).*?[\)\]]',
                caseSensitive: false),
            '')
        .replaceAll(RegExp(r'\s+[|｜].*$'), '')
        .trim();
    final dash = s.indexOf(' - ');
    if (dash >= 3) s = s.substring(0, dash).trim();
    s = s.replaceAll(RegExp(r'\s*[\(\[].*?[\)\]]'), '').trim();
    return s;
  } catch (_) {
    return '';
  }
}

// ---------- lrclib scoring (pure) ----------

/// Scores one lrclib record against the query. Null when the title gate
/// fails (no exact/start/2-word match). Mirrors searchLrclib scoring.
int? scoreLrclibRecord({
  required String query,
  required String trackName,
  required String artistName,
  required bool hasSynced,
  required bool hasPlain,
  required double durSec,
  required int durationMs,
  required String synced,
}) {
  try {
    if (trackName.trim().isEmpty) return null;
    if (!hasSynced && !hasPlain) return null;
    final ql = query.toLowerCase();
    final tl = trackName.toLowerCase();
    final al = artistName.toLowerCase();
    List<String> words(String s, int min) => s
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((e) => e.length > min)
        .toList();
    final normQ = words(ql, 2);
    final normT = words(tl, 2);
    final shared = normQ.where(normT.contains).length;
    final exactTitle = normQ.isNotEmpty &&
        normQ.join(' ') == normT.join(' ');
    bool prefix(List<String> a, List<String> b) {
      if (a.isEmpty || b.isEmpty) return false;
      final n = a.length < b.length ? a.length : b.length;
      for (var i = 0; i < n; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    final startMatch =
        prefix(normT, normQ) || prefix(normQ, normT);
    if (!exactTitle && !startMatch && shared < 2) return null;
    var score = hasSynced ? 4 : 1;
    if (exactTitle) {
      score += 4;
    } else if (startMatch) {
      score += 2;
    } else {
      score += shared;
    }
    if (al.isNotEmpty) {
      final aw = al
          .split(RegExp(r'\s+'))
          .where((e) => e.length > 2)
          .toList();
      if (aw.isNotEmpty && aw.every(ql.contains)) {
        score += 4;
      } else if (aw.any(ql.contains)) {
        score += 1;
      } else {
        score -= 4;
      }
    }
    if (durationMs > 0 && !(durSec.isNaN) && durSec > 0) {
      final diff = ((durSec * 1000).toInt() - durationMs).abs();
      if (diff <= 10000) {
        score += 4;
      } else if (diff <= 25000) {
        score += 1;
      } else if (diff > 60000) {
        score -= 6;
      } else {
        score -= 4;
      }
    }
    if (hasSynced && !(durSec.isNaN) && durSec > 0) {
      score += consistencyPenalty(lastLineMs(synced), durSec);
    }
    return score;
  } catch (_) {
    return null;
  }
}

String lrclibSearchUrl(String query) =>
    'https://lrclib.net/api/search?q=${Uri.encodeQueryComponent(query)}';

String lrclibExactUrl(String artist, String title) =>
    'https://lrclib.net/api/get?artist_name=${Uri.encodeQueryComponent(artist)}'
    '&track_name=${Uri.encodeQueryComponent(title)}';

String ovhUrl(String artist, String title) =>
    'https://api.lyrics.ovh/v1/${Uri.encodeComponent(artist)}/${Uri.encodeComponent(title)}';

/// Caption track JSON → model (pure half of parseCaptionTracks).
CaptionTrack? parseCaptionTrack(Map<String, dynamic> o) {
  try {
    final baseUrl = (o['baseUrl'] ?? '').toString();
    if (baseUrl.isEmpty) return null;
    final lang = (o['languageCode'] ?? '').toString();
    String name = '';
    try {
      final n = o['name'];
      if (n is Map) {
        final runs = n['runs'];
        if (runs is List && runs.isNotEmpty) {
          name = runs
              .map((e) => (e is Map ? e['text'] ?? '' : '').toString())
              .join();
        }
        if (name.isEmpty) {
          name = (n['simpleText'] ?? '').toString();
        }
      }
    } catch (_) {}
    final kind = (o['kind'] ?? '').toString();
    final low = name.toLowerCase();
    return CaptionTrack(
      baseUrl: baseUrl,
      lang: lang,
      name: name,
      isAuto: kind.toLowerCase() == 'asr' || low.contains('auto'),
    );
  } catch (_) {
    return null;
  }
}

/// Manual captions first, then English/Hindi, then the rest.
List<CaptionTrack> rankCaptions(List<CaptionTrack> tracks) {
  try {
    int langScore(CaptionTrack t) {
      final l = t.lang.toLowerCase();
      if (l == 'en') return 3;
      if (l.startsWith('en')) return 2;
      if (l == 'hi') return 2;
      if (l.startsWith('hi')) return 1;
      return 0;
    }

    final sorted = List<CaptionTrack>.of(tracks);
    sorted.sort((a, b) {
      final ma = !a.isAuto ? 1 : 0;
      final mb = !b.isAuto ? 1 : 0;
      if (ma != mb) return mb.compareTo(ma);
      return langScore(b).compareTo(langScore(a));
    });
    return sorted;
  } catch (_) {
    return tracks;
  }
}

/// Caption download URL preferring WebVTT.
String captionVttUrl(String baseUrl) {
  try {
    if (baseUrl.isEmpty) return '';
    if (baseUrl.contains('fmt=')) {
      return baseUrl.replaceAll(RegExp(r'fmt=[^&]*'), 'fmt=vtt');
    }
    final sep = baseUrl.contains('?') ? '&' : '?';
    return '$baseUrl${sep}fmt=vtt';
  } catch (_) {
    return baseUrl;
  }
}

// ---------- network pipeline (timeout + fallback + silent catch) ----------

const Duration _lyricTimeout = Duration(seconds: 12);

/// 128-entry LRU memo for lyric results (BitChord LyricsRepository
/// memo parity): repeat plays never re-hit the network. Successes
/// only — misses stay uncached so the "Change" retry can try the
/// next provider.
final _lyricsMemo = lyric_memo.LruMemo<String, LyricsState>(128);

/// Memo size probe (tests / diagnostics).
int lyricsMemoLength() {
  try {
    return _lyricsMemo.length;
  } catch (_) {
    return 0;
  }
}

/// Clears the lyrics memo (tests / account switch).
void clearLyricsMemo() {
  try {
    _lyricsMemo.clear();
  } catch (_) {}
}

Future<String?> _get(http.Client http, String url,
    [Map<String, String>? headers]) async {
  try {
    final res = await http
        .get(
            Uri.parse(url),
            headers: headers ??
                const {
                  'User-Agent': 'Cresca/0.1',
                })
        .timeout(_lyricTimeout);
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    return res.body;
  } catch (_) {
    return null;
  }
}

/// Multi-provider leg (LRCLIB is weak alone, so it is only the
/// first of several): exact → fuzzy queries → QQ → NetEase → KuGou →
/// Musixmatch → Genius → ovh. Synced wins over plain across providers
/// (first plain is stashed while later synced legs still run), best
/// score wins inside search providers (title gate + artist + duration
/// ±3 s). Every leg: timeout + fallback + silent catch. Successes are
/// memoized (128-entry LRU).
/// Kept under the historical [fetchLrclib] name: callers (lyrics
/// panel) race captions first and fall back here.
Future<LyricsState> fetchLrclib(
  http.Client http, {
  required String artist,
  required String title,
  int durationMs = 0,
}) async {
  try {
    final a = cleanArtist(artist);
    final t = cleanTitle(title);
    if (t.length < 2) return const LyricsNotFound();
    final key = lyric_memo.lyricsMemoKey(a.isNotEmpty ? a : artist,
        t.isNotEmpty ? t : title, durationMs);
    try {
      final hit = _lyricsMemo.get(key);
      if (hit != null) return hit;
    } catch (_) {}
    void memoize(LyricsState s) {
      try {
        if (s is LyricsSynced || s is LyricsPlain) {
          _lyricsMemo.put(key, s);
        }
      } catch (_) {}
    }

    LyricsState? plainFallback;
    LyricsState? take(LyricsState? s) {
      if (s == null) return null;
      if (s is LyricsSynced) {
        memoize(s);
        return s;
      }
      if (s is LyricsPlain && plainFallback == null) plainFallback = s;
      return null;
    }

    if (a.isNotEmpty) {
      try {
        final exact = await _fetchLrclibExact(http, a, t, durationMs);
        final hit = take(exact);
        if (hit != null) return hit;
      } catch (_) {}
    }
    final queries = <String>[
      if (a.isNotEmpty) '$t $a',
      t,
    ];
    for (final q in queries) {
      try {
        final hit = take(await _searchLrclib(http, q, durationMs));
        if (hit != null) return hit;
      } catch (_) {}
      // LRCLIB plain is only a fallback: keep looking for synced.
      if (plainFallback != null) break;
    }
    try {
      final hit = take(await fetchQq(http,
          artist: a, title: t, durationMs: durationMs));
      if (hit != null) return hit;
    } catch (_) {}
    try {
      final hit = take(await fetchNetease(http,
          artist: a, title: t, durationMs: durationMs));
      if (hit != null) return hit;
    } catch (_) {}
    // KuGou leg (BitChord parity): keyword search → hash → lyric
    // candidates → LRC download. Carries much the others lack.
    try {
      final kg = await fetchKugou(http,
          artist: a, title: t, durationMs: durationMs);
      final hit = take(kg);
      if (hit != null) return hit;
    } catch (_) {}
    try {
      final hit = take(await fetchMusixmatch(http,
          artist: a, title: t));
      if (hit != null) return hit;
    } catch (_) {}
    try {
      final hit = take(await fetchGenius(http,
          artist: a, title: t));
      if (hit != null) return hit;
    } catch (_) {}
    if (plainFallback != null) {
      memoize(plainFallback!);
      return plainFallback!;
    }
    try {
      final who = a.isNotEmpty ? a : t;
      final body = await _get(http, ovhUrl(who, t));
      if (body != null) {
        final txt =
            ((jsonDecode(body) as Map)['lyrics'] ?? '').toString().trim();
        if (txt.isNotEmpty) {
          final s = LyricsPlain(txt, LyricSource.ovh);
          memoize(s);
          return s;
        }
      }
    } catch (_) {}
    return const LyricsNotFound();
  } catch (_) {
    return const LyricsNotFound();
  }
}

/// KuGou leg (BitChord KuGou.kt parity): song-hash lookup, lyric
/// candidate search, LRC download (base64). Synced LRC only — plain
/// falls through to lyrics.ovh. Null on any miss.
Future<LyricsState?> fetchKugou(
  http.Client http, {
  required String artist,
  required String title,
  int durationMs = 0,
}) async {
  try {
    final q = [title, artist]
        .where((e) => e.trim().isNotEmpty)
        .join(' ')
        .trim();
    if (q.length < 2) return null;
    String? hash;
    try {
      final body = await _get(http,
          'https://mobileservice.kugou.com/api/v3/search/song?version=9108&plat=0&pagesize=8&showtype=0&keyword=${Uri.encodeQueryComponent(q)}');
      if (body != null) {
        final data = ((jsonDecode(body) as Map)['data'] as Map?);
        final info = (data?['info'] as List?);
        if (info != null && info.isNotEmpty) {
          hash = ((info.first as Map)['hash'] ?? '').toString();
          if (hash.isEmpty) hash = null;
        }
      }
    } catch (_) {}
    final params = <String, String>{
      'ver': '1',
      'man': 'yes',
      'client': 'pc',
      'keyword': q,
      if (durationMs > 0)
        'duration': durationMs.toString(),
    };
    if (hash != null && hash.isNotEmpty) {
      params['hash'] = hash;
    }
    final searchBody = await _get(http,
        'https://lyrics.kugou.com/search?${Uri(queryParameters: params).query}');
    if (searchBody == null) return null;
    final decoded = jsonDecode(searchBody);
    final cands = ((decoded as Map)['candidates'] as List?);
    if (cands == null || cands.isEmpty) return null;
    for (final c in cands.take(3)) {
      try {
        if (c is! Map) continue;
        final id = (c['id'] ?? '').toString();
        final key = (c['accesskey'] ?? '').toString();
        if (id.isEmpty || key.isEmpty) continue;
        final dl = await _get(http,
            'https://lyrics.kugou.com/download?ver=1&client=pc&fmt=lrc&charset=utf8&id=${Uri.encodeQueryComponent(id)}&accesskey=${Uri.encodeQueryComponent(key)}');
        if (dl == null) continue;
        final content =
            ((jsonDecode(dl) as Map)['content'] ?? '').toString();
        if (content.isEmpty) continue;
        String lrc = '';
        try {
          lrc = utf8.decode(base64.decode(content.trim()));
        } catch (_) {
          lrc = content;
        }
        final lines = parseLrc(lrc);
        if (lines.length >= 3) {
          return LyricsSynced(lines, LyricSource.kugou);
        }
      } catch (_) {}
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// QQ Music leg (no key): client search → top-scored songmid →
/// lyric query. Synced LRC when ≥3 lines parse, else the decoded
/// payload as plain. Null on any miss.
Future<LyricsState?> fetchQq(
  http.Client http, {
  required String artist,
  required String title,
  int durationMs = 0,
}) async {
  try {
    final q = [title, artist]
        .where((e) => e.trim().isNotEmpty)
        .join(' ')
        .trim();
    if (q.length < 2) return null;
    final searchBody =
        await _get(http, qq.qqSearchUrl(q), qq.qqHeaders());
    if (searchBody == null) return null;
    final songs = qq.parseQqSearch(searchBody);
    if (songs.isEmpty) return null;
    final ranked = songs.toList()
      ..sort((x, y) {
        final sx = scoring.scoreLyricCandidate(
              query: q,
              trackName: x.name,
              artistName: x.artist,
              hasSynced: true,
              hasPlain: true,
              durSec: x.durationMs > 0
                  ? x.durationMs / 1000.0
                  : double.nan,
              durationMs: durationMs,
            ) ??
            -1000;
        final sy = scoring.scoreLyricCandidate(
              query: q,
              trackName: y.name,
              artistName: y.artist,
              hasSynced: true,
              hasPlain: true,
              durSec: y.durationMs > 0
                  ? y.durationMs / 1000.0
                  : double.nan,
              durationMs: durationMs,
            ) ??
            -1000;
        return sy.compareTo(sx);
      });
    LyricsState? plain;
    for (final s in ranked.take(3)) {
      try {
        final body = await _get(
            http, qq.qqLyricUrl(s.mid), qq.qqHeaders());
        if (body == null) continue;
        final raw = qq.decodeQqLyric(body);
        if (raw.isEmpty) continue;
        final lines = parseLrc(raw);
        if (lines.length >= 3) {
          return LyricsSynced(lines, LyricSource.qq);
        }
        if (plain == null && raw.trim().length >= 30) {
          plain = LyricsPlain(raw.trim(), LyricSource.qq);
        }
      } catch (_) {}
    }
    return plain;
  } catch (_) {
    return null;
  }
}

/// NetEase Cloud Music leg (no key): web search → top-scored song →
/// lyric API (timestamped LRC first, word-synced YRC converted).
/// Synced LRC when ≥3 lines parse. Null on any miss (plain NetEase
/// payloads are rare; plain falls through to later providers).
Future<LyricsState?> fetchNetease(
  http.Client http, {
  required String artist,
  required String title,
  int durationMs = 0,
}) async {
  try {
    final q = [title, artist]
        .where((e) => e.trim().isNotEmpty)
        .join(' ')
        .trim();
    if (q.length < 2) return null;
    final searchBody = await _get(
        http, ne.neteaseSearchUrl(q), ne.neteaseHeaders());
    if (searchBody == null) return null;
    final songs = ne.parseNeteaseSearch(searchBody);
    if (songs.isEmpty) return null;
    final ranked = songs.toList()
      ..sort((x, y) {
        final sx = scoring.scoreLyricCandidate(
              query: q,
              trackName: x.name,
              artistName: x.artist,
              hasSynced: true,
              hasPlain: false,
              durSec: x.durationMs > 0
                  ? x.durationMs / 1000.0
                  : double.nan,
              durationMs: durationMs,
            ) ??
            -1000;
        final sy = scoring.scoreLyricCandidate(
              query: q,
              trackName: y.name,
              artistName: y.artist,
              hasSynced: true,
              hasPlain: false,
              durSec: y.durationMs > 0
                  ? y.durationMs / 1000.0
                  : double.nan,
              durationMs: durationMs,
            ) ??
            -1000;
        return sy.compareTo(sx);
      });
    for (final s in ranked.take(3)) {
      try {
        final body = await _get(
            http, ne.neteaseLyricUrl(s.id), ne.neteaseHeaders());
        if (body == null) continue;
        final raw = ne.parseNeteaseLyric(body);
        if (raw.isEmpty) continue;
        final lines = parseLrc(raw);
        if (lines.length >= 3) {
          return LyricsSynced(lines, LyricSource.netease);
        }
      } catch (_) {}
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Musixmatch leg (no key, tokenless scrape): search page → track
/// pages → `subtitle_body` (synced: raw LRC or JSON cues) else
/// `lyrics_body` (plain). Search rank is the relevance signal (no
/// structured titles to score). Null on any miss.
Future<LyricsState?> fetchMusixmatch(
  http.Client http, {
  required String artist,
  required String title,
}) async {
  try {
    final q = [title, artist]
        .where((e) => e.trim().isNotEmpty)
        .join(' ')
        .trim();
    if (q.length < 2) return null;
    final searchBody = await _get(
        http, mxm.musixmatchSearchUrl(q), mxm.musixmatchHeaders());
    if (searchBody == null) return null;
    final tracks = mxm.parseMusixmatchSearch(searchBody);
    if (tracks.isEmpty) return null;
    LyricsState? plain;
    for (final url in tracks.take(3)) {
      try {
        final page =
            await _get(http, url, mxm.musixmatchHeaders());
        if (page == null) continue;
        final sub = mxm.parseMusixmatchSubtitle(page);
        if (sub.isNotEmpty) {
          var lrc = sub;
          if (!lrc.contains('[') || !lrc.contains(']')) {
            lrc = mxm.musixmatchSubtitleToLrc(sub);
          } else if (lrc.trim().startsWith('[') &&
              !RegExp(r'\[\d+:').hasMatch(lrc)) {
            final conv = mxm.musixmatchSubtitleToLrc(sub);
            if (conv.isNotEmpty) lrc = conv;
          }
          final lines = parseLrc(lrc);
          if (lines.length >= 3) {
            return LyricsSynced(lines, LyricSource.musixmatch);
          }
        }
        if (plain == null) {
          final body = mxm.parseMusixmatchPlain(page);
          if (body.trim().length >= 30) {
            plain = LyricsPlain(body, LyricSource.musixmatch);
          }
        }
      } catch (_) {}
    }
    return plain;
  } catch (_) {
    return null;
  }
}

/// Genius leg (no key, plain-only scrape): search page → song pages →
/// lyric containers. First page with ≥30 chars of text wins.
Future<LyricsState?> fetchGenius(
  http.Client http, {
  required String artist,
  required String title,
}) async {
  try {
    final q = [title, artist]
        .where((e) => e.trim().isNotEmpty)
        .join(' ')
        .trim();
    if (q.length < 2) return null;
    final searchBody = await _get(
        http, genius.geniusSearchUrl(q), genius.geniusHeaders());
    if (searchBody == null) return null;
    final songs = genius.parseGeniusSearch(searchBody);
    if (songs.isEmpty) return null;
    for (final url in songs.take(3)) {
      try {
        final page =
            await _get(http, url, genius.geniusHeaders());
        if (page == null) continue;
        final text = genius.parseGeniusLyrics(page);
        if (text.trim().length >= 30) {
          return LyricsPlain(text.trim(), LyricSource.genius);
        }
      } catch (_) {}
    }
    return null;
  } catch (_) {
    return null;
  }
}

Future<LyricsState?> _fetchLrclibExact(
    http.Client http, String artist, String title, int durationMs) async {
  try {
    final body = await _get(http, lrclibExactUrl(artist, title));
    if (body == null) return null;
    final o = jsonDecode(body) as Map;
    final synced = (o['syncedLyrics'] ?? '').toString();
    final plain = (o['plainLyrics'] ?? '').toString();
    if (synced.isEmpty && plain.isEmpty) return null;
    final durSec =
        double.tryParse(o['duration'].toString()) ?? double.nan;
    if (durationMs > 0 &&
        !durSec.isNaN &&
        durSec > 0 &&
        ((durSec * 1000).toInt() - durationMs).abs() > 30000) {
      return null;
    }
    if (synced.isNotEmpty && !durSec.isNaN && durSec > 0) {
      if (consistencyPenalty(lastLineMs(synced), durSec) < 0) return null;
    }
    if (synced.isNotEmpty) {
      final lines = parseLrc(synced);
      if (lines.isNotEmpty) return LyricsSynced(lines);
    }
    if (plain.isNotEmpty) return LyricsPlain(plain);
    return null;
  } catch (_) {
    return null;
  }
}

Future<LyricsState?> _searchLrclib(
    http.Client http, String query, int durationMs) async {
  try {
    final body = await _get(http, lrclibSearchUrl(query));
    if (body == null) return null;
    final arr = jsonDecode(body);
    if (arr is! List || arr.isEmpty) return null;
    var bestScore = -1000;
    String bestSynced = '';
    String bestPlain = '';
    for (final e in arr) {
      try {
        if (e is! Map) continue;
        final score = scoreLrclibRecord(
          query: query,
          trackName: (e['trackName'] ?? '').toString(),
          artistName: (e['artistName'] ?? '').toString(),
          hasSynced:
              (e['syncedLyrics'] ?? '').toString().isNotEmpty,
          hasPlain:
              (e['plainLyrics'] ?? '').toString().isNotEmpty,
          durSec:
              double.tryParse(e['duration'].toString()) ?? double.nan,
          durationMs: durationMs,
          synced: (e['syncedLyrics'] ?? '').toString(),
        );
        if (score == null || score <= bestScore) continue;
        bestScore = score;
        bestSynced = (e['syncedLyrics'] ?? '').toString();
        bestPlain = (e['plainLyrics'] ?? '').toString();
      } catch (_) {}
    }
    if (bestScore < 4) return null;
    if (bestSynced.isNotEmpty) {
      final lines = parseLrc(bestSynced);
      if (lines.isNotEmpty) return LyricsSynced(lines);
    }
    if (bestPlain.isNotEmpty) return LyricsPlain(bestPlain);
    return null;
  } catch (_) {
    return null;
  }
}

/// Captions leg: ranked timedtext tracks (first 3), ≥3 lines to count.
/// [captionJson] fetches a player response map for track parsing;
/// [fetchText] downloads a caption file. Injected for tests.
Future<LyricsState> fetchCaptions({
  required Future<Map<String, dynamic>?> Function() captionJson,
  required Future<String?> Function(String url) fetchText,
}) async {
  try {
    Map<String, dynamic>? root;
    try {
      root = await captionJson().timeout(const Duration(seconds: 9));
    } catch (_) {
      root = null;
    }
    if (root == null) return const LyricsNotFound();
    final tracks = <CaptionTrack>[];
    try {
      final arr = ((root['captions'] as Map?)?['playerCaptionsTracklistRenderer']
          as Map?)?['captionTracks'];
      if (arr is List) {
        for (final e in arr) {
          try {
            if (e is! Map) continue;
            final t =
                parseCaptionTrack(e.cast<String, dynamic>());
            if (t != null) tracks.add(t);
          } catch (_) {}
        }
      }
    } catch (_) {}
    for (final t in rankCaptions(tracks).take(3)) {
      try {
        final raw = await fetchText(captionVttUrl(t.baseUrl))
            .timeout(const Duration(seconds: 9));
        if (raw == null) continue;
        final lines = parseCaptions(raw);
        if (lines.length >= 3) {
          return LyricsSynced(lines, LyricSource.youtubeCaptions);
        }
      } catch (_) {}
    }
    return const LyricsNotFound();
  } catch (_) {
    return const LyricsNotFound();
  }
}
