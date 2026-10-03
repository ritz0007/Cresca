// Trending tab (R1): Top 100 Global + Hindi/International/Telugu/
// Punjabi rails (7-day cache, parallel refresh). Videos rail hooks the
// trending-video resolver (H5 videos surface in Phase 3 UI).

import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../app.dart';
import '../state.dart';
import '../widgets/mini_player.dart';
import '../widgets/track_row.dart';
import 'see_all.dart';

class TrendingScreen extends StatefulWidget {
  const TrendingScreen({super.key});

  @override
  State<TrendingScreen> createState() => _TrendingScreenState();
}

class _TrendingScreenState extends State<TrendingScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final state = AppScope.of(context);
        if (state.trendingGlobal.isEmpty) state.loadTrending();
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) => Scaffold(
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
                onRefresh: () => state.loadTrending(force: true),
                child: ListView(
                  children: [
                    _GlobalTop(
                        tracks: state.trendingGlobal, state: state),
                    for (final rail in state.trendingRails)
                      _RegionRail(
                          title: rail.section.title,
                          tracks: rail.tracks),
                  ],
                ),
              ),
            ),
            const MiniPlayer(),
          ],
        ),
      ),
    );
  }
}

class _GlobalTop extends StatelessWidget {
  final List<YtTrack> tracks;
  final AppState state;
  const _GlobalTop({required this.tracks, required this.state});

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
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child:
                  Center(child: Text('Charts load on refresh')),
            ),
          for (var i = 0;
              i < (tracks.length > 10 ? 10 : tracks.length);
              i++)
            Row(
              children: [
                SizedBox(
                  width: 28,
                  child: Text('${i + 1}',
                      style:
                          Theme.of(context).textTheme.titleMedium),
                ),
                Expanded(
                  child: TrackRow(
                      track: tracks[i],
                      contextQueue: tracks,
                      index: i),
                ),
              ],
            ),
        ],
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
                  child: Text(title,
                      style:
                          Theme.of(context).textTheme.titleMedium),
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
            height: 132,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16),
              itemCount: tracks.length,
              itemBuilder: (_, i) => SizedBox(
                width: 240,
                child: TrackRow(
                    track: tracks[i],
                    contextQueue: tracks,
                    index: i),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
