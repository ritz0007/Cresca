// Home tab (H1–H10): header + spinner + pull hint, hard-pull refresh,
// Top Picks + Play-all/Shuffle + See All, rails, moods → deep-search,
// hero Play/Shuffle, skeleton shimmer first load, honest offline error
// + Retry, discovery endless rails.

import 'package:flutter/material.dart';

import '../../core/home_feed.dart';
import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import '../updates.dart'
    show UpdateBannerMotion, UpdateProgressShimmer;
import '../widgets/cresca_logo.dart';
import '../widgets/profile_sheet.dart';
import '../widgets/session_sheet.dart';
import '../widgets/track_row.dart';
import 'podcast_screen.dart';
import 'see_all.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final ScrollController _scroll = ScrollController();
  String _filter = 'Music';

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
        } else {
          _maybePrefetch(state);
        }
      } catch (_) {}
    });
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    try {
      if (!mounted) return;
      _maybePrefetch(AppScope.of(context));
    } catch (_) {}
  }

  /// Early prefetch: fires when ~1.5 viewports of content remain (not at
  /// the absolute end). Single-flight lives in state (loadMoreDiscovery
  /// no-ops while a page is in flight); this only decides *when* to ask.
  void _maybePrefetch(AppState state) {
    try {
      if (!_scroll.hasClients) return;
      final pos = _scroll.position;
      if (!pos.hasContentDimensions || !pos.hasPixels) return;
      final max = pos.maxScrollExtent;
      if (max <= 0) {
        // Short list: fill the viewport.
        state.loadMoreDiscovery();
        return;
      }
      final viewport = pos.viewportDimension;
      if (viewport <= 0) return;
      final remaining = max - pos.pixels;
      if (remaining < viewport * 1.5) {
        state.loadMoreDiscovery();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    // Refresh dissolve: native spinner stays in the app bar; the rails
    // below fade behind glass while reloading (220ms, transform-free
    // opacity only).
    final refreshing = state.homeStatus == HomeStatus.loading &&
        (state.topPicks.isNotEmpty || state.rails.isNotEmpty);
    final dissolve = refreshing ? 0.35 : 1.0;
    final dissolveMs = state.motionMs(220);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) => Scaffold(
        body: RefreshIndicator(
          // Standard pull-to-refresh (the old 200px hard-pull was
          // undiscoverable): normal pull distance, native spinner,
          // taste-rotating force reload.
          onRefresh: () => state.hardRefresh(),
          child: CustomScrollView(
            controller: _scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverAppBar(
                pinned: true,
                // Reference chrome: brand mark left,
                // "Listen Now" title.
                leading: const Padding(
                  padding: EdgeInsets.only(left: 12),
                  child: Center(
                    child: CrescaLogo(size: 32),
                  ),
                ),
                title: const Text('Listen Now',
                    style: TextStyle(
                        fontSize: 28,
                        fontWeight: FontWeight.w800)),
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
                  IconButton(
                    icon: const Icon(
                        Icons.person_outline),
                    tooltip: 'Profile',
                    onPressed: () =>
                        openProfileSheet(context),
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
                  // Copy deck: loading is spinner-only (app bar) — the
                  // hint stays constant so rows never shift copy.
                  child: Text(
                    'Pull to refresh',
                    style:
                        Theme.of(context).textTheme.labelSmall,
                  ),
                ),
              ),
              if (_filter == 'Podcasts')
                SliverToBoxAdapter(
                  child: StaggerEntrance(
                    key: const ValueKey('filter-podcasts'),
                    child: PodcastScreen(
                      motionOn: state.motionOn,
                      embedded: true,
                      subscribed:
                          state.podcastStore.subsList(),
                      progressById: Map<String, int>.from(
                          state.podcastStore.progress),
                      currentSpeed: state.podcastSpeed,
                      onSearch: (q) => state
                          .podcastService
                          .searchEpisodes(q),
                      onPlay: (ep, seekMs) =>
                          state.playEpisode(ep,
                              seekMs: seekMs),
                      onDownload: (ep) =>
                          state.downloadEpisode(ep),
                      downloadState: (ep) =>
                          state.downloadStateFor(ep),
                      onUnsubscribe: (show) =>
                          state.unsubscribeShow(show),
                      onFollowShow: (ep) =>
                          state.followEpisodeShow(ep),
                      isShowFollowed: (ep) =>
                          state.isShowFollowed(ep),
                      onSetSpeed: (r) =>
                          state.setPodcastSpeed(r),
                      onPause: () async {
                        try {
                          await state.saveEpisodeProgress();
                          await state.controller.player
                              .pause();
                        } catch (_) {}
                      },
                    ),
                  ),
                ),
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
                // Always mounted so UpdateBannerMotion can animate the
                // dismiss (it collapses to zero-size when hidden).
                const SliverToBoxAdapter(
                    child: _UpdateBannerSlot()),
                SliverToBoxAdapter(
                    child:
                        _SignInCard(state: state)),
                SliverToBoxAdapter(
                  child: _Dissolve(
                    opacity: dissolve,
                    ms: dissolveMs,
                    child: StaggerEntrance(
                      key: ValueKey('home-recents-$_filter'),
                      child: _RecentsGrid(state: state),
                    ),
                  ),
                ),
                // "Jump back in" removed per user direction (rails
                // flow straight from recents into Top Picks).
                // Top Picks is a 2x2 song grid (no wide banner: the old
                // hero Play/Shuffle card was deleted — rails flow up).
                if (state.topPicks.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _Dissolve(
                      opacity: dissolve,
                      ms: dissolveMs,
                      child: StaggerEntrance(
                        key: ValueKey('home-top-$_filter'),
                        child: _TopPicks(
                            tracks: state.topPicks),
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: _Dissolve(
                    opacity: dissolve,
                    ms: dissolveMs,
                    child: StaggerEntrance(
                      key: ValueKey('home-moods-$_filter'),
                      child: _Moods(state: state),
                    ),
                  ),
                ),
                for (var ri = 0;
                    ri < state.rails.length;
                    ri++)
                  SliverToBoxAdapter(
                    child: _Dissolve(
                      opacity: dissolve,
                      ms: dissolveMs,
                      child: StaggerEntrance(
                        key: ValueKey(
                            'rail-$_filter-${state.rails[ri].section.cacheKey}'),
                        index: ri,
                        child: _Rail(
                            rail: state.rails[ri],
                            state: state),
                      ),
                    ),
                  ),
                // Endless tail lives in the terminal clearance slot below
                // (canonical EndFooter pattern for U6/U7).
              ],
              // Bottom chrome (mini player + pill) is app-shell; the
              // list scrolls under the glass (Spotify parity). Live
              // clearance from the measured chrome (falls back to 210
              // pre-measurement so unmigrated frames stay safe).
              SliverPadding(
                  padding: EdgeInsets.only(
                      bottom:
                          BottomChromeScope.clearanceOf(context)),
                  // EndFooter: fixed-height skeleton holds layout while
                  // the next rails load (no jump on arrival); honest
                  // error-with-retry and end states.
                  sliver: SliverToBoxAdapter(
                    child: _DiscoveryTail(state: state),
                  )),
            ],
          ),
        ),
      ),
    );
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
                // Segment-switch blend: pill color eases over 180ms.
                // Visual stays compact (8px vertical padding) but the
                // pill is at least 48px tall for the tap target.
                child: AnimatedContainer(
                  duration: Duration(
                      milliseconds:
                          AppScope.of(context).motionMs(180)),
                  curve: Curves.easeOut,
                  constraints: const BoxConstraints(
                      minHeight: 48, minWidth: 48),
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: filter == f
                        ? spotifyGreen
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: Text(f,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        // Selected pill sits on spotifyGreen: derive
                        // the label from the actual pill bg.
                        color: filter == f
                            ? textOn(spotifyGreen)
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

/// Sign-in nudge (reference): dark card with "Sign in to
/// YouTube Music / Get personalized recommendations" + white
/// Sign in pill. Hidden once logged in.
class _SignInCard extends StatelessWidget {
  final AppState state;
  const _SignInCard({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.ytSession.isLoggedIn) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final cardBg = scheme.surfaceContainerHighest;
    // White pill: derive the label from the actual pill bg.
    const pillBg = Colors.white;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  AdaptiveText(
                      data: 'Sign in to YouTube Music',
                      background: cardBg,
                      style: const TextStyle(
                          fontSize: 15,
                          fontWeight:
                              FontWeight.w700)),
                  const SizedBox(height: 2),
                  AdaptiveText(
                      data:
                          'Get personalized recommendations.',
                      background: cardBg,
                      secondary: true,
                      maxLines: 1,
                      overflow:
                          TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13)),
                ],
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: pillBg,
                foregroundColor: textOn(pillBg),
              ),
              onPressed: () =>
                  openSessionSheet(context),
              child: const Text('Sign in',
                  style: TextStyle(
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Recently played: 2-col grid of INDIVIDUAL SONG cells (art +
/// title + artist, tappable to play). Collection tiles (playlists /
/// radios) never render here — songs only, graceful empty fallback.
class _RecentsGrid extends StatelessWidget {
  final AppState state;
  const _RecentsGrid({required this.state});

  @override
  Widget build(BuildContext context) {
    // Per-song pool: recent plays first, liked fills thin history.
    // Songs-only gate + dedupe, order-kept, max 6 (2-col x 3 rows).
    final pool =
        songsOnlyTracks([...state.library.recent, ...state.library.liked]);
    final seen = <String>{};
    final tracks = <YtTrack>[];
    for (final t in pool) {
      if (tracks.length >= 6) break;
      if (!seen.add(t.id)) continue;
      tracks.add(t);
    }
    if (tracks.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    // Fixed 2-col layout (≤6 cells → ≤3 rows) as plain Column+Row:
    // this grid lives inside the outer CustomScrollView, so a nested
    // scrollable here (shrinkWrap + NeverScrollable) would re-measure
    // its full extent on every outer scroll frame. Rows are 64dp like
    // before (2-line titles stay unclipped at 200% text scale).
    final rows = <Widget>[];
    for (var r = 0; r < tracks.length; r += 2) {
      final cells = <Widget>[];
      for (var c = r; c < r + 2 && c < tracks.length; c++) {
        if (cells.isNotEmpty) cells.add(const SizedBox(width: 8));
        cells.add(Expanded(
          child: SizedBox(
            height: 64,
            child: StaggerEntrance(
              index: c,
              child: _RecentSongCell(
                  track: tracks[c],
                  queue: tracks,
                  index: c,
                  state: state),
            ),
          ),
        ));
      }
      if (rows.isNotEmpty) rows.add(const SizedBox(height: 8));
      rows.add(Row(children: cells));
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: AdaptiveText(
              data: 'Recently played',
              background: scheme.surface,
              style: const TextStyle(
                  fontSize: 22, fontWeight: FontWeight.w800),
            ),
          ),
          ...rows,
        ],
      ),
    );
  }
}

/// One recent-song cell: 56dp art + title + artist, tappable to play.
/// 64dp row keeps a >=48px tap target; press-scale honors motionMs.
class _RecentSongCell extends StatelessWidget {
  final YtTrack track;
  final List<YtTrack> queue;
  final int index;
  final AppState state;
  const _RecentSongCell(
      {required this.track,
      required this.queue,
      required this.index,
      required this.state});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressScale(
      motionOn: state.motionOn,
      onTap: () =>
          state.actPlay(queue, index, origin: 'Home'),
      child: RepaintBoundary(
        child: Container(
        constraints: const BoxConstraints(minHeight: 48),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(8),
                bottomLeft: Radius.circular(8),
              ),
              child: TrackArt(track: track, size: 56),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                // Cell bg is surfaceContainerHighest (custom container):
                // derive title/subtitle from that bg, never inherited.
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AdaptiveText(
                      data: track.title,
                      background: scheme.surfaceContainerHighest,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700),
                    ),
                    AdaptiveText(
                      data: track.displayArtist(),
                      background: scheme.surfaceContainerHighest,
                      secondary: true,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
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

/// Update banner slot (H9/Y4): always mounted so [UpdateBannerMotion]
/// can animate enter/dismiss; collapses to zero-size when no update is
/// pending. Progress bar rides [UpdateProgressShimmer] while downloading.
class _UpdateBannerSlot extends StatelessWidget {
  const _UpdateBannerSlot();

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return UpdateBannerMotion(
      visible: state.pendingUpdate != null,
      motionOn: state.motionOn,
      child: _UpdateBanner(state: state),
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
    final active = prog >= 0;
    final scheme = Theme.of(context).colorScheme;
    // Banner bg is a green wash over the surface: derive label
    // colors from the blended result, inside the existing
    // UpdateBannerMotion wrapper (untouched above).
    final bannerBg = Color.alphaBlend(
        spotifyGreen.withValues(alpha: 0.14), scheme.surface);
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update_outlined,
                    color: spotifyGreen),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AdaptiveText(
                          data: 'Cresca Music ${u.tag} available',
                          background: bannerBg,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontWeight: FontWeight.w700)),
                      AdaptiveText(
                          data: active
                              ? 'Downloading… ${prog.round()}%'
                              : downloaded
                                  ? 'Downloaded — ready to install.'
                                  : 'Tap Update to download.',
                          background: bannerBg,
                          secondary: true,
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
                  onPressed: active
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
            if (active)
              Padding(
                padding: const EdgeInsets.only(top: 8, right: 8),
                child: UpdateProgressShimmer(
                  motionOn: state.motionOn,
                  active: true,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: (prog / 100).clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: spotifyGreen.withValues(
                          alpha: 0.2),
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(
                              spotifyGreen),
                    ),
                  ),
                ),
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

/// Top Picks + Play-all + Shuffle + See All (H3): 2x2 GRID of
/// per-song cards (art + title + artist, tappable to play).
class _TopPicks extends StatelessWidget {
  final List<YtTrack> tracks;
  const _TopPicks({required this.tracks});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    // Songs-only display pass: top picks arrive gated from state, but
    // cached/mixed lists can still carry cards — never render those.
    final tracks = songsOnlyTracks(this.tracks);
    if (tracks.isEmpty) return const SizedBox.shrink();
    // 2-row horizontal grid (2x2 look, slides right for more): up
    // to 12 songs; the pool re-ranks per visit + pull-to-refresh.
    final shown = tracks.take(12).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Row(
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
          ),
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text(state.topSeed.subtitle,
                style: Theme.of(context).textTheme.bodySmall),
          ),
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
          const SizedBox(height: 8),
          SizedBox(
            height: 412,
            child: GridView.builder(
              scrollDirection: Axis.horizontal,
              gridDelegate:
                  const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 10,
                crossAxisSpacing: 12,
                // Cells ~150 wide in a 194-tall row.
                childAspectRatio: 1.3,
              ),
              padding:
                  const EdgeInsets.only(right: 16),
              itemCount: shown.length,
              itemBuilder: (_, i) => StaggerEntrance(
                index: i,
                child: _PickCard(
                    track: shown[i],
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

class _PickCard extends StatelessWidget {
  final YtTrack track;
  final List<YtTrack> queue;
  final int index;
  const _PickCard(
      {required this.track, required this.queue, required this.index});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    // Rail card (reference look): square rounded art on top, title
    // (1-2 lines) + artist (1 line) BELOW on the page surface — no
    // overlay text. Tappable to play; press-scale honors motionMs.
    final surface = Theme.of(context).colorScheme.surface;
    return PressScale(
      motionOn: state.motionOn,
      onTap: () => state.actPlay(queue, index,
          origin: 'Home'),
      child: RepaintBoundary(
        child: Column(
          crossAxisAlignment:
              CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: TrackArt(track: track, size: 140),
            ),
            const SizedBox(height: 6),
            AdaptiveText(
                data: track.title,
                background: surface,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700)),
            AdaptiveText(
                data: track.displayArtist(),
                background: surface,
                secondary: true,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5)),
          ],
        ),
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
              // Padded tap target (48px) with a compact visual.
              materialTapTargetSize:
                  MaterialTapTargetSize.padded,
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

  /// A rail must never render a blank header: some server/cached
  /// sections arrive with empty titles. Derive a human title from the
  /// query token (`__browse__quick_picks` → `Quick Picks`,
  /// `__related__<id>` → `Related Mix`) so the category is always
  /// named. Colors are explicit on the page surface (never inherited,
  /// never white-on-white).
  static String headerTitle(dynamic section) {
    try {
      final t = (section.title as String).trim();
      if (t.isNotEmpty) return t;
    } catch (_) {}
    try {
      final q = (section.query as String).trim();
      if (q.startsWith('__related__')) return 'Related Mix';
      final core = q.replaceAll(RegExp(r'^__[a-z]+__'), '');
      final words = core
          .split(RegExp(r'[^a-zA-Z0-9]+'))
          .where((w) => w.isNotEmpty)
          .map((w) => w[0].toUpperCase() + w.substring(1))
          .join(' ')
          .trim();
      if (words.isNotEmpty) return words;
    } catch (_) {}
    return 'Top Picks';
  }

  static String headerSubtitle(dynamic section) {
    try {
      final s = (section.subtitle as String).trim();
      if (s.isNotEmpty) return s;
    } catch (_) {}
    return 'YouTube Music';
  }

  @override
  Widget build(BuildContext context) {
    // Songs-only display pass over the rail (cached + mixed-source
    // lists can carry playlist/video/podcast cards). Thin rails (<3
    // playable) never render — same rule as the state-side fetch.
    late final List<YtTrack> tracks;
    try {
      tracks = songsOnlyTracks(rail.tracks as List<YtTrack>);
    } catch (_) {
      return const SizedBox.shrink();
    }
    if (tracks.length < minRailTracks) return const SizedBox.shrink();
    final title = headerTitle(rail.section);
    final subtitle = headerSubtitle(rail.section);
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AdaptiveText(
                          data: title,
                          background: surface,
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600)),
                      AdaptiveText(
                          data: subtitle,
                          background: surface,
                          secondary: true,
                          style:
                              const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      openSeeAllStatic(context, title,
                          tracks, rail.section.query),
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
                // Horizontal rail: fixed 150dp song cards (the grid
                // sizes _PickCard itself; here the width is pinned).
                child: Padding(
                  padding: const EdgeInsets.only(right: 10, top: 8),
                  child: SizedBox(
                    width: 150,
                    height: 200,
                    child: _PickCard(
                        track: tracks[i], queue: tracks, index: i),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Endless-discovery tail: loading skeleton (fixed height so arriving
/// rails never jump the layout), honest error + Retry, honest end card.
/// Shown only once the initial rails exist; the Podcasts filter owns its
/// own list and never shows this.
class _DiscoveryTail extends StatelessWidget {
  final AppState state;
  const _DiscoveryTail({required this.state});

  @override
  Widget build(BuildContext context) {
    if (state.rails.isEmpty) return const SizedBox.shrink();
    if (state.discoveryLoading) {
      final scheme = Theme.of(context).colorScheme;
      final base = scheme.surfaceContainerHighest;
      // One rail tall (~header + 208px horizontal cards): arriving rails
      // replace this 1:1 with no scroll jump.
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: SizedBox(
          height: 260,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                  width: 180,
                  height: 18,
                  decoration: BoxDecoration(
                      color: base,
                      borderRadius: BorderRadius.circular(4))),
              const SizedBox(height: 6),
              Container(
                  width: 120,
                  height: 13,
                  decoration: BoxDecoration(
                      color: base,
                      borderRadius: BorderRadius.circular(4))),
              const SizedBox(height: 12),
              Expanded(
                child: Row(
                  children: [
                    for (var i = 0; i < 3; i++)
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                              right: i == 2 ? 0 : 10),
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Container(
                                    decoration: BoxDecoration(
                                        color: base,
                                        borderRadius:
                                            BorderRadius.circular(
                                                14))),
                              ),
                              const SizedBox(height: 6),
                              Container(
                                  height: 13,
                                  decoration: BoxDecoration(
                                      color: base,
                                      borderRadius:
                                          BorderRadius.circular(
                                              4))),
                              const SizedBox(height: 4),
                              Container(
                                  width: 90,
                                  height: 11,
                                  decoration: BoxDecoration(
                                      color: base,
                                      borderRadius:
                                          BorderRadius.circular(
                                              4))),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (state.discoveryError.isNotEmpty && state.discoveryHasMore) {
      final scheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: AdaptiveText(
                  data: state.discoveryError,
                  background: scheme.surfaceContainerHighest,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
              FilledButton(
                onPressed: () => state.retryDiscovery(),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }
    if (!state.discoveryHasMore) {
      final scheme = Theme.of(context).colorScheme;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Center(
          child: AdaptiveText(
            // Terminal footer copy (deck-exact).
            data: 'You\u2019re all caught up',
            background: scheme.surface,
            secondary: true,
            align: TextAlign.center,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      );
    }
    return const SizedBox.shrink();
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

