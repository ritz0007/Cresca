// Home tab (H1–H10): header + spinner + pull hint, hard-pull refresh,
// Top Picks + Play-all/Shuffle + See All, rails, moods → deep-search,
// hero Play/Shuffle, skeleton shimmer first load, honest offline error
// + Retry, discovery endless rails.

import 'package:flutter/material.dart';

import '../../core/home_feed.dart';
import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../library.dart' show UserPlaylist;
import '../radio_store.dart' show SavedRadio;
import '../state.dart';
import '../widgets/profile_sheet.dart';
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
  String _filter = 'All';

  @override
  void initState() {
    super.initState();
    // Post-frame: initState-time inherited lookup is unreliable, and the
    // AppState.init belt-and-suspenders call covers cold boot anyway.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        final state = AppScope.of(context);
        if (state.topPicks.isEmpty && state.rails.isEmpty) {
          state.loadHome();
        }
      } catch (_) {}
    });
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
                // Spotify parity: settings live top-left on home.
                leading: IconButton(
                  icon: const Icon(Icons.settings_outlined),
                  tooltip: 'Settings',
                  onPressed: () => openProfileSheet(context),
                ),
                title: Text(_greeting()),
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
                child: _FilterChips(
                  filter: _filter,
                  onPick: (f) =>
                      setState(() => _filter = f),
                ),
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
              if (_filter == 'Podcasts')
                const SliverToBoxAdapter(
                    child: _PodcastsEmpty()),
              if (_filter != 'Podcasts') ...[
                if (state.homeStatus ==
                        HomeStatus.loading &&
                    state.topPicks.isEmpty)
                  const SliverListSkeleton(),
                if (state.homeStatus == HomeStatus.error &&
                    state.topPicks.isEmpty &&
                    state.rails.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _ErrorCard(
                      message: state.homeError,
                      onRetry: () =>
                          state.loadHome(force: true),
                    ),
                  ),
                if (state.pendingUpdate != null)
                  SliverToBoxAdapter(
                      child:
                          _UpdateBanner(state: state)),
                SliverToBoxAdapter(
                    child: _RecentsGrid(state: state)),
                SliverToBoxAdapter(
                    child: _JumpBackIn(state: state)),
                if (state.topPicks.isNotEmpty) ...[
                  SliverToBoxAdapter(
                      child: _TopPicks(
                          tracks: state.topPicks)),
                  SliverToBoxAdapter(
                      child: _HeroCard(
                          tracks: state.topPicks)),
                ],
                SliverToBoxAdapter(
                    child: _Moods(state: state)),
                for (final rail in state.rails)
                  SliverToBoxAdapter(
                      child: _Rail(
                          rail: rail, state: state)),
              ],
              // Bottom chrome (mini player + pill) is app-shell; the
              // list scrolls under the glass (Spotify parity).
              const SliverPadding(padding: EdgeInsets.only(bottom: 210)),
            ],
          ),
        ),
      ),
    );
  }
}

String _greeting() {
  try {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good morning';
    if (h < 18) return 'Good afternoon';
    return 'Good evening';
  } catch (_) {
    return 'Listen Now';
  }
}

/// Spotify filter chips (All / Music / Podcasts). All = full home,
/// Music = same music catalog, Podcasts = honest empty state (music
/// app — never fake rows).
class _FilterChips extends StatelessWidget {
  final String filter;
  final ValueChanged<String> onPick;
  const _FilterChips({required this.filter, required this.onPick});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Row(
        children: [
          for (final f in const ['All', 'Music', 'Podcasts'])
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onPick(f),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: filter == f
                        ? spotifyGreen
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(f,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: filter == f
                            ? Colors.black
                            : scheme.onSurface,
                      )),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Honest empty state for the Podcasts filter (music-only app).
class _PodcastsEmpty extends StatelessWidget {
  const _PodcastsEmpty();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(16, 24, 16, 48),
      child: Column(
        children: [
          Icon(Icons.podcasts_outlined, size: 48),
          SizedBox(height: 12),
          Text('No podcasts here',
              style:
                  TextStyle(fontWeight: FontWeight.w700, fontSize: 17)),
          SizedBox(height: 6),
          Text('Cresca is music-only — your songs live under All.',
              textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

/// Spotify recents grid: 2-col × up-to-4 rows of 56dp-art cells —
/// recent PLAYLISTS + RADIOS (never songs), Liked Songs tile first.
class _RecentsGrid extends StatelessWidget {
  final AppState state;
  const _RecentsGrid({required this.state});

  @override
  Widget build(BuildContext context) {
    final cells = <_Cell>[];
    if (state.library.liked.isNotEmpty) {
      cells.add(const _Cell.liked());
    }
    for (final p in state.library.playlists) {
      if (cells.length >= 8) break;
      cells.add(_Cell.playlist(p));
    }
    for (final r in state.library.radios) {
      if (cells.length >= 8) break;
      cells.add(_Cell.radio(r));
    }
    if (cells.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate:
            const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          mainAxisExtent: 56,
        ),
        itemCount: cells.length,
        itemBuilder: (_, i) =>
            _RecentCell(cell: cells[i], state: state),
      ),
    );
  }
}

class _Cell {
  final UserPlaylist? playlist;
  final SavedRadio? radio;
  final bool likedTile;
  const _Cell.liked()
      : playlist = null,
        radio = null,
        likedTile = true;
  const _Cell.playlist(UserPlaylist p)
      : playlist = p,
        radio = null,
        likedTile = false;
  const _Cell.radio(SavedRadio r)
      : playlist = null,
        radio = r,
        likedTile = false;
}

class _RecentCell extends StatelessWidget {
  final _Cell cell;
  final AppState state;
  const _RecentCell({required this.cell, required this.state});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget art;
    String title;
    VoidCallback onTap;
    if (cell.likedTile) {
      art = Container(
        width: 56,
        height: 56,
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [
            Color(0xFF4B2DD0),
            Color(0xFF8A9BB5),
          ]),
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(8),
            bottomLeft: Radius.circular(8),
          ),
        ),
        child: const Icon(Icons.favorite,
            color: Colors.white, size: 24),
      );
      title = 'Liked Songs';
      onTap = () {
        if (state.library.liked.isNotEmpty) {
          state.actPlay(state.library.liked, 0);
        }
      };
    } else if (cell.playlist != null) {
      final p = cell.playlist!;
      art = p.tracks.isNotEmpty
          ? ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                bottomLeft: Radius.circular(8),
              ),
              child: TrackArt(track: p.tracks.first, size: 56),
            )
          : Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  bottomLeft: Radius.circular(8),
                ),
              ),
              child: Icon(Icons.folder_outlined,
                  color: scheme.onSurfaceVariant),
            );
      title = p.name;
      onTap = () {
        if (p.tracks.isNotEmpty) {
          state.actPlay(p.tracks, 0);
        }
      };
    } else {
      // Radio cell (only remaining variant).
      final r = cell.radio!;
      final seedThumb = r.thumbUrl.isNotEmpty
          ? r.thumbUrl
          : r.seed.thumbUrl;
      art = seedThumb.isNotEmpty
          ? ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                bottomLeft: Radius.circular(8),
              ),
              child: TrackArt(track: r.seed, size: 56),
            )
          : Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  bottomLeft: Radius.circular(8),
                ),
              ),
              child: Icon(Icons.radio_outlined,
                  color: scheme.onSurfaceVariant),
            );
      title = r.title;
      onTap = () => state.startRadio(r.seed);
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            art,
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Spotify "Jump back in": horizontal large cards (art + type +
/// title + subtitle) from recent, falling back to top picks.
class _JumpBackIn extends StatelessWidget {
  final AppState state;
  const _JumpBackIn({required this.state});

  @override
  Widget build(BuildContext context) {
    final seen = <String>{};
    final picks = <YtTrack>[];
    for (final t in [
      ...state.library.recent,
      ...state.topPicks,
    ]) {
      if (picks.length >= 10) break;
      if (!seen.add(t.id)) continue;
      picks.add(t);
    }
    if (picks.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Text('Jump back in',
              style:
                  TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
        ),
        SizedBox(
          height: 236,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding:
                const EdgeInsets.symmetric(horizontal: 16),
            itemCount: picks.length,
            itemBuilder: (_, i) =>
                _JumpCard(track: picks[i], queue: picks, index: i),
          ),
        ),
      ],
    );
  }
}

class _JumpCard extends StatelessWidget {
  final YtTrack track;
  final List<YtTrack> queue;
  final int index;
  const _JumpCard(
      {required this.track,
      required this.queue,
      required this.index});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return GestureDetector(
      onTap: () => state.actPlay(queue, index),
      child: Container(
        width: 160,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: TrackArt(track: track, size: 160),
            ),
            const SizedBox(height: 6),
            Text('Song',
                style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant)),
            Text(track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700)),
            Text(track.displayArtist(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant)),
          ],
        ),
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

/// Update banner (H9/Y4): green-tinted, tag + Download/Install +
/// release notes + dismiss. Session-scoped dismiss only.
class _UpdateBanner extends StatelessWidget {
  final AppState state;
  const _UpdateBanner({required this.state});

  @override
  Widget build(BuildContext context) {
    final u = state.pendingUpdate;
    if (u == null) return const SizedBox.shrink();
    final prog = state.updateProgress;
    final downloaded = state.updateDownloaded;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        decoration: BoxDecoration(
          color: spotifyGreen.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: spotifyGreen.withValues(alpha: 0.4)),
        ),
        child: Row(
          children: [
            const Icon(Icons.system_update_outlined,
                color: spotifyGreen),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Cresca ${u.tag} available',
                      style: const TextStyle(
                          fontWeight: FontWeight.w700)),
                  Text(
                      prog >= 0
                          ? 'Downloading… ${prog.round()}%'
                          : downloaded
                              ? 'Downloaded — ready to install.'
                              : 'Tap Update to download.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall),
                ],
              ),
            ),
            TextButton(
              onPressed: () => state.openReleasePage(),
              child: const Text("What's new"),
            ),
            FilledButton(
              style: spotifyPlayStyle(),
              onPressed: prog >= 0
                  ? null
                  : () async {
                      try {
                        if (downloaded) {
                          await state.installUpdate();
                        } else {
                          final msg =
                              await state.downloadUpdate();
                          if (context.mounted &&
                              msg.isNotEmpty) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(
                                    content: Text(msg)));
                          }
                        }
                      } catch (_) {}
                    },
              child: Text(
                  downloaded ? 'Install' : 'Update'),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              tooltip: 'Dismiss',
              onPressed: () => state.dismissUpdate(),
            ),
          ],
        ),
      ),
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
                style: spotifyPlayStyle(),
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
            height: 178,
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
        width: 124,
        margin: const EdgeInsets.only(right: 10, top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            TrackArt(track: track, size: 112),
            const SizedBox(height: 6),
            Text(track.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
            Text(track.displayArtist(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant)),
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
                        style: spotifyPlayStyle(),
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
            height: 178,
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

