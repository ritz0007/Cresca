// Pure-Dart discovery scoring (vibe + smart shuffle).
// Native refs: YoutubeRepository.vibeQueries/detectMood/isSameName/
// rankByVibe, MainActivity.applySmartShuffle. No network here — these
// rank already-gated tracks.

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
List<YtTrack> rankByVibe(
  YtTrack seed,
  List<YtTrack> pool, {
  Set<String> relatedIds = const {},
  Random? random,
}) {
  try {
    final seedMood = detectMood('${seed.title} ${seed.artist}');
    final seedArtist = seed.artist.toLowerCase();
    final rnd = random ?? Random();
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
  } catch (_) {
    return List.of(pool)..shuffle(random);
  }
}

/// Smart-shuffle order: preference-scored (liked/recent/same artist),
/// randomized within score tiers, current first. Mirrors
/// MainActivity.applySmartShuffle; caller feeds [QueueEngine.applyOrder].
List<int> smartOrderFor({
  required List<YtTrack> items,
  required int currentIndex,
  required Set<String> likedArtists,
  required List<String> recentArtists,
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
