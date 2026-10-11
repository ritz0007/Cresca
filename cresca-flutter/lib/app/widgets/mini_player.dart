// Mini-player (P10): swipe L/R = next/prev (glide + snap-back + peek
// chevrons), tap opens the full sheet, equalizer bars, red play button,
// progress bar, loading/error states.

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/motion.dart';
import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'player_sheet.dart';
import 'track_row.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return _MiniBodyHost(state: state);
  }
}

class _MiniBodyHost extends StatefulWidget {
  final AppState state;
  const _MiniBodyHost({required this.state});

  @override
  State<_MiniBodyHost> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<_MiniBodyHost>
    with SingleTickerProviderStateMixin {
  double _dx = 0;
  bool _peekLeft = false;
  bool _peekRight = false;
  bool _pressed = false;
  YtTrack? _lastTrack;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    // AppScope never re-notifies (mutable singleton), so subscribe to
    // the ChangeNotifier directly like every other live widget.
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) => _miniBody(state),
    );
  }

  Widget _miniBody(AppState state) {
    final engine = state.controller.engine;
    final track = engine.current;
    // Keep the last track alive one frame so the exit (slide+fade)
    // can play instead of popping to nothing.
    if (track != null) _lastTrack = track;
    final display = track ?? _lastTrack;
    if (display == null) return const SizedBox.shrink();
    final hasTrack = track != null;
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Narrow phones (360dp): shrink trailing glyphs so the
    // art + title + two buttons never overflow the row.
    final narrow =
        MediaQuery.sizeOf(context).width < 380;
    final trailingIconSize = narrow ? 22.0 : 26.0;
    final enterMs = state.motionMs(220);
    if (!hasTrack) {
      // Collapse the slot after the exit fade finishes so an empty
      // queue leaves no invisible gap (re-entry cancels via _lastTrack
      // being repopulated above).
      Future<void>.delayed(
          Duration(milliseconds: enterMs + 60), () {
        if (!mounted) return;
        try {
          if (widget.state.controller.engine.current == null &&
              _lastTrack != null) {
            setState(() => _lastTrack = null);
          }
        } catch (_) {}
      });
    }
    // Swipe gestures live on the whole card; the expand tap lives
    // only on the art+title region so the IconButtons below sit
    // outside the tap region (no nested buttons in AT).
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragEnd: (d) {
        try {
          final v = d.primaryVelocity ?? 0;
          // Swipe-up-to-expand affordance (vertical only; horizontal
          // still drives next/prev below).
          if (v < -300 && hasTrack) openPlayerSheet(context);
        } catch (_) {}
      },
      onHorizontalDragUpdate: (d) {
        try {
          setState(() {
            _dx = (_dx + d.delta.dx).clamp(-96.0, 96.0);
            _peekLeft = _dx < -24;
            _peekRight = _dx > 24;
          });
        } catch (_) {}
      },
      onHorizontalDragEnd: (d) {
        try {
          final v = d.primaryVelocity ?? 0;
          if (_dx < -48 || v < -400) {
            state.controller.next();
          } else if (_dx > 48 || v > 400) {
            state.controller.previous();
          }
          // Glide + snap-back.
          setState(() {
            _dx = 0;
            _peekLeft = false;
            _peekRight = false;
          });
        } catch (_) {}
      },
      // Entrance/exit: 12px slide + fade (~220ms, transform/opacity
      // only). Exit plays against _lastTrack so clearing the queue
      // fades the card out instead of popping it.
      child: AnimatedSlide(
        duration: Duration(milliseconds: enterMs),
        curve: Curves.easeOut,
        offset: hasTrack ? Offset.zero : const Offset(0, 0.18),
        child: AnimatedOpacity(
          duration: Duration(milliseconds: enterMs),
          curve: Curves.easeOut,
          opacity: hasTrack ? 1.0 : 0.0,
          child: ExcludeSemantics(
            excluding: !hasTrack,
            child: Material(
                type: MaterialType.transparency,
                child: Padding(
                  // Bottom gutter is 0 here: it sits directly above the floating
                  // tab bar (own 10dp gutter), so the two read as one chrome unit.
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                  child: AnimatedContainer(
                    duration:
                        Duration(milliseconds: state.motionMs(180)),
                    transform: Matrix4.translationValues(_dx, 0, 0),
                    // Tap press-scale 0.94 / 120ms (transform only).
                    child: AnimatedScale(
                      duration: Duration(
                          milliseconds: state.motionMs(pressMs)),
                      curve: Curves.easeOut,
                      scale: _pressed ? pressedScale : 1.0,
                      child: Glass(
                        radius: 16,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Padding(
                              padding: const EdgeInsets.fromLTRB(
                                  4, 6, 4, 6),
                              child: Row(
                              children: [
                                if (_peekRight)
                                  const Padding(
                                    padding: EdgeInsets.only(left: 4),
                                    child: Icon(Icons.chevron_left,
                                        size: 18),
                                  ),
                                Expanded(
                                  child: Semantics(
                                    button: true,
                                    label: hasTrack
                                        ? 'Now playing ${display.title} by ${display.displayArtist()}. Tap to expand player.'
                                        : 'Mini player',
                                    child: GestureDetector(
                                      behavior:
                                          HitTestBehavior.opaque,
                                      onTap: () {
                                        if (hasTrack) {
                                          openPlayerSheet(context);
                                        }
                                      },
                                      onTapDown: (_) {
                                        try {
                                          setState(() =>
                                              _pressed = true);
                                        } catch (_) {}
                                      },
                                      onTapUp: (_) {
                                        try {
                                          setState(() =>
                                              _pressed = false);
                                        } catch (_) {}
                                      },
                                      onTapCancel: () {
                                        try {
                                          setState(() =>
                                              _pressed = false);
                                        } catch (_) {}
                                      },
                                      child: ListTile(
                                    dense: true,
                                    contentPadding:
                                        const EdgeInsets.symmetric(
                                            horizontal: 8),
                                    leading: _MiniArt(
                                        track: display),
                                    title: Text(
                                      display.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: glassText(dark),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                              height: 1.25),
                        ),
                        subtitle: Text(
                          display.displayArtist(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: glassSubtext(dark),
                              fontSize: 12,
                              height: 1.3),
                        ),
                      ),
                    ),
                  ),
                ),
                ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: 120),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      StreamBuilder<PlayerState>(
                              stream: state.controller.player.playerStateStream,
                              builder: (_, snap) {
                                final playing =
                                    snap.data?.playing ??
                                    state.controller.player.playing;
                                final loading =
                                    snap.data?.processingState ==
                                        ProcessingState.loading ||
                                    snap.data?.processingState ==
                                        ProcessingState.buffering ||
                                    state.controller.resolving;
                                if (loading) {
                                  return Row(
                                    mainAxisSize:
                                        MainAxisSize.min,
                                    children: [
                                      const SizedBox(
                                        width: 30,
                                        height: 30,
                                        child: Padding(
                                          padding:
                                              EdgeInsets.all(
                                                  5),
                                          child:
                                              CircularProgressIndicator(
                                            strokeWidth:
                                                2,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        iconSize: trailingIconSize,
                                        icon: const Icon(Icons
                                            .skip_next),
                                        color: Theme.of(
                                                context)
                                            .colorScheme
                                            .onSurface,
                                        tooltip: 'Next',
                                        onPressed: () =>
                                            state.controller
                                                .next(),
                                      ),
                                    ],
                                  );
                                }
                                // Reference mini style: plain white
                                // glyphs, pause + next, no fill.
                                // Play/pause morph: scale + rotation (180ms).
                                return Row(
                                  mainAxisSize:
                                      MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      iconSize: trailingIconSize,
                                      icon: AnimatedSwitcher(
                                        duration: Duration(
                                            milliseconds:
                                                state.motionMs(
                                                    180)),
                                        transitionBuilder:
                                            (child, anim) {
                                          final curved =
                                              CurvedAnimation(
                                                  parent: anim,
                                                  curve: Curves
                                                      .easeOut);
                                          return ScaleTransition(
                                            scale: Tween<
                                                        double>(
                                                    begin: 0.6,
                                                    end: 1.0)
                                                .animate(
                                                    curved),
                                            child:
                                                RotationTransition(
                                              turns: Tween<
                                                      double>(
                                                  begin:
                                                      -0.12,
                                                  end: 0.0)
                                                  .animate(
                                                      curved),
                                              child: FadeTransition(
                                                  opacity:
                                                      curved,
                                                  child:
                                                      child),
                                            ),
                                          );
                                        },
                                        child: Icon(
                                          playing
                                              ? Icons.pause
                                              : Icons
                                                  .play_arrow,
                                          key: ValueKey<bool>(
                                              playing),
                                        ),
                                      ),
                                      color: Theme.of(
                                              context)
                                          .colorScheme
                                          .onSurface,
                                      tooltip: playing
                                          ? 'Pause'
                                          : 'Play',
                                      onPressed: () =>
                                          state.controller
                                              .togglePlay(),
                                    ),
                                    IconButton(
                                      iconSize: trailingIconSize,
                                      icon: const Icon(Icons
                                          .skip_next),
                                      color: Theme.of(
                                              context)
                                          .colorScheme
                                          .onSurface,
                                      tooltip: 'Next',
                                      onPressed: () =>
                                          state.controller
                                              .next(),
                                    ),
                                  ],
                                );
                              },
                            ),
                    ],
                  ),
                ),
                    if (_peekLeft)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.chevron_right, size: 18),
                      ),
                  ],
                              ),
                            ),
                if (state.controller.errorLine != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      state.controller.errorLine!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: scheme.error, fontSize: 12),
                    ),
                  ),
                _Progress(state: state),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
  ),
  ),
),
);
  }
}

class _MiniArt extends StatelessWidget {
  final YtTrack track;
  const _MiniArt({required this.track});

  @override
  Widget build(BuildContext context) {
    // Artwork crossfade on track change (320ms, subtle 0.96→1 scale).
    final state = AppScope.of(context);
    return SizedBox(
      width: 44,
      height: 44,
      child: AnimatedSwitcher(
        duration: Duration(milliseconds: state.motionMs(320)),
        transitionBuilder: (child, anim) {
          final curved =
              CurvedAnimation(parent: anim, curve: Curves.easeOut);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale:
                  Tween<double>(begin: 0.96, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
        child: _ArtProxy(key: ValueKey(track.id), track: track),
      ),
    );
  }
}

class _ArtProxy extends StatelessWidget {
  final YtTrack track;
  const _ArtProxy({super.key, required this.track});

  @override
  Widget build(BuildContext context) {
    // Reuses the row art (cached thumb + gradient fallback).
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: TrackArt(track: track, size: 44),
    );
  }
}

class _Progress extends StatelessWidget {
  final AppState state;
  const _Progress({required this.state});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: state.controller.player.positionStream,
      builder: (_, snap) {
        final pos = snap.data ?? Duration.zero;
        final total = state.controller.player.duration ?? Duration.zero;
        final f = total.inMilliseconds <= 0
            ? 0.0
            : (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
        // Smooth the bar between position ticks (no setState storms:
        // the stream drives rebuilds, TweenAnimationBuilder eases the
        // painted value between them; transform/opacity-free paint).
        return TweenAnimationBuilder<double>(
          duration: Duration(milliseconds: state.motionMs(200)),
          curve: Curves.linear,
          tween: Tween<double>(begin: 0, end: f),
          builder: (_, value, _) => ExcludeSemantics(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
              value: value,
              minHeight: 2.5,
              backgroundColor: Theme.of(context)
                  .colorScheme
                  .surfaceContainerHighest
                  .withValues(alpha: 0.6),
              valueColor: AlwaysStoppedAnimation<Color>(
                Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.9),
              ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Equalizer bars while sounding (visual only — no haptics anywhere).
class _EqBars extends StatefulWidget {
  final bool running;
  const _EqBars({required this.running});

  @override
  State<_EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<_EqBars> with SingleTickerProviderStateMixin {
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
    bool motionOn = true;
    try {
      motionOn = AppScope.of(context).motionOn;
    } catch (_) {}
    // Kill-switch: freeze on static bars instead of repeating.
    if (!widget.running || !motionOn) {
      try {
        if (_c.isAnimating) _c.stop();
      } catch (_) {}
      return const SizedBox(width: 18, height: 18);
    }
    try {
      if (!_c.isAnimating) {
        _c.repeat(reverse: true);
      }
    } catch (_) {}
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => SizedBox(
        width: 18,
        height: 18,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            _bar(color, 4 + 10 * _c.value),
            _bar(color, 4 + 10 * (1 - _c.value)),
            _bar(color, 4 + 10 * ((_c.value + 0.3) % 1)),
          ],
        ),
      ),
    );
  }

  Widget _bar(Color color, double h) => Container(
    width: 3,
    height: h,
    color: color,
    margin: const EdgeInsets.only(bottom: 2),
  );
}
