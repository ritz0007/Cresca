// Mini-player (P10): swipe L/R = next/prev (glide + snap-back + peek
// chevrons), tap opens the full sheet, equalizer bars, red play button,
// progress bar, loading/error states.

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

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
    if (track == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: () => openPlayerSheet(context),
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
      // Liquid-glass floating card (D3): frosted, specular rim.
      child: Padding(
        // Bottom gutter is 0 here: it sits directly above the floating
        // tab bar (own 10dp gutter), so the two read as one chrome unit.
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
        child: AnimatedContainer(
          duration: Duration(milliseconds: state.motionMs(180)),
          transform: Matrix4.translationValues(_dx, 0, 0),
          child: Glass(
            radius: 18,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    if (_peekRight)
                      const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Icon(Icons.chevron_left, size: 20),
                      ),
                    Expanded(
                      child: ListTile(
                        dense: true,
                        leading: _MiniArt(track: track),
                        title: Text(
                          track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          track.displayArtist(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _EqBars(running: true),
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
                                  return const SizedBox(
                                    width: 40,
                                    height: 40,
                                    child: Padding(
                                      padding: EdgeInsets.all(8),
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  );
                                }
                                // Spotify mini style: white glyph, no fill.
                                return IconButton(
                                  iconSize: 32,
                                  icon: Icon(
                                    playing ? Icons.pause : Icons.play_arrow,
                                  ),
                                  color: Colors.white,
                                  tooltip: playing ? 'Pause' : 'Play',
                                  onPressed: () =>
                                      state.controller.togglePlay(),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_peekLeft)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: Icon(Icons.chevron_right, size: 20),
                      ),
                  ],
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
    );
  }
}

class _MiniArt extends StatelessWidget {
  final YtTrack track;
  const _MiniArt({required this.track});

  @override
  Widget build(BuildContext context) {
    return SizedBox(width: 40, height: 40, child: _ArtProxy(track: track));
  }
}

class _ArtProxy extends StatelessWidget {
  final YtTrack track;
  const _ArtProxy({required this.track});

  @override
  Widget build(BuildContext context) {
    // Reuses the row art (cached thumb + gradient fallback).
    return TrackArt(track: track, size: 40);
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
        return ExcludeSemantics(
          child: LinearProgressIndicator(
            value: f,
            minHeight: 2,
            backgroundColor: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest,
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
    if (!widget.running) {
      return const SizedBox(width: 18, height: 18);
    }
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
