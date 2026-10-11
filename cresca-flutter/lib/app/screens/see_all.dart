// See All full page (H11, not a sheet): endless pagination (search
// continuations), Play-all + Shuffle-play, `N loaded — tap for more`,
// warms next-8 on open. Rail variant extends via discovery paging.

import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import '../widgets/track_row.dart';

Future<void> openSeeAllQuery(BuildContext context, String title,
    String query, {List<YtTrack>? initial}) async {
  try {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SeeAllScreen(
            title: title, query: query, initial: initial ?? [])));
  } catch (_) {}
}

Future<void> openSeeAllStatic(BuildContext context, String title,
    List<YtTrack> tracks, String query) async {
  try {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            SeeAllScreen(title: title, staticTracks: tracks, query: query)));
  } catch (_) {}
}

class SeeAllScreen extends StatefulWidget {
  final String title;
  final String query;
  final List<YtTrack> initial;
  final List<YtTrack>? staticTracks;
  const SeeAllScreen({
    super.key,
    required this.title,
    this.query = '',
    this.initial = const [],
    this.staticTracks,
  });

  @override
  State<SeeAllScreen> createState() => _SeeAllScreenState();
}

class _SeeAllScreenState extends State<SeeAllScreen> {
  final ScrollController _scroll = ScrollController();
  List<YtTrack> _tracks = [];
  List<YtTrack> _base = [];
  final Set<String> _seen = <String>{};
  bool _loading = false;
  bool _exhausted = false;
  bool _didInit = false;
  String _moreError = '';
  dynamic _pager;

  /// Only real search queries drive a continuation pager. Rail-internal
  /// tokens (`__browse__…`, `__browsepl__…`, `__related__…`, `__charts__`,
  /// `__charts_for_you__`, `__released__`) are cache keys, not searchable
  /// text — paging them would append unrelated results and break the
  /// page-one ordering gate. Those (and empty queries) stay finite with
  /// an honest end-of-list footer.
  String? _pageableQuery() {
    try {
      final q = widget.query.trim();
      if (q.isEmpty) return null;
      if (q.startsWith('__')) return null;
      return q;
    } catch (_) {
      return null;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didInit) return;
    _didInit = true;
    // Songs-only: rail/hero entry lists can carry non-playable cards
    // (cached/mixed sources) — gate before painting rows.
    try {
      _base = songsOnlyTracks(widget.staticTracks ?? widget.initial);
    } catch (_) {
      _base = <YtTrack>[];
    }
    _tracks = List<YtTrack>.of(_base);
    _seen.clear();
    for (final t in _tracks) {
      try {
        _seen.add(t.id);
      } catch (_) {}
    }
    _attachPager();
    _scroll.addListener(_onScroll);
    // Defer first fetch + warm to post-frame: AppScope depend is not
    // valid synchronously in initState, and the scroll metrics needed
    // for the fill check only exist after layout.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _warm();
      if (_pager != null) {
        _more();
      } else if (mounted) {
        // Finite list (pure static / internal-token rail): honest end.
        setState(() => _exhausted = true);
      }
    });
  }

  void _attachPager() {
    try {
      final q = _pageableQuery();
      if (q == null) {
        _pager = null;
        return;
      }
      _pager = AppScope.of(context).repo.searchPager(q, pageSize: 20);
    } catch (_) {
      _pager = null;
    }
  }

  @override
  void dispose() {
    try {
      _scroll.removeListener(_onScroll);
    } catch (_) {}
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Early trigger ~1 screen before the end so rows keep arriving
    // before the user reaches the tail.
    try {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      double viewport = 800;
      try {
        final v = pos.viewportDimension;
        if (v.isFinite && v > 0) viewport = v;
      } catch (_) {}
      final remaining = pos.maxScrollExtent - pos.pixels;
      if (remaining <= viewport + 200) _more();
    } catch (_) {}
  }

  void _maybeFill() {
    // Short lists may never fill the viewport, so the scroll trigger
    // would never fire — top up until the screen is full or we exhaust.
    try {
      if (!mounted || !_scroll.hasClients) return;
      if (_loading || _exhausted || _moreError.isNotEmpty) return;
      if (_pager == null) return;
      final pos = _scroll.position;
      double viewport = 800;
      try {
        final v = pos.viewportDimension;
        if (v.isFinite && v > 0) viewport = v;
      } catch (_) {}
      if (pos.maxScrollExtent <= viewport * 1.5) _more();
    } catch (_) {}
  }

  /// Warms next-8 on open (H11).
  Future<void> _warm() async {
    try {
      // One parallel primeNext over the first screen (H11): bundles
      // land in urlCache + bundle memo, so taps resolve with zero
      // new POSTs. Batches of 3, self-bounded; never throws.
      final state = AppScope.of(context);
      await state.resolver.primeNext(_tracks.take(8).toList());
    } catch (_) {}
  }

  Future<void> _refresh() async {
    try {
      final q = _pageableQuery();
      if (q == null) {
        // Finite list: reset to the base snapshot, no network.
        if (!mounted) return;
        setState(() {
          _tracks = List<YtTrack>.of(_base);
          _seen.clear();
          for (final t in _tracks) {
            try {
              _seen.add(t.id);
            } catch (_) {}
          }
          _moreError = '';
          _exhausted = true;
          _loading = false;
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _moreError = '';
        _exhausted = false;
        _tracks = List<YtTrack>.of(_base);
        _seen.clear();
        for (final t in _tracks) {
          try {
            _seen.add(t.id);
          } catch (_) {}
        }
      });
      _attachPager();
      await _more();
    } catch (_) {}
  }

  Future<void> _more([int hop = 0]) async {
    try {
      // Single-flight guard: concurrent scroll ticks join by dropping;
      // the post-frame fill check re-triggers while content is short.
      if (_loading || _exhausted) return;
      final pager = _pager;
      if (pager == null) {
        if (mounted) setState(() => _exhausted = true);
        return;
      }
      if (mounted) {
        setState(() {
          _loading = true;
          _moreError = '';
        });
      } else {
        return;
      }
      dynamic rawDyn;
      try {
        rawDyn = await pager.loadMore();
      } catch (_) {
        rawDyn = null;
      }
      if (!mounted) return;
      final List<YtTrack> raw = rawDyn is List
          ? rawDyn.whereType<YtTrack>().toList()
          : <YtTrack>[];
      bool exhaustedNow = false;
      try {
        exhaustedNow = (pager.exhausted as bool?) ?? false;
      } catch (_) {
        exhaustedNow = false;
      }
      if (raw.isEmpty) {
        if (exhaustedNow) {
          setState(() {
            _loading = false;
            _exhausted = true;
          });
        } else {
          // Pager swallows transport errors into [] without flipping
          // exhausted — surface Retry instead of a false end-of-list.
          setState(() {
            _loading = false;
            _moreError = 'Couldn’t load more — check your connection.';
          });
        }
        return;
      }
      // Songs-only: pager continuations can surface non-playable
      // rows — gate before merging, order kept, no dupes across pages.
      List<YtTrack> clean;
      try {
        clean = songsOnlyTracks(raw);
      } catch (_) {
        clean = <YtTrack>[];
      }
      var added = 0;
      for (final t in clean) {
        try {
          if (_seen.add(t.id)) {
            _tracks.add(t);
            added++;
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _exhausted = exhaustedNow;
      });
      if (added == 0 && !exhaustedNow && hop < 3) {
        // Whole page was dupes/filtered: transparently pull the next
        // continuation instead of stalling on a no-growth footer.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _more(hop + 1);
        });
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFill());
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _moreError = 'Couldn’t load more — check your connection.';
        });
      }
    }
  }

  Widget _footer(BuildContext context) {
    if (_loading) {
      // Bottom skeleton holds layout while the next page flies in:
      // same row height as real rows, so the tail never jumps.
      return const Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TrackSkeleton(),
          TrackSkeleton(),
          TrackSkeleton(),
        ],
      );
    }
    if (_moreError.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_moreError,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error)),
            const SizedBox(height: 8),
            TextButton(
              style: TextButton.styleFrom(
                  minimumSize: const Size(64, 48)),
              onPressed: _more,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    if (!_exhausted && _pager != null) {
      return TextButton(
        style:
            TextButton.styleFrom(minimumSize: const Size(64, 48)),
        onPressed: _more,
        child: Text('${_tracks.length} loaded — tap for more'),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Center(child: Text('${_tracks.length} songs')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final initialLoading =
        _tracks.isEmpty && _loading && _moreError.isEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: StaggerEntrance(
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      style: spotifyPlayStyle(),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Play all'),
                      onPressed: _tracks.isEmpty
                          ? null
                          : () => state.actPlay(_tracks, 0),
                    ),
                  ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.shuffle),
                    label: const Text('Shuffle play'),
                    onPressed: _tracks.isEmpty
                        ? null
                        : () {
                            final order = List<int>.generate(
                                _tracks.length, (i) => i)
                              ..shuffle();
                            state.actPlay(
                                [for (final i in order) _tracks[i]],
                                0);
                          },
                  ),
                ),
              ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _refresh,
              child: initialLoading
                  ? ListView.builder(
                      physics:
                          const AlwaysScrollableScrollPhysics(),
                      padding: EdgeInsets.only(
                          bottom:
                              BottomChromeScope.clearanceOf(context)),
                      itemCount: 8,
                      itemBuilder: (_, i) =>
                          const TrackSkeleton(),
                    )
                  : ListView.builder(
                controller: _scroll,
                physics:
                    const AlwaysScrollableScrollPhysics(),
                // Bottom chrome is app-shell; live measured clearance
                // (210 fallback) so the tail row never slides under it.
                padding: EdgeInsets.only(
                    bottom: BottomChromeScope.clearanceOf(context)),
                itemCount: _tracks.length + 1,
                itemBuilder: (_, i) {
                  if (i >= _tracks.length) return _footer(context);
                   return StaggerEntrance(
                    index: i,
                    child: TrackRow(
                        track: _tracks[i],
                        contextQueue: _tracks,
                        index: i,
                        origin: 'Search'),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
