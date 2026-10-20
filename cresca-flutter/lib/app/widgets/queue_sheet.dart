// Queue sheet (reference parity): drag handle + mini header
// (art + title/artist + overflow), "Queue" title + "Similar music,
// selected to play next" subtitle, flat up-next list with drag
// handles (=), art + title/artist, per-row X remove, long-press
// drag reorder, tap-to-play. Gapless auto-advance + instant skip
// + repeat labels ride the engine as before.

import 'package:flutter/material.dart';

import '../../core/queue.dart';
import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'cresca_toast.dart';
import 'track_menu.dart';
import 'track_row.dart';

Future<void> openQueueSheet(BuildContext context) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scroll) => Theme(
          data: crescaTheme(Brightness.dark),
          child: GlassSheetSurface(
            child: QueueSheet(scroll: scroll),
          ),
        ),
      ),
    );
  } catch (e, st) {
    await logUserFailure(context, 'open queue failed', e, st);
    await showCrescaToast(context, 'Could not open queue — Retry');
  }
}

/// Queue layout language: one gutter, quiet headers, even rows.
/// Layout-only — engine behavior byte-identical.
const _qGutter = 20.0;

class QueueSheet extends StatelessWidget {
  final ScrollController scroll;
  const QueueSheet({super.key, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final engine = state.controller.engine;
        final order = engine.playOrder();
        final pos = order.indexOf(engine.currentIndex);
        final next = pos < 0 || pos >= order.length - 1
            ? <int>[]
            : order.sublist(pos + 1);
        final cur = engine.current;
        return CustomScrollView(
          controller: scroll,
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Semantics(
                    label: 'Drag handle',
                    container: true,
                    child: const SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: Center(
                        child: _QueueGrabBar(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (cur != null)
                    _MiniHeader(
                        state: state, track: cur),
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(
                            _qGutter, 12, _qGutter, 2),
                    child: Text('Queue',
                        style: TextStyle(
                            color: glassText(true),
                            fontSize: 20,
                            fontWeight:
                                FontWeight.w700,
                            letterSpacing: -0.3,
                            height: 1.2)),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                        _qGutter, 0, _qGutter, 8),
                    child: Text(
                        engine.shuffleMode ==
                                shuffleSmart
                            ? 'Similar music, selected to play next • smart shuffled'
                            : 'Similar music, selected to play next',
                        style: TextStyle(
                            color: glassSubtext(true),
                            fontSize: 13,
                            height: 1.35)),
                  ),
                ],
              ),
            ),
            if (next.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      _qGutter, 24, _qGutter, 48),
                  child: Text(
                      'Nothing up next — add songs from any row menu.',
                      style: TextStyle(
                          color: glassSubtext(true),
                          fontSize: 13,
                          height: 1.4)),
                ),
              )
            else
              SliverToBoxAdapter(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  physics:
                      const NeverScrollableScrollPhysics(),
                  itemCount: next.length,
                  // Drag proxy: elevation + subtle scale while dragging
                  // (transform/opacity only; default handle kept).
                  proxyDecorator: (child, _, animation) =>
                      AnimatedBuilder(
                    animation: animation,
                    builder: (_, _) => Transform.scale(
                      scale: 1.0 + 0.04 * animation.value,
                      child: Opacity(
                        opacity: 0.85 + 0.15 * animation.value,
                        child: Material(
                          type: MaterialType.transparency,
                          elevation:
                              6 * animation.value,
                          borderRadius:
                              BorderRadius.circular(12),
                          child: child,
                        ),
                      ),
                    ),
                  ),
                  onReorderItem: (a, b) {
                    try {
                      // onReorderItem hands an already-adjusted
                      // newIndex (removal accounted for).
                      state.controller.engine
                          .moveInOrder(
                              pos + 1 + a, pos + 1 + b);
                      state.poke();
                    } catch (e, st) {
                      state.crash.log(
                          'queue reorder failed', e, st);
                    }
                  },
                  itemBuilder: (_, i) {
                    final itemIndex = next[i];
                    final t = (itemIndex >= 0 &&
                            itemIndex <
                                engine.items.length)
                        ? engine.items[itemIndex]
                        : null;
                    if (t == null) {
                      return SizedBox(
                          key: ValueKey(
                              'qn-$itemIndex'));
                    }
                    return _QueueRow(
                      key: ValueKey(
                          'qn-$itemIndex-$i'),
                      state: state,
                      engine: engine,
                      itemIndex: itemIndex,
                      track: t,
                    );
                  },
                ),
              ),
            // Suggested next: autoplay-ranked, one-tap add. Renders
            // nothing while loading/empty; queue rows above keep their
            // animated insert/remove exactly as before.
            SliverToBoxAdapter(
              child: _SuggestedNext(
                state: state,
                engine: engine,
                current: cur,
              ),
            ),
            const SliverPadding(
                padding:
                    EdgeInsets.only(bottom: 32)),
          ],
        );
      },
    );
  }
}

/// Mini header: 40dp art + title/artist + overflow (reference).
class _MiniHeader extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  const _MiniHeader(
      {required this.state, required this.track});

  @override
  Widget build(BuildContext context) {
    // Now-playing row: highlighted background (AnimatedContainer,
    // 220ms) + animated equalizer/pulse indicator.
    return AnimatedContainer(
      duration: Duration(milliseconds: state.motionMs(220)),
      curve: Curves.easeOut,
      margin:
          const EdgeInsets.fromLTRB(_qGutter, 4, _qGutter, 8),
      padding: const EdgeInsets.symmetric(
          horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: Theme.of(context)
                .colorScheme
                .primary
                .withValues(alpha: 0.35),
            width: 0.8),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child:
                TrackArt(track: track, size: 44),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                Text(track.title,
                    maxLines: 1,
                    overflow:
                        TextOverflow.ellipsis,
                    style: TextStyle(
                        color: glassText(true),
                        fontWeight:
                            FontWeight.w600,
                        fontSize: 14,
                        letterSpacing: -0.1,
                        height: 1.25)),
                Text(track.displayArtist(),
                    maxLines: 1,
                    overflow:
                        TextOverflow.ellipsis,
                    style: TextStyle(
                        color: glassSubtext(true),
                        fontSize: 12,
                        height: 1.3)),
              ],
            ),
          ),
          const _NowPlayingEq(),
          IconButton(
            icon: Icon(Icons.more_horiz,
                color: glassText(true)),
            tooltip: 'More',
            onPressed: () => showTrackMenu(
                context,
                state,
                track,
                state.controller.engine
                    .snapshot()),
          ),
        ],
      ),
    );
  }
}

/// Animated equalizer/pulse for the now-playing row (transform-only
/// bar scales; honors the motion kill-switch by freezing).
class _NowPlayingEq extends StatefulWidget {
  const _NowPlayingEq();

  @override
  State<_NowPlayingEq> createState() => _NowPlayingEqState();
}

class _NowPlayingEqState extends State<_NowPlayingEq>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = AppScope.of(context).motionOn;
    final color = Theme.of(context).colorScheme.primary;
    if (!on) {
      // Frozen bars when motion is off (kill-switch).
      return ExcludeSemantics(
        child: SizedBox(
          width: 18,
          height: 18,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 3; i++)
                Container(
                    width: 3,
                    height: 8,
                    color: color,
                    margin:
                        const EdgeInsets.only(bottom: 2)),
            ],
          ),
        ),
      );
    }
    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => SizedBox(
          width: 18,
          height: 18,
          child: Row(
            mainAxisAlignment:
                MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _eqBar(color, _c.value),
              _eqBar(color, 1 - _c.value),
              _eqBar(color, (_c.value + 0.3) % 1),
            ],
          ),
        ),
      ),
    );
  }

  Widget _eqBar(Color color, double t) => Align(
        alignment: Alignment.bottomCenter,
        child: Transform.scale(
          scaleY: 0.35 + 0.65 * t,
          alignment: Alignment.bottomCenter,
          child: Container(
            width: 3,
            height: 14,
            color: color,
            margin: const EdgeInsets.only(bottom: 2),
          ),
        ),
      );
}

/// One up-next row: = handle, art, title/artist, X remove.
/// Entrance plays SizeTransition + FadeTransition (220ms); remove
/// animates out first, then performs the identical engine removal.
class _QueueRow extends StatefulWidget {
  final AppState state;
  final QueueEngine engine;
  final int itemIndex;
  final YtTrack track;
  const _QueueRow(
      {super.key,
      required this.state,
      required this.engine,
      required this.itemIndex,
      required this.track});

  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  bool _removing = false;
  bool _removed = false;

  @override
  void initState() {
    super.initState();
    int ms = 220;
    try {
      ms = widget.state.motionMs(220);
    } catch (_) {
      // silent: motion probe, 220 ms default is safe
    }
    _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: ms),
    )..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _remove() {
    if (_removing) return;
    try {
      final waitMs = widget.state.motionMs(220);
      setState(() => _removing = true);
      _c.reverse().whenComplete(() {
        if (_removed) return;
        _removed = true;
        try {
          widget.state.controller.engine
              .removeAt(widget.itemIndex);
          widget.state.poke();
        } catch (e, st) {
          widget.state.crash
              .log('queue remove failed', e, st);
        }
      });
      // Safety net: if the reverse never completes (disposed mid
      // reorder), still perform the identical removal — once.
      Future<void>.delayed(
          Duration(milliseconds: waitMs + 120), () {
        if (!mounted || _removed) return;
        _removed = true;
        try {
          widget.state.controller.engine
              .removeAt(widget.itemIndex);
          widget.state.poke();
        } catch (e, st) {
          widget.state.crash
              .log('queue remove failed', e, st);
        }
      });
    } catch (e, st) {
      widget.state.crash.log('queue remove failed', e, st);
      try {
        widget.state.controller.engine
            .removeAt(widget.itemIndex);
        widget.state.poke();
      } catch (_) {
        // silent: engine fallback failed too, already logged above
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final itemIndex = widget.itemIndex;
    final track = widget.track;
    final curved = CurvedAnimation(
        parent: _c, curve: Curves.easeOut);
    return FadeTransition(
      opacity: curved,
      child: SizeTransition(
        sizeFactor: curved,
        alignment: Alignment.topCenter,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.08, 0),
            end: Offset.zero,
          ).animate(curved),
          child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        try {
          state.controller.playAt(itemIndex);
        } catch (e, st) {
          state.crash.log('queue play failed', e, st);
          showCrescaToast(context, 'Could not play — Retry');
        }
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            12, 5, 12, 5),
        child: Row(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4),
              child: Icon(Icons.drag_handle,
                  color: glassSubtext(true), size: 20),
            ),
            ClipRRect(
              borderRadius:
                  BorderRadius.circular(8),
              child: TrackArt(
                  track: track, size: 48),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(track.title,
                      maxLines: 1,
                      overflow:
                          TextOverflow.ellipsis,
                      style: TextStyle(
                          color: glassText(true),
                          fontSize: 14,
                          fontWeight:
                              FontWeight.w600,
                          letterSpacing: -0.1,
                          height: 1.25)),
                  const SizedBox(height: 2),
                  Text(track.displayArtist(),
                      maxLines: 1,
                      overflow:
                          TextOverflow.ellipsis,
                      style: TextStyle(
                          color: glassSubtext(true),
                          fontSize: 13,
                          height: 1.3)),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close,
                  color: glassSubtext(true), size: 20),
              tooltip: 'Remove',
              onPressed: _remove,
            ),
          ],
        ),
      ),
          ),
        ),
      ),
    );
  }
}

/// Suggested next: autoplay-ranked one-tap adds below the manual queue.
/// Source: repo.autoplayFor (related graph + filler) re-ranked by
/// [rankSuggestions] (artist overlap + discovery affinities + skip
/// decay + diversity caps). Every repo/discovery touch is defensive:
/// any failure falls back to the ranked remainder or hides the
/// section. One tap appends via the identical dupe-safe engine path,
/// so the new queue row plays its kept entrance animation.
class _SuggestedNext extends StatefulWidget {
  final AppState state;
  final QueueEngine engine;
  final YtTrack? current;
  const _SuggestedNext(
      {required this.state,
      required this.engine,
      required this.current});

  @override
  State<_SuggestedNext> createState() => _SuggestedNextState();
}

class _SuggestedNextState extends State<_SuggestedNext> {
  Future<List<YtTrack>>? _future;
  String _seedId = '';
  final Set<String> _dismissed = {};

  @override
  void initState() {
    super.initState();
    _kick();
  }

  @override
  void didUpdateWidget(covariant _SuggestedNext old) {
    super.didUpdateWidget(old);
    if (widget.current?.id != old.current?.id) _kick();
  }

  void _kick() {
    try {
      final seed = widget.current;
      final id = seed?.id ?? '';
      if (id.isEmpty || id == _seedId && _future != null) return;
      _seedId = id;
      _dismissed.clear();
      _future = _load(seed!);
    } catch (_) {
      // silent: suggestion kick only, empty suggestions below
      _future = Future.value(const <YtTrack>[]);
    }
  }

  Future<List<YtTrack>> _load(YtTrack seed) async {
    try {
      List<YtTrack> pool = const [];
      try {
        pool = await widget.state.repo
            .autoplayFor(seed, max: 20)
            .timeout(const Duration(seconds: 15));
      } catch (_) {
        // silent: background autoplay fetch, empty pool shows nothing
        pool = const [];
      }
      if (pool.isEmpty) return const [];
      Set<String> queueIds = const {};
      try {
        queueIds =
            widget.engine.snapshot().map((e) => e.id).toSet();
      } catch (_) {
        // silent: snapshot probe, ranker treats queue as empty
      }
      Map<String, double> affinities = const {};
      try {
        affinities = affinityFor(
          liked: widget.state.library.liked,
          recent: widget.state.library.recent,
        );
      } catch (_) {
        // silent: affinity probe, ranker falls back to pool order
        affinities = const {};
      }
      Map<String, int> skips = const {};
      try {
        skips = Map.of(widget.engine.skipCounts);
      } catch (_) {
        // silent: skip-count probe, ranker ignores skips
      }
      Set<String> relatedIds = const {};
      try {
        // Graph head floats: first half of the autoplay pool keeps the
        // repo order signal; the ranker re-scores everything anyway.
        relatedIds =
            pool.take(10).map((e) => e.id).toSet();
      } catch (_) {
        // silent: related-id probe, ranker proceeds without the signal
      }
      return rankSuggestions(
        seed: seed,
        pool: pool,
        queueIds: queueIds,
        relatedIds: relatedIds,
        affinities: affinities,
        skipCounts: skips,
        max: 5,
      );
    } catch (_) {
      // silent: background suggestion rank, empty suggestions below
      return const [];
    }
  }

  void _added(YtTrack t) {
    try {
      if (mounted) setState(() => _dismissed.add(t.id));
    } catch (_) {
      // silent: dismiss-mark only, row already added to the queue
    }
  }

  @override
  Widget build(BuildContext context) {
    final seedId = widget.current?.id ?? '';
    if (seedId.isEmpty) return const SizedBox.shrink();
    final f = _future;
    if (f == null) return const SizedBox.shrink();
    return FutureBuilder<List<YtTrack>>(
      future: f,
      builder: (_, snap) {
        try {
          if (snap.connectionState !=
              ConnectionState.done) {
            return const SizedBox.shrink();
          }
          final data = snap.data ?? const <YtTrack>[];
          // Drop rows already queued since the fetch (no-dupes race)
          // plus locally added ones.
          final visible = <YtTrack>[];
          try {
            final queued = widget.engine
                .snapshot()
                .map((e) => e.id)
                .toSet();
            final seen = <String>{};
            for (final t in data) {
              if (_dismissed.contains(t.id)) continue;
              if (queued.contains(t.id)) continue;
              if (!seen.add(t.id)) continue;
              visible.add(t);
              if (visible.length >= 5) break;
            }
          } catch (_) {
            // silent: suggestion filter probe, section hides below
          }
          if (visible.isEmpty) {
            return const SizedBox.shrink();
          }
          return Column(
            crossAxisAlignment:
                CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    _qGutter, 14, _qGutter, 2),
                child: Text('Suggested next',
                    style: TextStyle(
                        color: glassText(true),
                        fontSize: 16,
                        fontWeight:
                            FontWeight.w700,
                        letterSpacing: -0.2,
                        height: 1.25)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                    _qGutter, 0, _qGutter, 4),
                child: Text(
                    'Autoplay picks for this song — tap + to queue',
                    style: TextStyle(
                        color: glassSubtext(true),
                        fontSize: 12,
                        height: 1.35)),
              ),
              for (var i = 0;
                  i < visible.length;
                  i++)
                StaggerEntrance(
                  key: ValueKey(
                      'qs-$_seedId-${visible[i].id}'),
                  index: i,
                  child: _SuggestionRow(
                    key: ValueKey(
                        'qsr-$_seedId-${visible[i].id}'),
                    state: widget.state,
                    engine: widget.engine,
                    track: visible[i],
                    onGone: _added,
                  ),
                ),
            ],
          );
        } catch (_) {
          // silent: suggestion section render, hides on bad snapshot
          return const SizedBox.shrink();
        }
      },
    );
  }
}

/// One suggestion row: art + title/artist + 48px + button. Entrance is
/// the shared fade + rise (220ms via motionMs); tapping + animates out
/// first (reverse, same duration) and only then performs the identical
/// dupe-safe engine append, so the queue row's kept entrance plays.
class _SuggestionRow extends StatefulWidget {
  final AppState state;
  final QueueEngine engine;
  final YtTrack track;
  final void Function(YtTrack) onGone;
  const _SuggestionRow(
      {super.key,
      required this.state,
      required this.engine,
      required this.track,
      required this.onGone});

  @override
  State<_SuggestionRow> createState() => _SuggestionRowState();
}

class _SuggestionRowState extends State<_SuggestionRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  bool _busy = false;
  bool _gone = false;

  @override
  void initState() {
    super.initState();
    int ms = 220;
    try {
      ms = widget.state.motionMs(220);
    } catch (_) {
      // silent: motion probe, 220 ms default is safe
    }
    _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: ms),
    )..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _add() {
    if (_busy) return;
    _busy = true;
    try {
      final waitMs = widget.state.motionMs(220);
      setState(() {});
      _c.reverse().whenComplete(() {
        if (_gone) return;
        _gone = true;
        try {
          // No dupes: skip the append when the row landed in the
          // queue after the fetch (sheet still open elsewhere).
          if (!widget.engine
              .containsId(widget.track.id)) {
            widget.engine
                .addToQueue(widget.track);
            widget.state.poke();
            if (mounted) showCrescaToast(context, 'Added to queue');
          }
        } catch (e, st) {
          widget.state.crash
              .log('suggestion add failed', e, st);
        }
        try {
          widget.onGone(widget.track);
        } catch (_) {
          // silent: dismiss-mark callback, row already added
        }
      });
      Future<void>.delayed(
          Duration(milliseconds: waitMs + 120), () {
        if (!mounted || _gone) return;
        _gone = true;
        try {
          if (!widget.engine
              .containsId(widget.track.id)) {
            widget.engine
                .addToQueue(widget.track);
            widget.state.poke();
          }
        } catch (e, st) {
          widget.state.crash
              .log('suggestion add failed', e, st);
        }
        try {
          widget.onGone(widget.track);
        } catch (_) {
          // silent: dismiss-mark callback, row already added
        }
      });
    } catch (e, st) {
      widget.state.crash.log('suggestion add failed', e, st);
      try {
        if (!widget.engine
            .containsId(widget.track.id)) {
          widget.engine.addToQueue(widget.track);
          widget.state.poke();
        }
        widget.onGone(widget.track);
      } catch (_) {
        // silent: engine fallback failed too, already logged above
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final curved = CurvedAnimation(
        parent: _c, curve: Curves.easeOut);
    return FadeTransition(
      opacity: curved,
      child: SizeTransition(
        sizeFactor: curved,
        alignment: Alignment.topCenter,
        child: Padding(
          padding:
              const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Row(
            children: [
              ClipRRect(
                borderRadius:
                    BorderRadius.circular(8),
                child: TrackArt(
                    track: track, size: 48),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(track.title,
                        maxLines: 1,
                        overflow:
                            TextOverflow.ellipsis,
                        style: TextStyle(
                            color: glassText(true),
                            fontSize: 14,
                            fontWeight:
                                FontWeight.w600,
                            letterSpacing: -0.1,
                            height: 1.25)),
                    const SizedBox(height: 2),
                    Text(track.displayArtist(),
                        maxLines: 1,
                        overflow:
                            TextOverflow.ellipsis,
                        style: TextStyle(
                            color:
                                glassSubtext(true),
                            fontSize: 13,
                            height: 1.3)),
                  ],
                ),
              ),
              SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  icon: Icon(Icons.add,
                      color: glassText(true)),
                  tooltip: 'Add to queue',
                  onPressed: _add,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sheet grab bar: 40x4 pill in a 48px touch/semantics zone.
class _QueueGrabBar extends StatelessWidget {
  const _QueueGrabBar();
  @override
  Widget build(BuildContext context) {
    return Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
            color: Colors.white54,
            borderRadius: BorderRadius.circular(2)));
  }
}

Future<void> showQueueRowMenu(BuildContext context,
    AppState state, YtTrack track,
    List<YtTrack> queue) async {
  try {
    await showTrackMenu(context, state, track, queue);
  } catch (e, st) {
    // Log only: showTrackMenu already toasts its own failures, so a
    // second toast here would double-announce.
    state.crash.log('open track menu failed', e, st);
  }
}
