// Home tab (H1–H10): header + spinner + pull hint, hard-pull refresh,
// Top Picks + Play-all/Shuffle + See All, rails, moods → deep-search,
// hero Play/Shuffle, skeleton shimmer first load, honest offline error
// + Retry, discovery endless rails.

import 'package:flutter/material.dart';

import '../../core/home_feed.dart';
import '../../core/track.dart';
import '../app.dart';
import '../state.dart';
import '../widgets/mini_player.dart';
import '../widgets/track_row.dart';
import 'see_all.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ScrollController _scroll = ScrollController();
  double _pull = 0;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    final state = AppScope.of(context);
    if (state.topPicks.isEmpty && state.rails.isEmpty) {
      state.loadHome();
    }
    _scroll.addListener(() {
      try {
        final max = _scroll.position.maxScrollExtent;
        if (max > 0 &&
            _scroll.position.pixels > max - 400) {
          AppScope.of(context).loadMoreDiscovery();
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n, AppState state) {
    try {
      // Custom hard-pull: >200px overscroll at the pinned top arms a
      // refresh on release (H2, 3-state indicator).
      if (n is OverscrollNotification && n.overscroll < 0) {
        if (_scroll.position.pixels <=
            _scroll.position.minScrollExtent + 1) {
          setState(() {
            _pull = (-n.overscroll).clamp(0.0, 260.0);
            _armed = _pull > 200;
          });
        }
      } else if (n is ScrollEndNotification) {
        if (_armed) {
          setState(() {
            _armed = false;
            _pull = 0;
          });
          state.hardRefresh();
        } else if (_pull > 0) {
          setState(() => _pull = 0);
        }
      }
    } catch (_) {}
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) => Scaffold(
        body: NotificationListener<ScrollNotification>(
          onNotification: (n) => _onScroll(n, state),
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverAppBar(
                pinned: true,
                title: const Text('Listen Now'),
                actions: [
                  if (state.homeStatus == HomeStatus.loading)
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2)),
                    ),
                ],
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    _armed
                        ? 'Release to refresh'
                        : _pull > 0
                            ? 'Pull down hard to refresh'
                            : state.homeStatus ==
                                    HomeStatus.loading
                                ? 'Loading…'
                                : 'Pull down hard to refresh',
                    style:
                        Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
              if (state.homeStatus == HomeStatus.loading &&
                  state.topPicks.isEmpty)
                const SliverListSkeleton(),
              if (state.homeStatus == HomeStatus.error &&
                  state.topPicks.isEmpty &&
                  state.rails.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: _ErrorCard(
                    message: state.homeError,
                    onRetry: () => state.loadHome(force: true),
                  ),
                ),
              if (state.topPicks.isNotEmpty) ...[
                SliverToBoxAdapter(
                    child: _TopPicks(tracks: state.topPicks)),
                SliverToBoxAdapter(
                    child: _HeroCard(tracks: state.topPicks)),
              ],
              SliverToBoxAdapter(child: _Moods(state: state)),
              for (final rail in state.rails)
                SliverToBoxAdapter(
                    child: _Rail(rail: rail, state: state)),
            ],
          ),
        ),
        bottomNavigationBar: const MiniPlayer(),
      ),
    );
  }
}

class SliverListSkeleton extends StatelessWidget {
  const SliverListSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return SliverList.builder(
      itemCount: 8,
      itemBuilder: (_, _) => const TrackSkeleton(),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorCard({required this.message, required this.onRetry});

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
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(
                onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}

/// Top Picks + Play-all + Shuffle + See All (H3).
class _TopPicks extends StatelessWidget {
  final List<YtTrack> tracks;
  const _TopPicks({required this.tracks});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(state.topSeed.title,
                    style: Theme.of(context).textTheme.titleLarge),
              ),
              TextButton(
                  onPressed: () => openSeeAllQuery(
                      context, state.topSeed.title, state.topSeed.query,
                      initial: tracks),
                  child: const Text('See All')),
            ],
          ),
          Text(state.topSeed.subtitle,
              style: Theme.of(context).textTheme.bodySmall),
          Row(
            children: [
              FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('Play all'),
                onPressed: () => state.actPlay(tracks, 0),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.shuffle),
                label: const Text('Shuffle'),
                onPressed: () {
                  final order =
                      List<int>.generate(tracks.length, (i) => i)
                        ..shuffle();
                  state.actPlay(
                      [for (final i in order) tracks[i]], 0);
                },
              ),
            ],
          ),
          SizedBox(
            height: 148,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tracks.length,
              itemBuilder: (_, i) => _PickCard(
                  track: tracks[i], queue: tracks, index: i),
            ),
          ),
        ],
      ),
    );
  }
}

class _PickCard extends StatelessWidget {
  final YtTrack track;
  final List<YtTrack> queue;
  final int index;
  const _PickCard(
      {required this.track, required this.queue, required this.index});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return GestureDetector(
      onTap: () => state.actPlay(queue, index),
      child: Container(
        width: 120,
        margin: const EdgeInsets.only(right: 8, top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TrackArt(track: track, size: 112),
            Text(track.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(track.displayArtist(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

/// Hero card with working Play/Shuffle (whole list = queue, H7).
class _HeroCard extends StatelessWidget {
  final List<YtTrack> tracks;
  const _HeroCard({required this.tracks});

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) return const SizedBox.shrink();
    final state = AppScope.of(context);
    final track = tracks.first;
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(colors: [
          scheme.primary,
          scheme.primaryContainer
        ]),
      ),
      child: Row(
        children: [
          TrackArt(track: track, size: 72),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.bold)),
                Text(track.displayArtist(),
                    style: TextStyle(color: scheme.onPrimary)),
                Row(
                  children: [
                    FilledButton(
                        onPressed: () => state.actPlay(tracks, 0),
                        child: const Text('Play')),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () {
                        final order = List<int>.generate(
                            tracks.length, (i) => i)
                          ..shuffle();
                        state.actPlay(
                            [for (final i in order) tracks[i]], 0);
                      },
                      child: const Text('Shuffle'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Moods dotted tiles → deep-search (H6).
class _Moods extends StatelessWidget {
  final AppState state;
  const _Moods({required this.state});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Wrap(
        spacing: 8,
        children: [
          for (final m in HomeFeed.moods)
            ActionChip(
              avatar: const Icon(Icons.circle, size: 8),
              label: Text(m.$1),
              onPressed: () =>
                  openSeeAllQuery(context, m.$1, m.$2),
            ),
        ],
      ),
    );
  }
}

class _Rail extends StatelessWidget {
  final dynamic rail;
  final AppState state;
  const _Rail({required this.rail, required this.state});

  @override
  Widget build(BuildContext context) {
    final List<YtTrack> tracks = rail.tracks;
    if (tracks.isEmpty) return const SizedBox.shrink();
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(rail.section.title,
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium),
                      if ((rail.section.subtitle as String)
                          .isNotEmpty)
                        Text(rail.section.subtitle,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      openSeeAllStatic(context, rail.section.title,
                          tracks, rail.section.query),
                  child: const Text('See All'),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 148,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16),
              itemCount: tracks.length,
              itemBuilder: (_, i) => _PickCard(
                  track: tracks[i], queue: tracks, index: i),
            ),
          ),
        ],
      ),
    );
  }
}
