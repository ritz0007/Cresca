// 128-entry LRU memo for lyric results (BitChord LyricsRepository
// memo parity). Pure Dart, no dependencies.

import 'dart:collection';

/// Fixed-capacity LRU map: reads refresh recency, writes evict the
/// least-recently-used entry past [capacity].
class LruMemo<K, V> {
  final int capacity;
  final LinkedHashMap<K, V> _m = LinkedHashMap<K, V>();

  LruMemo([this.capacity = 128]);

  V? get(K key) {
    try {
      if (!_m.containsKey(key)) return null;
      final v = _m.remove(key) as V;
      _m[key] = v;
      return v;
    } catch (_) {
      return null;
    }
  }

  void put(K key, V value) {
    try {
      _m.remove(key);
      _m[key] = value;
      while (_m.length > capacity) {
        _m.remove(_m.keys.first);
      }
    } catch (_) {}
  }

  bool containsKey(K key) {
    try {
      return _m.containsKey(key);
    } catch (_) {
      return false;
    }
  }

  int get length {
    try {
      return _m.length;
    } catch (_) {
      return 0;
    }
  }

  void clear() {
    try {
      _m.clear();
    } catch (_) {}
  }
}

/// Memo key: normalized artist + title + exact duration.
String lyricsMemoKey(String artist, String title, int durationMs) {
  try {
    return '${artist.toLowerCase().trim()}\x00'
        '${title.toLowerCase().trim()}\x00$durationMs';
  } catch (_) {
    return '\x00\x00$durationMs';
  }
}
