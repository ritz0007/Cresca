// Trending tab (R1): Top videos Global + Hindi/International/Telugu/
// Punjabi video rails (7-day cache, parallel refresh). Video-first:
// the global chart rides repo.trendingVideoTracks (chart "video"
// shelf, rank order kept) and region rails ride defensive video
// searches (titles kept); every row/card opens the video player
// (video_sheet) on tap. Repository/state are never edited — all
// video calls here are defensive (timeout + fallback + silent catch).

import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import '../widgets/track_menu.dart';
import '../widgets/track_row.dart';
import '../widgets/player_sheet.dart';
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
  /// tap via video_sheet's muxed resolve. Never throws.
  Future<void> _loadVideoTop() async {
    try {
      if (_videoLoading) return;
      _videoLoading = true;
      final state = AppScope.of(context);
      const titles = ['Hindi', 'International', 'Telugu', 'Punjabi'];
      try {
        final futures = <Future>[
          state.repo
              .trendingVideoTracks(max: 25)
              .timeout(const Duration(seconds: 30))
              .catchError((_) => <YtTrack>[]),
          for (final t in titles)
            state.repo
                .searchVideos(
                    'top ${t.toLowerCase()} songs official music video',
                    max: 15)
                .timeout(const Duration(seconds: 30))
                .catchError((_) => <YtTrack>[]),
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
        });
      } catch (_) {}
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
        // Refresh dissolve mirrors home: rails fade behind the native
        // spinner while reloading (opacity only, motion-gated).
        final refreshing = state.trendingLoading &&
            (_topVideos.isNotEmpty ||
                state.trendingGlobal.isNotEmpty ||
                state.trendingRails.isNotEmpty);
        final dissolve = refreshing ? 0.35 : 1.0;
        final dissolveMs = state.motionMs(220);
        // Effective chart: video shelf first (rank kept), state chart
        // fallback (rank kept). Never re-sorted.
        final top =
            _topVideos.isNotEmpty ? _topVideos : state.trendingGlobal;
        final rails = state.trendingRails;
        final allEmpty = top.isEmpty && rails.isEmpty;
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
                    // Live measured clearance (210 fallback pre-measure).
                    padding: EdgeInsets.only(
                        bottom:
                            BottomChromeScope.clearanceOf(context)),
                    children: [
                      if (allEmpty &&
                          (state.trendingLoading || _videoLoading))
                        const _TrendSkeleton()
                      else if (allEmpty)
                        _TrendError(onRetry: _refresh)
                      else ...[
                        _Dissolve(
                          opacity: dissolve,
                          ms: dissolveMs,
                          child: _VideoGlobal(
                              tracks: top,
                              state: state,
                              loading: state.trendingLoading &&
                                  top.isEmpty,
                              onRetry: _refresh),
                        ),
                        for (var ri = 0;
                            ri < rails.length;
                            ri++)
                          _Dissolve(
                            opacity: dissolve,
                            ms: dissolveMs,
                            child: StaggerEntrance(
                              key: ValueKey(
                                  'trend-${rails[ri].section.title}'),
                              index: ri + 1,
                              child: _RegionRail(
                                title:
                                    rails[ri].section.title,
                                tracks: _railVideos[rails[ri]
                                            .section
                                            .title] ??
                                    rails[ri].tracks,
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
              const _TrendSkeleton()
            else
              _TrendError(onRetry: onRetry),
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
                track.title.toLowerCase().contains('official') ||
                        track.title.toLowerCase().contains('mv')
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

/// Home _ErrorCard pattern: honest offline message + Retry.
class _TrendError extends StatelessWidget {
  final VoidCallback onRetry;
  const _TrendError({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_outlined, size: 48),
            const SizedBox(height: 12),
            const Text(
                'Trending videos unavailable — check your connection.',
                textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
                onPressed: onRetry,
                child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// Skeleton rows while the first trending load is in flight.
class _TrendSkeleton extends StatelessWidget {
  const _TrendSkeleton();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: const [
        TrackSkeleton(),
        TrackSkeleton(),
        TrackSkeleton(),
        TrackSkeleton(),
      ],
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

/// Refresh dissolve: opacity-only fade behind the native spinner.
/// Duration is pre-collapsed via motionMs by the caller.
class _Dissolve extends StatelessWidget {
  final double opacity;
  final int ms;
  final Widget child;
  const _Dissolve(
      {required this.opacity, required this.ms, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: Duration(milliseconds: ms),
      opacity: opacity,
      child: child,
    );
  }
}
