// Search tab (S1–S4): debounced (250ms) songs-only search, instant
// cached results first (session-mem → disk snapshot → network),
// suggestions (fast engine only) + artist row (channel lane with
// track-derived fallback), song rows + overflow menu. Stale in-flight
// queries are generation-guarded (late arrivals dropped); search +
// artist lanes fly in parallel; display-side songs-only gate mirrors
// the parse-side one. Debug timing logs trace query→paint.
// Motion: focus glow on the field (180ms), AnimatedSwitcher crossfade
// between idle/loading/results/empty (180ms), skeleton shimmer while
// loading, gentle empty-state fade/scale-in, staggered row entrance.
// Data/fetch logic unchanged.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/search_guard.dart';
import '../../core/track.dart';
import '../app.dart';
import '../state.dart';
import '../widgets/player_sheet.dart';
import '../widgets/state_widgets.dart';
import '../widgets/track_row.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  List<YtTrack> _rows = [];
  List<YtTrack> _cachedFirst = [];
  List<String> _suggestions = [];
  List<YtArtist> _artists = [];
  bool _loading = false;
  String _query = '';
  bool _focused = false;

  /// Last transport failure (the query that failed). Rows are never
  /// cleared on error: stale rows stay visible under an inline banner,
  /// and the full ErrorRetry shows only when the cache is empty.
  String _searchError = '';

  /// Stale-query guard: every [_run] bumps [_gen]; late arrivals whose
  /// generation mismatches are dropped. The repo has no cancel token,
  /// so dropping stale futures on arrival IS the cancellation.
  int _gen = 0;

  /// Instant session results: normalized query → painted rows (10 min
  /// TTL, 20-entry cap). Disk snapshots (searchCached) still paint on
  /// every keystroke; this skips the network entirely on repeats.
  final Map<String, List<YtTrack>> _mem = {};
  final Map<String, int> _memAt = {};
  static const int _memTtlMs = 10 * 60 * 1000;

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (mounted) setState(() => _focused = _focus.hasFocus);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        AppScope.of(context).onSearchFocusRequest = () {
          try {
            FocusScope.of(context).requestFocus(_focus);
          } catch (_) {}
        };
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    try {
      AppScope.of(context).onSearchFocusRequest = null;
    } catch (_) {}
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value, AppState state) {
    try {
      _debounce?.cancel();
      // Invalidate in-flight runs upstream of debounce: every keystroke
      // retires the previous generation, so only the latest query may
      // paint (the text check in _run covers the pre-fire window).
      _gen++;
      // Stale lane guard: the previous query's artists stay painted
      // while the new query loads — drop them on every keystroke
      // (the fresh lane rebuilds in _run). A new keystroke also
      // retires any previous transport error.
      if ((_artists.isNotEmpty || _searchError.isNotEmpty) && mounted) {
        setState(() {
          _artists = [];
          _searchError = '';
        });
      }
      // Instant cached results first (S1): session-mem paints
      // synchronously (zero async gap), then disk snapshots refresh.
      try {
        final key = value.trim().toLowerCase();
        final at = _memAt[key];
        if (at != null &&
            DateTime.now().millisecondsSinceEpoch - at < _memTtlMs) {
          final hit = _mem[key];
          if (hit != null && hit.isNotEmpty && mounted) {
            setState(() => _cachedFirst = List.of(hit));
          }
        }
      } catch (_) {}
      state.searchCached(value).then((c) {
        if (!mounted || value != _text.text) return;
        setState(() => _cachedFirst = _songsOnly(c ?? <YtTrack>[]));
      }).catchError((_) {});
      // Suggestions on every keystroke (fast engine only, S2).
      state.suggestions(value).then((s) {
        if (!mounted || value != _text.text) return;
        setState(() => _suggestions = s);
      }).catchError((_) {});
      // Debounced (250ms) songs-only search.
      _debounce = Timer(const Duration(milliseconds: 250), () {
        _run(value, state);
      });
    } catch (_) {}
  }

  Future<void> _run(String value, AppState state) async {
    try {
      final q = value.trim();
      final g = ++_gen;
      final t0 = DateTime.now().millisecondsSinceEpoch;
      if (q.isEmpty) {
        if (mounted) {
          setState(() {
            _rows = [];
            _cachedFirst = [];
            _artists = [];
            _loading = false;
            _query = '';
            _searchError = '';
          });
        }
        return;
      }
      // Repeat query within TTL: instant paint, zero round trips.
      try {
        final key = q.toLowerCase();
        final at = _memAt[key];
        if (at != null &&
            DateTime.now().millisecondsSinceEpoch - at < _memTtlMs) {
          final hit = _mem[key];
          if (hit != null && hit.isNotEmpty) {
            if (mounted && g == _gen) {
              setState(() {
                _rows = List.of(hit);
                _artists = _artistsFromTracks(hit);
                _loading = false;
                _query = q;
              });
            }
            if (kDebugMode) {
              debugPrint('[search] query="$q" mem-hit '
                  '${DateTime.now().millisecondsSinceEpoch - t0}ms '
                  'rows=${hit.length}');
            }
            return;
          }
        }
      } catch (_) {}
      if (mounted) {
        setState(() {
          _loading = true;
          _query = q;
        });
      }
      // Search + artist lanes fly together (were sequential: ~2 RTTs).
      // The channel lane only needs the query; its track-derived
      // fallback is rebuilt locally below, so no rows are passed up
      // front and nothing is lost.
      //
      // searchNow throws StateError on transport failure (single
      // caller): a failure keeps the stale rows and raises _searchError
      // — error reads as "couldn't load", never as empty.
      List<YtTrack> rawHits;
      // Futures are constructed before the guarded await so both lanes
      // fly together; transport failure is caught below.
      final hitsF = state.searchNow(q);
      final artistsF = state.artistsFor(q, const <YtTrack>[]);
      try {
        rawHits = await hitsF;
        if (!mounted ||
            !searchGenPaintable(
                gen: g,
                currentGen: _gen,
                fieldText: _text.text.trim(),
                query: q)) {
          return;
        }
      } catch (e, st) {
        try {
          unawaited(state.crash.log('search failed: $q', e, st));
        } catch (_) {}
        // Never clear on error: stale rows stay, banner/Retry raises.
        if (!mounted || g != _gen) return;
        setState(() {
          _loading = false;
          _searchError = q;
        });
        return;
      }
      final hits = _songsOnly(rawHits);
      var artists = <YtArtist>[];
      try {
        artists = await artistsF;
      } catch (_) {}
      if (!mounted ||
          !searchGenPaintable(
              gen: g,
              currentGen: _gen,
              fieldText: _text.text.trim(),
              query: q)) {
        return;
      }
      if (artists.isEmpty) artists = _artistsFromTracks(hits);
      _rememberMem(q, hits);
      if (!mounted || g != _gen) return;
      setState(() {
        _rows = hits;
        _artists = artists;
        _loading = false;
        _searchError = '';
      });
      if (kDebugMode) {
        debugPrint('[search] query="$q" network '
            '${DateTime.now().millisecondsSinceEpoch - t0}ms '
            'rows=${hits.length} artists=${artists.length}');
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Display-side songs-only gate (parse already drops non-song
  /// renderers in innertube.dart; this is the defensive pass over
  /// cached + mixed-source rows): 11-char ids, non-blank titles, no
  /// shorts/reels, no podcast/episode junk. Order-kept, deduped.
  /// Never throws.
  static List<YtTrack> _songsOnly(List<YtTrack> tracks) {
    try {
      final seen = <String>{};
      final out = <YtTrack>[];
      for (final t in tracks) {
        try {
          if (t.id.length != 11) continue;
          if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(t.id)) continue;
          if (t.title.trim().isEmpty) continue;
          // Mixed-source caches occasionally pair a row id with another
          // upload's watch URL — gibberish without this check. Rows with
          // no usable watch URL are kept (id + title already gated).
          try {
            final vid = extractVideoId(t.watchUrl);
            if (vid != null && vid != t.id) continue;
          } catch (_) {}
          if (isShortsUrl(t.watchUrl) ||
              isReelEndpoint(t.watchUrl)) {
            continue;
          }
          if (isMusicJunk(t.title, t.artist)) continue;
          if (seen.add(t.id)) out.add(t);
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const <YtTrack>[];
    }
  }

  /// Track-derived artist fallback (mirrors AppState.artistsFor when
  /// the channel lane comes back empty): distinct display artists,
  /// max 8. Never throws.
  static List<YtArtist> _artistsFromTracks(List<YtTrack> rows) {
    try {
      final seen = <String>{};
      final out = <YtArtist>[];
      for (final t in rows) {
        try {
          final a = t.displayArtist();
          if (a == 'Unknown Artist' || !seen.add(a.toLowerCase())) {
            continue;
          }
          out.add(YtArtist(name: a, thumbUrl: t.thumbUrl));
          if (out.length >= 8) break;
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const <YtArtist>[];
    }
  }

  void _rememberMem(String q, List<YtTrack> hits) {
    try {
      if (hits.isEmpty) return;
      final key = q.toLowerCase();
      _mem[key] = List.of(hits);
      _memAt[key] = DateTime.now().millisecondsSinceEpoch;
      while (_mem.length > 20) {
        final oldest = _memAt.keys.first;
        _mem.remove(oldest);
        _memAt.remove(oldest);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final shown =
        searchShownRows(query: _query, rows: _rows, cached: _cachedFirst);
    final switchMs = state.motionMs(180);
    // Keyboard inset: the scrollable list pads by viewInsets.bottom so
    // the keyboard never covers the tail rows.
    final kb = MediaQuery.of(context).viewInsets.bottom;
    // Body phase drives the crossfade: idle → loading (skeleton) →
    // results → empty. Transport failure with an empty cache is its
    // own 'error' phase (full ErrorRetry); failure over stale rows
    // keeps 'results' with an inline banner on top.
    final bool failed = _searchError.isNotEmpty && shown.isEmpty;
    final String phase;
    if (_loading && shown.isEmpty && !failed) {
      phase = 'loading';
    } else if (shown.isEmpty) {
      phase = _query.isEmpty ? 'idle' : (failed ? 'error' : 'empty');
    } else {
      phase = 'results';
    }
    final bool staleBanner = _searchError.isNotEmpty && shown.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        // iOS search field (CupertinoSearchTextField carries its own
        // clear button + activity indicator styling). Focus glow rides
        // an AnimatedContainer so focus in/out blends over 180ms.
        title: AnimatedContainer(
          duration: Duration(milliseconds: switchMs),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            // Tight glow: 6px blur reads the same on the field but
            // never runs a wide shadow pass while scrolling/typing.
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.35),
                      blurRadius: 6,
                      spreadRadius: 0,
                    ),
                  ]
                : const [],
          ),
          // Diagnosis: the tab icon (FloatingTabBar) and suggestion
          // chips already ride theme colors — the invisible one is the
          // SEARCH-FIELD icon. The field used CupertinoIcons glyphs for
          // its prefix/suffix; the Cupertino icon font isn't guaranteed
          // to be bundled (tofu/blank boxes where the magnifier + clear
          // should be). Both glyphs now come from the MaterialIcons
          // font (always bundled) with explicit scheme-derived colors,
          // so they stay legible in light AND dark mode.
          child: CupertinoSearchTextField(
            controller: _text,
            focusNode: _focus,
            placeholder: 'Search songs, artists',
            style: TextStyle(color: scheme.onSurface),
            placeholderStyle:
                TextStyle(color: scheme.onSurfaceVariant),
            backgroundColor: scheme.surfaceContainerHighest,
            prefixIcon: Icon(Icons.search,
                color: scheme.onSurfaceVariant),
            suffixIcon: Icon(Icons.cancel,
                color: scheme.onSurfaceVariant),
            onChanged: (v) => _onChanged(v, state),
            onSubmitted: (v) => _run(v, state),
            onSuffixTap: () {
              _text.clear();
              _run('', state);
            },
          ),
        ),
      ),
      body: Column(
        children: [
          // Slim progress row while a debounced search is in flight —
          // stale cached rows stay visible underneath.
          if (_loading)
            const LinearProgressIndicator(minHeight: 2),
          // Text query completions (fast-engine suggestions) as tappable
          // rows: tap re-runs the search for that query. Capped height
          // so song rows stay visible; the scrollable results list below
          // keeps the keyboard-safe padding.
          if (_suggestions.isNotEmpty && _text.text.trim().isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 192),
              // Plain Column, not a nested scrollable list inside the page
              // scroll (U6 de-nest).
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0;
                        i <
                            (_suggestions.length > 4
                                ? 4
                                : _suggestions.length);
                        i++)
                      _SuggestionRow(
                        text: _suggestions[i],
                        onTap: () {
                          final s = _suggestions[i];
                          _text.text = s;
                          _text.selection = TextSelection.collapsed(
                              offset: s.length);
                          setState(() => _suggestions = []);
                          _run(s, state);
                        },
                      ),
                  ],
                ),
              ),
            ),
          if (_artists.isNotEmpty)
            SizedBox(
              // Taller lane so 2-line names don't clip at 200%.
              height: 104,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _artists.length,
                itemBuilder: (_, i) {
                  final a = _artists[i];
                  // U6: artist rows carry a TalkBack label (U10 verifies).
                  return Semantics(
                    button: true,
                    label: 'Artist ${a.name}',
                    child: GestureDetector(
                    onTap: () {
                      // Tapping an artist opens its page (was: re-ran a
                      // "<name> songs" text search, so the tap never
                      // reached ArtistPage and looked broken).
                      try {
                        openArtistPage(
                          context,
                          YtTrack(
                              id: '',
                              title: '',
                              artist: a.name,
                              thumbUrl: a.thumbUrl,
                              watchUrl: ''),
                        );
                      } catch (_) {}
                    },
                    child: Container(
                      width: 72,
                      margin: const EdgeInsets.only(right: 8),
                      child: RepaintBoundary(
                        child: Column(
                          children: [
                            // Tight 48px decode (not the full upload):
                            // ~144px mem cache stays crisp on xxxhdpi.
                            SizedBox(
                              width: 48,
                              height: 48,
                              child: ClipOval(
                                child: a.thumbUrl.isEmpty
                                    ? Container(
                                        color: scheme
                                            .surfaceContainerHighest,
                                        child: Icon(Icons.person,
                                            color: scheme
                                                .onSurfaceVariant),
                                      )
                                    : CachedNetworkImage(
                                        imageUrl: a.thumbUrl,
                                        width: 48,
                                        height: 48,
                                        fit: BoxFit.cover,
                                        memCacheWidth: 144,
                                        memCacheHeight: 144,
                                        maxWidthDiskCache: 144,
                                        maxHeightDiskCache: 144,
                                        fadeInDuration: Duration(
                                            milliseconds:
                                                state.motionMs(150)),
                                        fadeOutDuration:
                                            const Duration(
                                                milliseconds: 1),
                                        errorWidget: (_, _, _) =>
                                            Container(
                                          color: scheme
                                              .surfaceContainerHighest,
                                          child: Icon(Icons.person,
                                              color: scheme
                                                  .onSurfaceVariant),
                                        ),
                                      ),
                              ),
                            ),
                            const SizedBox(height: 2),
                          Text(a.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onSurfaceVariant)),
                        ],
                        ),
                      ),
                    ),
                    ),
                  );
                },
              ),
            ),
          Expanded(
            child: Column(
              children: [
                // Inline banner over stale rows after a failed refresh;
                // full ErrorRetry (error phase) when the cache is empty.
                if (staleBanner)
                  InlineRetryBanner(
                    onRetry: () => _run(_text.text, state),
                  ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: Duration(milliseconds: switchMs),
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child:
                        _phaseBody(phase, shown, state, kb, context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _phaseBody(String phase, List<YtTrack> shown, AppState state,
      double kb, BuildContext context) {
    // Live measured chrome clearance (estimator fallback pre-measure) plus
    // the keyboard inset so the tail rows clear both.
    final clearance = BottomChromeScope.clearanceOf(context);
    switch (phase) {
      case 'loading':
        return ListView.builder(
          key: const ValueKey('search-loading'),
          padding: EdgeInsets.only(bottom: clearance + kb),
          itemCount: 8,
          itemBuilder: (_, _) => const TrackSkeleton(),
        );
      case 'error':
        // Transport failure, cache empty: deck copy names the scope,
        // Retry re-runs the field text. Never conflated with empty.
        return ErrorRetry(
          key: ValueKey('search-error-$_query'),
          message: "Couldn't load search for '$_query' — check connection",
          onRetry: () => _run(_text.text, state),
        );
      case 'empty':
        // True empty always echoes the query; one action clears it.
        return EmptyState(
          key: ValueKey('search-empty-$_query'),
          icon: Icons.music_off_outlined,
          title: "No results for '$_query'",
          actionLabel: 'Clear',
          onAction: () {
            _text.clear();
            _run('', state);
          },
        );
      case 'idle':
        return const EmptyState(
          key: ValueKey('search-idle'),
          icon: Icons.search_outlined,
          title: 'Search for songs and artists',
        );
      case 'results':
      default:
        return ListView.builder(
          // Bottom chrome is app-shell; scroll under the glass.
          key: ValueKey('search-results-$_query'),
          padding: EdgeInsets.only(bottom: clearance + kb),
          itemCount: shown.length,
          itemBuilder: (_, i) => StaggerEntrance(
            key: ValueKey('q=$_query:${shown[i].id}'),
            index: i,
            child: TrackRow(
                track: shown[i],
                contextQueue: shown,
                index: i,
                origin: 'Search'),
          ),
        );
    }
  }
}

/// One tappable query-completion row (extracted so the suggestion lane
/// is a plain Column, not a nested scrollable). Never throws.
class _SuggestionRow extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const _SuggestionRow({required this.text, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Search for $text',
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          try {
            onTap();
          } catch (_) {}
        },
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.search,
                  size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: scheme.onSurface)),
              ),
              Icon(Icons.north_west,
                  size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
