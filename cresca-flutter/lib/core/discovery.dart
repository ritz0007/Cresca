// Pure-Dart discovery scoring (vibe + smart shuffle + taste engine).
// Native refs: YoutubeRepository.vibeQueries/detectMood/isSameName/
// rankByVibe, MainActivity.applySmartShuffle + topVibe (last-10 related),
// autoplayFor hard rules. No network here — these rank already-gated
// tracks. The taste engine (TasteProfile + rankTopPicks/rankUpNext)
// is the best-in-class suggestion core: recency-weighted affinity,
// related-graph co-occurrence, skip penalties with decay, dedupe,
// diversity caps and freshness rotation. Profiles persist via
// [TasteProfile.encode]/decode (see radio_store TasteStore /
// repository saveTaste/loadTaste); scoring is O(n) sync and the
// *Async wrappers yield off the hot path.

import 'dart:convert';
import 'dart:math';
import 'track.dart';

/// Vibe queries from a track: title keywords + mood words, no artist.
List<String> vibeQueries(YtTrack t) {
  try {
    var title = t.title.toLowerCase();
    title = title.replaceAll(
      RegExp(
          r'[\([].*?(official|video|audio|lyric|visualizer|mv|m\/v|teaser|trailer).*?[\)\]]'),
      ' ',
    );
    title = title.replaceAll(RegExp(r'\s+[|｜].*$'), ' ');
    final dash = title.indexOf(' - ');
    if (dash >= 3) title = title.substring(0, dash);
    title = title.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    final words = title
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.length > 3)
        .where((e) => !{
              'official',
              'video',
              'audio',
              'lyrics',
              'song',
              'songs',
              'full',
              'hd',
              'with',
            }.contains(e))
        .toSet()
        .take(4)
        .toList();
    final mood = detectMood('${t.title} ${t.artist}');
    final out = <String>[];
    if (mood != null) out.add('$mood hindi songs');
    if (words.length >= 2) {
      out.add('${[...words.take(3), ?mood].join(' ')} songs');
    }
    if (words.isNotEmpty && mood != null) {
      out.add('${words.take(2).join(' ')} $mood');
    } else if (words.isNotEmpty) {
      out.add('${words.take(2).join(' ')} songs');
    }
    return out.toSet().take(3).toList();
  } catch (_) {
    return [];
  }
}

String? detectMood(String text) {
  try {
    final low = text.toLowerCase();
    if (low.contains('love') ||
        low.contains('romantic') ||
        low.contains('dil')) {
      return 'romantic';
    }
    if (low.contains('party') ||
        low.contains('dance') ||
        low.contains('club')) {
      return 'party';
    }
    if (low.contains('lofi') ||
        low.contains('chill') ||
        low.contains('slow')) {
      return 'lofi';
    }
    if (low.contains('workout') ||
        low.contains('gym') ||
        low.contains('motivat')) {
      return 'workout';
    }
    if (low.contains('sad') ||
        low.contains('dard') ||
        low.contains('bewafa')) {
      return 'sad';
    }
    if (low.contains('punjabi') || low.contains('bhangra')) {
      return 'punjabi';
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Same-name test: normalized titles equal, or the shorter title's 2+ word
/// core sits inside the other. Same-name hits are title-matches, never
/// vibe — dropped from filler, sunk in ranking.
bool isSameName(YtTrack a, YtTrack b) {
  try {
    List<String> norm(String t) {
      var s = t.toLowerCase().replaceAll(RegExp(r'[\(\[].*?[\)\]]'), ' ');
      final dash = s.indexOf(' - ');
      if (dash >= 3) s = s.substring(0, dash);
      s = s.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
      return s
          .split(RegExp(r'\s+'))
          .map((e) => e.trim())
          .where((e) => e.length > 2)
          .where((e) => !{
                'official',
                'video',
                'audio',
                'lyrics',
                'lyric',
                'song',
                'songs',
                'full',
                'visualizer',
                'the',
              }.contains(e))
          .toList();
    }

    final aw = norm(a.title);
    final bw = norm(b.title);
    if (aw.isEmpty || bw.isEmpty) return false;
    if (aw.join(' ') == bw.join(' ')) return true;
    final core = aw.length <= bw.length ? aw : bw;
    final other = aw.length <= bw.length ? bw : aw;
    return core.length >= 2 && core.every(other.contains);
  } catch (_) {
    return false;
  }
}

/// Score pool by vibe: related-graph first, same mood next, artist variety
/// over clumps, same-NAME sunk hard. Title-word overlap is deliberately NOT
/// scored. Returns the ranked pool.
///
/// Taste mode: when [taste] (or any penalty set) is given, candidates are
/// scored with [scoreCandidate] — affinity + co-occurrence + skip/recent
/// penalties — instead of the legacy seed-mood terms. With all taste
/// params at their defaults the legacy arithmetic runs unchanged.
List<YtTrack> rankByVibe(
  YtTrack seed,
  List<YtTrack> pool, {
  Set<String> relatedIds = const {},
  Random? random,
  TasteProfile? taste,
  Set<String> skipIds = const {},
  Set<String> likedIds = const {},
  Set<String> recentIds = const {},
  Map<String, double>? coOccurrence,
  List<YtTrack> sessionContext = const [],
  Set<String> skipArtists = const {},
}) {
  try {
    final rnd = random ?? Random();
    final legacy = taste == null &&
        skipIds.isEmpty &&
        likedIds.isEmpty &&
        recentIds.isEmpty &&
        (coOccurrence == null || coOccurrence.isEmpty);
    if (legacy) {
      final seedMood = detectMood('${seed.title} ${seed.artist}');
      final seedArtist = seed.artist.toLowerCase();
      final scored = pool.map((c) {
        var s = 0;
        if (relatedIds.contains(c.id)) s += 5;
        if (isSameName(c, seed)) s -= 8;
        try {
          final cm = detectMood('${c.title} ${c.artist}');
          if (seedMood != null && cm == seedMood) s += 4;
        } catch (_) {}
        final ca = c.artist.toLowerCase();
        if (ca == seedArtist) {
          s -= 3;
        } else if (ca.contains(seedArtist.substring(
                0, seedArtist.length < 5 ? seedArtist.length : 5)) &&
            seedArtist.length > 5) {
          s -= 2;
        } else {
          s += 1;
        }
        return (s, rnd.nextInt(1 << 30), c);
      }).toList();
      scored.sort((a, b) {
        final d = b.$1.compareTo(a.$1);
        return d != 0 ? d : a.$2.compareTo(b.$2);
      });
      return scored.map((e) => e.$3).toList();
    }
    final scored = pool.map((c) {
      final s = scoreCandidate(
        c,
        seed: seed,
        taste: taste,
        relatedIds: relatedIds,
        coOccurrence: coOccurrence ?? const {},
        likedIds: likedIds,
        recentIds: recentIds,
        skipIds: skipIds,
        sessionAffinity: sessionContext.isEmpty
            ? const {}
            : sessionAffinityFor(sessionContext),
        sessionMoods: sessionContext.isEmpty
            ? const {}
            : sessionMoodsFor(sessionContext),
        skipArtists: skipArtists,
      );
      return (s, rnd.nextInt(1 << 30), c);
    }).toList();
    scored.sort((a, b) {
      final d = b.$1.compareTo(a.$1);
      return d != 0 ? d : a.$2.compareTo(b.$2);
    });
    return scored.map((e) => e.$3).toList();
  } catch (_) {
    return List.of(pool)..shuffle(random);
  }
}

/// BitChord-style autoplay queue fill (pure half of autoplayFor).
/// Hard rules: seed + same-NAME echoes never queue, max [maxPerArtist]
/// per artist (seed artist included), related-graph order preserved,
/// mood-ranked.
/// [fillerExtra] is the ONE artist-radio filler used when the graph is thin
/// (already caller-filtered for labelish artists).
///
/// Taste mode: when [taste] (or skip/exclude sets) is given, the final
/// order comes from [rankUpNext] — affinity + skip penalties + diversity
/// caps + freshness — instead of the legacy vibe rank. Queue ids to
/// dedupe against go in [excludeIds].
List<YtTrack> buildAutoplay(
  YtTrack seed,
  List<YtTrack> related,
  List<YtTrack> fillerExtra, {
  int max = 20,
  Random? random,
  TasteProfile? taste,
  Set<String> skipIds = const {},
  Set<String> excludeIds = const {},
  Set<String> likedIds = const {},
  Set<String> recentIds = const {},
  Map<String, double>? coOccurrence,
  List<YtTrack> sessionContext = const [],
  Set<String> skipArtists = const {},
  bool moodArc = true,
  int? rotationSalt,
  int maxPerArtist = 2,
}) {
  try {
    final clean = <YtTrack>[];
    final artistCount = <String, int>{};
    final dupeGuard = <String>{};
    void consider(YtTrack c) {
      if (clean.length >= max) return;
      if (c.id == seed.id || isSameName(c, seed)) return;
      // Taste-mode guards only (empty defaults = legacy path unchanged).
      if (skipIds.contains(c.id)) return;
      if (excludeIds.contains(c.id)) return;
      if (excludeIds.isNotEmpty && !dupeGuard.add(c.id)) return;
      final key = c.artist.toLowerCase();
      final n = (artistCount[key] ?? 0) + 1;
      if (n > maxPerArtist) return;
      artistCount[key] = n;
      clean.add(c);
    }

    for (final c in related) {
      consider(c);
      if (clean.length >= max) break;
    }
    // Thin graph: ONE artist-radio filler, same hard rules, no dupes.
    if (clean.length < max ~/ 2) {
      for (final h in fillerExtra) {
        if (clean.length >= max) break;
        if (clean.any((e) => e.id == h.id)) continue;
        consider(h);
      }
    }
    final relIds = related.map((e) => e.id).toSet();
    final ranked = rankUpNext(
      seed,
      clean,
      relatedIds: relIds,
      taste: taste,
      likedIds: likedIds,
      recentIds: recentIds,
      skipIds: skipIds,
      coOccurrence: coOccurrence,
      sessionContext: sessionContext,
      skipArtists: skipArtists,
      moodArc: moodArc,
      rotationSalt: rotationSalt,
      max: max,
      maxPerArtist: maxPerArtist,
      random: random,
    );
    final seen = <String>{};
    return ranked
        .where((t) => t.id != seed.id && seen.add(t.id))
        .take(max)
        .toList();
  } catch (_) {
    return [];
  }
}

/// Round-robin interleave: keeps every artist represented in new-release
/// rails (native newReleases). Dedupes ids, caps at max.
List<YtTrack> interleaveRoundRobin(List<List<YtTrack>> perArtist,
    {int max = 12}) {
  try {
    final out = <YtTrack>[];
    final seen = <String>{};
    var round = 0;
    var progress = true;
    while (out.length < max && progress) {
      progress = false;
      for (final list in perArtist) {
        if (out.length >= max) break;
        if (round >= list.length) continue;
        final t = list[round];
        if (seen.add(t.id)) {
          out.add(t);
          progress = true;
        }
      }
      round++;
    }
    return out;
  } catch (_) {
    return [];
  }
}

/// Smart-shuffle order: preference-scored (liked/recent/same artist),
/// randomized within score tiers, current first. Mirrors
/// MainActivity.applySmartShuffle; caller feeds [QueueEngine.applyOrder].
/// Skipped ids ([skipIds]) sink to the end so a smart shuffle never
/// surfaces tracks the user keeps skipping.
List<int> smartOrderFor({
  required List<YtTrack> items,
  required int currentIndex,
  required Set<String> likedArtists,
  required List<String> recentArtists,
  Set<String> skipIds = const {},
  Random? random,
}) {
  try {
    if (items.length < 2 ||
        currentIndex < 0 ||
        currentIndex >= items.length) {
      return List<int>.generate(items.length, (i) => i);
    }
    final rnd = random ?? Random();
    final liked = likedArtists.map((e) => e.toLowerCase()).toSet();
    final recent = recentArtists.take(8).map((e) => e.toLowerCase()).toList();
    final curA = items[currentIndex].artist.toLowerCase();
    final rest = List<int>.generate(items.length, (i) => i)
        .where((i) => i != currentIndex)
        .map((idx) {
      final ta = items[idx].artist.toLowerCase();
      var s = 0;
      if (liked.contains(ta)) s += 3;
      final ri = recent.indexOf(ta);
      if (ri >= 0) s += 2 - ri ~/ 4;
      if (ta.isNotEmpty && ta == curA) s += 2;
      if (skipIds.contains(items[idx].id)) s -= 8;
      return (s, rnd.nextInt(1 << 30), idx);
    }).toList();
    rest.sort((a, b) {
      final d = b.$1.compareTo(a.$1);
      return d != 0 ? d : a.$2.compareTo(b.$2);
    });
    return [currentIndex, ...rest.map((e) => e.$3)];
  } catch (_) {
    return List<int>.generate(items.length, (i) => i);
  }
}

// ---------------------------------------------------------------------------
// Taste engine: recency-weighted affinity + related scoring + skip decay.
//
// Shape mirrors the native app: Top Picks come from recent taste (last-10
// related pools), Up Next from the related graph with the BitChord hard
// rules. This engine adds the ranking brain on top: artist/mood affinity
// with exponential recency decay, co-occurrence boosts, skip penalties
// that decay the offending affinity, dedupe, per-artist diversity caps
// and freshness rotation so repeats never look identical.
//
// Tuning knobs live here (one place). Repository/home layers pass data,
// never magic numbers.
// ---------------------------------------------------------------------------

/// Per-position recency decay for recent-play affinity (newest = 1.0).
const double tasteRecencyBase = 0.85;

/// How many recent plays feed affinity (newest-first window).
const int tasteRecentWindow = 30;

/// Weight added per liked track to its artist affinity.
const double tasteLikedBoost = 2.0;

/// Score weight per unit of artist affinity.
const double tasteArtistWeight = 2.0;

/// Score weight per unit of mood affinity.
const double tasteMoodWeight = 3.0;

/// Related-graph membership bonus (true co-listen vibe).
const double tasteRelatedWeight = 5.0;

/// Score weight per unit of co-occurrence (multi-seed agreement).
const double tasteCoOccurWeight = 1.5;

/// Quadratic bonus per squared unit of co-occurrence: tracks surfacing
/// under several seeds win superlinearly (2 seeds ≈ +4.5, 3 seeds ≈ +9.75
/// with the linear term included), so multi-seed agreement dominates
/// single-seed noise without any one seed dictating the rail.
const double tasteCoOccurQuad = 0.75;

/// Session-context weights: the live session tail (queue around the seed
/// / just-played tracks) re-ranks ON TOP of global taste, so tonight's
/// obsession outranks yesterday's loop. Built by [sessionAffinityFor] /
/// [sessionMoodsFor] from the newest-first session window.
const double tasteSessionArtistWeight = 1.5;
const double tasteSessionMoodWeight = 2.0;

/// How many session-tail tracks feed context (newest-first, decayed).
const int tasteSessionWindow = 5;

/// Cold-start mood boost: with zero taste, seed-mood fit counts extra so
/// a single song still opens instant mood radio instead of a flat list.
const double tasteColdMoodBoost = 1.25;

/// Penalty for the FIRST recorded skip of a track (a skip is a strong
/// negative signal); each further skip adds [tasteSkipPerExtra], capped
/// by [tasteSkipMax]. One skip (-3.0) already outweighs a same-artist or
/// keyword nudge, so dislikes actually bury.
const double tasteSkipFirst = 3.0;

/// Penalty per skip beyond the first.
const double tasteSkipPerExtra = 2.5;

/// Skip-artist aversion: candidates sharing an artist blob with a skipped
/// track sink too — dislikes bury the singer, not just the song.
const double tasteSkipArtistPenalty = 2.0;

/// Mood-arc variety: repeating the mood of the last emitted pick costs
/// this; completing a 3-in-a-row run costs [tasteMoodRunPenalty]. Soft
/// penalties applied as a same-set resequence (rails never go empty),
/// so the next 5 read as variety with a through-line, not random jumps.
const double tasteMoodRepeatPenalty = 1.5;
const double tasteMoodRunPenalty = 2.5;

/// Bonus for an exact liked-track hit in the pool.
const double tasteLikedTrackBoost = 2.5;

/// Penalty per recorded skip of a track (capped by [tasteSkipMax]).
const double tasteSkipPerSkip = 2.0;

/// Ceiling on accumulated skip penalty for one track.
const double tasteSkipMax = 8.0;

/// Penalty for a track already played recently (homescreen freshness).
const double tasteRecentPenalty = 3.0;

/// Penalty per previous impression (freshness rotation).
const double tasteShownPerImpression = 0.6;

/// Ceiling on the impression penalty for one track.
const double tasteShownMax = 4.0;

/// Skip-aware decay: recordSkip multiplies the skipped track's artist
/// affinity by this (taste learns aversions fast).
const double tasteSkipDecay = 0.5;

/// recordPlay bump added to the played track's artist affinity.
const double tastePlayBump = 1.0;

/// Background global decay applied on load (stale taste fades out).
const double tasteLoadDecay = 0.98;

/// Default diversity caps.
const int tasteTopPicksPerArtist = 3;
const int tasteUpNextPerArtist = 2;

/// Default Top Picks size.
const int tasteTopPicksDefault = 12;

/// Profile storage caps (persisted maps stay small).
const int tasteProfileArtistCap = 200;
const int tasteProfileTrackCap = 2000;

/// Persisted, recency-weighted taste: artist/mood affinities plus the
/// skip/impression memory that keeps suggestions fresh. JSON-serializable
/// ([toJson]/fromJson, [encode]/decode) so affinities survive restarts;
/// storage lives in radio_store TasteStore / repository saveTaste.
class TasteProfile {
  final Map<String, double> artistScores;
  final Map<String, double> moodScores;
  final Map<String, int> playCounts;
  final Map<String, int> skipCounts;
  final Map<String, int> shownCounts;
  final int updatedAt;

  const TasteProfile({
    this.artistScores = const {},
    this.moodScores = const {},
    this.playCounts = const {},
    this.skipCounts = const {},
    this.shownCounts = const {},
    this.updatedAt = 0,
  });

  bool get isEmpty =>
      artistScores.isEmpty && moodScores.isEmpty && playCounts.isEmpty;

  /// Best affinity across the candidate's artist keys (full blob + parts).
  double artistAffinity(String artist) {
    try {
      var best = 0.0;
      for (final k in tasteArtistKeys(artist)) {
        final v = artistScores[k] ?? 0.0;
        if (v > best) best = v;
      }
      return best;
    } catch (_) {
      return 0.0;
    }
  }

  double moodAffinity(String? mood) {
    if (mood == null) return 0.0;
    try {
      return moodScores[mood] ?? 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  /// Top affinity artists (lowercased keys), for taste seed queries.
  List<String> topArtists([int max = 4]) {
    try {
      final keys = artistScores.keys.toList()
        ..sort((a, b) => artistScores[b]!.compareTo(artistScores[a]!));
      return keys.take(max).toList();
    } catch (_) {
      return [];
    }
  }

  /// A play bumps the artist affinity and play count.
  TasteProfile recordPlay(YtTrack t, {int nowMs = 0}) {
    try {
      final artists = Map<String, double>.of(artistScores);
      for (final k in tasteArtistKeys(t.artist)) {
        artists[k] = (artists[k] ?? 0.0) + tastePlayBump;
      }
      final plays = Map<String, int>.of(playCounts)..update(
          t.id, (v) => v + 1,
          ifAbsent: () => 1);
      final moods = Map<String, double>.of(moodScores);
      final m = detectMood('${t.title} ${t.artist}');
      if (m != null) moods[m] = (moods[m] ?? 0.0) + tastePlayBump * 0.5;
      return TasteProfile(
        artistScores: _capScores(artists, tasteProfileArtistCap),
        moodScores: moods,
        playCounts: _capCounts(plays, tasteProfileTrackCap),
        skipCounts: skipCounts,
        shownCounts: shownCounts,
        updatedAt: nowMs,
      );
    } catch (_) {
      return this;
    }
  }

  /// Skip-aware decay: the skip is remembered AND the skipped track's
  /// artist affinity is multiplied down, so aversions stick.
  TasteProfile recordSkip(YtTrack t, {int nowMs = 0}) {
    try {
      final artists = Map<String, double>.of(artistScores);
      for (final k in tasteArtistKeys(t.artist)) {
        artists[k] = (artists[k] ?? 0.0) * tasteSkipDecay;
      }
      artists.removeWhere((_, v) => v < 0.01);
      final skips = Map<String, int>.of(skipCounts)..update(
          t.id, (v) => v + 1,
          ifAbsent: () => 1);
      return TasteProfile(
        artistScores: artists,
        moodScores: moodScores,
        playCounts: playCounts,
        skipCounts: _capCounts(skips, tasteProfileTrackCap),
        shownCounts: shownCounts,
        updatedAt: nowMs,
      );
    } catch (_) {
      return this;
    }
  }

  /// Freshness memory: call with the ids a Top Picks refresh surfaced so
  /// the next rotation prefers unseen tracks.
  TasteProfile noteShown(Iterable<String> ids, {int nowMs = 0}) {
    try {
      final shown = Map<String, int>.of(shownCounts);
      for (final id in ids) {
        if (id.isEmpty) continue;
        shown.update(id, (v) => v + 1, ifAbsent: () => 1);
      }
      return TasteProfile(
        artistScores: artistScores,
        moodScores: moodScores,
        playCounts: playCounts,
        skipCounts: skipCounts,
        shownCounts: _capCounts(shown, tasteProfileTrackCap),
        updatedAt: nowMs,
      );
    } catch (_) {
      return this;
    }
  }

  /// Global decay (stale taste fades); applied on load by the stores.
  TasteProfile decayed([double factor = tasteLoadDecay]) {
    try {
      final artists = <String, double>{};
      artistScores.forEach((k, v) {
        final d = v * factor;
        if (d >= 0.01) artists[k] = d;
      });
      final moods = <String, double>{};
      moodScores.forEach((k, v) {
        final d = v * factor;
        if (d >= 0.01) moods[k] = d;
      });
      return TasteProfile(
        artistScores: artists,
        moodScores: moods,
        playCounts: playCounts,
        skipCounts: skipCounts,
        shownCounts: shownCounts,
        updatedAt: updatedAt,
      );
    } catch (_) {
      return this;
    }
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'artists': artistScores,
        'moods': moodScores,
        'plays': playCounts,
        'skips': skipCounts,
        'shown': shownCounts,
        'updatedAt': updatedAt,
      };

  String encode() {
    try {
      return jsonEncode(toJson());
    } catch (_) {
      return '';
    }
  }

  static TasteProfile fromJson(Map<String, dynamic> j) {
    try {
      Map<String, double> scores(dynamic v) {
        final out = <String, double>{};
        if (v is! Map) return out;
        for (final e in v.entries.take(tasteProfileArtistCap * 2)) {
          try {
            final k = e.key.toString();
            final d = e.value is num
                ? (e.value as num).toDouble()
                : double.tryParse(e.value.toString()) ?? 0.0;
            if (k.isNotEmpty && d > 0) out[k] = d;
          } catch (_) {}
        }
        return _capScores(out, tasteProfileArtistCap);
      }

      Map<String, int> counts(dynamic v) {
        final out = <String, int>{};
        if (v is! Map) return out;
        for (final e in v.entries.take(tasteProfileTrackCap * 2)) {
          try {
            final k = e.key.toString();
            final n = e.value is num
                ? (e.value as num).toInt()
                : int.tryParse(e.value.toString()) ?? 0;
            if (k.isNotEmpty && n > 0) out[k] = n;
          } catch (_) {}
        }
        return _capCounts(out, tasteProfileTrackCap);
      }

      return TasteProfile(
        artistScores: scores(j['artists']),
        moodScores: scores(j['moods']),
        playCounts: counts(j['plays']),
        skipCounts: counts(j['skips']),
        shownCounts: counts(j['shown']),
        updatedAt: j['updatedAt'] is num
            ? (j['updatedAt'] as num).toInt()
            : int.tryParse(j['updatedAt'].toString()) ?? 0,
      );
    } catch (_) {
      return const TasteProfile();
    }
  }

  static TasteProfile decode(String raw) {
    try {
      if (raw.trim().isEmpty) return const TasteProfile();
      final v = jsonDecode(raw);
      if (v is! Map) return const TasteProfile();
      return fromJson(v.cast<String, dynamic>());
    } catch (_) {
      return const TasteProfile();
    }
  }
}

Map<String, double> _capScores(Map<String, double> m, int cap) {
  try {
    if (m.length <= cap) return m;
    final keys = m.keys.toList()
      ..sort((a, b) => m[b]!.compareTo(m[a]!));
    return {for (final k in keys.take(cap)) k: m[k]!};
  } catch (_) {
    return m;
  }
}

Map<String, int> _capCounts(Map<String, int> m, int cap) {
  try {
    if (m.length <= cap) return m;
    final keys = m.keys.toList()
      ..sort((a, b) => m[b]!.compareTo(m[a]!));
    return {for (final k in keys.take(cap)) k: m[k]!};
  } catch (_) {
    return m;
  }
}

/// Artist lookup keys: full lowercased blob plus split parts (multi-artist
/// "A feat. B" blobs overlap on either half). Mirrors the label-tolerant
/// spirit of HomeFeed.artistSeeds without importing it.
Set<String> tasteArtistKeys(String artist) {
  try {
    final full = artist.trim().toLowerCase();
    final out = <String>{};
    if (full.isEmpty) return out;
    out.add(full);
    final parts = full
        .split(RegExp(r'[,&+/;|•·:]'))
        .expand((e) => e.split(RegExp(
            r' and | x | X | feat | feat\. | ft | ft\. ',
            caseSensitive: false)))
        .map((e) => e.trim())
        .where((e) => e.length >= 3 && e.length <= 40);
    out.addAll(parts);
    return out;
  } catch (_) {
    return {};
  }
}

/// Build a taste profile from library signals. [recent] is newest-first;
/// position `i` weighs `tasteRecencyBase^i` so yesterday's loop fades
/// below today's obsession. Liked tracks boost their artists; skip and
/// impression memory is carried over (or seeded from the stores).
TasteProfile buildTasteProfile({
  List<YtTrack> recent = const [],
  List<YtTrack> liked = const [],
  Map<String, int> skipCounts = const {},
  Map<String, int> shownCounts = const {},
  int nowMs = 0,
}) {
  try {
    final artists = <String, double>{};
    final moods = <String, double>{};
    final plays = <String, int>{};
    void addArtist(String blob, double w) {
      if (w <= 0) return;
      for (final k in tasteArtistKeys(blob)) {
        artists[k] = (artists[k] ?? 0.0) + w;
      }
    }

    var i = 0;
    for (final t in recent.take(tasteRecentWindow)) {
      try {
        final w = pow(tasteRecencyBase, i).toDouble();
        addArtist(t.artist, w);
        final m = detectMood('${t.title} ${t.artist}');
        if (m != null) moods[m] = (moods[m] ?? 0.0) + w * 0.5;
        if (t.id.isNotEmpty) plays[t.id] = (plays[t.id] ?? 0) + 1;
      } catch (_) {}
      i++;
    }
    for (final t in liked.take(500)) {
      try {
        addArtist(t.artist, tasteLikedBoost * 0.5);
      } catch (_) {}
    }
    return TasteProfile(
      artistScores: _capScores(artists, tasteProfileArtistCap),
      moodScores: moods,
      playCounts: _capCounts(plays, tasteProfileTrackCap),
      skipCounts: Map.of(skipCounts),
      shownCounts: Map.of(shownCounts),
      updatedAt: nowMs,
    );
  } catch (_) {
    return TasteProfile(updatedAt: nowMs);
  }
}

/// Session-context artist affinity from the live session tail (the queue
/// around the seed / just-played tracks, newest-first): position `i`
/// weighs `0.7^i` so the NOW dominates and 5-songs-ago barely whispers.
/// Keys reuse [tasteArtistKeys] so "A feat. B" blobs overlap. Pure, never
/// throws; empty map when the session is empty.
Map<String, double> sessionAffinityFor(List<YtTrack> session) {
  try {
    final out = <String, double>{};
    var i = 0;
    for (final t in session.take(tasteSessionWindow)) {
      try {
        final w = pow(0.7, i).toDouble();
        for (final k in tasteArtistKeys(t.artist)) {
          out[k] = (out[k] ?? 0.0) + w;
        }
      } catch (_) {}
      i++;
    }
    return out;
  } catch (_) {
    return const {};
  }
}

/// Session-context mood affinity from the live session tail (same decay
/// shape as [sessionAffinityFor]). Lets the current mood of the session
/// steer ranking even when global taste says otherwise. Pure, never
/// throws.
Map<String, double> sessionMoodsFor(List<YtTrack> session) {
  try {
    final out = <String, double>{};
    var i = 0;
    for (final t in session.take(tasteSessionWindow)) {
      try {
        final m = detectMood('${t.title} ${t.artist}');
        if (m != null) out[m] = (out[m] ?? 0.0) + pow(0.7, i).toDouble();
      } catch (_) {}
      i++;
    }
    return out;
  } catch (_) {
    return const {};
  }
}

/// Related-track score for one candidate: artist overlap (affinity),
/// co-occurrence (multi-seed agreement), mood fit, liked bonus, minus
/// skip/recent/impression penalties and the same-name sink. Higher wins.
double scoreCandidate(
  YtTrack c, {
  YtTrack? seed,
  TasteProfile? taste,
  Set<String> relatedIds = const {},
  Map<String, double> coOccurrence = const {},
  Set<String> likedIds = const {},
  Set<String> recentIds = const {},
  Set<String> skipIds = const {},
  Map<String, double> sessionAffinity = const {},
  Map<String, double> sessionMoods = const {},
  Set<String> skipArtists = const {},
}) {
  try {
    var s = 0.0;
    if (relatedIds.contains(c.id)) s += tasteRelatedWeight;
    // Multi-seed agreement wins superlinearly: a track co-listened with
    // several seeds is evidence, not noise.
    final co = coOccurrence[c.id] ?? 0.0;
    if (co > 0) s += co * tasteCoOccurWeight + co * co * tasteCoOccurQuad;
    if (taste != null) {
      s += taste.artistAffinity(c.artist) * tasteArtistWeight;
      try {
        final m = detectMood('${c.title} ${c.artist}');
        if (m != null) s += taste.moodAffinity(m) * tasteMoodWeight;
      } catch (_) {}
    }
    // Session context (the live moment) stacks on top of global taste.
    if (sessionAffinity.isNotEmpty) {
      try {
        var best = 0.0;
        for (final k in tasteArtistKeys(c.artist)) {
          final v = sessionAffinity[k] ?? 0.0;
          if (v > best) best = v;
        }
        s += best * tasteSessionArtistWeight;
      } catch (_) {}
    }
    if (sessionMoods.isNotEmpty) {
      try {
        final m = detectMood('${c.title} ${c.artist}');
        if (m != null) s += (sessionMoods[m] ?? 0.0) * tasteSessionMoodWeight;
      } catch (_) {}
    }
    if (likedIds.contains(c.id)) s += tasteLikedTrackBoost;
    var skips = 0;
    try {
      skips = taste?.skipCounts[c.id] ?? 0;
    } catch (_) {}
    if (skipIds.contains(c.id)) skips += 1;
    if (skips > 0) {
      // Escalating: the first skip already buries (-3.0), repeats pile
      // on, ceiling [tasteSkipMax] so ancient history can't nuke forever.
      final pen = (tasteSkipFirst + (skips - 1) * tasteSkipPerExtra)
          .clamp(0.0, tasteSkipMax);
      s -= pen;
    }
    // Skip-artist aversion: the skipped singer's other songs sink too.
    if (skipArtists.isNotEmpty) {
      try {
        var hit = false;
        for (final k in tasteArtistKeys(c.artist)) {
          if (skipArtists.contains(k)) {
            hit = true;
            break;
          }
        }
        if (hit) s -= tasteSkipArtistPenalty;
      } catch (_) {}
    }
    if (recentIds.contains(c.id)) s -= tasteRecentPenalty;
    try {
      final shown = taste?.shownCounts[c.id] ?? 0;
      if (shown > 0) {
        s -= (shown * tasteShownPerImpression).clamp(0.0, tasteShownMax);
      }
    } catch (_) {}
    if (seed != null) {
      try {
        // Mood/type fit: same energy, genre, era, language — works with
        // zero taste (cold single-song start), affinities stack on top.
        // Cold starts count extra so one song still opens mood radio.
        final fit = moodFitScore(seed, c);
        final cold = taste == null || taste.isEmpty;
        s += cold ? fit * tasteColdMoodBoost : fit;
      } catch (_) {}
      if (isSameName(c, seed)) s -= 8;
      // Variety over clumps even in taste mode: the seed's own singer
      // never dominates Up Next (diversity caps enforce the rest).
      try {
        if (c.artist.toLowerCase() == seed.artist.toLowerCase()) s -= 2;
      } catch (_) {}
    }
    return s;
  } catch (_) {
    return 0.0;
  }
}

/// Resequence a picked set as a mood arc WITHOUT changing membership:
/// greedy emit, highest-score first, then the best remaining track whose
/// mood doesn't repeat the last emission (a 3-in-a-row run is deferred
/// while anything else remains). Same tracks, same caps — only the walk
/// reads as variety with a through-line. Pure, never throws.
List<YtTrack> arcOrder(List<(double, YtTrack)> picked) {
  try {
    if (picked.length < 3) return picked.map((e) => e.$2).toList();
    final moods = <String, String?>{};
    String? moodOf(YtTrack t) {
      try {
        return moods.putIfAbsent(
            t.id, () => detectMood('${t.title} ${t.artist}'));
      } catch (_) {
        return null;
      }
    }

    final rest = List<(double, YtTrack)>.of(picked);
    final out = <YtTrack>[];
    String? last;
    String? last2;
    while (rest.isNotEmpty) {
      var idx = 0;
      // Prefer the best track that neither repeats the last mood nor
      // completes a 3-run; fall back to raw best when all remaining
      // share the mood (rails never go empty for variety's sake).
      for (var i = 0; i < rest.length; i++) {
        try {
          final m = moodOf(rest[i].$2);
          if (m == null) {
            idx = i;
            break;
          }
          if (m != last) {
            idx = i;
            break;
          }
        } catch (_) {
          idx = i;
          break;
        }
      }
      // If the preference above landed on a 3-run, scan once more for
      // any non-run alternative before accepting it.
      try {
        final m = moodOf(rest[idx].$2);
        if (m != null && m == last && m == last2) {
          for (var i = 0; i < rest.length; i++) {
            final alt = moodOf(rest[i].$2);
            if (alt != m) {
              idx = i;
              break;
            }
          }
        }
      } catch (_) {}
      final next = rest.removeAt(idx);
      out.add(next.$2);
      last2 = last;
      last = moodOf(next.$2);
    }
    return out;
  } catch (_) {
    return picked.map((e) => e.$2).toList();
  }
}

/// Taste-matched Top Picks: scores [pool] by affinity/co-occurrence,
/// dedupes, drops excluded + heavily-skipped ids, enforces [maxPerArtist]
/// diversity, and rotates freshness ([shownIds]/profile impressions sink
/// repeats; [rotationSalt] re-rolls the tiebreak so refreshes vary).
/// [sessionContext] (live session tail, newest-first) steers toward the
/// current moment on top of global taste; [skipArtists] buries skipped
/// singers; [moodArc] resequences the picked set for variety.
List<YtTrack> rankTopPicks(
  List<YtTrack> pool, {
  TasteProfile? taste,
  Set<String> excludeIds = const {},
  Set<String> likedIds = const {},
  Set<String> recentIds = const {},
  Set<String> skipIds = const {},
  Set<String> shownIds = const {},
  Map<String, double>? coOccurrence,
  List<YtTrack> sessionContext = const [],
  Set<String> skipArtists = const {},
  bool moodArc = true,
  int max = tasteTopPicksDefault,
  int maxPerArtist = tasteTopPicksPerArtist,
  int? rotationSalt,
  Random? random,
}) {
  try {
    final rnd =
        random ?? (rotationSalt != null ? Random(rotationSalt) : Random());
    final sessAff =
        sessionContext.isEmpty ? const <String, double>{} : sessionAffinityFor(sessionContext);
    final sessMoods =
        sessionContext.isEmpty ? const <String, double>{} : sessionMoodsFor(sessionContext);
    final seen = <String>{};
    final scored = <(double, int, YtTrack)>[];
    for (final c in pool) {
      if (c.id.isEmpty || !seen.add(c.id)) continue;
      if (excludeIds.contains(c.id)) continue;
      if (skipIds.contains(c.id)) continue;
      var extra = 0.0;
      if (shownIds.contains(c.id)) extra = tasteShownPerImpression;
      final s = scoreCandidate(
            c,
            taste: taste,
            coOccurrence: coOccurrence ?? const {},
            likedIds: likedIds,
            recentIds: recentIds,
            skipIds: skipIds,
            sessionAffinity: sessAff,
            sessionMoods: sessMoods,
            skipArtists: skipArtists,
          ) -
          extra;
      scored.add((s, rnd.nextInt(1 << 30), c));
    }
    scored.sort((a, b) {
      final d = b.$1.compareTo(a.$1);
      return d != 0 ? d : a.$2.compareTo(b.$2);
    });
    final picked = <(double, YtTrack)>[];
    final perArtist = <String, int>{};
    for (final e in scored) {
      if (picked.length >= max) break;
      final key = e.$3.artist.toLowerCase();
      final n = (perArtist[key] ?? 0) + 1;
      if (n > maxPerArtist) continue;
      perArtist[key] = n;
      picked.add((e.$1, e.$3));
    }
    if (moodArc) return arcOrder(picked);
    return picked.map((e) => e.$2).toList();
  } catch (_) {
    return [];
  }
}

/// Queue Up Next: seed + same-NAME echoes never queue, [excludeIds]
/// (the visible queue) dedupes, skips drop, [maxPerArtist] caps clumps.
/// Score-tied tracks shuffle ([rotationSalt] re-rolls the tiebreak so
/// repeats vary); [moodArc] resequences the picked set for variety.
/// [sessionContext] (live session tail) steers the moment on top of
/// global taste; [skipArtists] buries skipped singers.
List<YtTrack> rankUpNext(
  YtTrack seed,
  List<YtTrack> pool, {
  Set<String> relatedIds = const {},
  TasteProfile? taste,
  Set<String> excludeIds = const {},
  Set<String> likedIds = const {},
  Set<String> recentIds = const {},
  Set<String> skipIds = const {},
  Map<String, double>? coOccurrence,
  List<YtTrack> sessionContext = const [],
  Set<String> skipArtists = const {},
  bool moodArc = true,
  int? rotationSalt,
  int max = 20,
  int maxPerArtist = tasteUpNextPerArtist,
  Random? random,
}) {
  try {
    final rnd =
        random ?? (rotationSalt != null ? Random(rotationSalt) : Random());
    final sessAff =
        sessionContext.isEmpty ? const <String, double>{} : sessionAffinityFor(sessionContext);
    final sessMoods =
        sessionContext.isEmpty ? const <String, double>{} : sessionMoodsFor(sessionContext);
    final seen = <String>{seed.id, ...excludeIds};
    final scored = <(double, int, YtTrack)>[];
    for (final c in pool) {
      if (c.id == seed.id || !seen.add(c.id)) continue;
      if (isSameName(c, seed)) continue;
      if (skipIds.contains(c.id)) continue;
      final s = scoreCandidate(
        c,
        seed: seed,
        taste: taste,
        relatedIds: relatedIds,
        coOccurrence: coOccurrence ?? const {},
        likedIds: likedIds,
        recentIds: recentIds,
        skipIds: skipIds,
        sessionAffinity: sessAff,
        sessionMoods: sessMoods,
        skipArtists: skipArtists,
      );
      scored.add((s, rnd.nextInt(1 << 30), c));
    }
    scored.sort((a, b) {
      final d = b.$1.compareTo(a.$1);
      return d != 0 ? d : a.$2.compareTo(b.$2);
    });
    final picked = <(double, YtTrack)>[];
    final perArtist = <String, int>{};
    for (final e in scored) {
      if (picked.length >= max) break;
      final key = e.$3.artist.toLowerCase();
      final n = (perArtist[key] ?? 0) + 1;
      if (n > maxPerArtist) continue;
      perArtist[key] = n;
      picked.add((e.$1, e.$3));
    }
    if (moodArc) return arcOrder(picked);
    return picked.map((e) => e.$2).toList();
  } catch (_) {
    return [];
  }
}

/// Off-hot-path wrappers: scoring is O(n) sync, but these yield to the
/// event loop first so frame/queue work never janks. Prefer these (or
/// `compute`) from UI/queue call sites; the repository uses them.
Future<List<YtTrack>> rankTopPicksAsync(
  List<YtTrack> pool, {
  TasteProfile? taste,
  Set<String> excludeIds = const {},
  Set<String> likedIds = const {},
  Set<String> recentIds = const {},
  Set<String> skipIds = const {},
  Set<String> shownIds = const {},
  Map<String, double>? coOccurrence,
  List<YtTrack> sessionContext = const [],
  Set<String> skipArtists = const {},
  bool moodArc = true,
  int max = tasteTopPicksDefault,
  int maxPerArtist = tasteTopPicksPerArtist,
  int? rotationSalt,
  Random? random,
}) =>
    Future(() => rankTopPicks(
          pool,
          taste: taste,
          excludeIds: excludeIds,
          likedIds: likedIds,
          recentIds: recentIds,
          skipIds: skipIds,
          shownIds: shownIds,
          coOccurrence: coOccurrence,
          sessionContext: sessionContext,
          skipArtists: skipArtists,
          moodArc: moodArc,
          max: max,
          maxPerArtist: maxPerArtist,
          rotationSalt: rotationSalt,
          random: random,
        ));

/// Off-hot-path Up Next wrapper (see [rankTopPicksAsync]).
Future<List<YtTrack>> rankUpNextAsync(
  YtTrack seed,
  List<YtTrack> pool, {
  Set<String> relatedIds = const {},
  TasteProfile? taste,
  Set<String> excludeIds = const {},
  Set<String> likedIds = const {},
  Set<String> recentIds = const {},
  Set<String> skipIds = const {},
  Map<String, double>? coOccurrence,
  List<YtTrack> sessionContext = const [],
  Set<String> skipArtists = const {},
  bool moodArc = true,
  int? rotationSalt,
  int max = 20,
  int maxPerArtist = tasteUpNextPerArtist,
  Random? random,
}) =>
    Future(() => rankUpNext(
          seed,
          pool,
          relatedIds: relatedIds,
          taste: taste,
          excludeIds: excludeIds,
          likedIds: likedIds,
          recentIds: recentIds,
          skipIds: skipIds,
          coOccurrence: coOccurrence,
          sessionContext: sessionContext,
          skipArtists: skipArtists,
          moodArc: moodArc,
          rotationSalt: rotationSalt,
          max: max,
          maxPerArtist: maxPerArtist,
          random: random,
        ));

// ---------------------------------------------------------------------------
// Mood/type engine: Up-Next suggestions must feel related by MOOD (same
// energy, genre, era, language) — explicitly NOT same-singer radio.
//
// Signals are derived from AVAILABLE metadata only: YtTrack carries id +
// title + artist (+ thumb/watch urls), so every signal below comes from
// title/artist text (keywords, mood words, script detection, era/year
// tokens, tempo hints like "slowed"/"sped up"), layered with the
// discovery affinities + related-track graph at scoring time (the graph
// and affinity terms live in [scoreCandidate], not here). Duration/tempo
// have no dedicated YtTrack field, so tempo is a title-keyword hint
// (fast/slow/null) and duration never gates mood — it only gates song
// candidacy in track.dart (30s–10min S3 gates).
//
// [moodFitScore] is the pure pairwise fit used by [scoreCandidate] (seed
// mood fit, taste-independent so a single cold song still gets mood
// radio) and by queue.dart rankSuggestions + the offline library fill.
// ---------------------------------------------------------------------------

/// Same-mood anchor bonus (strongest single mood term).
const double moodSameBonus = 4.0;

/// Same-language bonus; known-different languages sink (mismatch).
const double moodLanguageBonus = 2.0;
const double moodLanguageMismatch = -1.0;

/// Energy proximity weight: (1 - |e1 - e2|) * this.
const double moodEnergyWeight = 2.5;

/// Same-era (decade bucket) bonus.
const double moodEraBonus = 1.5;

/// Title-keyword overlap: per shared word, capped.
const double moodKeywordPerWord = 0.8;
const double moodKeywordCap = 2.4;

/// Tempo-hint (fast/slow from title keywords) agreement bonus.
const double moodTempoBonus = 1.0;

/// Mood/type signal snapshot for one track. Pure value object.
class MoodSignals {
  final String? mood;
  final double energy;
  final String? language;
  final String? era;
  final String? tempo;
  final Set<String> keywords;
  const MoodSignals({
    this.mood,
    this.energy = 0.5,
    this.language,
    this.era,
    this.tempo,
    this.keywords = const {},
  });
}

/// High-energy title markers (party/workout/dance/bhangra/dj).
bool _moodHigh(String low) {
  try {
    for (final k in const [
      'party', 'dance', 'club', 'workout', 'gym', 'motivat', 'pump',
      'bhangra', 'dhol', 'dj', 'bass', 'hype', 'anthem', 'danceable',
      'edm', 'remix', 'kuthu', 'garba', 'baraat',
    ]) {
      if (low.contains(k)) return true;
    }
  } catch (_) {}
  return false;
}

/// Low-energy title markers (chill/sad/slow/acoustic/sleep).
bool _moodLow(String low) {
  try {
    for (final k in const [
      'lofi', 'chill', 'slow', 'sad', 'bewafa', 'dard', 'acoustic',
      'lullaby', 'sleep', 'soft', 'soulful', 'unplugged', 'slowed',
      'reverb', 'sufi', 'gazal', 'ghazal', 'bhajan', 'aarti',
    ]) {
      if (low.contains(k)) return true;
    }
  } catch (_) {}
  return false;
}

/// Language guess from explicit markers + script ranges. Null = unknown
/// (never forces a mismatch penalty).
String? detectLanguage(String text) {
  try {
    final low = text.toLowerCase();
    if (RegExp(r'[\u0900-\u097F]').hasMatch(text)) return 'hindi';
    if (RegExp(r'[\u0A00-\u0A7F]').hasMatch(text)) return 'punjabi';
    if (RegExp(r'[\u0B80-\u0BFF]').hasMatch(text)) return 'tamil';
    if (RegExp(r'[\u0C00-\u0C7F]').hasMatch(text)) return 'telugu';
    if (RegExp(r'[\u0C80-\u0CFF]').hasMatch(text)) return 'kannada';
    if (RegExp(r'[\u0D00-\u0D7F]').hasMatch(text)) return 'malayalam';
    if (RegExp(r'[\u0980-\u09FF]').hasMatch(text)) return 'bengali';
    const hits = <String, String>{
      'punjabi': 'punjabi', 'bhangra': 'punjabi', 'diljit': 'punjabi',
      'shubh': 'punjabi', 'sidhu': 'punjabi', 'karan aujla': 'punjabi',
      'hindi': 'hindi', 'urdu': 'hindi', 'pyaar': 'hindi', 'mohabbat': 'hindi',
      'ishq': 'hindi', 'sanam': 'hindi', 'tamil': 'tamil', 'telugu': 'telugu',
      'malayalam': 'malayalam', 'kannada': 'kannada', 'bengali': 'bengali',
      'marathi': 'marathi', 'gujarati': 'gujarati', 'korean': 'korean',
      'spanish': 'spanish', 'english': 'english',
    };
    for (final e in hits.entries) {
      if (low.contains(e.key)) return e.value;
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Era/decade bucket from year tokens + retro markers. Null = unknown.
String? detectEra(String text) {
  try {
    final low = text.toLowerCase();
    final ym = RegExp(r"(19[6-9]\d|20[0-3]\d)").firstMatch(low);
    if (ym != null) {
      final y = int.tryParse(ym.group(1)!) ?? 0;
      if (y >= 1960 && y <= 1969) return '60s';
      if (y >= 1970 && y <= 1979) return '70s';
      if (y >= 1980 && y <= 1989) return '80s';
      if (y >= 1990 && y <= 1999) return '90s';
      if (y >= 2000 && y <= 2009) return '2000s';
      if (y >= 2010 && y <= 2019) return '2010s';
      if (y >= 2020) return '2020s';
    }
    if (low.contains('90s') ||
        low.contains('90 s') ||
        low.contains("90's")) {
      return '90s';
    }
    if (low.contains('2000s') || low.contains('2000 s')) return '2000s';
    if (low.contains('retro') ||
        low.contains('classic') ||
        low.contains('throwback') ||
        low.contains('old song') ||
        low.contains('evergreen')) {
      return 'retro';
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Normalized title keyword set (len > 3, stopwords dropped).
Set<String> moodKeywords(String title) {
  try {
    var s = title.toLowerCase().replaceAll(RegExp(r'[\(\[].*?[\)\]]'), ' ');
    final dash = s.indexOf(' - ');
    if (dash >= 3) s = s.substring(0, dash);
    s = s.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
    return s
        .split(RegExp(r'\s+'))
        .map((e) => e.trim())
        .where((e) => e.length > 3)
        .where((e) => !{
              'official', 'video', 'audio', 'lyrics', 'lyric', 'song',
              'songs', 'full', 'visualizer', 'with', 'from', 'feat',
            }.contains(e))
        .toSet();
  } catch (_) {
    return const {};
  }
}

/// Derive the mood/type signals for one track (never throws).
MoodSignals moodSignals(YtTrack t) {
  try {
    final text = '${t.title} ${t.artist}';
    final low = text.toLowerCase();
    final mood = detectMood(text);
    var energy = 0.5;
    String? tempo;
    final high = _moodHigh(low);
    final lowE = _moodLow(low);
    if (high && !lowE) {
      energy = 0.85;
      tempo = 'fast';
    } else if (lowE && !high) {
      energy = 0.2;
      tempo = 'slow';
    } else if (mood == 'romantic') {
      energy = 0.35;
      tempo = 'slow';
    } else if (mood == 'party' || mood == 'workout') {
      energy = 0.85;
      tempo = 'fast';
    } else if (mood == 'lofi' || mood == 'sad') {
      energy = 0.2;
      tempo = 'slow';
    }
    if (low.contains('sped up') || low.contains('nightcore')) {
      energy = energy < 0.8 ? 0.8 : energy;
      tempo = 'fast';
    }
    return MoodSignals(
      mood: mood,
      energy: energy,
      language: detectLanguage(text),
      era: detectEra(text),
      tempo: tempo,
      keywords: moodKeywords(t.title),
    );
  } catch (_) {
    return const MoodSignals();
  }
}

/// Pairwise mood/type fit: same mood + language + energy proximity +
/// era + keyword overlap + tempo agreement. Higher = closer vibe.
/// Range roughly -1 .. +11. Pure, never throws.
double moodFitScore(YtTrack seed, YtTrack candidate) {
  try {
    final a = moodSignals(seed);
    final b = moodSignals(candidate);
    var s = 0.0;
    if (a.mood != null && a.mood == b.mood) s += moodSameBonus;
    if (a.language != null && b.language != null) {
      if (a.language == b.language) {
        s += moodLanguageBonus;
      } else {
        s += moodLanguageMismatch;
      }
    }
    try {
      final gap = (a.energy - b.energy).abs().clamp(0.0, 1.0);
      s += (1.0 - gap) * moodEnergyWeight;
    } catch (_) {}
    if (a.era != null && a.era == b.era) s += moodEraBonus;
    try {
      var shared = 0;
      final small = a.keywords.length <= b.keywords.length
          ? a.keywords
          : b.keywords;
      final big = identical(small, a.keywords) ? b.keywords : a.keywords;
      for (final k in small) {
        if (big.contains(k)) shared++;
      }
      final kw = (shared * moodKeywordPerWord).clamp(0.0, moodKeywordCap);
      s += kw;
    } catch (_) {}
    if (a.tempo != null && a.tempo == b.tempo) s += moodTempoBonus;
    return s;
  } catch (_) {
    return 0.0;
  }
}
