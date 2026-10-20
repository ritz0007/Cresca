// Pure search-paint rules (U6): which rows paint, and which async
// completions may paint them. Zero Flutter imports so package:test
// pins the stale-guard without the widget closure. The screen calls
// both; the 10-queries-in-5s test drives [searchGenPaintable].
//
// Native ref: the gen-token in SearchScreen.kt (debounce decides when
// to fire, the token decides what may paint — dropping stale futures
// on arrival IS the cancellation).

import 'track.dart';

/// Which rows paint: while a query is set the live [rows] own the
/// list (even when empty — stale cache must never cover a fresh
/// query's empty state). With no query, cached rows fill the idle
/// list. Pure for tests. Never throws.
List<YtTrack> searchShownRows(
    {required String query,
    required List<YtTrack> rows,
    required List<YtTrack> cached}) {
  try {
    if (query.isNotEmpty) return rows;
    return rows.isEmpty ? cached : rows;
  } catch (_) {
    return const <YtTrack>[];
  }
}

/// Stale-guard gate: a completion may paint only when it is still the
/// latest generation AND the field still shows its query. The gen
/// covers debounce-to-completion races; the text check covers the
/// keystroke window before the next debounce fires (every keystroke
/// bumps the gen upstream of debounce). Pure for tests — [_run]-style
/// flows call this at every paint site. Never throws.
bool searchGenPaintable({
  required int gen,
  required int currentGen,
  required String fieldText,
  required String query,
}) {
  try {
    return gen == currentGen && fieldText == query;
  } catch (_) {
    return false;
  }
}
