// Lyrics translation + Hinglish romanization (karaoke companion).
// - translateLines: per-line EN translation via the keyless Google
//   `translate_a/single` endpoint (gtx client), timeout + per-line memo,
//   fallback to the original line on any failure (offline-safe).
// - romanizeLine: Devanagari/Gurmukhi → Latin sing-along (Hinglish
//   narration text) via a compact rule table. No packages, pure Dart.
// Karaoke timings never change: callers rebuild LyricLine(startMs,
// displayText) so highlight/roll/auto-scroll stay identical.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// Per-line memo: original text → English. Session-lived, capped.
final Map<String, String> _translationMemo = {};

/// Number of cached translation entries (tests/diagnostics).
int translationMemoSize() => _translationMemo.length;

/// Clears the translation memo (tests).
void clearTranslationMemo() => _translationMemo.clear();

/// True when [text] has any non-Latin rune (Devanagari, Gurmukhi, …).
bool needsTranslation(String text) {
  try {
    for (final r in text.runes) {
      if (r > 0xFF) return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// True when [text] contains Devanagari or Gurmukhi (romanizable).
bool needsRomanization(String text) {
  try {
    for (final r in text.runes) {
      if ((r >= 0x0900 && r <= 0x097F) ||
          (r >= 0x0A00 && r <= 0x0A7F)) {
        return true;
      }
    }
    return false;
  } catch (_) {
    return false;
  }
}

// ---------- Devanagari / Gurmukhi → Latin (compact rule table) ----------

/// Independent vowels.
const Map<int, String> _vowels = {
  // Devanagari.
  0x0905: 'a', 0x0906: 'aa', 0x0907: 'i', 0x0908: 'ee',
  0x0909: 'u', 0x090A: 'oo', 0x090B: 'ri', 0x090E: 'e',
  0x090F: 'e', 0x0910: 'ai', 0x0911: 'o', 0x0912: 'o',
  0x0913: 'au', 0x0914: 'au',
  // Gurmukhi.
  0x0A05: 'a', 0x0A06: 'aa', 0x0A07: 'i', 0x0A08: 'ee',
  0x0A09: 'u', 0x0A0A: 'oo', 0x0A0F: 'e', 0x0A10: 'ai',
  0x0A13: 'o', 0x0A14: 'au',
};

/// Consonant bases (bare, without the inherent 'a').
const Map<int, String> _consonants = {
  // Devanagari.
  0x0915: 'k', 0x0916: 'kh', 0x0917: 'g', 0x0918: 'gh', 0x0919: 'ng',
  0x091A: 'ch', 0x091B: 'chh', 0x091C: 'j', 0x091D: 'jh', 0x091E: 'ny',
  0x091F: 't', 0x0920: 'th', 0x0921: 'd', 0x0922: 'dh', 0x0923: 'n',
  0x0924: 't', 0x0925: 'th', 0x0926: 'd', 0x0927: 'dh', 0x0928: 'n',
  0x0929: 'nn', 0x092A: 'p', 0x092B: 'ph', 0x092C: 'b', 0x092D: 'bh',
  0x092E: 'm', 0x092F: 'y', 0x0930: 'r', 0x0931: 'rr', 0x0932: 'l',
  0x0933: 'll', 0x0935: 'v', 0x0936: 'sh', 0x0937: 'sh', 0x0938: 's',
  0x0939: 'h', 0x093C: '', // nukta: folds into previous mapping
  0x0958: 'q', 0x0959: 'kh', 0x095A: 'gh', 0x095B: 'z',
  0x095C: 'rr', 0x095D: 'rh', 0x095E: 'f', 0x095F: 'y',
  // Gurmukhi.
  0x0A15: 'k', 0x0A16: 'kh', 0x0A17: 'g', 0x0A18: 'gh', 0x0A19: 'ng',
  0x0A1A: 'ch', 0x0A1B: 'chh', 0x0A1C: 'j', 0x0A1D: 'jh', 0x0A1E: 'ny',
  0x0A1F: 't', 0x0A20: 'th', 0x0A21: 'd', 0x0A22: 'dh', 0x0A23: 'n',
  0x0A24: 't', 0x0A25: 'th', 0x0A26: 'd', 0x0A27: 'dh', 0x0A28: 'n',
  0x0A2A: 'p', 0x0A2B: 'ph', 0x0A2C: 'b', 0x0A2D: 'bh', 0x0A2E: 'm',
  0x0A2F: 'y', 0x0A30: 'r', 0x0A32: 'l', 0x0A33: 'll', 0x0A35: 'v',
  0x0A36: 'sh', 0x0A38: 's', 0x0A39: 'h', 0x0A3C: '',
  0x0A59: 'kh', 0x0A5A: 'gh', 0x0A5B: 'z', 0x0A5C: 'rr',
  0x0A5E: 'f',
};

/// Dependent vowel signs (matras).
const Map<int, String> _matras = {
  // Devanagari.
  0x093E: 'aa', 0x093F: 'i', 0x0940: 'ee', 0x0941: 'u',
  0x0942: 'oo', 0x0943: 'ri', 0x0946: 'e', 0x0947: 'e',
  0x0948: 'ai', 0x094A: 'o', 0x094B: 'o', 0x094C: 'au',
  // Gurmukhi.
  0x0A3E: 'aa', 0x0A3F: 'i', 0x0A40: 'ee', 0x0A41: 'u',
  0x0A42: 'oo', 0x0A47: 'e', 0x0A48: 'ai', 0x0A4B: 'o',
  0x0A4C: 'au',
};

const int _devaVirama = 0x094D;
const int _guruVirama = 0x0A4D;
const int _devaNukta = 0x093C;
const int _guruNukta = 0x0A3C;

/// Nukta-modified consonant folding (base + nukta → roman).
String _foldNukta(String base) => switch (base) {
      'k' => 'q',
      'kh' => 'kh',
      'g' => 'gh',
      'j' => 'z',
      'd' when true => 'r', // ड + nukta → r (approximation)
      'dh' => 'rh',
      'ph' => 'f',
      _ => base,
    };

/// Romanizes one line: Devanagari/Gurmukhi → Latin, everything else
/// passed through. Handles the inherent-'a' rule with one-rune
/// lookahead (bare consonant before a matra/virama, else + 'a').
String romanizeLine(String input) {
  try {
    if (input.isEmpty || !needsRomanization(input)) return input;
    final runes = input.runes.toList();
    final out = StringBuffer();
    for (var i = 0; i < runes.length; i++) {
      final r = runes[i];
      // Devanagari / Gurmukhi digits → ASCII.
      if (r >= 0x0966 && r <= 0x096F) {
        out.write(String.fromCharCode(0x30 + (r - 0x0966)));
        continue;
      }
      if (r >= 0x0A66 && r <= 0x0A6F) {
        out.write(String.fromCharCode(0x30 + (r - 0x0A66)));
        continue;
      }
      final vowel = _vowels[r];
      if (vowel != null) {
        out.write(vowel);
        continue;
      }
      final base = _consonants[r];
      if (base != null) {
        if (r == _devaNukta || r == _guruNukta) continue; // folded below
        var bare = base;
        // Nukta right after this consonant → fold.
        if (i + 1 < runes.length &&
            (runes[i + 1] == _devaNukta ||
                runes[i + 1] == _guruNukta)) {
          bare = _foldNukta(base);
          i++; // consume nukta
        }
        final next = i + 1 < runes.length ? runes[i + 1] : -1;
        if (next == _devaVirama || next == _guruVirama) {
          out.write(bare); // virama kills the inherent a
        } else if (_matras.containsKey(next)) {
          out.write(bare); // matra replaces the inherent a
        } else {
          out.write('${bare}a');
        }
        continue;
      }
      final matra = _matras[r];
      if (matra != null) {
        out.write(matra);
        continue;
      }
      if (r == _devaVirama || r == _guruVirama) continue; // consumed above
      if (r == 0x0902 || r == 0x0901 || r == 0x0A02 || r == 0x0A01) {
        out.write('n'); // anusvara / chandrabindu
        continue;
      }
      if (r == 0x0903 || r == 0x0A03) {
        out.write('h'); // visarga
        continue;
      }
      out.write(String.fromCharCode(r));
    }
    return out.toString();
  } catch (_) {
    return input;
  }
}

/// Romanizes every line (pure, instant, offline-safe).
List<String> romanizeLines(List<String> lines) {
  try {
    return lines.map(romanizeLine).toList();
  } catch (_) {
    return lines;
  }
}

// ---------- keyless translation (Google gtx single endpoint) ----------

/// Translates one line to English. Memoized; any failure (timeout,
/// network, parse) returns [fallback] (defaults to the original).
Future<String> translateLine(
  String text, {
  String to = 'en',
  http.Client? client,
  String? fallback,
}) async {
  final orig = text;
  try {
    if (text.trim().isEmpty || !needsTranslation(text)) return orig;
    final key = '$to\u0000$text';
    final hit = _translationMemo[key];
    if (hit != null && hit.isNotEmpty) return hit;
    final owned = client == null;
    final c = client ?? http.Client();
    try {
      final uri = Uri.parse(
          'https://translate.googleapis.com/translate_a/single'
          '?client=gtx&sl=auto&tl=$to&dt=t&q=${Uri.encodeQueryComponent(text)}');
      final res =
          await c.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode < 200 || res.statusCode >= 300) return orig;
      final decoded = jsonDecode(res.body);
      // Shape: [[["translated","orig",null,null,...],...],...]
      final buf = StringBuffer();
      if (decoded is List && decoded.isNotEmpty) {
        final segs = decoded[0];
        if (segs is List) {
          for (final s in segs) {
            if (s is List && s.isNotEmpty && s[0] is String) {
              buf.write(s[0] as String);
            }
          }
        }
      }
      final out = buf.toString().trim();
      if (out.isEmpty) return orig;
      if (_translationMemo.length > 500) _translationMemo.clear();
      _translationMemo[key] = out;
      return out;
    } finally {
      if (owned) {
        try {
          c.close();
        } catch (_) {}
      }
    }
  } catch (_) {
    return fallback ?? orig;
  }
}

/// Translates every line, preserving order. Lines already in Latin
/// (or empty) pass through untouched; failures fall back per-line to
/// the original so karaoke keeps working offline.
Future<List<String>> translateLines(
  List<String> lines, {
  String to = 'en',
  http.Client? client,
}) async {
  try {
    final out = <String>[];
    for (final l in lines) {
      out.add(await translateLine(l, to: to, client: client));
    }
    return out;
  } catch (_) {
    return lines;
  }
}

// ---------- per-track timing offset (karaoke companion) ----------

/// One offset step (UI -/+ buttons move by this).
const int lyricOffsetStepMs = 500;

/// Offset clamp (keeps a stray tap from pushing lines out of the song).
const int lyricOffsetMaxMs = 10000;

/// Session-lived per-track offset: track id → milliseconds. Backed by
/// SharedPreferences by the lyrics panel (load on open, save on change)
/// so it persists per track; this memo is the live read path (no async
/// in build methods, no new packages).
final Map<String, int> _lyricOffsetMemo = {};

/// Current offset for [trackId] (0 when unset).
int lyricOffsetMs(String trackId) {
  try {
    return _lyricOffsetMemo[trackId] ?? 0;
  } catch (_) {
    return 0;
  }
}

/// SharedPreferences key for a track's offset.
String lyricOffsetPrefKey(String trackId) {
  try {
    return 'lyrics_offset_$trackId';
  } catch (_) {
    return 'lyrics_offset_unknown';
  }
}

/// Stores [ms] for [trackId], clamped to ±[lyricOffsetMaxMs].
/// Returns the stored (clamped) value.
int setLyricOffsetMs(String trackId, int ms) {
  try {
    final v = ms.clamp(-lyricOffsetMaxMs, lyricOffsetMaxMs);
    _lyricOffsetMemo[trackId] = v;
    return v;
  } catch (_) {
    return 0;
  }
}

/// Effective start of a line with [offsetMs] applied (never negative).
int effectiveLyricMs(int startMs, int offsetMs) {
  try {
    final v = startMs + offsetMs;
    return v < 0 ? 0 : v;
  } catch (_) {
    return startMs;
  }
}

/// Human offset label: 'Off', '+1.0s', '-0.5s'.
String formatLyricOffset(int ms) {
  try {
    if (ms == 0) return 'Off';
    final sign = ms > 0 ? '+' : '-';
    return '$sign${(ms.abs() / 1000).toStringAsFixed(1)}s';
  } catch (_) {
    return 'Off';
  }
}
