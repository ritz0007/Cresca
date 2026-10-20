// U6 transport-failure ledger: which search queries failed at transport,
// so the search screen raises Retry instead of "No results". Pure for
// tests — YoutubeRepository owns one; searchNow consults it before
// deciding that an empty result is a genuine empty. Zero Flutter
// imports so package:test pins the transitions without the widget
// closure. Transport failures are never cached (positive or negative);
// only the failure mark persists, cleared by the next successful fetch.

// Bounded set of normalized search keys whose last fetch threw.
// Insert-ordered: re-marked keys go last, oldest evicted past [cap].
// Pure. Never throws.
class SearchFailureLedger {
  final int cap;
  SearchFailureLedger({this.cap = 50});

  final List<String> _keys = [];

  /// True when [key]'s last fetch failed at transport.
  bool failed(String key) {
    try {
      return key.isNotEmpty && _keys.contains(key);
    } catch (_) {
      return false;
    }
  }

  /// Marks [key] failed (most-recent). Evicts oldest past [cap].
  void noteFailure(String key) {
    try {
      if (key.isEmpty) return;
      _keys.remove(key);
      _keys.add(key);
      while (_keys.length > cap) {
        _keys.removeAt(0);
      }
    } catch (_) {}
  }

  /// Clears [key]'s failure mark after any successful fetch — including
  /// a genuinely-empty one (definitive empty supersedes old failures).
  void noteSuccess(String key) {
    try {
      _keys.remove(key);
    } catch (_) {}
  }
}
