// Pure-Dart queue engine (P12 order semantics, player-agnostic).
// Native ref: PlayerQueue.kt (order list, generation-cancel, SHUFFLE
// OFF/ON/SMART, manual repeat, playNext/add/remove/moveInOrder/applyOrder,
// adoptJamQueue silent swap, auto-tail rules, setQueueSilent restore).
//
// The engine never touches audio: it decides *which index plays next* and
// the just_audio binding (Phase 2 UI layer) executes resolve + play.
// Randomness is injectable so tests are deterministic.

import 'dart:collection';
import 'dart:math';
import 'discovery.dart' as discovery;
import 'track.dart';

const int shuffleOff = 0;
const int shuffleOn = 1;
const int shuffleSmart = 2;

const int repeatOff = 0;
const int repeatAll = 1;
const int repeatOne = 2;

/// What next() decided (mirrors the native branches incl. autoplay hook).
enum NextStep { play, exhausted, none }

class NextResult {
  final NextStep step;
  final int index;
  final YtTrack? exhaustedTrack;
  NextResult(this.step, {this.index = -1, this.exhaustedTrack});
}

/// int clamp that stays int (num.clamp returns num).
int _clampInt(int v, int lo, int hi) =>
    v < lo ? lo : (v > hi ? hi : v);

/// All valid indices for a list of length [n].
List<int> _all(int n) => List<int>.generate(n, (i) => i);

class QueueEngine {
  final List<YtTrack> items = [];
  int currentIndex = -1;
  int shuffleMode = shuffleOff;
  bool shuffled = false;
  int repeatMode = repeatOff;

  final List<int> order = [];
  final LinkedHashSet<String> autoIds = LinkedHashSet();
  String? exhaustedFor;

  /// Skip-decay memory: track id -> consecutive skips. Fed by the UI
  /// layer (remove/next-without-listen); consumed by [rankSuggestions].
  /// Pure counters — never drive playback by themselves.
  final Map<String, int> skipCounts = {};

  /// Skip-artist aversion memory (artist keys of skipped tracks, oldest
  /// first, capped): dislikes bury the singer, not just the song.
  /// Additive memory — read by [rankSuggestions] via [skipArtistsOf].
  final LinkedHashSet<String> skipArtists = LinkedHashSet();

  /// Cap on remembered skip-artist keys (memory stays bounded).
  static const int skipArtistsCap = 200;

  /// Record a skip for suggestion decay (clamped, never throws).
  void noteSkipped(YtTrack t) {
    try {
      final n = (skipCounts[t.id] ?? 0) + 1;
      skipCounts[t.id] = n > 9 ? 9 : n;
    } catch (_) {}
    try {
      final key = t.artistKey();
      if (key.isNotEmpty) {
        skipArtists.remove(key);
        skipArtists.add(key);
        while (skipArtists.length > skipArtistsCap) {
          skipArtists.remove(skipArtists.first);
        }
      }
    } catch (_) {}
  }

  /// A completed listen clears skip stigma for that track.
  void notePlayed(YtTrack t) {
    try {
      skipCounts.remove(t.id);
    } catch (_) {}
  }

  /// True when [id] is already queued (play-next/add guard: no dupes).
  bool containsId(String id) {
    try {
      for (final t in items) {
        if (t.id == id) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Stuck fix: every tap bumps the generation so stale async resolves
  /// lose (native: generation token + resolveJob cancel).
  int generation = 0;
  void cancelPending() => generation++;

  YtTrack? get current =>
      currentIndex >= 0 && currentIndex < items.length
          ? items[currentIndex]
          : null;

  List<int> playOrder() => List.of(order);

  void setQueue(List<YtTrack> tracks, [int startIndex = 0]) {
    cancelPending();
    autoIds.clear();
    exhaustedFor = null;
    items
      ..clear()
      ..addAll(tracks);
    if (items.isEmpty) {
      currentIndex = -1;
      order.clear();
      return;
    }
    currentIndex = _clampInt(startIndex, 0, items.length - 1);
    if (shuffled) {
      _rebuildShuffled();
    } else {
      _rebuildIdentity();
    }
  }

  /// Spotify-style cold restore: queue + position back, no autoplay.
  /// Returns the restored index or -1.
  int setQueueSilent(
    List<YtTrack> tracks,
    int startIndex,
    bool shuffle,
    int repeat,
  ) {
    cancelPending();
    items
      ..clear()
      ..addAll(tracks);
    if (items.isEmpty) {
      currentIndex = -1;
      order.clear();
      return -1;
    }
    shuffleMode = shuffle ? shuffleOn : shuffleOff;
    shuffled = shuffle;
    repeatMode = repeat;
    currentIndex = _clampInt(startIndex, 0, items.length - 1);
    if (shuffled) {
      order
        ..clear()
        ..add(currentIndex)
        ..addAll(_shuffledOthers(currentIndex));
    } else {
      _rebuildIdentity();
    }
    return currentIndex;
  }

  List<YtTrack> snapshot() => List.of(items);

  /// JAM guest: BECOME the host queue (F3). Silent swap, never autoplay.
  /// Keeps the sounding track's seat when present, else host index.
  void adoptJamQueue(List<YtTrack> tracks, String hostCurId) {
    try {
      if (tracks.isEmpty) return;
      final soundingId = current?.id;
      items
        ..clear()
        ..addAll(tracks.take(60));
      autoIds.clear();
      exhaustedFor = null;
      int idx = -1;
      if (soundingId != null) {
        idx = items.indexWhere((t) => t.id == soundingId);
      }
      if (idx < 0) idx = items.indexWhere((t) => t.id == hostCurId);
      currentIndex = idx >= 0 ? idx : 0;
      _rebuildIdentity();
    } catch (_) {}
  }

  /// Load tracks without autoplaying (home/search results).
  void replaceAll(List<YtTrack> tracks) {
    final keepId = current?.id;
    final keepShuffle = shuffled;
    items
      ..clear()
      ..addAll(tracks);
    currentIndex = keepId == null
        ? -1
        : items.indexWhere((t) => t.id == keepId);
    if (keepShuffle && currentIndex != -1) {
      _rebuildShuffled();
    } else if (keepShuffle) {
      order.clear();
    } else {
      _rebuildIdentity();
    }
  }

  int playAt(int index) {
    if (index < 0 || index >= items.length) return currentIndex;
    cancelPending();
    currentIndex = index;
    exhaustedFor = null;
    return currentIndex;
  }

  int playTrack(YtTrack t) {
    final idx = items.indexWhere((e) => e.id == t.id);
    if (idx >= 0) return playAt(idx);
    cancelPending();
    items.add(t);
    order.add(items.length - 1);
    return playAt(items.length - 1);
  }

  void addToQueue(YtTrack t) {
    // No dupes: keyed lists crash on dupes and repeats feel broken.
    if (containsId(t.id)) return;
    items.add(t);
    order.add(items.length - 1);
  }

  void playNext(YtTrack t) {
    if (items.isEmpty || currentIndex == -1) {
      // No dupes even on a cold queue.
      if (containsId(t.id)) return;
      items.add(t);
      final i = items.length - 1;
      if (!order.contains(i)) order.add(i);
      return;
    }
    final existing = items.indexWhere((e) => e.id == t.id);
    if (existing >= 0) {
      // No dupes: relocate the existing row to right-after-current
      // instead of inserting a second copy. Playing track stays put.
      if (existing == currentIndex) return;
      final track = items[existing];
      removeAt(existing);
      if (items.isEmpty || currentIndex == -1) {
        items.add(track);
        order.add(items.length - 1);
        return;
      }
      final insertPos = _clampInt(currentIndex + 1, 0, items.length);
      items.insert(insertPos, track);
      for (var i = 0; i < order.length; i++) {
        if (order[i] >= insertPos) order[i]++;
      }
      final curPos = order.indexOf(currentIndex);
      if (curPos == -1) {
        order.add(insertPos);
      } else {
        order.insert(curPos + 1, insertPos);
      }
      return;
    }
    final insertPos = _clampInt(currentIndex + 1, 0, items.length);
    items.insert(insertPos, t);
    for (var i = 0; i < order.length; i++) {
      if (order[i] >= insertPos) order[i]++;
    }
    final curPos = order.indexOf(currentIndex);
    if (curPos == -1) {
      order.add(insertPos);
    } else {
      order.insert(curPos + 1, insertPos);
    }
  }

  /// Removes a row. Returns the index the player should resolve next,
  /// or -1 when nothing should play (empty queue).
  int removeAt(int index) {
    if (index < 0 || index >= items.length) return currentIndex;
    final removingCurrent = index == currentIndex;
    if (removingCurrent) cancelPending();
    items.removeAt(index);
    if (items.isEmpty) {
      currentIndex = -1;
      order.clear();
      return -1;
    }
    order.remove(index);
    for (var i = 0; i < order.length; i++) {
      if (order[i] > index) order[i]--;
    }
    if (removingCurrent) {
      currentIndex =
          index < items.length ? index : items.length - 1;
      if (!order.contains(currentIndex)) order.insert(0, currentIndex);
      return currentIndex;
    } else if (index < currentIndex) {
      currentIndex--;
    }
    return currentIndex;
  }

  NextResult next() {
    if (items.isEmpty || currentIndex == -1) {
      return NextResult(NextStep.none);
    }
    if (repeatMode == repeatOne) {
      cancelPending();
      return NextResult(NextStep.play, index: currentIndex);
    }
    final pos = order.indexOf(currentIndex);
    if (pos == -1) {
      if (shuffled) {
        _rebuildShuffled();
      } else {
        _rebuildIdentity();
      }
      return NextResult(NextStep.none);
    }
    if (pos < order.length - 1) {
      cancelPending();
      currentIndex = order[pos + 1];
      exhaustedFor = null;
      return NextResult(NextStep.play, index: currentIndex);
    }
    if (repeatMode == repeatAll && order.isNotEmpty) {
      cancelPending();
      currentIndex = order[0];
      exhaustedFor = null;
      return NextResult(NextStep.play, index: currentIndex);
    }
    // Queue exhausted with repeat off: caller tops up autoplay once
    // per track (endless radio hook).
    final cur = current;
    if (cur != null && exhaustedFor != cur.id) {
      exhaustedFor = cur.id;
      return NextResult(NextStep.exhausted, exhaustedTrack: cur);
    }
    return NextResult(NextStep.none);
  }

  int previous() {
    if (items.isEmpty || currentIndex == -1) return -1;
    final pos = order.indexOf(currentIndex);
    if (pos == -1) {
      if (shuffled) {
        _rebuildShuffled();
      } else {
        _rebuildIdentity();
      }
      return -1;
    }
    if (pos > 0) {
      cancelPending();
      currentIndex = order[pos - 1];
      exhaustedFor = null;
      return currentIndex;
    }
    if (repeatMode == repeatAll && order.isNotEmpty) {
      cancelPending();
      currentIndex = order[order.length - 1];
      exhaustedFor = null;
      return currentIndex;
    }
    return -1;
  }

  int cycleRepeat() {
    repeatMode = switch (repeatMode) {
      repeatOff => repeatAll,
      repeatAll => repeatOne,
      _ => repeatOff,
    };
    return repeatMode;
  }

  /// OFF -> ON -> SMART -> OFF. Returns the new mode; the UI applies
  /// preference-scored order on SMART via [smartOrderFor].
  int cycleShuffle({Random? random}) {
    shuffleMode = switch (shuffleMode) {
      shuffleOff => shuffleOn,
      shuffleOn => shuffleSmart,
      _ => shuffleOff,
    };
    shuffled = shuffleMode != shuffleOff;
    if (items.isEmpty || currentIndex == -1) {
      order.clear();
      return shuffleMode;
    }
    if (shuffleMode == shuffleOff) {
      _rebuildIdentity();
    } else {
      _rebuildShuffled(random: random);
    }
    return shuffleMode;
  }

  /// Manual reorder: move one step in play order (drag & drop).
  void moveInOrder(int fromPos, int toPos) {
    try {
      if (fromPos < 0 ||
          fromPos >= order.length ||
          toPos < 0 ||
          toPos >= order.length) {
        return;
      }
      if (fromPos == toPos) return;
      final v = order.removeAt(fromPos);
      order.insert(_clampInt(toPos, 0, order.length), v);
    } catch (_) {}
  }

  /// Apply a caller-computed play order (smart shuffle). Current first.
  void applyOrder(List<int> indices) {
    try {
      // NB: Dart Set.== is identity (unlike Kotlin), so compare by
      // membership, not equality.
      if (indices.length != items.length) return;
      final want = _all(items.length).toSet();
      if (!want.containsAll(indices) || !indices.toSet().containsAll(want)) {
        return;
      }
      order
        ..clear()
        ..addAll(indices);
    } catch (_) {}
  }

  /// True when next() would move somewhere (ENDED dead-end fix).
  bool hasNext({required bool exhaustHookArmed}) {
    if (items.isEmpty || currentIndex == -1) return false;
    if (repeatMode != repeatOff) return true;
    final pos = order.indexOf(currentIndex);
    if (pos == -1) return items.length > 1;
    if (pos < order.length - 1) return true;
    return exhaustHookArmed;
  }

  /// Tracks queued after the current one (autoplay keeps this at ~20).
  int upcomingCount() {
    if (items.isEmpty || currentIndex == -1) return 0;
    final pos = order.indexOf(currentIndex);
    if (pos == -1) return items.length;
    return order.length - 1 - pos;
  }

  /// Endless-queue trigger: true when [upcomingCount] is at or below
  /// [threshold] (default [endlessRefillThreshold]). Checked after EVERY
  /// played song (load + advance + gapless adopt) so playback never
  /// dead-ends — even a single-song queue refills. Pure, never throws.
  bool needsRefill({int threshold = endlessRefillThreshold}) {
    try {
      if (items.isEmpty || currentIndex == -1) return false;
      return upcomingCount() <= threshold;
    } catch (_) {
      return false;
    }
  }

  /// Next [n] tracks in play order (background pre-caching).
  List<YtTrack> upcomingIds(int n) {
    try {
      if (items.isEmpty || currentIndex == -1 || n <= 0) return [];
      final pos = order.indexOf(currentIndex);
      if (pos == -1) return [];
      return order
          .sublist(pos + 1)
          .take(n)
          .map((i) => items[i])
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Previous [n] tracks in play order (back-skip precache).
  List<YtTrack> previousIds(int n) {
    try {
      if (items.isEmpty || currentIndex == -1 || n <= 0) return [];
      final pos = order.indexOf(currentIndex);
      if (pos <= 0) return [];
      return order
          .sublist(0, pos)
          .reversed
          .take(n)
          .toList()
          .reversed
          .map((i) => items[i])
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Append engine-picked tracks (related autoplay), tagged as auto tail.
  void appendAuto(List<YtTrack> tracks) {
    try {
      if (tracks.isEmpty) return;
      final fresh =
          tracks.where((t) => !items.any((e) => e.id == t.id)).toList();
      if (fresh.isEmpty) return;
      final base = items.length;
      items.addAll(fresh);
      for (final t in fresh) {
        autoIds.add(t.id);
      }
      final curPos = order.indexOf(currentIndex);
      var at = curPos == -1 ? order.length : curPos + 1;
      for (var k = 0; k < fresh.length; k++) {
        order.insert(_clampInt(at, 0, order.length), base + k);
        at++;
      }
    } catch (_) {}
  }

  /// Drop engine-picked tail (keeps the playing track + user tracks).
  void clearAutoTail({Random? random}) {
    try {
      if (autoIds.isEmpty) return;
      final curId = current?.id;
      final drop = <int>[];
      for (var i = 0; i < items.length; i++) {
        if (i != currentIndex && autoIds.contains(items[i].id)) drop.add(i);
      }
      if (drop.isEmpty) {
        autoIds.clear();
        return;
      }
      for (final i in drop.reversed) {
        items.removeAt(i);
      }
      autoIds.clear();
      order.clear();
      if (items.isEmpty) {
        currentIndex = -1;
        return;
      }
      currentIndex = curId == null
          ? 0
          : items.indexWhere((t) => t.id == curId);
      if (currentIndex < 0) currentIndex = 0;
      if (shuffleMode == shuffleOff) {
        _rebuildIdentity();
      } else {
        order
          ..add(currentIndex)
          ..addAll(_shuffledOthers(currentIndex, random: random));
      }
    } catch (_) {}
  }

  /// 403/410 budget: 3 retries per track (native: retriesLeft).
  int retriesLeft = 3;
  void resetRetries() => retriesLeft = 3;

  /// Index N steps ahead in play order (0 = immediate next), for the
  /// 2-ahead primer. Null past the end (or with repeat-one past 0).
  int? peekIndexAhead(int ahead) {
    try {
      if (items.isEmpty || currentIndex == -1) return null;
      if (repeatMode == repeatOne) {
        return ahead == 0 ? currentIndex : null;
      }
      final pos = order.indexOf(currentIndex);
      if (pos == -1) return null;
      final target = pos + 1 + ahead;
      if (target <= order.length - 1) return order[target];
      if (repeatMode == repeatAll && order.isNotEmpty) {
        return order[target % order.length];
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  void _rebuildIdentity() {
    order
      ..clear()
      ..addAll(_all(items.length));
  }

  void _rebuildShuffled({Random? random}) {
    order.clear();
    if (items.isEmpty || currentIndex == -1) return;
    final rnd = random ?? Random();
    final rest = _all(items.length).where((i) => i != currentIndex).toList()
      ..shuffle(rnd);
    order
      ..add(currentIndex)
      ..addAll(rest);
  }

  List<int> _shuffledOthers(int cur, {Random? random}) {
    final rnd = random ?? Random();
    return (_all(items.length).where((i) => i != cur).toList()
      ..shuffle(rnd));
  }
}

/// Discovery affinities from library state (liked + recent display
/// artists). Liked weighs +3, recent decays 2.0 → 0.5 over the first 8.
/// Defensive: never throws, empty map on failure.
Map<String, double> affinityFor({
  required List<YtTrack> liked,
  required List<YtTrack> recent,
}) {
  try {
    final out = <String, double>{};
    for (final t in liked) {
      try {
        final k = t.artistKey();
        out[k] = (out[k] ?? 0) + 3.0;
      } catch (_) {}
    }
    var i = 0;
    for (final t in recent.take(8)) {
      try {
        final k = t.artistKey();
        final w = 2.0 - i * 0.25;
        out[k] = (out[k] ?? 0) + (w < 0.5 ? 0.5 : w);
      } catch (_) {}
      i++;
    }
    return out;
  } catch (_) {
    return const {};
  }
}

bool _sameNameFallback(YtTrack a, YtTrack b) {
  try {
    List<String> norm(String title) {
      var s = title.toLowerCase().replaceAll(RegExp(r'[\(\[].*?[\)\]]'), ' ');
      final dash = s.indexOf(' - ');
      if (dash >= 3) s = s.substring(0, dash);
      s = s.replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
      return s
          .split(RegExp(r'\s+'))
          .map((e) => e.trim())
          .where((e) => e.length > 2)
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

/// Endless-queue refill trigger: when [upcoming] tracks remain at or
/// below this, the app layer appends a fresh related batch (see
/// repository.endlessRefillFor + playback.maybeRefill). Checked for ANY
/// played song — single-song queues refill too.
const int endlessRefillThreshold = 2;

/// Fresh endless batch size (matches the autoplay fill window).
const int endlessRefillMax = 20;

/// Pure refill check for call sites without an engine handy.
bool needsEndlessRefill(int upcoming, {int threshold = endlessRefillThreshold}) {
  try {
    return upcoming <= threshold;
  } catch (_) {
    return false;
  }
}

/// Best-in-class Up Next suggestion ranking (pure, deterministic with
/// [random]).
///
/// Signal stack, in order (mood/type FIRST — explicitly not same-singer
/// radio):
/// - mood/type fit ([discovery.moodFitScore]: same mood +4, same
///   language +2 / mismatch -1, energy proximity x2.5, same era +1.5,
///   title-keyword overlap +0.8/word cap 2.4, tempo agreement +1).
///   Cold starts (no taste) count the fit ×1.25 so one song still opens
///   instant mood radio.
/// - repo/discovery graph ([relatedIds], e.g. autoplayFor/related order)
///   consumed defensively: any discovery call failure falls back to the
///   local same-name/mood checks and the remaining signals still rank.
/// - multi-seed agreement ([coOccurrence]: tracks co-listened with
///   several seeds win superlinearly — linear 1.5 + quadratic 0.75).
/// - artist variety: the seed's own singer NEVER boosts (same artist -2);
///   token overlap only (+1/shared, cap 3) so "feat." cousins surface
///   without singer clumps.
/// - discovery affinities ([affinities] from [affinityFor], or [taste]
///   artist/mood affinity x2/x3): liked/recent artists float up.
/// - session context ([sessionContext], newest-first tail): the live
///   moment re-ranks on top of global taste (artist ×1.5, mood ×2.0).
/// - skip decay ([skipCounts] from [QueueEngine.noteSkipped]): first skip
///   -3, each repeat -2.5 more (floor -9); [skipIds] hard-drops (refill
///   never repeats a skip); [skipArtists] buries skipped singers -2.
/// - recency: [recentIds] (recently played) sink -3 each; [shownIds]
///   (already-surfaced suggestions) sink per impression.
/// - liked hits ([likedIds]) float +2.5.
/// - diversity caps ([maxPerArtist], default 2): at most N rows per
///   artist — same-artist capped at 1-2; [moodArc] resequences the picked
///   set as a mood arc (same tracks, variety walk, rails never empty).
///
/// Hard rules: seed + queued ids + skip ids + same-name echoes never
/// suggest. Returns at most [max] tracks, ranked best-first.
List<YtTrack> rankSuggestions({
  required YtTrack? seed,
  required List<YtTrack> pool,
  Set<String> queueIds = const {},
  Set<String> relatedIds = const {},
  Map<String, double> affinities = const {},
  Map<String, int> skipCounts = const {},
  Set<String> recentIds = const {},
  Set<String> skipIds = const {},
  Set<String> likedIds = const {},
  Set<String> shownIds = const {},
  Set<String> skipArtists = const {},
  Map<String, double> coOccurrence = const {},
  List<YtTrack> sessionContext = const [],
  discovery.TasteProfile? taste,
  bool moodArc = true,
  int? rotationSalt,
  int max = 5,
  int maxPerArtist = 2,
  Random? random,
}) {
  try {
    if (pool.isEmpty || max <= 0) return [];
    final rnd =
        random ?? (rotationSalt != null ? Random(rotationSalt) : Random());
    final sessAff = sessionContext.isEmpty
        ? const <String, double>{}
        : discovery.sessionAffinityFor(sessionContext);
    final sessMoods = sessionContext.isEmpty
        ? const <String, double>{}
        : discovery.sessionMoodsFor(sessionContext);
    final seen = <String>{};
    final deduped = <YtTrack>[];
    for (final t in pool) {
      try {
        if (t.id.isEmpty || !seen.add(t.id)) continue;
        deduped.add(t);
      } catch (_) {}
    }
    if (deduped.isEmpty) return [];

    String seedKey = '';
    Set<String> seedTokens = const {};
    try {
      if (seed != null) {
        seedKey = seed.artistKey();
        seedTokens = artistTokensOf(seed.displayArtist());
      }
    } catch (_) {}

    final scored = <(double, int, YtTrack)>[];
    for (final c in deduped) {
      try {
        if (seed != null && c.id == seed.id) continue;
        if (queueIds.contains(c.id)) continue;
        if (skipIds.contains(c.id)) continue;
        var sameName = false;
        if (seed != null) {
          try {
            sameName = discovery.isSameName(c, seed);
          } catch (_) {
            sameName = _sameNameFallback(c, seed);
          }
        }
        if (sameName) continue;

        var s = 0.0;
        if (relatedIds.contains(c.id)) s += 5;
        // Multi-seed agreement: co-listened tracks win superlinearly.
        try {
          final co = coOccurrence[c.id] ?? 0.0;
          if (co > 0) {
            s += co * discovery.tasteCoOccurWeight +
                co * co * discovery.tasteCoOccurQuad;
          }
        } catch (_) {}
        // Mood/type fit FIRST (taste-independent: cold single-song
        // queues still get mood radio, not singer radio; cold ×1.25).
        try {
          if (seed != null) {
            final fit = discovery.moodFitScore(seed, c);
            final cold = taste == null || taste.isEmpty;
            s += cold ? fit * discovery.tasteColdMoodBoost : fit;
          }
        } catch (_) {}
        try {
          final ck = c.artistKey();
          if (seedKey.isNotEmpty && ck == seedKey) {
            // Variety over clumps: the seed's own singer never dominates.
            s -= 2;
          } else if (seedTokens.isNotEmpty) {
            final ct = artistTokensOf(c.displayArtist());
            var shared = 0;
            for (final tok in ct) {
              if (seedTokens.contains(tok)) shared++;
            }
            if (shared > 3) shared = 3;
            s += shared * 1.0;
          }
          s += affinities[ck] ?? 0;
          try {
            if (taste != null) {
              s += taste.artistAffinity(c.artist) *
                  discovery.tasteArtistWeight;
              final tm = discovery.detectMood('${c.title} ${c.artist}');
              if (tm != null) {
                s += taste.moodAffinity(tm) * discovery.tasteMoodWeight;
              }
            }
          } catch (_) {}
          // Session context: the live moment on top of global taste.
          if (sessAff.isNotEmpty) {
            try {
              var best = 0.0;
              for (final k in discovery.tasteArtistKeys(c.artist)) {
                final v = sessAff[k] ?? 0.0;
                if (v > best) best = v;
              }
              s += best * discovery.tasteSessionArtistWeight;
            } catch (_) {}
          }
          if (sessMoods.isNotEmpty) {
            try {
              final m = discovery.detectMood('${c.title} ${c.artist}');
              if (m != null) {
                s += (sessMoods[m] ?? 0.0) *
                    discovery.tasteSessionMoodWeight;
              }
            } catch (_) {}
          }
          if (likedIds.contains(c.id)) {
            s += discovery.tasteLikedTrackBoost;
          }
        } catch (_) {}
        try {
          // Escalating skip decay: first skip buries (-3), repeats pile
          // on (floor -9) — dislikes stay buried.
          var skips = skipCounts[c.id] ?? 0;
          try {
            skips += taste?.skipCounts[c.id] ?? 0;
          } catch (_) {}
          if (skips > 0) {
            var pen =
                discovery.tasteSkipFirst + (skips - 1) * discovery.tasteSkipPerExtra;
            if (pen > 9) pen = 9;
            s -= pen;
          }
          if (skipArtists.isNotEmpty) {
            var hit = false;
            try {
              for (final k in discovery.tasteArtistKeys(c.artist)) {
                if (skipArtists.contains(k)) {
                  hit = true;
                  break;
                }
              }
            } catch (_) {}
            if (hit) s -= discovery.tasteSkipArtistPenalty;
          }
        } catch (_) {}
        try {
          if (recentIds.contains(c.id)) {
            s -= discovery.tasteRecentPenalty;
          }
        } catch (_) {}
        try {
          var shown = 0;
          try {
            shown += taste?.shownCounts[c.id] ?? 0;
          } catch (_) {}
          if (shownIds.contains(c.id)) shown += 1;
          if (shown > 0) {
            var pen = shown * discovery.tasteShownPerImpression;
            if (pen > discovery.tasteShownMax) {
              pen = discovery.tasteShownMax;
            }
            s -= pen;
          }
        } catch (_) {}
        scored.add((s, rnd.nextInt(1 << 30), c));
      } catch (_) {}
    }
    scored.sort((a, b) {
      final d = b.$1.compareTo(a.$1);
      return d != 0 ? d : a.$2.compareTo(b.$2);
    });
    final perArtist = <String, int>{};
    final picked = <(double, YtTrack)>[];
    final cap = maxPerArtist < 1 ? 1 : maxPerArtist;
    for (final e in scored) {
      if (picked.length >= max) break;
      try {
        final k = e.$3.artistKey();
        final n = (perArtist[k] ?? 0) + 1;
        if (n > cap) continue;
        perArtist[k] = n;
        picked.add((e.$1, e.$3));
      } catch (_) {}
    }
    if (moodArc) return discovery.arcOrder(picked).take(max).toList();
    return picked.map((e) => e.$2).toList();
  } catch (_) {
    // Total fallback: dedupe + queue filter, input order, artist cap.
    try {
      final perArtist = <String, int>{};
      final out = <YtTrack>[];
      final seenIds = <String>{};
      for (final t in pool) {
        if (out.length >= max) break;
        try {
          if (t.id.isEmpty || !seenIds.add(t.id)) continue;
          if (queueIds.contains(t.id)) continue;
          if (skipIds.contains(t.id)) continue;
          if (seed != null && t.id == seed.id) continue;
          final k = t.artistKey();
          final n = (perArtist[k] ?? 0) + 1;
          if (n > (maxPerArtist < 1 ? 1 : maxPerArtist)) continue;
          perArtist[k] = n;
          out.add(t);
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}
