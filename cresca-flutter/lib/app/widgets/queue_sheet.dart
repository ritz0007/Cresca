// Queue sheet (reference parity): drag handle + mini header
// (art + title/artist + overflow), "Queue" title + "Similar music,
// selected to play next" subtitle, flat up-next list with drag
// handles (=), art + title/artist, per-row X remove, long-press
// drag reorder, tap-to-play. Gapless auto-advance + instant skip
// + repeat labels ride the engine as before.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/queue.dart';
import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'track_menu.dart';
import 'track_row.dart';

Future<void> openQueueSheet(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
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
  } catch (_) {
    try {
      messenger.showSnackBar(
          SnackBar(content: Semantics(liveRegion: true, child: Text('Could not open queue'))));
    } catch (_) {}
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
                    child: Row(
                      children: [
                        Expanded(
                          child: Text('Queue',
                              style: TextStyle(
                                  color: glassText(true),
                                  fontSize: 20,
                                  fontWeight:
                                      FontWeight.w700,
                                  letterSpacing: -0.3,
                                  height: 1.2)),
                        ),
                        IconButton(
                          icon: Icon(Icons.close,
                              color: glassSubtext(true)),
                          tooltip: 'Close queue',
                          onPressed: () =>
                              Navigator.pop(context),
                        ),
                      ],
                    ),
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
              SliverReorderableList(
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
                onReorderStart: (_) {
                  // One haptic per grab — never on move ticks.
                  try {
                    HapticFeedback.lightImpact();
                  } catch (_) {}
                },
                onReorderItem: (a, b) {
                  // Snapshot BEFORE mutation: Undo re-commits the exact
                  // inverse via applyOrder (commit-on-drop stays).
                  List<int> prevOrder = const [];
                  try {
                    prevOrder = state.controller.engine
                        .playOrder();
                  } catch (_) {}
                  YtTrack? moved;
                  try {
                    final movedIndex = next[a];
                    if (movedIndex >= 0 &&
                        movedIndex <
                            engine.items.length) {
                      moved =
                          engine.items[movedIndex];
                    }
                  } catch (_) {}
                  try {
                    // onReorderItem hands an already-adjusted
                    // newIndex (removal accounted for).
                    state.controller.engine
                        .moveInOrder(
                            pos + 1 + a, pos + 1 + b);
                    state.poke();
                  } catch (_) {
                    return;
                  }
                  if (moved == null) return;
                  final movedTitle = moved.title;
                  try {
                    ScaffoldMessenger.of(context)
                      ..hideCurrentSnackBar()
                      ..showSnackBar(SnackBar(
                        content: Semantics(liveRegion: true, child: Text('Moved "$movedTitle"')),
                        duration: const Duration(
                            seconds: 5),
                        action: SnackBarAction(
                          label: 'Undo',
                          onPressed: () {
                            try {
                              state.controller.engine
                                  .applyOrder(
                                      prevOrder);
                              state.poke();
                            } catch (_) {}
                          },
                        ),
                      ));
                  } catch (_) {}
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
                    // Stable track-id key (never positional): reorder
                    // keeps row state instead of remounting every row.
                    key: ValueKey('qn-${t.id}'),
                    state: state,
                    engine: engine,
                    itemIndex: itemIndex,
                    reorderIndex: i,
                    track: t,
                  );
                },
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
  // Engine item index (removal identity) vs sliver position (drag
  // identity): the key is the track id, so both survive reorder.
  final int itemIndex;
  final int reorderIndex;
  final YtTrack track;
  const _QueueRow(
      {super.key,
      required this.state,
      required this.engine,
      required this.itemIndex,
      required this.reorderIndex,
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
    } catch (_) {}
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
    // Snapshot BEFORE mutation: Undo re-inserts at this slot and
    // restores the exact order (see restoreRemoved).
    final track = widget.track;
    final at = widget.itemIndex;
    List<int> prevOrder = const [];
    try {
      prevOrder =
          widget.state.controller.engine.playOrder();
    } catch (_) {}
    ScaffoldMessengerState? messenger;
    try {
      messenger = ScaffoldMessenger.of(context);
    } catch (_) {}
    void finish() {
      if (_removed) return;
      _removed = true;
      try {
        widget.state.controller.engine.removeAt(at);
        widget.state.poke();
      } catch (_) {}
      final m = messenger;
      if (m == null) return;
      try {
        m
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            content: Semantics(liveRegion: true, child: Text('Removed "${track.title}"')),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () {
                try {
                  widget.state.controller.engine
                      .restoreRemoved(
                          index: at,
                          track: track,
                          prevOrder: prevOrder);
                  widget.state.poke();
                } catch (_) {}
              },
            ),
          ));
      } catch (_) {}
    }

    try {
      final waitMs = widget.state.motionMs(220);
      setState(() => _removing = true);
      _c.reverse().whenComplete(finish);
      // Safety net: if the reverse never completes (disposed mid
      // reorder), still perform the identical removal — once.
      Future<void>.delayed(
          Duration(milliseconds: waitMs + 120), () {
        if (!mounted || _removed) return;
        finish();
      });
    } catch (_) {
      try {
        finish();
      } catch (_) {}
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
          child: ReorderableDelayedDragStartListener(
            index: widget.reorderIndex,
            child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        try {
          state.controller.playAt(itemIndex);
        } catch (_) {}
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
            12, 5, 12, 5),
        child: Row(
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 4),
              child: ReorderableDragStartListener(
                index: widget.reorderIndex,
                child: Semantics(
                  button: true,
                  label: 'Reorder ${track.title}',
                  excludeSemantics: true,
                  child: Icon(Icons.drag_handle,
                      color: glassSubtext(true),
                      size: 20),
                ),
              ),
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
        pool = const [];
      }
      if (pool.isEmpty) return const [];
      Set<String> queueIds = const {};
      try {
        queueIds =
            widget.engine.snapshot().map((e) => e.id).toSet();
      } catch (_) {}
      Map<String, double> affinities = const {};
      try {
        affinities = affinityFor(
          liked: widget.state.library.liked,
          recent: widget.state.library.recent,
        );
      } catch (_) {
        affinities = const {};
      }
      Map<String, int> skips = const {};
      try {
        skips = Map.of(widget.engine.skipCounts);
      } catch (_) {}
      Set<String> relatedIds = const {};
      try {
        // Graph head floats: first half of the autoplay pool keeps the
        // repo order signal; the ranker re-scores everything anyway.
        relatedIds =
            pool.take(10).map((e) => e.id).toSet();
      } catch (_) {}
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
      return const [];
    }
  }

  void _added(YtTrack t) {
    try {
      if (mounted) setState(() => _dismissed.add(t.id));
    } catch (_) {}
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
          } catch (_) {}
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
    } catch (_) {}
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
            try {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                      content: Semantics(liveRegion: true, child: Text('Added to queue'))));
            } catch (_) {}
          }
        } catch (_) {}
        try {
          widget.onGone(widget.track);
        } catch (_) {}
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
        } catch (_) {}
        try {
          widget.onGone(widget.track);
        } catch (_) {}
      });
    } catch (_) {
      try {
        if (!widget.engine
            .containsId(widget.track.id)) {
          widget.engine.addToQueue(widget.track);
          widget.state.poke();
        }
        widget.onGone(widget.track);
      } catch (_) {}
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
  } catch (_) {}
}
