// Generic lyric-candidate scoring (pure): synced > plain, duration
// match ±3 s top bonus, title/artist fuzzy match. Mirrors the LRCLIB
// scorer's title gate so junk records never pass.

/// Lowercase alphanumeric tokens longer than [minLen].
List<String> lyricTokens(String s, [int minLen = 2]) {
  try {
    return s
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .split(RegExp(r'\s+'))
        .where((e) => e.length > minLen)
        .toList();
  } catch (_) {
    return const [];
  }
}

bool lyricPrefix(List<String> a, List<String> b) {
  try {
    if (a.isEmpty || b.isEmpty) return false;
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// Duration bonus: ±3 s is the top tier, then ±10 s / ±25 s, heavy
/// penalty past 60 s. Zero when either side is unknown.
int lyricDurationBonus({required int durationMs, required double durSec}) {
  try {
    if (durationMs <= 0 || durSec.isNaN || durSec <= 0) return 0;
    final diff = ((durSec * 1000).toInt() - durationMs).abs();
    if (diff <= 3000) return 5;
    if (diff <= 10000) return 3;
    if (diff <= 25000) return 1;
    if (diff > 60000) return -6;
    return -4;
  } catch (_) {
    return 0;
  }
}

/// Scores one provider record. Null when the title gate fails (no
/// exact/start/2-word match). [consistency] carries the caller's
/// timestamp-consistency penalty (negative or zero).
int? scoreLyricCandidate({
  required String query,
  required String trackName,
  required String artistName,
  required bool hasSynced,
  required bool hasPlain,
  required double durSec,
  required int durationMs,
  int consistency = 0,
}) {
  try {
    if (trackName.trim().isEmpty) return null;
    if (!hasSynced && !hasPlain) return null;
    final ql = query.toLowerCase();
    final tl = trackName.toLowerCase();
    final al = artistName.toLowerCase();
    final normQ = lyricTokens(ql);
    final normT = lyricTokens(tl);
    final shared = normQ.where(normT.contains).length;
    final exactTitle =
        normQ.isNotEmpty && normQ.join(' ') == normT.join(' ');
    final startMatch =
        lyricPrefix(normT, normQ) || lyricPrefix(normQ, normT);
    if (!exactTitle && !startMatch && shared < 2) return null;
    var score = hasSynced ? 6 : 1;
    if (exactTitle) {
      score += 4;
    } else if (startMatch) {
      score += 2;
    } else {
      score += shared > 4 ? 4 : shared;
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
    score +=
        lyricDurationBonus(durationMs: durationMs, durSec: durSec);
    score += consistency;
    return score;
  } catch (_) {
    return null;
  }
}
