// Player transport (U4 split): seek bar + elapsed/-remaining, 3-button
// transport, volume row, output pill. Extracted verbatim from
// player_sheet.dart — layout and behavior unchanged.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/motion.dart';
import '../../core/track.dart';
import '../../audio/system_volume.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'audio_output_sheet.dart';
import 'player_header.dart';
import 'queue_sheet.dart';
import 'video_sheet.dart';


/// Press-scale wrapper (0.94 / 120ms, transform only).
class PressScale extends StatefulWidget {
  final Widget child;
  const PressScale({super.key, required this.child});

  @override
  State<PressScale> createState() => PressScaleState();
}

class PressScaleState extends State<PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    late final AppState state;
    try {
      state = AppScope.of(context);
    } catch (_) {
      return widget.child;
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) {
        try {
          setState(() => _down = true);
        } catch (_) {}
      },
      onTapUp: (_) {
        try {
          setState(() => _down = false);
        } catch (_) {}
      },
      onTapCancel: () {
        try {
          setState(() => _down = false);
        } catch (_) {}
      },
      child: AnimatedScale(
        duration: Duration(milliseconds: state.motionMs(pressMs)),
        curve: Curves.easeOut,
        scale: _down ? pressedScale : 1.0,
        child: widget.child,
      ),
    );
  }
}

/// Output pill (reference): lyrics bubble | output pill | queue list,
/// with the "This phone" caption. JAM lives inside the Audio output
/// sheet (reachable only from the output section) — no JAM segment
/// here, so the row fits 360dp. The pill honestly reports the only
/// output until device switching lands.
class PlayerOutputPill extends StatelessWidget {
  final AppState state;
  final VoidCallback onLyrics;
  final bool lyricsActive;
  const PlayerOutputPill(
      {required this.state,
      required this.onLyrics,
      this.lyricsActive = false});

  @override
  Widget build(BuildContext context) {
    Widget circle(
        {required IconData icon,
        required String tip,
        required VoidCallback onTap,
        bool active = false}) {
      // State toggles animate color + size (180ms, no blur).
      return PressScale(
        child: Tooltip(
          message: tip,
          child: Semantics(
            button: true,
            label: tip,
            child: GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration:
                  Duration(milliseconds: state.motionMs(180)),
              curve: Curves.easeOut,
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active
                    ? Colors.white.withValues(alpha: 0.24)
                    : Colors.white.withValues(alpha: 0.14),
                border: Border.all(
                    color: Colors.white.withValues(alpha: 0.22),
                    width: 0.5),
              ),
              child: Icon(icon,
                  color: glassText(true),
                  size: 22),
            ),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: playerGutter),
          child: Row(
            mainAxisAlignment:
                MainAxisAlignment.spaceBetween,
            crossAxisAlignment:
                CrossAxisAlignment.center,
            children: [
              circle(
                  icon: Icons.chat_bubble_outline,
                  tip: 'Lyrics',
                  onTap: onLyrics,
                  active: lyricsActive),
              // Output control: ONE pill opening the Audio output
              // sheet (JAM moved there). The bottom row stays lyrics |
              // output | queue.
              Container(
                height: 52,
                padding:
                    const EdgeInsets.symmetric(
                        horizontal: playerGapLg),
                decoration: BoxDecoration(
                  color: Colors.white
                      .withValues(alpha: 0.14),
                  borderRadius:
                      BorderRadius.circular(26),
                  border: Border.all(
                      color: Colors.white
                          .withValues(alpha: 0.22),
                      width: 0.5),
                ),
                child: Tooltip(
                  message: 'Audio output',
                  child: Semantics(
                    button: true,
                    label: 'Audio output',
                    child: GestureDetector(
                      behavior:
                          HitTestBehavior.opaque,
                      onTap: () =>
                          openAudioOutputSheet(context),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: playerGapXs),
                        child: Row(
                          mainAxisSize:
                              MainAxisSize.min,
                          children: [
                            Icon(
                                Icons.headphones_outlined,
                                color: glassText(true),
                                size: 20),
                            const SizedBox(width: playerGapSm),
                            Icon(Icons.person_outline,
                                color: glassText(true),
                                size: 20),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              circle(
                  icon: Icons.playlist_play,
                  tip: 'Queue',
                  onTap: () =>
                      openQueueSheet(context)),
            ],
          ),
        ),
        const SizedBox(height: playerGapSm),
        // Quiet caption + shadow over the dark wash — no scrim box
        // (it stamped a black rectangle under the pill).
        Text('This phone',
            style: TextStyle(
                color: Colors.white
                    .withValues(alpha: 0.65),
                fontSize: 12,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.4,
                shadows: const [
                  Shadow(
                      blurRadius: 8,
                      color: Colors.black87)
                ])),
      ],
    );
  }
}

/// Thin seek bar (reference): hairline progress, tap + drag scrub,
/// knob swell while dragging, elapsed left / -remaining right.
class PlayerSeekBar extends StatelessWidget {
  final AppState state;
  final VideoHandle? handle;
  final double? dragPos;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onSeek;
  const PlayerSeekBar(
      {required this.state,
      this.handle,
      required this.dragPos,
      required this.onDrag,
      required this.onSeek});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: state.controller.player.positionStream,
      builder: (_, posSnap) {
        final pos =
            (posSnap.data ?? Duration.zero).inMilliseconds.toDouble();
        final total = (state.controller.player.duration ?? Duration.zero)
            .inMilliseconds
            .toDouble();
        final value = dragPos ??
            (total <= 0 ? 0.0 : pos.clamp(0.0, total));
        final clamped =
            total <= 0 ? 0.0 : value.clamp(0.0, total);
        final max = total <= 0 ? 1.0 : total;
        Widget slider(double v) => Semantics(
              // Label for TalkBack + dumps; the Slider keeps its
              // native role, value, and adjust actions (merged up).
              label: 'Seek',
              child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                // Elegant thin track; compact thumb resting, gentle swell
                // while dragging; wide overlay keeps the 48px touch target.
                trackHeight: 3,
                trackShape:
                    const RoundedRectSliderTrackShape(),
                thumbShape: RoundSliderThumbShape(
                    enabledThumbRadius:
                        dragPos != null ? 9 : 6),
                overlayShape: const RoundSliderOverlayShape(
                    overlayRadius: 24),
                activeTrackColor:
                    Colors.white.withValues(alpha: 0.95),
                inactiveTrackColor:
                    Colors.white.withValues(alpha: 0.22),
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: max <= 0 ? 0.0 : v.clamp(0.0, max),
                max: max,
                onChanged: onDrag,
                onChangeEnd: onSeek,
              ),
            ),
          );
        // Progress animates between position ticks (TweenAnimationBuilder
        // eases the painted value; dragging stays immediate).
        final bar = dragPos != null
            ? slider(clamped)
            : TweenAnimationBuilder<double>(
                duration:
                    Duration(milliseconds: state.motionMs(180)),
                curve: Curves.linear,
                tween: Tween<double>(begin: 0, end: clamped),
                builder: (_, v, _) => slider(v),
              );
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: playerGutter),
          child: Column(
            children: [
              bar,
              Padding(
                padding: const EdgeInsets.only(top: playerGapXs),
                // Quiet time labels + shadows over the dark wash —
                // no scrim box (it stamped a black rectangle).
                child: Row(
                mainAxisAlignment:
                    MainAxisAlignment.spaceBetween,
                children: [
                    Text(fmtMs(value.toInt()),
                        style: TextStyle(
                            color: Colors.white
                                .withValues(alpha: 0.65),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.3,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ],
                            shadows: const [
                              Shadow(
                                  blurRadius: 8,
                                  color: Colors.black87)
                            ])),
                    // BitChord/YTM parity: remaining, not total.
                    Text(
                        total <= 0
                            ? fmtMs(0)
                            : '-${fmtMs((total - value).clamp(0.0, total).toInt())}',
                        style: TextStyle(
                            color: Colors.white
                                .withValues(alpha: 0.65),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 0.3,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ],
                            shadows: const [
                              Shadow(
                                  blurRadius: 8,
                                  color: Colors.black87)
                            ])),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Transport (reference): prev / play-pause / next only — large
/// white glyphs, no circles. Shuffle / repeat live in overflow.
/// Shows a spinner while resolving/buffering. While embedded video is
/// active, the center button drives the picture (via [handle]) instead
/// of the audio engine.
class PlayerTransport extends StatelessWidget {
  final AppState state;
  final VideoHandle handle;
  const PlayerTransport({required this.state, required this.handle});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: handle.active,
      builder: (_, videoActive, _) {
        if (videoActive) {
          return ValueListenableBuilder<bool>(
            valueListenable: handle.playing,
            builder: (_, vPlaying, _) {
              return ValueListenableBuilder<bool>(
                valueListenable: handle.loading,
                builder: (_, vLoading, _) =>
                    _transportRow(
                  context,
                  playing: vPlaying,
                  loading: vLoading,
                  onToggle: () {
                    try {
                      handle.togglePlay?.call();
                    } catch (_) {}
                  },
                ),
              );
            },
          );
        }
        return StreamBuilder<PlayerState>(
          stream: state.controller.player.playerStateStream,
          builder: (_, snap) {
            final playing = snap.data?.playing ??
                state.controller.player.playing;
            // Spinner only when genuinely stalled: background tail
            // prefetch sets `resolving` while music keeps playing, and
            // that must never mask the pause button.
            final stalled = snap.data?.processingState ==
                    ProcessingState.loading ||
                snap.data?.processingState == ProcessingState.buffering;
            final loading =
                (stalled || state.controller.resolving) && !playing;
            return _transportRow(
              context,
              playing: playing,
              loading: loading,
              onToggle: () =>
                  state.controller.togglePlay(),
            );
          },
        );
      },
    );
  }

  Widget _transportRow(
    BuildContext context, {
    required bool playing,
    required bool loading,
    required VoidCallback onToggle,
  }) {
    return Padding(
          padding:
              const EdgeInsets.symmetric(vertical: playerGapXs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              PressScale(
                child: SizedBox(
                  width: 80,
                  height: 80,
                  child: IconButton(
                  iconSize: 56,
                  icon: Icon(Icons.fast_rewind,
                      color: glassText(true)),
                  tooltip: 'Previous',
                  onPressed: () =>
                      state.controller.previous(),
                  ),
                ),
              ),
              const SizedBox(width: playerGapSm),
              // Loading <-> icon crossfade + play/pause morph
              // (scale + rotation, 180ms). Reference look: big
              // white glyphs straight on the wash, no discs.
              AnimatedSwitcher(
                duration:
                    Duration(milliseconds: state.motionMs(180)),
                transitionBuilder: (child, anim) {
                  final curved = CurvedAnimation(
                      parent: anim, curve: Curves.easeOut);
                  return FadeTransition(
                      opacity: curved, child: child);
                },
                child: loading
                    ? SizedBox(
                        key: const ValueKey('loading'),
                        width: 80,
                        height: 80,
                        child: Padding(
                          padding:
                              const EdgeInsets.all(20),
                          child:
                              CircularProgressIndicator(
                                  color:
                                      glassText(true),
                                  strokeWidth: 3),
                        ),
                      )
                    : PressScale(
                        key: const ValueKey('transport'),
                        child: SizedBox(
                          width: 96,
                          height: 96,
                          child: IconButton(
                          iconSize: 76,
                          icon: AnimatedSwitcher(
                            duration: Duration(
                                milliseconds:
                                    state.motionMs(180)),
                            transitionBuilder:
                                (child, anim) {
                              final curved = CurvedAnimation(
                                  parent: anim,
                                  curve: Curves.easeOut);
                              return ScaleTransition(
                                scale: Tween<double>(
                                        begin: 0.6,
                                        end: 1.0)
                                    .animate(curved),
                                child: RotationTransition(
                                  turns: Tween<double>(
                                          begin: -0.12,
                                          end: 0.0)
                                      .animate(curved),
                                  child: FadeTransition(
                                      opacity: curved,
                                      child: child),
                                ),
                              );
                            },
                            child: Icon(
                              playing
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              key:
                                  ValueKey<bool>(playing),
                              color: glassText(true),
                            ),
                          ),
                          tooltip:
                              playing ? 'Pause' : 'Play',
                          onPressed: onToggle,
                        ),
                      ),
                    ),
              ),
              const SizedBox(width: playerGapSm),
              PressScale(
                child: SizedBox(
                  width: 80,
                  height: 80,
                  child: IconButton(
                  iconSize: 56,
                  icon: Icon(Icons.fast_forward,
                      color: glassText(true)),
                  tooltip: 'Next',
                  onPressed: () =>
                      state.controller.next(),
                  ),
                ),
              ),
            ],
          ),
        );
  }
}

/// Volume row (Apple-Music shape): 20dp speakers + slider.
/// Drives the SYSTEM volume (STREAM_MUSIC via SystemVolume): the stream
/// emits the current level first, then hardware-button changes; drags
/// call setLevel. The audio-engine level is never reset here.
class PlayerVolumeRow extends StatefulWidget {
  final AppState state;
  const PlayerVolumeRow({required this.state});

  @override
  State<PlayerVolumeRow> createState() => PlayerVolumeRowState();
}

class PlayerVolumeRowState extends State<PlayerVolumeRow> {
  late final Stream<double> _stream = _sysVolume();

  static Stream<double> _sysVolume() async* {
    try {
      yield await SystemVolume.level();
    } catch (_) {
      yield 1.0;
    }
    yield* SystemVolume.watch();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return StreamBuilder<double>(
      stream: _stream,
      initialData: 1.0,
      builder: (_, snap) {
        final v = (snap.data ?? 1.0).clamp(0.0, 1.0);
        // Volume eases between stream ticks (120ms); the drag itself
        // stays immediate via onChanged driving the system volume.
        final slider = TweenAnimationBuilder<double>(
          duration: Duration(milliseconds: state.motionMs(pressMs)),
          curve: Curves.linear,
          tween: Tween<double>(begin: 0, end: v),
          builder: (_, av, _) => SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              thumbShape:
                  const RoundSliderThumbShape(
                      enabledThumbRadius: 7),
              overlayShape:
                  const RoundSliderOverlayShape(
                      overlayRadius: 24),
              activeTrackColor: Colors.white
                  .withValues(alpha: 0.9),
              inactiveTrackColor: Colors.white
                  .withValues(alpha: 0.22),
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: av,
              onChanged: (nv) {
                try {
                  SystemVolume.setLevel(nv);
                } catch (_) {}
              },
            ),
          ),
        );
        return Padding(
          padding:
              const EdgeInsets.fromLTRB(
                  playerGutter, 0, playerGutter, playerGapXs),
          child: Row(
            children: [
              Icon(Icons.volume_down_outlined,
                  size: 20,
                  color: Colors.white
                      .withValues(alpha: 0.65)),
              const SizedBox(width: playerGapMd),
              Expanded(child: slider),
              const SizedBox(width: playerGapMd),
              Icon(Icons.volume_up_outlined,
                  size: 20,
                  color: Colors.white
                      .withValues(alpha: 0.65)),
            ],
          ),
        );
      },
    );
  }
}
