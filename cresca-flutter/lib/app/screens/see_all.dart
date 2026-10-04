// See All full page (H11, not a sheet): endless pagination (search
// continuations), Play-all + Shuffle-play, `N loaded — tap for more`,
// warms next-8 on open. Rail variant extends via discovery paging.

import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../widgets/mini_player.dart';
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
            SeeAllScreen(title: title, staticTracks: tracks)));
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
  bool _loading = false;
  bool _exhausted = false;
  dynamic _pager;

  @override
  void initState() {
    super.initState();
    _tracks = List.of(
        widget.staticTracks ?? widget.initial);
    if (widget.staticTracks == null && widget.query.isNotEmpty) {
      _pager = AppScope.of(context)
          .repo
          .searchPager(widget.query, pageSize: 20);
      _more();
    }
    unawaited(_warm());
    _scroll.addListener(() {
      try {
        if (_scroll.position.pixels >
            _scroll.position.maxScrollExtent - 400) {
          _more();
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Warms next-8 on open (H11).
  Future<void> unawaited(Future<void> f) async {
    try {
      await f;
    } catch (_) {}
  }

  Future<void> _warm() async {
    try {
      final state = AppScope.of(context);
      for (final t in _tracks.take(8)) {
        try {
          await state.resolver.audioUrl(t.watchUrl);
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _more() async {
    try {
      if (_loading || _exhausted) return;
      if (_pager == null) {
        setState(() => _exhausted = true);
        return;
      }
      setState(() => _loading = true);
      final page = await _pager.loadMore();
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (page.isEmpty) {
          _exhausted = _pager.exhausted;
        } else {
          final seen = _tracks.map((e) => e.id).toSet();
          for (final t in page) {
            if (seen.add(t.id)) _tracks.add(t);
          }
          _exhausted = _pager.exhausted && page.isEmpty;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
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
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              itemCount: _tracks.length + 1,
              itemBuilder: (_, i) {
                if (i >= _tracks.length) {
                  if (_loading) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                          child: CircularProgressIndicator()),
                    );
                  }
                  if (!_exhausted && _pager != null) {
                    return TextButton(
                      onPressed: _more,
                      child: Text(
                          '${_tracks.length} loaded — tap for more'),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Center(
                        child: Text('${_tracks.length} loaded')),
                  );
                }
                return TrackRow(
                    track: _tracks[i],
                    contextQueue: _tracks,
                    index: i);
              },
            ),
          ),
          const MiniPlayer(),
        ],
      ),
    );
  }
}
