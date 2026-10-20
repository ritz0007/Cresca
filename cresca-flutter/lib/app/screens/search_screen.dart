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

import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import '../widgets/player_sheet.dart';
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
      // U2: first focus dismisses the shell's "Tap to type" chip for
      // the rest of the session (flag lives in AppState, not persisted).
      if (_focus.hasFocus) {
        try {
          AppScope.of(context).dismissSearchHint();
        } catch (_) {}
      }
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
            _artists = [];
            _loading = false;
            _query = '';
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
      final hitsF = state.searchNow(q);
      final artistsF = state.artistsFor(q, const <YtTrack>[]);
      final rawHits = await hitsF;
      if (!mounted || g != _gen || _text.text.trim() != q) return;
      final hits = _songsOnly(rawHits);
      var artists = <YtArtist>[];
      try {
        artists = await artistsF;
      } catch (_) {}
      if (!mounted || g != _gen || _text.text.trim() != q) return;
      if (artists.isEmpty) artists = _artistsFromTracks(hits);
      _rememberMem(q, hits);
      if (!mounted || g != _gen) return;
      setState(() {
        _rows = hits;
        _artists = artists;
        _loading = false;
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
    final shown = _rows.isEmpty ? _cachedFirst : _rows;
    final switchMs = state.motionMs(180);
    // Keyboard inset: the scrollable list pads by viewInsets.bottom so
    // the keyboard never covers the tail rows.
    final kb = MediaQuery.of(context).viewInsets.bottom;
    // Body phase drives the crossfade: idle → loading (skeleton) →
    // results → empty. Keyed child so AnimatedSwitcher blends states.
    final String phase;
    if (_loading && shown.isEmpty) {
      phase = 'loading';
    } else if (shown.isEmpty) {
      phase = _query.isEmpty ? 'idle' : 'empty';
    } else {
      phase = 'results';
    }
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
                    // U2: focus ring rides Spotify green (== scheme
                    // primary in both modes; pinned explicitly).
                    BoxShadow(
                      color: spotifyGreen.withValues(alpha: 0.35),
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
            // U2: never steal focus on tab switch (screen-reader flow);
            // focus only on explicit tap (hint chip tap).
            autofocus: false,
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
              child: ListView.builder(
                shrinkWrap: true,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _suggestions.length > 4
                    ? 4
                    : _suggestions.length,
                itemBuilder: (_, i) {
                  final s = _suggestions[i];
                  return Semantics(
                    button: true,
                    label: 'Search for $s',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        _text.text = s;
                        _text.selection = TextSelection.collapsed(
                            offset: s.length);
                        setState(() => _suggestions = []);
                        _run(s, state);
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 10),
                        child: Row(
                          children: [
                            Icon(Icons.search,
                                size: 20,
                                color: scheme.onSurfaceVariant),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(s,
                                  maxLines: 1,
                                  overflow:
                                      TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color:
                                          scheme.onSurface)),
                            ),
                            Icon(Icons.north_west,
                                size: 18,
                                color: scheme.onSurfaceVariant),
                          ],
                        ),
                      ),
                    ),
                  );
                },
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
                  return GestureDetector(
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
                  );
                },
              ),
            ),
          Expanded(
            child: AnimatedSwitcher(
              duration: Duration(milliseconds: switchMs),
              transitionBuilder: (child, anim) =>
                  FadeTransition(opacity: anim, child: child),
              child: _phaseBody(phase, shown, state, kb, context),
            ),
          ),
        ],
      ),
    );
  }

  Widget _phaseBody(String phase, List<YtTrack> shown, AppState state,
      double kb, BuildContext context) {
    // Live measured chrome clearance (210 fallback pre-measure) plus
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
      case 'empty':
        return _SearchEmpty(
          key: ValueKey('search-empty-$_query'),
          icon: Icons.music_off_outlined,
          text: 'No results — try another query',
        );
      case 'idle':
        return const _SearchEmpty(
          key: ValueKey('search-idle'),
          icon: Icons.search_outlined,
          text: 'Search for songs and artists',
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

/// Gentle empty-state: fade + scale 0.97→1 in, one-shot, static when
/// motion is off. Transform/opacity only.
class _SearchEmpty extends StatefulWidget {
  final IconData icon;
  final String text;
  const _SearchEmpty({super.key, required this.icon, required this.text});

  @override
  State<_SearchEmpty> createState() => _SearchEmptyState();
}

class _SearchEmptyState extends State<_SearchEmpty> {
  bool _in = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _in = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    bool on = true;
    int ms = 220;
    try {
      final s = AppScope.of(context);
      on = s.motionOn;
      ms = s.motionMs(220);
    } catch (_) {}
    final body = Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(widget.icon,
                size: 56,
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant),
            const SizedBox(height: 12),
            Text(widget.text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
    if (!on) return body;
    return AnimatedOpacity(
      duration: Duration(milliseconds: ms),
      opacity: _in ? 1 : 0,
      child: AnimatedScale(
        duration: Duration(milliseconds: ms),
        scale: _in ? 1.0 : 0.97,
        child: body,
      ),
    );
  }
}
