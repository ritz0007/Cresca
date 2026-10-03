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
    items.add(t);
    order.add(items.length - 1);
  }

  void playNext(YtTrack t) {
    if (items.isEmpty || currentIndex == -1) {
      items.add(t);
      final i = items.length - 1;
      if (!order.contains(i)) order.add(i);
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
