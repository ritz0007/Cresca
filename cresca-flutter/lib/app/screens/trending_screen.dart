// Trending tab (R1): Top videos Global + Hindi/International/Telugu/
// Punjabi video rails (7-day cache, parallel refresh). Video-first:
// the global chart rides repo.trendingVideoTracks (chart "video"
// shelf, rank order kept) and region rails ride defensive video
// searches (titles kept); every row/card opens the video player
// (video_sheet) on tap. Repository/state are never edited — all
// video calls here are defensive (timeout + fallback + silent catch).

import 'package:flutter/material.dart';

import '../../core/rail_slots.dart';
import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import '../widgets/track_menu.dart';
import '../widgets/track_row.dart';
import '../widgets/player_sheet.dart';
import '../widgets/state_widgets.dart';
import 'see_all.dart';

class TrendingScreen extends StatefulWidget {
  const TrendingScreen({super.key});

  @override
  State<TrendingScreen> createState() => _TrendingScreenState();
}

class _TrendingScreenState extends State<TrendingScreen> {
  /// Video-first lists. Rank order is whatever the repository returned
  /// (shelf rank / search rank) — never re-sorted here.
  List<YtTrack> _topVideos = [];
  final Map<String, List<YtTrack>> _railVideos = {};
  bool _videoLoading = false;

  /// U6 per-rail status for the video fetches: 'global' + rail titles
  /// whose fetch threw. Rebuilt per load (success clears). Combined
  /// with state.trendingFailedRails for the in-place banners.
  Set<String> _videoFailed = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final state = AppScope.of(context);
        if (state.trendingGlobal.isEmpty) {
          state.loadTrending();
        }
      } catch (_) {}
      _loadVideoTop();
    });
  }

  /// Defensive video fetch: chart video shelf + one video search per
  /// region rail, in parallel. Any failure falls back to the
  /// state (audio-chart) lists, which still open the video player on
  /// tap via video_sheet's muxed resolve. Failures are recorded per
  /// rail in _videoFailed (success clears) for the in-place banners.
  /// Never throws.
  Future<void> _loadVideoTop() async {
    try {
      if (_videoLoading) return;
      _videoLoading = true;
      final state = AppScope.of(context);
      const titles = trendingRailTitles;
      final failed = <String>{};
      Future<List<YtTrack>> guardVideo(
          String key, Future<List<YtTrack>> f) async {
        try {
          final r = await f.timeout(const Duration(seconds: 30));
          if (r.isEmpty) failed.add(key);
          return r;
        } catch (_) {
          failed.add(key);
          return <YtTrack>[];
        }
      }
      try {
        final futures = <Future>[
          guardVideo('global', state.repo.trendingVideoTracks(max: 25)),
          for (final t in titles)
            guardVideo(
                t,
                state.repo.searchVideos(
                    'top ${t.toLowerCase()} songs official music video',
                    max: 15)),
        ];
        final results = await Future.wait(futures);
        if (!mounted) return;
        setState(() {
          try {
            final top = (results[0] as List<YtTrack>);
            if (top.isNotEmpty) _topVideos = top;
          } catch (_) {}
          try {
            for (var i = 0; i < titles.length; i++) {
              final vids = (results[i + 1] as List<YtTrack>);
              if (vids.isNotEmpty) _railVideos[titles[i]] = vids;
            }
          } catch (_) {}
          _videoFailed = failed;
        });
      } catch (_) {
        if (mounted) setState(() => _videoFailed = failed);
      }
      _videoLoading = false;
    } catch (_) {
      _videoLoading = false;
    }
  }

  Future<void> _refresh() async {
    try {
      final state = AppScope.of(context);
      await state.loadTrending(force: true);
    } catch (_) {}
    await _loadVideoTop();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        // Effective chart: video shelf first (rank kept), state chart
        // fallback (rank kept). Never re-sorted.
        final top =
            _topVideos.isNotEmpty ? _topVideos : state.trendingGlobal;
        // Canonical rail slots in paint order (trendingRailTitles): each
        // resolves to video tracks, else state tracks, else — when that
        // rail's fetch failed and nothing is loading — an in-place
        // InlineRetryBanner. One rail's 403 never blanks its siblings.
        final anyLoading = state.trendingLoading || _videoLoading;
        final stateTracks = <String, List<YtTrack>>{};
        for (final r in state.trendingRails) {
          try {
            stateTracks[r.section.title] = r.tracks;
          } catch (_) {}
        }
        final slots = resolveRailSlots(
          titles: trendingRailTitles,
          primary: _railVideos,
          fallback: stateTracks,
          failedPrimary: _videoFailed,
          failedFallback: state.trendingFailedRails,
        );
        final anyTracks =
            top.isNotEmpty || slots.any((s) => s.tracks.isNotEmpty);
        final anyFailed = _videoFailed.isNotEmpty ||
            state.trendingFailedRails.isNotEmpty;
        // Refresh dissolve mirrors home: rails fade behind the native
        // spinner while reloading (opacity only, motion-gated).
        final dissolve = (anyLoading && anyTracks) ? 0.35 : 1.0;
        final dissolveMs = state.motionMs(220);
        return Scaffold(
          appBar: AppBar(
            title: const Text('Trending'),
            actions: [
              if (state.trendingLoading)
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                      width: 20,
                      height: 20,
                      child:
                          CircularProgressIndicator(strokeWidth: 2)),
                ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    // Bottom chrome is app-shell; scroll under the glass.
                    // Live measured clearance (estimator fallback pre-measure).
                    padding: EdgeInsets.only(
                        bottom:
                            BottomChromeScope.clearanceOf(context)),
                    children: [
                      if (!anyTracks && anyLoading)
                        const LoadingState()
                      else if (!anyTracks)
                        // Page-level failure (all rails): full ErrorRetry
                        // with deck copy. Mixed failure banners per rail.
                        ErrorRetry(
                          message:
                              "Couldn't load 'Trending' — check connection",
                          onRetry: _refresh,
                        )
                      else ...[
                        // Stale-rows refresh failure: one banner on top,
                        // content underneath stays interactive.
                        if (anyFailed && !anyLoading)
                          InlineRetryBanner(onRetry: _refresh),
                        Dissolve(
                          opacity: dissolve,
                          ms: dissolveMs,
                          child: _VideoGlobal(
                              tracks: top,
                              state: state,
                              loading: anyLoading && top.isEmpty,
                              onRetry: _refresh),
                        ),
                        for (var i = 0; i < slots.length; i++)
                          if (slots[i].tracks.isNotEmpty)
                            Dissolve(
                              opacity: dissolve,
                              ms: dissolveMs,
                              child: StaggerEntrance(
                                key: ValueKey(
                                    'trend-${slots[i].title}'),
                                index: i + 1,
                                child: _RegionRail(
                                  title: slots[i].title,
                                  tracks: slots[i].tracks,
                                ),
                              ),
                            )
                          else if (slots[i].failed && !anyLoading)
                            Dissolve(
                              opacity: dissolve,
                              ms: dissolveMs,
                              child: StaggerEntrance(
                                key: ValueKey(
                                    'trend-${slots[i].title}-retry'),
                                index: i + 1,
                                child: _RailRetry(
                                  title: slots[i].title,
                                  onRetry: _refresh,
                                ),
                              ),
                            ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// In-place per-rail failure: the rail's title names the scope, Retry
/// re-runs the same loader as the page. Never throws.
class _RailRetry extends StatelessWidget {
  final String title;
  final VoidCallback onRetry;
  const _RailRetry({required this.title, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 17, fontWeight: FontWeight.w600)),
          InlineRetryBanner(
            message: "Couldn't load '$title' — check connection",
            onRetry: onRetry,
          ),
        ],
      ),
    );
  }
}

/// Ranked global chart: rank number + video row. Every tap opens the
/// video player (video_sheet). Rank order is the list order — kept.
class _VideoGlobal extends StatelessWidget {
  final List<YtTrack> tracks;
  final AppState state;
  final bool loading;
  final VoidCallback onRetry;
  const _VideoGlobal(
      {required this.tracks,
      required this.state,
      required this.loading,
      required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Top 100 Global',
                    style:
                        Theme.of(context).textTheme.titleLarge),
              ),
              if (tracks.isNotEmpty)
                TextButton(
                  onPressed: () => openSeeAllStatic(
                      context, 'Top 100 Global', tracks, ''),
                  child: const Text('See All'),
                ),
            ],
          ),
          if (tracks.isEmpty)
            if (loading)
              const LoadingState(itemCount: 4)
            else
              ErrorRetry(
                message:
                    "Couldn't load 'Top 100 Global' — check connection",
                onRetry: onRetry,
              ),
          for (var i = 0;
              i < (tracks.length > 10 ? 10 : tracks.length);
              i++)
            StaggerEntrance(
              index: i,
              child: Row(
                children: [
                  SizedBox(
                    width: 28,
                    child: Text('${i + 1}',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium),
                  ),
                  Expanded(
                    child: _VideoRankRow(
                        track: tracks[i],
                        queue: tracks,
                        index: i),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Ranked video row: art + title + artist, tap opens the video
/// player. Overflow menu keeps the identical row actions (M1).
class _VideoRankRow extends StatelessWidget {
  final YtTrack track;
  final List<YtTrack> queue;
  final int index;
  const _VideoRankRow(
      {required this.track, required this.queue, required this.index});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final low = track.title.toLowerCase();
    // RepaintBoundary: ranked rows rebuild on AppState notifies —
    // keep each row out of the list's repaint scope.
    return RepaintBoundary(
      child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        try {
          // Video rows play in the player sheet with video mode on
          // (YTM parity): queue starts here, picture in the art slot.
          state.actPlay(queue, index, origin: 'Trending');
          openPlayerSheet(context, video: true);
        } catch (_) {}
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: TrackArt(track: track, size: 48),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AdaptiveText(
                      data: track.title,
                      background: scheme.surface,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600)),
                  AdaptiveText(
                      data: track.displayArtist(),
                      background: scheme.surface,
                      secondary: true,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
            Icon(
                low.contains('official') || low.contains('mv')
                    ? Icons.play_circle_outline
                    : Icons.music_video_outlined,
                color: scheme.onSurfaceVariant),
            SizedBox(
              width: 48,
              height: 48,
              child: IconButton(
                icon: const Icon(Icons.more_vert),
                color: scheme.onSurfaceVariant,
                tooltip: 'More actions',
                onPressed: () =>
                    showTrackMenu(context, state, track, queue),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}

/// Home _PickCard language: rounded art with title + artist overlaid
/// on a deep bottom scrim. Tap opens the video player.
class _TrendCard extends StatelessWidget {
  final YtTrack track;
  final List<YtTrack> queue;
  final int index;
  const _TrendCard(
      {required this.track,
      required this.queue,
      required this.index});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    // Single scrim layer (TextScrim only); tight 4px text shadows so
    // dense rails never run a wide blur per card per frame.
    return GestureDetector(
      onTap: () {
        try {
          state.actPlay(queue, index, origin: 'Trending');
          openPlayerSheet(context, video: true);
        } catch (_) {}
      },
      child: RepaintBoundary(
        child: Container(
        width: 150,
        margin: const EdgeInsets.only(right: 10, top: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Stack(
            fit: StackFit.expand,
            children: [
              TrackArt(track: track, size: 150),
              // Text over artwork: light scrim + colors derived
              // from the dark scrim base (non-text paint stops ok).
              // Legibility rides shadow + AdaptiveText, not a wash.
              TextScrim(
                scrim: const [
                  Color(0xB3000000),
                  Color(0x66000000),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.35, 0.8],
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(
                        left: 10, right: 10, bottom: 10),
                    child: Column(
                      crossAxisAlignment:
                          CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        AdaptiveText(
                            data: track.title,
                            background: Colors.black,
                            maxLines: 2,
                            overflow:
                                TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight:
                                    FontWeight.w700,
                                shadows: [
                                  Shadow(
                                      color: Colors.black,
                                      blurRadius: 4)
                                ])),
                        AdaptiveText(
                            data: track.displayArtist(),
                            background: Colors.black,
                            secondary: true,
                            maxLines: 2,
                            overflow:
                                TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11.5,
                                shadows: [
                                  Shadow(
                                      color: Colors.black,
                                      blurRadius: 4)
                                ])),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}

class _RegionRail extends StatelessWidget {
  final String title;
  final List<YtTrack> tracks;
  const _RegionRail({required this.title, required this.tracks});

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    final surface = Theme.of(context).colorScheme.surface;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      AdaptiveText(
                          data: title,
                          background: surface,
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600)),
                      AdaptiveText(
                          data: 'Music videos',
                          background: surface,
                          secondary: true,
                          style:
                              const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => openSeeAllStatic(
                      context, title, tracks, ''),
                  child: const Text('See All'),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 208,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16),
              itemCount: tracks.length,
              itemBuilder: (_, i) => StaggerEntrance(
                index: i,
                child: _TrendCard(
                    track: tracks[i],
                    queue: tracks,
                    index: i),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
