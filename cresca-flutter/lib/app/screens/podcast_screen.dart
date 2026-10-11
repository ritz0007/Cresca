// Podcasts tab (MVP): subscriptions row, episode list with progress
// bars + resume badges, download-for-offline entries, speed + sleep
// timer controls, and loading/empty/error states.
//
// Decoupled by design: every integration point (search, play, queue,
// downloads, pause) arrives as an injected callback that the
// coordinator wires to AppState/DownloadStore/PlayerController after
// this file lands. This screen never touches playback.dart, state.dart,
// or downloads.dart directly.
//
// Legibility: titles ride AdaptiveText over explicit backgrounds;
// secondary text uses glassSubtext; motion uses motionMs everywhere;
// interactive targets are ≥48 px.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/motion.dart' as motion;
import '../../podcasts/models.dart';
import '../../podcasts/playback_support.dart';
import '../design.dart';

/// Minimum touch target (48 px) applied to every control on this screen.
const double _target = 48;

/// Search debounce (mirrors search_screen S1).
const int _searchDebounceMs = 250;

class PodcastScreen extends StatefulWidget {
  /// Motion kill-switch (AppState.motionOn).
  final bool motionOn;

  /// Subscribed shows (coordinator feeds PodcastStore.subsList()).
  final List<PodcastShow> subscribed;

  /// episodeId → resumeMs (coordinator feeds PodcastStore.progress).
  final Map<String, int> progressById;

  /// Episode search (coordinator: PodcastService.searchEpisodes).
  final Future<List<PodcastEpisode>> Function(String query)? onSearch;

  /// Play tap with restore offset (coordinator: resolve URL via
  /// StreamResolver.audioUrl → controller.playQueue at seekMs).
  final void Function(PodcastEpisode episode, int seekMs)? onPlay;

  /// Download entry (coordinator: DownloadStore.enqueue/retry with a
  /// freshly resolved URL; read-only status via [downloadState]).
  final void Function(PodcastEpisode episode)? onDownload;

  /// Per-episode download status by id (coordinator reads the existing
  /// DownloadStore: isDownloaded/progressFor/isDownloading).
  final PodcastDownloadState Function(PodcastEpisode episode)?
      downloadState;

  /// Follow-show affordance for search-result episodes
  /// (coordinator: followEpisodeShow; episodes carry no browseId).
  final void Function(PodcastEpisode episode)? onFollowShow;

  /// True when the episode's show is already followed (hides the
  /// follow button to avoid duplicates).
  final bool Function(PodcastEpisode episode)? isShowFollowed;

  /// Unsubscribe (coordinator: PodcastStore.unsubscribe + setState).
  final void Function(PodcastShow show)? onUnsubscribe;

  /// Current playback rate (coordinator: player.speed).
  final double currentSpeed;

  /// Rate change (coordinator: applyPodcastSpeed on the player).
  final Future<void> Function(double speed)? onSetSpeed;

  /// Sleep-timer fire action (coordinator: player.pause).
  final Future<void> Function()? onPause;

  /// Embedded mode (home Podcasts filter): no Scaffold/appBar, no
  /// Expanded — fixed-height results box so the screen can live
  /// inside a sliver. Standalone route use keeps the default false.
  final bool embedded;

  const PodcastScreen({
    super.key,
    this.motionOn = true,
    this.subscribed = const [],
    this.progressById = const {},
    this.onSearch,
    this.onPlay,
    this.onDownload,
    this.downloadState,
    this.onFollowShow,
    this.isShowFollowed,
    this.onUnsubscribe,
    this.currentSpeed = 1.0,
    this.onSetSpeed,
    this.onPause,
    this.embedded = false,
  });

  @override
  State<PodcastScreen> createState() => _PodcastScreenState();
}

class _PodcastScreenState extends State<PodcastScreen> {
  final TextEditingController _text = TextEditingController();
  Timer? _debounce;
  Timer? _sleepTick;
  late SleepTimer _sleep;
  double _speed = 1.0;
  List<PodcastEpisode> _episodes = [];
  bool _loading = false;
  String? _error;
  int _gen = 0;
  int _sleepLeftMs = 0;

  /// Selected browse category (empty = free search). Tapping a category
  /// fills the field and runs "`<Category>` podcasts".
  String _selectedCat = '';

  /// Browse categories (YTM Podcasts shelf language). Queries are
  /// "<label> podcasts" so episode parsing stays selective.
  static const _categories = [
    'Comedy',
    'True Crime',
    'News',
    'Society & Culture',
    'Business',
    'Health & Fitness',
    'Education',
    'Sports',
    'Technology',
    'Arts',
    'History',
    'Music',
  ];

  @override
  void initState() {
    super.initState();
    _speed = clampPodcastSpeed(widget.currentSpeed);
    _sleep = SleepTimer(onFire: () async {
      try {
        await widget.onPause?.call();
      } catch (_) {}
      if (mounted) {
        setState(() => _sleepLeftMs = 0);
      }
    });
    // Default shelf: the tab must never open empty — run a broad
    // discovery search once (user queries replace it afterwards).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        if (!mounted) return;
        if (_text.text.trim().isEmpty && _episodes.isEmpty) {
          _run('popular podcasts');
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _sleepTick?.cancel();
    _sleep.dispose();
    _text.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    try {
      _debounce?.cancel();
      // Manual typing leaves category mode.
      if (mounted && _selectedCat.isNotEmpty) {
        setState(() => _selectedCat = '');
      }
      if (value.trim().isEmpty) {
        if (mounted) {
          setState(() {
            _episodes = [];
            _loading = false;
            _error = null;
          });
        }
        return;
      }
      _debounce = Timer(
        Duration(
            milliseconds:
                motion.motionMs(widget.motionOn, _searchDebounceMs)),
        () => _run(value),
      );
    } catch (_) {}
  }

  Future<void> _run(String value) async {
    final g = ++_gen;
    try {
      if (mounted) {
        setState(() {
          _loading = true;
          _error = null;
        });
      }
      final fn = widget.onSearch;
      if (fn == null) {
        if (mounted && g == _gen) {
          setState(() {
            _loading = false;
            _episodes = [];
          });
        }
        return;
      }
      List<PodcastEpisode> eps;
      try {
        eps = await fn(value.trim()).timeout(
            const Duration(seconds: 20));
      } catch (_) {
        if (mounted && g == _gen) {
          setState(() {
            _loading = false;
            _error = 'Search failed. Check connection and retry.';
          });
        }
        return;
      }
      if (!mounted || g != _gen) return;
      setState(() {
        _loading = false;
        _episodes = eps;
        if (eps.isEmpty) _error = null;
      });
    } catch (_) {
      if (mounted && g == _gen) {
        setState(() {
          _loading = false;
          _error = 'Search failed. Check connection and retry.';
        });
      }
    }
  }

  int _resumeFor(PodcastEpisode ep) {
    try {
      return widget.progressById[ep.id] ?? ep.resumeMs;
    } catch (_) {
      return 0;
    }
  }

  void _cycleSpeed() {
    try {
      final next = nextPodcastSpeed(_speed);
      setState(() => _speed = next);
      widget.onSetSpeed?.call(next).catchError((_) {});
    } catch (_) {}
  }

  void _sleepMenu() {
    try {
      final ms = motion.motionMs(widget.motionOn, motion.sheetEnterMs);
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        builder: (ctx) {
          final scheme = Theme.of(ctx).colorScheme;
          final dark =
              Theme.of(ctx).brightness == Brightness.dark;
          return GlassSheetSurface(
            motionOn: widget.motionOn,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final m in sleepTimerPresetsMin)
                    SizedBox(
                      height: _target,
                      width: double.infinity,
                      child: TextButton(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _startSleep(m);
                        },
                        child: AnimatedDefaultTextStyle(
                          duration: Duration(milliseconds: ms),
                          style: TextStyle(
                              color: glassText(dark),
                              fontSize: 16),
                          child: Text('Sleep in $m min'),
                        ),
                      ),
                    ),
                  SizedBox(
                    height: _target,
                    width: double.infinity,
                    child: TextButton(
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _cancelSleep();
                      },
                      child: AnimatedDefaultTextStyle(
                        duration: Duration(milliseconds: ms),
                        style: TextStyle(
                            color: scheme.error,
                            fontSize: 16),
                        child:
                            const Text('Cancel sleep timer'),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          );
        },
      );
    } catch (_) {}
  }

  void _startSleep(int minutes) {
    try {
      _sleep.startMinutes(minutes);
      _sleepTick?.cancel();
      setState(
          () => _sleepLeftMs = minutes * 60 * 1000);
      _sleepTick = Timer.periodic(
          const Duration(seconds: 1), (_) {
        if (!mounted) return;
        final left = _sleep.remainingMs();
        if (mounted) setState(() => _sleepLeftMs = left);
        if (left <= 0) _sleepTick?.cancel();
      });
    } catch (_) {}
  }

  void _cancelSleep() {
    try {
      _sleep.cancel();
      _sleepTick?.cancel();
      if (mounted) setState(() => _sleepLeftMs = 0);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final on = widget.motionOn;
    final switchMs = motion.motionMs(on, motion.tabExitMs);
    if (widget.embedded) {
      // Sliver-safe: bounded content, no Scaffold, no Expanded.
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _searchField(scheme, on),
            _categoryLane(scheme, on),
            _controlsRow(scheme, on, switchMs),
            _subsRow(scheme, on),
            SizedBox(
              height: 420,
              child: AnimatedSwitcher(
                duration: Duration(milliseconds: switchMs),
                child: _body(scheme, on),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: const GlassBar(title: 'Podcasts'),
      body: Column(
        children: [
          _searchField(scheme, on),
          _categoryLane(scheme, on),
          _controlsRow(scheme, on, switchMs),
          _subsRow(scheme, on),
          Expanded(
            child: AnimatedSwitcher(
              duration: Duration(milliseconds: switchMs),
              child: _body(scheme, on),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchField(ColorScheme scheme, bool on) {
    final glowMs = motion.motionMs(on, motion.tabExitMs);
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: AnimatedContainer(
        duration: Duration(milliseconds: glowMs),
        height: _target,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest
              .withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: scheme.outlineVariant),
        ),
        child: TextField(
          controller: _text,
          onChanged: _onQueryChanged,
          textInputAction: TextInputAction.search,
          onSubmitted: _run,
          style: TextStyle(
              color: scheme.onSurface, fontSize: 16),
          decoration: InputDecoration(
            hintText: 'Search shows and episodes',
            hintStyle: TextStyle(
                color: scheme.onSurfaceVariant),
            prefixIcon: Icon(Icons.search,
                color: scheme.onSurfaceVariant),
            border: InputBorder.none,
            contentPadding:
                const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
      ),
    );
  }

  /// Category rails (YTM Podcasts shelf language): one tap runs
  /// "`<Category>` podcasts" as the field query.
  Widget _categoryLane(ColorScheme scheme, bool on) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding:
            const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _categories.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final c = _categories[i];
          final selected = _selectedCat == c;
          final chip = GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              try {
                _debounce?.cancel();
                _text.text = '$c podcasts';
                if (mounted) {
                  setState(() => _selectedCat = c);
                }
                _run('$c podcasts');
              } catch (_) {}
            },
            child: Container(
              constraints: const BoxConstraints(
                  minHeight: 36, minWidth: 48),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(
                  horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: selected
                    ? scheme.primary
                    : scheme.surfaceContainerHighest
                        .withValues(alpha: 0.6),
                borderRadius:
                    BorderRadius.circular(20),
              ),
              child: Text(c,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: selected
                        ? scheme.onPrimary
                        : scheme.onSurface,
                  )),
            ),
          );
          if (i >= motion.staggerCapItems) return chip;
          return FadeSlide(
            motionOn: on,
            delay: Duration(
                milliseconds: motion.motionMs(
                    on, motion.staggerMs * i)),
            child: chip,
          );
        },
      ),
    );
  }

  Widget _controlsRow(
      ColorScheme scheme, bool on, int switchMs) {
    final sleeping = _sleepLeftMs > 0;
    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            height: _target,
            child: PressScale(
              motionOn: on,
              onTap: _cycleSpeed,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest
                      .withValues(alpha: 0.6),
                  borderRadius:
                      BorderRadius.circular(24),
                ),
                alignment: Alignment.center,
                child: AnimatedDefaultTextStyle(
                  duration:
                      Duration(milliseconds: switchMs),
                  style: TextStyle(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w700),
                  child: Text(
                      '${_speed.toStringAsFixed(1)}× speed'),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: _target,
            child: PressScale(
              motionOn: on,
              onTap: _sleepMenu,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14),
                decoration: BoxDecoration(
                  color: sleeping
                      ? scheme.primary
                          .withValues(alpha: 0.2)
                      : scheme.surfaceContainerHighest
                          .withValues(alpha: 0.6),
                  borderRadius:
                      BorderRadius.circular(24),
                ),
                alignment: Alignment.center,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bedtime_outlined,
                        size: 18,
                        color: scheme.onSurface),
                    const SizedBox(width: 6),
                    Text(
                      sleeping
                          ? 'Sleep ${fmtEpisodeMs(_sleepLeftMs)}'
                          : 'Sleep timer',
                      style: TextStyle(
                          color: scheme.onSurface,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _subsRow(ColorScheme scheme, bool on) {
    final dark =
        Theme.of(context).brightness == Brightness.dark;
    if (widget.subscribed.isEmpty) {
      return Padding(
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'No subscriptions yet — search and follow a show.',
            style: TextStyle(
                color: glassSubtext(dark), fontSize: 13),
          ),
        ),
      );
    }
    final stagger =
        motion.motionMs(on, motion.staggerMs);
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 6),
        itemCount: widget.subscribed.length,
        separatorBuilder: (_, _) =>
            const SizedBox(width: 10),
        itemBuilder: (ctx, i) {
          final show = widget.subscribed[i];
          final chip = Container(
            height: 64,
            constraints:
                const BoxConstraints(minHeight: _target),
            padding: const EdgeInsets.symmetric(
                horizontal: 10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest
                  .withValues(alpha: 0.6),
              borderRadius:
                  BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _showThumb(show.thumbUrl, scheme),
                const SizedBox(width: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                      maxWidth: 140),
                  child: AdaptiveText(
                    data: show.title.isEmpty
                        ? 'Untitled show'
                        : show.title,
                    background: scheme.surface,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                SizedBox(
                  width: _target,
                  height: _target,
                  child: IconButton(
                    tooltip: 'Unsubscribe',
                    iconSize: 20,
                    onPressed: () =>
                        widget.onUnsubscribe
                            ?.call(show),
                    icon: Icon(Icons.close,
                        color:
                            scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          );
          if (i >= motion.staggerCapItems) return chip;
          return FadeSlide(
            motionOn: on,
            delay: Duration(
                milliseconds: stagger * i),
            child: chip,
          );
        },
      ),
    );
  }

  Widget _body(ColorScheme scheme, bool on) {
    final dark =
        Theme.of(context).brightness == Brightness.dark;
    if (_loading) {
      return const Center(
          key: ValueKey('loading'),
          child: IosSpinner(size: 28));
    }
    if (_error != null) {
      return Center(
        key: const ValueKey('error'),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AdaptiveText(
                data: _error!,
                background: scheme.surface,
                align: TextAlign.center,
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: _target,
                child: FilledButton(
                  style: spotifyPlayStyle(),
                  onPressed: () =>
                      _run(_text.text),
                  child: const Text('Retry'),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_episodes.isEmpty) {
      return Center(
        key: const ValueKey('empty'),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.podcasts_outlined,
                  size: 48,
                  color: glassSubtext(dark)),
              const SizedBox(height: 12),
              Text(
                _text.text.trim().isEmpty
                    ? 'Search for shows and episodes to get started.'
                    : 'No episodes found. Try another search.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: glassSubtext(dark),
                    fontSize: 15),
              ),
            ],
          ),
        ),
      );
    }
    return ListView.separated(
      key: const ValueKey('results'),
      padding: const EdgeInsets.fromLTRB(
          12, 4, 12, 24),
      itemCount: _episodes.length,
      separatorBuilder: (_, _) =>
          const SizedBox(height: 4),
      itemBuilder: (ctx, i) {
        final ep = _episodes[i];
        final tile = _episodeTile(ep, scheme, dark);
        if (i >= motion.staggerCapItems) return tile;
        return FadeSlide(
          motionOn: on,
          delay: Duration(
              milliseconds: motion.motionMs(
                  on, motion.staggerMs * i)),
          child: tile,
        );
      },
    );
  }

  /// Episode CARD (music-section language): wide 16:9 art on top,
  /// title (2 lines) + subtitle (1 line) below on the surface, progress
  /// + resume badge, action row (play / download / follow). Whole
  /// card taps to play; icon buttons keep 48px targets.
  Widget _episodeTile(
      PodcastEpisode ep, ColorScheme scheme, bool dark) {
    final resumeMs = _resumeFor(ep);
    final frac = resumeFractionOf(
        resumeMs, ep.durationSec);
    final offerResume =
        shouldOfferResumeFor(resumeMs, ep.durationSec);
    final dl = _downloadState(ep);
    final followed =
        widget.isShowFollowed?.call(ep) ?? false;
    return RepaintBoundary(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius:
              BorderRadius.circular(16),
          onTap: () =>
              widget.onPlay?.call(ep, resumeMs),
          child: Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius:
                    BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: CachedNetworkImage(
                    imageUrl: ep.thumbUrl,
                    fit: BoxFit.cover,
                    errorWidget: (_, _, _) => Container(
                      color: scheme
                          .surfaceContainerHighest,
                      child: Icon(Icons.podcasts,
                          size: 44,
                          color: scheme
                              .onSurfaceVariant),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    4, 8, 4, 2),
                child: AdaptiveText(
                  data: ep.title.isEmpty
                      ? 'Untitled episode'
                      : ep.title,
                  background: scheme.surface,
                  maxLines: 2,
                  overflow:
                      TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 4),
                child: AdaptiveText(
                  data: _subtitleFor(ep),
                  background: scheme.surface,
                  secondary: true,
                  maxLines: 1,
                  overflow:
                      TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 12.5),
                ),
              ),
              if (frac >= 0) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 4),
                  child: ClipRRect(
                    borderRadius:
                        BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: frac,
                      minHeight: 3,
                      backgroundColor: scheme
                          .surfaceContainerHighest,
                      valueColor:
                          AlwaysStoppedAnimation<
                                  Color>(
                              scheme.primary),
                    ),
                  ),
                ),
              ],
              Row(
                children: [
                  if (offerResume)
                    Container(
                      margin:
                          const EdgeInsets.only(left: 4),
                      padding:
                          const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3),
                      decoration: BoxDecoration(
                        color: scheme.primary
                            .withValues(alpha: 0.18),
                        borderRadius:
                            BorderRadius.circular(10),
                      ),
                      child: Text(
                        'Resume ${fmtEpisodeMs(resumeMs)}',
                        style: TextStyle(
                            color:
                                scheme.onSurface,
                            fontSize: 11,
                            fontWeight:
                                FontWeight.w700),
                      ),
                    ),
                  const Spacer(),
                  SizedBox(
                    width: _target,
                    height: _target,
                    child: IconButton(
                      tooltip: 'Play episode',
                      iconSize: 26,
                      onPressed: () => widget.onPlay
                          ?.call(ep, resumeMs),
                      icon: Icon(Icons.play_arrow,
                          color: scheme.primary),
                    ),
                  ),
                  _downloadButton(ep, dl, scheme),
                  if (ep.showTitle.trim().isNotEmpty &&
                      widget.onFollowShow != null &&
                      !followed)
                    SizedBox(
                      width: _target,
                      height: _target,
                      child: IconButton(
                        tooltip:
                            'Follow ${ep.showTitle}',
                        iconSize: 22,
                        onPressed: () => widget
                            .onFollowShow
                            ?.call(ep),
                        icon: Icon(
                            Icons.person_add_outlined,
                            color: scheme
                                .onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _subtitleFor(PodcastEpisode ep) {
    try {
      final bits = <String>[];
      if (ep.showTitle.isNotEmpty) {
        bits.add(ep.showTitle);
      }
      if (ep.durationSec > 0) {
        bits.add(
            fmtEpisodeMs(ep.durationSec * 1000));
      }
      if (ep.publishDate.isNotEmpty) {
        bits.add(ep.publishDate);
      }
      return bits.isEmpty
          ? 'Episode'
          : bits.join(' • ');
    } catch (_) {
      return 'Episode';
    }
  }

  PodcastDownloadState _downloadState(PodcastEpisode ep) {
    try {
      return widget.downloadState?.call(ep) ??
          const PodcastDownloadState();
    } catch (_) {
      return const PodcastDownloadState();
    }
  }

  Widget _downloadButton(PodcastEpisode ep,
      PodcastDownloadState dl, ColorScheme scheme) {
    Widget icon;
    if (dl.downloaded) {
      icon = Icon(Icons.download_done,
          color: scheme.primary);
    } else if (dl.downloading) {
      icon = SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: dl.progress >= 0
              ? dl.progress / 100
              : null,
          color: scheme.primary,
        ),
      );
    } else {
      icon = Icon(Icons.download_outlined,
          color: scheme.onSurfaceVariant);
    }
    return SizedBox(
      width: _target,
      height: _target,
      child: IconButton(
        tooltip: dl.downloaded
            ? 'Downloaded for offline'
            : 'Download for offline',
        iconSize: 22,
        onPressed: dl.downloading
            ? null
            : () => widget.onDownload?.call(ep),
        icon: icon,
      ),
    );
  }

  Widget _showThumb(String url, ColorScheme scheme) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 44,
        height: 44,
        color: scheme.surfaceContainerHighest,
        child: url.isEmpty
            ? Icon(Icons.podcasts,
                color: scheme.onSurfaceVariant)
            : CachedNetworkImage(
                imageUrl: url,
                width: 44,
                height: 44,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => Icon(
                    Icons.podcasts,
                    color:
                        scheme.onSurfaceVariant),
              ),
      ),
    );
  }
}
