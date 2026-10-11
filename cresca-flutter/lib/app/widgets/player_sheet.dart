// Full player (reference parity): full-bleed artwork wash + static
// edge-to-edge art, "Playing from X", marquee title + overflow,
// lyric preview (tap expands), thin seek bar with remaining time,
// 3-button transport, volume row, bottom output pill
// (lyrics | output | queue + "This phone"). Lyrics mode cross-fades
// in with the mini header + karaoke + translation tools. Shuffle /
// repeat / like / download / video live in the overflow menu.

import 'dart:async';
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/motion.dart';
import '../../core/track.dart';
import '../../audio/system_volume.dart';
import '../../data/details.dart';
import '../../data/lyrics.dart';
import '../../data/translate.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'audio_output_sheet.dart';
import 'lyrics_panel.dart';
import 'queue_sheet.dart';
import 'track_menu.dart';
import 'track_row.dart';
import 'video_sheet.dart';

/// Player layout language (Apple-Music-grade rhythm): one gutter down
/// the whole sheet, one spacing scale, deliberate type steps.
/// Layout-only constants — zero behavior change.
const _gutter = 24.0;
const _gapXs = 4.0;
const _gapSm = 8.0;
const _gapMd = 12.0;
const _gapLg = 16.0;

Future<void> openPlayerSheet(BuildContext context,
    {bool video = false}) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // The artwork must bleed under the status bar (reference
      // parity): no safe-area inset on the sheet route itself.
      useSafeArea: false,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 1.0,
        minChildSize: 0.55,
        maxChildSize: 1.0,
        builder: (_, scroll) =>
            PlayerSheet(scroll: scroll, video: video),
      ),
    );
  } catch (_) {}
}

class PlayerSheet extends StatefulWidget {
  final ScrollController scroll;
  final bool video;
  const PlayerSheet(
      {super.key, required this.scroll, this.video = false});

  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet> {
  double? _dragPos;
  bool _lyricsExpanded = false;
  final ValueNotifier<List<LyricLine>> _lyricLines = ValueNotifier(const []);

  /// Display lines in the EXPANDED karaoke's current language
  /// (Original/English/Hinglish). The collapsed preview renders these
  /// instead of the raw lines, so preview and karaoke never disagree.
  /// Cleared on every raw-lines update (track change / refetch) and
  /// republished by the visible lyrics body; empty = show raw lines.
  final ValueNotifier<List<LyricLine>> _lyricDisplay =
      ValueNotifier(const []);

  /// Track id the display cache belongs to. The hidden lyrics
  /// publisher remounts (and re-fires raw lines from memo) on every
  /// collapse — without this guard that would wipe a selected
  /// translation the moment the user returns to the player.
  String _displayTrackId = '';

  /// Raw-lines intake shared by both lyrics publishers: always
  /// refreshes the raw feed; drops the translated display ONLY when
  /// the lines belong to another track (or a load starts for one).
  /// Same-track reloads keep the selected language.
  void _onRawLyricLines(YtTrack track, List<LyricLine> ls) {
    try {
      _lyricLines.value = ls;
    } catch (_) {}
    try {
      if (ls.isEmpty || track.id != _displayTrackId) {
        _displayTrackId = track.id;
        _lyricDisplay.value = const [];
      }
    } catch (_) {}
  }

  /// YTM-style embedded video mode: the video plays in the art slot in
  /// place. Survives track changes until toggled off. While a fullscreen
  /// expand route is on top, the inline embed is unmounted (exactly one
  /// video controller ever lives).
  bool _videoMode = false;
  bool _videoFull = false;
  final VideoHandle _videoHandle = VideoHandle();

  /// Shared key for the inline [VideoEmbed]: the SAME element moves
  /// between the art slot and the expanded-lyrics compact strip, so
  /// exactly one video controller ever lives and the picture never
  /// reloads on expand/collapse.
  final GlobalKey _videoKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Deep link into video mode (trending rows, track menu): the
    // sheet opens with the video already in the art slot.
    _videoMode = widget.video;
  }

  Future<void> _expandVideo(YtTrack track) async {
    if (_videoFull) return;
    setState(() => _videoFull = true);
    String? res;
    try {
      final state = AppScope.of(context);
      res = await Navigator.of(context, rootNavigator: true)
          .push<String>(MaterialPageRoute<String>(
        builder: (_) =>
            VideoFullscreenPage(state: state, track: track),
      ));
    } catch (_) {
      res = null;
    }
    if (!mounted) return;
    setState(() {
      // Audio-only from fullscreen drops video mode instead of
      // remounting the inline embed.
      if (res == 'audio') _videoMode = false;
      _videoFull = false;
    });
  }

  @override
  void dispose() {
    try {
      _lyricLines.dispose();
    } catch (_) {}
    try {
      _lyricDisplay.dispose();
    } catch (_) {}
    try {
      _videoHandle.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final track = state.controller.engine.current;
        if (track == null) {
          return const Center(child: Text('Nothing playing'));
        }
        // Reference player is always dark. Forcing the dark theme
        // keeps the hardcoded white type/icons legible in light mode.
        // Full-sheet enter: slide up + fade (320ms easeOutCubic,
        // transform/opacity only — blur sigmas never animate).
        //
        // Layout contract (reference parity):
        // - Artwork is full-bleed to the top edge, UNDER the status
        //   bar (no top SafeArea inset; the light overlay style keeps
        //   status icons white over the art). The grab handle + origin
        //   caption float over the art with manual status-bar padding.
        // - Transport (seek / play-pause / volume / output row) is
        //   PINNED at the bottom in all cases — only art, title and
        //   lyrics/details scroll.
        return Theme(
          data: crescaTheme(Brightness.dark),
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: SystemUiOverlayStyle.light,
            child: _SheetEnter(
            ms: state.motionMs(titleSlideMs),
            child: Stack(
            children: [
              Positioned.fill(
                child: _ArtBlurBackdrop(track: track),
              ),
              Builder(builder: (context) {
                final bottomPad =
                    MediaQuery.of(context).padding.bottom;
                return Column(
                  children: [
                    Expanded(
                      child: CustomScrollView(
                      controller: widget.scroll,
                      slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      children: [
                        // Full-bleed art: starts at y=0 behind the
                        // status bar. Horizontal swipe = prev/next
                        // (glide + snap-back, reference feel). Video
                        // mode swaps the static art for the embedded
                        // video surface in the same slot.
                        _ArtSwipe(
                          state: state,
                          child: _videoMode &&
                                  !_videoFull
                              ? VideoEmbed(
                                  key: _videoKey,
                                  state: state,
                                  track: track,
                                  handle: _videoHandle,
                                  onAudioOnly: () {
                                    if (mounted) {
                                      setState(() =>
                                          _videoMode =
                                              false);
                                    }
                                  },
                                  onExpand: () =>
                                      _expandVideo(
                                          track),
                                )
                              : _StaticArt(track: track),
                        ),
                        if (!_lyricsExpanded) ...[
                          // Tight art→title rhythm (reference spacing).
                          const SizedBox(height: _gapSm),
                          // Cross-fade between art-mode title block and
                          // lyrics-mode karaoke (reference transition).
                          AnimatedSwitcher(
                          duration: Duration(
                              milliseconds:
                                  state.motionMs(320)),
                          transitionBuilder:
                              (child, anim) =>
                                  FadeTransition(
                            opacity: anim,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin:
                                    const Offset(0, 0.08),
                                end: Offset.zero,
                              ).animate(CurvedAnimation(
                                  parent: anim,
                                  curve: Curves.easeOut)),
                              child: child,
                            ),
                          ),
                          child: _ArtTitleBlock(
                              key: const ValueKey('art'),
                              state: state,
                              track: track,
                              lines: _lyricLines,
                              display: _lyricDisplay,
                              onRaw: (ls) =>
                                  _onRawLyricLines(
                                      track, ls),
                              handle: _videoHandle,
                              onExpandLyrics: () =>
                                  setState(() =>
                                      _lyricsExpanded =
                                          true),
                              videoActive: _videoMode,
                              onToggleVideo: () =>
                                  setState(() =>
                                      _videoMode =
                                          !_videoMode),
                            ),
                        ),
                        ] else ...[
                          const SizedBox(height: _gapMd),
                          // VIDEO-MODE expanded lyrics: the karaoke lives
                          // in the BOTTOM area with the video still
                          // upfront — compact video strip on top, lyrics
                          // fill below. Never a fullscreen takeover; the
                          // strip reuses the art-slot VideoEmbed element
                          // (shared key), so the picture keeps playing.
                          if (_videoMode && !_videoFull)
                            _CompactVideoStrip(
                              state: state,
                              track: track,
                              videoKey: _videoKey,
                              handle: _videoHandle,
                              onAudioOnly: () {
                                if (mounted) {
                                  setState(() =>
                                      _videoMode = false);
                                }
                              },
                              onExpand: () =>
                                  _expandVideo(track),
                            ),
                          _MiniHeader(
                              state: state, track: track),
                          _LyricsMode(
                            key: const ValueKey(
                                'lyrics'),
                            state: state,
                            track: track,
                            lines: _lyricLines,
                            display: _lyricDisplay,
                            clockMs: _videoMode
                                ? _videoHandle.videoMs
                                : null,
                            onDisplay: (ls) {
                              // Record the owning track alongside the
                              // lines: the remount-clear guard compares
                              // against this, otherwise every collapse
                              // wipes a selected translation.
                              _displayTrackId = track.id;
                              _lyricDisplay.value = ls;
                            },
                            onRaw: (ls) =>
                                _onRawLyricLines(
                                    track, ls),
                            onCollapse: () =>
                                setState(() =>
                                    _lyricsExpanded =
                                        false),
                          ),
                        ],
                        // Scroll clearance so the last line clears
                        // the pinned transport.
                        const SizedBox(height: _gapLg),
                      ],
                    ),
                  ),
                ],
              ),
                    ),
                    // PINNED transport block: never scrolls, never
                    // moves — seek, transport, volume, output row.
                    _SeekBar(
                      state: state,
                      handle: _videoHandle,
                      dragPos: _dragPos,
                      onDrag: (v) =>
                          setState(() => _dragPos = v),
                      onSeek: (ms) {
                        try {
                          state.controller.player.seek(
                              Duration(
                                  milliseconds:
                                      ms.toInt()));
                        } catch (_) {}
                        // While video is active the picture seeks too,
                        // so both clocks land on the same frame.
                        try {
                          _videoHandle.seekToMs
                              ?.call(ms.toInt());
                        } catch (_) {}
                        setState(
                            () => _dragPos = null);
                      },
                    ),
                    _Transport(
                        state: state,
                        handle: _videoHandle),
                    _VolumeRow(state: state),
                    if (state.controller.errorLine !=
                        null)
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(
                                horizontal: _gutter),
                        child: Text(
                            state.controller
                                .errorLine!,
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .error)),
                      ),
                    const SizedBox(height: _gapSm),
                    _OutputPill(
                      state: state,
                      lyricsActive: _lyricsExpanded,
                      onLyrics: () => setState(
                          () => _lyricsExpanded =
                              !_lyricsExpanded),
                    ),
                    SizedBox(
                        height: _gapLg + bottomPad),
                  ],
                );
              }),
              // Floating chrome over the art (manual status-bar
              // padding — never a SafeArea, so the art stays
              // full-bleed behind the status bar).
              Builder(builder: (context) {
                final topPad =
                    MediaQuery.of(context).padding.top;
                return Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(height: topPad + 6),
                      Semantics(
                        label: 'Drag handle',
                        container: true,
                        child: const SizedBox(
                          width: double.infinity,
                          height: 28,
                          child: Center(
                            child: _GrabBar(),
                          ),
                        ),
                      ),
                      if (!_lyricsExpanded)
                        // Plain caption over the dark blurred
                        // backdrop: text + shadow only, never a
                        // pill/scrim box (black rectangles read as
                        // boxes on the dark wash). Contrast rides
                        // white-over-dark + shadow.
                        Text(
                            'Playing from ${state.playOrigin}',
                            style: TextStyle(
                                color: subtextOn(
                                    const Color(
                                        0xFF000000)),
                                fontSize: 12,
                                fontWeight:
                                    FontWeight.w600,
                                letterSpacing: 0.4,
                                shadows: const [
                                  Shadow(
                                      blurRadius: 8,
                                      color: Colors.black87)
                                ])),
                    ],
                  ),
                );
              }),
            ],
          ),
          ),
          ),
        );
      },
    );
  }
}

/// Grab bar (shared chrome): 40x4 pill centered in a 48px
/// touch/semantics zone.
class _GrabBar extends StatelessWidget {
  const _GrabBar();
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

/// Sheet enter wrapper: slide up + fade (320ms easeOutCubic).
/// Transform/opacity only; honors the motion kill-switch via [ms].
class _SheetEnter extends StatelessWidget {
  final int ms;
  final Widget child;
  const _SheetEnter({required this.ms, required this.child});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: ms),
      curve: Curves.easeOutCubic,
      tween: Tween<double>(begin: 0, end: 1),
      builder: (_, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(
          offset: Offset(0, 28 * (1 - v)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// Press-scale wrapper (0.94 / 120ms, transform only).
class _PressScale extends StatefulWidget {
  final Widget child;
  const _PressScale({super.key, required this.child});

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
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

/// Art mode: static edge-to-edge art is above (in the sheet), then the
/// left-aligned marquee title + overflow, artist, lyric preview.
class _ArtTitleBlock extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  final ValueNotifier<List<LyricLine>> lines;
  final ValueNotifier<List<LyricLine>> display;
  final ValueChanged<List<LyricLine>> onRaw;
  final VideoHandle? handle;
  final VoidCallback onExpandLyrics;
  final bool videoActive;
  final VoidCallback onToggleVideo;
  const _ArtTitleBlock(
      {super.key,
      required this.state,
      required this.track,
      required this.lines,
      required this.display,
      required this.onRaw,
      this.handle,
      required this.onExpandLyrics,
      this.videoActive = false,
      required this.onToggleVideo});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Lyric preview rides ABOVE the song name (reference order):
        // live line, then title/artist below it.
        _LyricPreview(
            state: state,
            track: track,
            lines: lines,
            display: display,
            handle: handle,
            onTap: onExpandLyrics),
        Padding(
          padding:
              const EdgeInsets.fromLTRB(_gutter, _gapXs, _gutter, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                // Title/artist slide on track change (320ms spec,
                // transform/opacity only).
                child: AnimatedSwitcher(
                  duration: Duration(
                      milliseconds: state.motionMs(titleSlideMs)),
                  // Pin children left: the default stack centers
                  // shrink-wrapped titles mid-transition.
                  layoutBuilder: (current, previous) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      ...previous,
                      ?current,
                    ],
                  ),
                  transitionBuilder: (child, anim) {
                    final curved = CurvedAnimation(
                        parent: anim, curve: Curves.easeOut);
                    return FadeTransition(
                      opacity: curved,
                      child: SlideTransition(
                        position: Tween<Offset>(
                          begin: const Offset(0.12, 0),
                          end: Offset.zero,
                        ).animate(curved),
                        child: child,
                      ),
                    );
                  },
                  child: Column(
                    key: ValueKey(track.id),
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      _MarqueeTitle(
                          key: ValueKey('t-${track.id}'),
                          text: track.title),
                      GestureDetector(
                        onTap: () =>
                            openArtistPage(context, track),
                        // Plain text + shadow over the dark wash —
                        // no scrim box (boxes read as black
                        // rectangles on the blurred backdrop).
                        child: Text(track.displayArtist(),
                            maxLines: 1,
                            overflow:
                                TextOverflow.ellipsis,
                            textAlign: TextAlign.left,
                            style: TextStyle(
                                color: subtextOn(
                                    const Color(
                                        0xFF000000)),
                                fontSize: 15,
                                fontWeight:
                                    FontWeight.w500,
                                letterSpacing: 0.1,
                                height: 1.3,
                                shadows: const [
                                  Shadow(
                                      blurRadius: 8,
                                      color: Colors.black87)
                                ])),
                      ),
                    ],
                  ),
                ),
              ),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white
                      .withValues(alpha: 0.14),
                  border: Border.all(
                      color: Colors.white
                          .withValues(alpha: 0.22),
                      width: 0.5),
                ),
                child: IconButton(
                  icon: Icon(
                      videoActive
                          ? Icons.videocam
                          : Icons.videocam_outlined,
                      color: glassText(true),
                      size: 22),
                  tooltip: videoActive
                      ? 'Audio only'
                      : 'Video',
                  onPressed: onToggleVideo,
                ),
              ),
              const SizedBox(width: _gapSm),
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white
                      .withValues(alpha: 0.14),
                  border: Border.all(
                      color: Colors.white
                          .withValues(alpha: 0.22),
                      width: 0.5),
                ),
                child: IconButton(
                  icon: Icon(
                      Icons.more_horiz,
                      color: glassText(true),
                      size: 20),
                  tooltip: 'More',
                  onPressed: () => showTrackMenu(
                      context,
                      state,
                      track,
                      state.controller.engine
                          .snapshot()),
                ),
              ),
            ],
          ),
        ),
        // Publishes synced lines for the preview (hidden publisher,
        // excluded from semantics: zero-size live feed only).
        ExcludeSemantics(
          child: SizedBox(
          height: 0,
          child: OverflowBox(
            maxHeight: 0,
            child: LyricsSection(
                track: track,
                hide: true,
                onLines: (ls) {
                  try {
                    onRaw(ls);
                  } catch (_) {
                    try {
                      lines.value = ls;
                    } catch (_) {}
                  }
                }),
          ),
        ),
        ),
      ],
    );
  }
}

/// Lyrics mode: full karaoke (with translation tools + attribution).
/// Forwards the karaoke's display lines + an optional video clock so
/// the collapsed preview matches the expanded language and keeps
/// moving in video mode.
class _LyricsMode extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  final ValueNotifier<List<LyricLine>> lines;
  final ValueNotifier<List<LyricLine>> display;
  final ValueListenable<int>? clockMs;
  final ValueChanged<List<LyricLine>>? onDisplay;
  final ValueChanged<List<LyricLine>> onRaw;
  final VoidCallback onCollapse;
  const _LyricsMode(
      {super.key,
      required this.state,
      required this.track,
      required this.lines,
      required this.display,
      this.clockMs,
      this.onDisplay,
      required this.onRaw,
      required this.onCollapse});

  @override
  Widget build(BuildContext context) {
    return LyricsSection(
        track: track,
        clockMs: clockMs,
        onDisplay: (ls) {
          try {
            if (onDisplay != null) {
              onDisplay!(ls);
            } else {
              display.value = ls;
            }
          } catch (_) {}
        },
        onLines: (ls) {
          try {
            onRaw(ls);
          } catch (_) {
            try {
              lines.value = ls;
            } catch (_) {}
          }
        });
  }
}

/// Marquee title: static ellipsis when it fits or motion is off,
/// slow loop-scroll when a long title overflows (reference behavior).
class _MarqueeTitle extends StatefulWidget {
  final String text;
  const _MarqueeTitle({super.key, required this.text});

  @override
  State<_MarqueeTitle> createState() => _MarqueeTitleState();
}

class _MarqueeTitleState extends State<_MarqueeTitle> {
  final ScrollController _ctrl = ScrollController();
  bool _overflows = false;
  int _gen = 0;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeScroll());
  }

  @override
  void didUpdateWidget(covariant _MarqueeTitle old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) {
      _gen++;
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _maybeScroll(_gen));
    }
  }

  Future<void> _maybeScroll([int? gen]) async {
    final myGen = gen ?? ++_gen;
    try {
      if (!mounted || _disposed || !_ctrl.hasClients) return;
      final motion = AppScope.of(context).motionOn;
      final max = _ctrl.position.maxScrollExtent;
      if (max <= 0 || !motion) {
        if (mounted) setState(() => _overflows = false);
        return;
      }
      if (mounted) setState(() => _overflows = true);
      await Future<void>.delayed(
          const Duration(milliseconds: 1200));
      // Re-check the kill-switch every loop; the generation token
      // cancels stale loops on dispose / track change.
      while (mounted && !_disposed && myGen == _gen && _ctrl.hasClients) {
        bool motionNow = false;
        try {
          motionNow = AppScope.of(context).motionOn;
        } catch (_) {
          motionNow = false;
        }
        if (!motionNow) return;
        final end = _ctrl.position.maxScrollExtent;
        try {
          await _ctrl.animateTo(end,
              duration: Duration(
                  milliseconds: (end * 30).clamp(2000, 6000).toInt()),
              curve: Curves.linear);
        } catch (_) {
          return;
        }
        if (!mounted || _disposed || myGen != _gen) return;
        await Future<void>.delayed(
            const Duration(milliseconds: 900));
        if (!mounted ||
            _disposed ||
            myGen != _gen ||
            !_ctrl.hasClients) {
          return;
        }
        try {
          await _ctrl.animateTo(0,
              duration: const Duration(milliseconds: 800),
              curve: Curves.easeInOut);
        } catch (_) {
          return;
        }
        await Future<void>.delayed(
            const Duration(milliseconds: 1200));
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    try {
      _ctrl.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_overflows) {
      // Plain title + shadow over the dark wash — no scrim box
      // (scrim pills render as black rectangles on the backdrop).
      return Text(widget.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              color: textOn(const Color(0xFF000000)),
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              height: 1.2,
              shadows: const [
                Shadow(blurRadius: 8, color: Colors.black87)
              ]));
    }
    // Scrolling copy is hidden from AT; one label is exposed above it.
    return Semantics(
      label: widget.text,
      child: ExcludeSemantics(
        child: SingleChildScrollView(
      controller: _ctrl,
      scrollDirection: Axis.horizontal,
      physics: const NeverScrollableScrollPhysics(),
      // Plain scrolling title + shadow — no scrim box.
      child: Text('${widget.text}   •   ${widget.text}',
          maxLines: 1,
          style: TextStyle(
              color: textOn(const Color(0xFF000000)),
              fontSize: 22,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              height: 1.2,
              shadows: const [
                Shadow(blurRadius: 8, color: Colors.black87)
              ])),
    ),
      ),
    );
  }
}

/// Full-bleed artwork wash (BitChord/YTM backdrop): maxres art,
/// blurred via ImageFiltered (compositor-safe: no BackdropFilter),
/// dark scrim top-to-bottom for legibility.
class _ArtBlurBackdrop extends StatelessWidget {
  final YtTrack track;
  const _ArtBlurBackdrop({required this.track});

  @override
  Widget build(BuildContext context) {
    final art =
        track.thumbUrl.replaceAll('hqdefault', 'maxresdefault');
    late final int swapMs;
    try {
      swapMs = AppScope.of(context).motionMs(artSlideMs);
    } catch (_) {
      swapMs = artSlideMs;
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        // Opaque base: the modal route behind is transparent, so any
        // image gap (maxres 404s are common) would ghost the home
        // route through as phantom boxes. Black kills that class.
        Container(color: Colors.black),
        // Backdrop washes between artworks (fade only; the fixed
        // blur sigma never animates).
        AnimatedSwitcher(
          duration: Duration(milliseconds: swapMs),
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: art.isNotEmpty
              ? SizedBox.expand(
                  key: ValueKey(track.id),
                  child: ImageFiltered(
                    imageFilter:
                        ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                    child: CachedNetworkImage(
                      imageUrl: art,
                      fit: BoxFit.cover,
                      // maxres 404s often: fall back to the thumb
                      // that provably loads (the poster uses it) so
                      // the wash never goes translucent.
                      errorWidget: (_, _, _) =>
                          CachedNetworkImage(
                        imageUrl: track.thumbUrl,
                        fit: BoxFit.cover,
                        errorWidget: (_, _, _) =>
                            const SizedBox.shrink(),
                      ),
                    ),
                  ),
                )
              : Container(
                  key: const ValueKey('no-art'),
                  color: Colors.black),
        ),
        Container(
          decoration: BoxDecoration(
            // The art zone (top ~45%) stays undarkened: the feathered
            // art edge lands on same-hue blurred art, so no seam can
            // form. Darkness grows only where content sits below.
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.transparent,
                Colors.black.withValues(alpha: 0.45),
                Colors.black.withValues(alpha: 0.75),
              ],
              stops: const [0.0, 0.42, 0.72, 1.0],
            ),
          ),
        ),
      ],
    );
  }
}

/// Compact header (BitChord): 48dp art + title/artist + overflow.
class _MiniHeader extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  const _MiniHeader({required this.state, required this.track});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _gutter),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TrackArt(track: track, size: 44),
          ),
          const SizedBox(width: _gapMd),
          Expanded(
            child: AnimatedSwitcher(
              duration:
                  Duration(milliseconds: state.motionMs(titleSlideMs)),
              transitionBuilder: (child, anim) {
                final curved = CurvedAnimation(
                    parent: anim, curve: Curves.easeOut);
                return FadeTransition(
                  opacity: curved,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.12, 0),
                      end: Offset.zero,
                    ).animate(curved),
                    child: child,
                  ),
                );
              },
              child: Column(
                key: ValueKey(track.id),
                // Plain title block + shadows over the dark wash —
                // no scrim boxes (they stamp black rectangles on
                // the blurred backdrop).
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(track.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: glassText(true),
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          letterSpacing: -0.1,
                          height: 1.25,
                          shadows: const [
                            Shadow(
                                blurRadius: 8,
                                color: Colors.black87)
                          ])),
                  Text(track.displayArtist(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: glassSubtext(true),
                          fontSize: 13,
                          height: 1.3,
                          shadows: const [
                            Shadow(
                                blurRadius: 8,
                                color: Colors.black87)
                          ])),
                ],
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.more_horiz,
                color: glassText(true)),
            tooltip: 'More',
            onPressed: () => showTrackMenu(context, state, track,
                state.controller.engine.snapshot()),
          ),
        ],
      ),
    );
  }
}

/// Output pill (reference): lyrics bubble | output pill | queue list,
/// with the "This phone" caption. JAM lives inside the Audio output
/// sheet (reachable only from the output section) — no JAM segment
/// here, so the row fits 360dp. The pill honestly reports the only
/// output until device switching lands.
class _OutputPill extends StatelessWidget {
  final AppState state;
  final VoidCallback onLyrics;
  final bool lyricsActive;
  const _OutputPill(
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
      return _PressScale(
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
              const EdgeInsets.symmetric(horizontal: _gutter),
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
                        horizontal: _gapLg),
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
                            horizontal: _gapXs),
                        child: Row(
                          mainAxisSize:
                              MainAxisSize.min,
                          children: [
                            Icon(
                                Icons.headphones_outlined,
                                color: glassText(true),
                                size: 20),
                            const SizedBox(width: _gapSm),
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
        const SizedBox(height: _gapSm),
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

/// Current-line preview (BitChord art mode): the live lyric line
/// ABOVE the title, chevron included; tap scrolls to full karaoke.
/// Empty (still loading / plain / none) renders nothing. Line changes
/// crossfade + slide (motionMs-gated, transform/opacity only); the
/// persisted per-track timing offset applies here too.
class _LyricPreview extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  final ValueNotifier<List<LyricLine>> lines;
  final ValueNotifier<List<LyricLine>> display;
  final VideoHandle? handle;
  final VoidCallback onTap;
  const _LyricPreview(
      {required this.state,
      required this.track,
      required this.lines,
      required this.display,
      this.handle,
      required this.onTap});

  /// Picks the live line from [ls] at [pos] (offset-aware).
  String _cur(List<LyricLine> ls, int pos, int off) {
    try {
      var cur = ls.first.text;
      for (final l in ls) {
        if (effectiveLyricMs(l.startMs, off) <= pos) {
          cur = l.text;
        } else {
          break;
        }
      }
      return cur;
    } catch (_) {
      return '';
    }
  }

  Widget _row(String cur) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding:
            const EdgeInsets.fromLTRB(_gutter, _gapXs, _gutter, _gapXs),
        // Plain lyric line + chevron over the dark wash —
        // no scrim box (boxes read as black rectangles).
        child: Row(
        children: [
          Expanded(
            child: AnimatedSwitcher(
              duration: Duration(
                  milliseconds:
                      state.motionMs(titleSlideMs)),
              // Stack default centers children; pin left.
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.centerLeft,
                children: [
                  ...previous,
                  ?current,
                ],
              ),
              transitionBuilder: (child, anim) {
                final curved = CurvedAnimation(
                    parent: anim,
                    curve: Curves.easeOut);
                // Box-shift roll: the line rises from below, masked
                // to one line height (outgoing sinks back, masked).
                return ClipRect(
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 1),
                      end: Offset.zero,
                    ).animate(curved),
                    child: FadeTransition(
                      opacity: curved,
                      child: child,
                    ),
                  ),
                );
              },
              child: Text(cur,
                  key: ValueKey(cur),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.left,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight:
                          FontWeight.w600,
                      letterSpacing: 0.1,
                      height: 1.35,
                      shadows: [
                        Shadow(
                            blurRadius: 8,
                            color: Colors.black87)
                      ])),
            ),
          ),
          Icon(Icons.chevron_right,
              color: subtextOn(
                  const Color(0xFF000000)),
              size: 18),
        ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<LyricLine>>(
      valueListenable: lines,
      builder: (_, ls, _) {
        if (ls.isEmpty) return const SizedBox.shrink();
        return ValueListenableBuilder<List<LyricLine>>(
          valueListenable: display,
          builder: (_, disp, _) {
            // Translated/romanized display lines win when present
            // (same order + timings as raw); else raw originals.
            final use =
                disp.isNotEmpty && disp.length == ls.length
                    ? disp
                    : ls;
            var off = 0;
            try {
              off = lyricOffsetMs(track.id);
            } catch (_) {}
            final h = handle;
            // Video mode follows the sounding video clock (the
            // parked engine freezes); otherwise the engine stream.
            if (h != null) {
              return ValueListenableBuilder<bool>(
                valueListenable: h.active,
                builder: (_, act, _) {
                  if (!act) {
                    return StreamBuilder<Duration>(
                      stream: state.controller.player
                          .positionStream,
                      builder: (_, snap) => _row(_cur(
                          use,
                          (snap.data ?? Duration.zero)
                              .inMilliseconds,
                          off)),
                    );
                  }
                  return ValueListenableBuilder<int>(
                    valueListenable: h.videoMs,
                    builder: (_, ms, _) =>
                        _row(_cur(use, ms, off)),
                  );
                },
              );
            }
            return StreamBuilder<Duration>(
              stream:
                  state.controller.player.positionStream,
              builder: (_, snap) => _row(_cur(
                  use,
                  (snap.data ?? Duration.zero)
                      .inMilliseconds,
                  off)),
            );
          },
        );
      },
    );
  }
}

/// Compact video strip for VIDEO-MODE expanded lyrics: the same
/// [VideoEmbed] element as the art slot (shared [videoKey] — one
/// controller ever lives, no reload), cropped to a 200px strip on top
/// while the karaoke fills below. Swipe prev/next still works.
class _CompactVideoStrip extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  final Key videoKey;
  final VideoHandle handle;
  final VoidCallback onAudioOnly;
  final VoidCallback onExpand;
  const _CompactVideoStrip(
      {required this.state,
      required this.track,
      required this.videoKey,
      required this.handle,
      required this.onAudioOnly,
      required this.onExpand});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          _gutter, _gapXs, _gutter, _gapSm),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 200,
          width: double.infinity,
          child: OverflowBox(
            alignment: Alignment.topCenter,
            maxHeight: 4000,
            child: _ArtSwipe(
              state: state,
              child: VideoEmbed(
                key: videoKey,
                state: state,
                track: track,
                handle: handle,
                onAudioOnly: onAudioOnly,
                onExpand: onExpand,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Artwork swipe (reference parity): horizontal drag glides the art
/// with the finger and snaps back; past ±80px it fires prev/next.
/// Transform only; vertical sheet scrolling is unaffected (horizontal
/// gestures win the arena only for horizontal drags).
class _ArtSwipe extends StatefulWidget {
  final AppState state;
  final Widget child;
  const _ArtSwipe({required this.state, required this.child});

  @override
  State<_ArtSwipe> createState() => _ArtSwipeState();
}

class _ArtSwipeState extends State<_ArtSwipe>
    with SingleTickerProviderStateMixin {
  double _dx = 0;
  double _acc = 0;
  double _snapFrom = 0;
  late final AnimationController _snap;

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(vsync: this);
    _snap.addListener(() {
      try {
        if (mounted) setState(() {});
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    try {
      _snap.dispose();
    } catch (_) {}
    super.dispose();
  }

  double get _offset {
    try {
      if (_snap.isAnimating) {
        return _snapFrom * (1 - _snap.value);
      }
    } catch (_) {}
    return _dx;
  }

  void _onStart(_) {
    try {
      _snap.stop();
    } catch (_) {}
    _acc = 0;
    _snapFrom = _dx;
  }

  void _onUpdate(DragUpdateDetails d, double width) {
    try {
      final max = width * 0.3;
      final next = (_dx + d.delta.dx).clamp(-max, max);
      _acc += d.delta.dx;
      if (mounted) setState(() => _dx = next);
    } catch (_) {}
  }

  void _onEnd(_) {
    VoidCallback? fire;
    try {
      if (_acc < -80) {
        fire = () => widget.state.controller.next();
      } else if (_acc > 80) {
        fire = () => widget.state.controller.previous();
      }
    } catch (_) {
      fire = null;
    }
    _acc = 0;
    _snapFrom = _dx;
    var ms = 260;
    try {
      ms = widget.state.motionMs(260);
    } catch (_) {}
    try {
      _snap.duration = Duration(milliseconds: ms);
      _snap.forward(from: 0).whenComplete(() {
        try {
          if (mounted) setState(() => _dx = 0);
        } catch (_) {}
        try {
          fire?.call();
        } catch (_) {}
      });
    } catch (_) {
      try {
        if (mounted) setState(() => _dx = 0);
      } catch (_) {}
      try {
        fire?.call();
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, cons) {
      final w = cons.maxWidth.isFinite
          ? cons.maxWidth
          : MediaQuery.of(context).size.width;
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragStart: _onStart,
        onHorizontalDragUpdate: (d) => _onUpdate(d, w),
        onHorizontalDragEnd: _onEnd,
        child: Transform.translate(
          offset: Offset(_offset, 0),
          child: widget.child,
        ),
      );
    });
  }
}

/// Static edge-to-edge art (reference): sharp art running under the
/// status bar, melting into the blurred backdrop at its base. No
/// breathe, no pause-shrink — the reference art is static.
class _StaticArt extends StatelessWidget {
  final YtTrack track;
  const _StaticArt({required this.track});

  @override
  Widget build(BuildContext context) {
    final art = track.thumbUrl.replaceAll('hqdefault', 'maxresdefault');
    late final int swapMs;
    try {
      swapMs = AppScope.of(context).motionMs(artSlideMs);
    } catch (_) {
      swapMs = artSlideMs;
    }
    // Hero feel: crossfade + subtle scale on track change (450ms art
    // slide spec, transform/opacity only).
    return AnimatedSwitcher(
      duration: Duration(milliseconds: swapMs),
      transitionBuilder: (child, anim) {
        final curved =
            CurvedAnimation(parent: anim, curve: Curves.easeOut);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
      child: _StaticArtBody(key: ValueKey(track.id), track: track, art: art),
    );
  }
}

class _StaticArtBody extends StatelessWidget {
  final YtTrack track;
  final String art;
  const _StaticArtBody({super.key, required this.track, required this.art});

  @override
  Widget build(BuildContext context) {
    // Full-HD sharp art, no filters on the pixels. The base dissolves
    // into the backdrop over the bottom 25% only (short gentle
    // feather): the backdrop directly underneath is the SAME artwork
    // blurred, undarkened in the art zone — identical hues meet, so
    // no edge or line can form.
    Widget artBox(double width) => SizedBox(
          width: width,
          height: width * 1.10,
          child: ShaderMask(
            shaderCallback: (r) => const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Colors.white, Colors.transparent],
              stops: [0.0, 0.75, 1.0],
            ).createShader(r),
            blendMode: BlendMode.dstIn,
            child: TrackArt(
                track: YtTrack(
                    id: track.id,
                    title: track.title,
                    artist: track.artist,
                    thumbUrl: art,
                    watchUrl: track.watchUrl),
                size: width),
          ),
        );
    return LayoutBuilder(
      builder: (_, cons) {
        final w = cons.maxWidth.isFinite
            ? cons.maxWidth
            : MediaQuery.of(context).size.width;
        return artBox(w);
      },
    );
  }
}

/// Thin seek bar (reference): hairline progress, tap + drag scrub,
/// knob swell while dragging, elapsed left / -remaining right.
class _SeekBar extends StatelessWidget {
  final AppState state;
  final VideoHandle? handle;
  final double? dragPos;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onSeek;
  const _SeekBar(
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
        Widget slider(double v) => SliderTheme(
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
          padding: const EdgeInsets.symmetric(horizontal: _gutter),
          child: Column(
            children: [
              bar,
              Padding(
                padding: const EdgeInsets.only(top: _gapXs),
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
class _Transport extends StatelessWidget {
  final AppState state;
  final VideoHandle handle;
  const _Transport({required this.state, required this.handle});

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
              const EdgeInsets.symmetric(vertical: _gapXs),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _PressScale(
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
              const SizedBox(width: _gapSm),
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
                    : _PressScale(
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
              const SizedBox(width: _gapSm),
              _PressScale(
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
class _VolumeRow extends StatefulWidget {
  final AppState state;
  const _VolumeRow({required this.state});

  @override
  State<_VolumeRow> createState() => _VolumeRowState();
}

class _VolumeRowState extends State<_VolumeRow> {
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
                  _gutter, 0, _gutter, _gapXs),
          child: Row(
            children: [
              Icon(Icons.volume_down_outlined,
                  size: 20,
                  color: Colors.white
                      .withValues(alpha: 0.65)),
              const SizedBox(width: _gapMd),
              Expanded(child: slider),
              const SizedBox(width: _gapMd),
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

/// About-this-song card (P8): Plays/Likes/Released/Duration + trimmed
/// description. Extractor-backed (P8 native DetailsCard parity).
class DetailsSection extends StatefulWidget {
  final YtTrack track;
  const DetailsSection({super.key, required this.track});

  @override
  State<DetailsSection> createState() => _DetailsSectionState();
}

class _DetailsSectionState extends State<DetailsSection> {
  VideoDetails? _details;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DetailsSection old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id) _load();
  }

  Future<void> _load() async {
    final store = AppScope.of(context).details;
    try {
      final d = await store.load(widget.track.watchUrl);
      if (!mounted) return;
      setState(() => _details = d);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final d = _details;
    final rows = <(String, String)>[
      ('Artist', widget.track.displayArtist()),
      if (d != null && d.views >= 0)
        ('Plays', fmtCompact(d.views)),
      if (d != null && d.likes > 0) ('Likes', fmtCompact(d.likes)),
      if (d != null && d.uploadDate.isNotEmpty)
        ('Released', d.uploadDate),
      if (d != null && d.durationSec > 0) ...[
        (
          'Duration',
          '${(d.durationSec ~/ 60)}:${(d.durationSec % 60).toString().padLeft(2, '0')}'
        ),
      ],
      ('Source', 'YouTube'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('About this song',
                style: TextStyle(
                    color: glassSubtext(true),
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                        width: 84,
                        child: Text(k,
                            style: TextStyle(
                                color: glassSubtext(true),
                                fontSize: 12))),
                    Expanded(
                      child: Text(v,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                              color: glassText(true),
                              fontSize: 12)),
                    ),
                  ],
                ),
              ),
            if (d != null && d.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                d.description.trimLeft(),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: glassSubtext(true),
                    fontSize: 12,
                    height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> openArtistPage(BuildContext context, YtTrack track) async {
  AppState state;
  try {
    state = AppScope.of(context);
  } catch (_) {
    return;
  }
  final name = track.displayArtist();
  if (name == 'Unknown Artist' || name.trim().isEmpty) return;
  // Thumb resolves best-effort: the page opens even when the channel
  // lookup throws/offlines. Previously the searchArtists await shared
  // one try with the push, so any lookup failure swallowed the whole
  // navigation and the tap looked dead.
  var thumb = track.thumbUrl;
  try {
    final hits = await state.repo.searchArtists(name, max: 1);
    if (hits.isNotEmpty && hits.first.thumbUrl.isNotEmpty) {
      thumb = hits.first.thumbUrl;
    }
  } catch (_) {}
  if (!context.mounted) return;
  try {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ArtistPage(name: name, thumb: thumb)));
  } catch (_) {}
}

/// Artist page (P15): hero + top songs + Play/Shuffle + fav-heart.
class ArtistPage extends StatefulWidget {
  final String name;
  final String thumb;
  const ArtistPage({super.key, required this.name, required this.thumb});

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  List<YtTrack> songs = [];
  List<YtTrack> videos = [];
  bool loading = true;
  bool _radioBusy = false;

  @override
  void initState() {
    super.initState();
    // AppScope is an InheritedWidget: of(context) inside initState throws
    // (dependOnInheritedWidget during init), which the old try/catch
    // turned into an instant empty page. Load post-frame instead.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  /// Tolerant artist match: exact displayArtist equality almost never
  /// holds (topic suffixes, "Artist - Title" splits, label uploaders
  /// resolving to "Unknown Artist"), so the old == filter emptied every
  /// page. Key equality, containment, then token overlap win.
  static bool _matches(String display, String want) {
    try {
      final d = artistKeyOf(display);
      final w = artistKeyOf(want);
      if (d.isEmpty ||
          w.isEmpty ||
          d == 'unknown artist' ||
          w == 'unknown artist') {
        return false;
      }
      if (d == w) return true;
      if (d.contains(w) || w.contains(d)) return true;
      final dt = artistTokensOf(display);
      final wt = artistTokensOf(want);
      return wt.isNotEmpty && wt.any(dt.contains);
    } catch (_) {
      return false;
    }
  }

  /// Two honest legs, fanned out concurrently (each repo-bounded, never
  /// throws): top songs via song search + music videos via video search.
  /// No artist-browse/album/about endpoint exists in the repo
  /// (parseSearch drops album/artist cards by design; searchArtists
  /// carries no subs/bio), so those YTM sections are skipped, never
  /// faked — see build().
  Future<void> _load() async {
    AppState state;
    try {
      state = AppScope.of(context);
    } catch (_) {
      if (mounted) setState(() => loading = false);
      return;
    }
    try {
      final want = widget.name;
      final results = await Future.wait([
        state.repo.searchMusic('$want songs', max: 20),
        state.repo.searchVideos('$want music video', max: 10),
      ]);
      if (!mounted) return;
      final hits = results[0]
          .where((t) => t.id.length == 11 && t.title.trim().isNotEmpty)
          .toList();
      final mine =
          hits.where((t) => _matches(t.displayArtist(), want)).toList();
      // Songs-only rows: same gate the rest of the app plays through.
      List<YtTrack> cleanTop;
      try {
        cleanTop = songsOnlyTracks(mine.isNotEmpty ? mine : hits);
      } catch (_) {
        cleanTop = mine.isNotEmpty ? mine : hits;
      }
      final vids = results[1]
          .where((t) => t.id.length == 11 && t.title.trim().isNotEmpty)
          .toList();
      setState(() {
        // Never blank when upstream returned songs: when the tolerant
        // filter still finds nothing, paint the hits themselves.
        songs = cleanTop.isNotEmpty
            ? cleanTop
            : (mine.isNotEmpty ? mine : hits);
        videos = vids;
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bg = scheme.surface;
    final fav = state.library.liked
        .any((t) => t.displayArtist() == widget.name);
    return Scaffold(
      appBar: AppBar(title: Text(widget.name), actions: [
        SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            icon: Icon(fav ? Icons.favorite : Icons.favorite_border),
            tooltip: fav ? 'Unfavorite artist' : 'Favorite artist',
            onPressed: () async {
              try {
                await state.library.toggleArtist(widget.name,
                    thumbUrl: widget.thumb);
                if (mounted) setState(() {});
              } catch (_) {}
            },
          ),
        ),
      ]),
      body: loading && songs.isEmpty && videos.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : songs.isEmpty && videos.isEmpty
              // Honest empty state (theme-derived colors): the old code
              // rendered a blank ListView here, which read as broken.
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.music_off_outlined,
                            size: 56,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                        const SizedBox(height: 12),
                        Text(
                            'No songs found for ${widget.name}',
                            textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                )
              // YTM artist shape: header art + name + stats line,
              // Shuffle + Radio, ranked Top songs, Videos rail.
              // Skipped with reason (no endpoint, never faked):
              // - subscriber/monthly-listener counts (searchArtists
              //   carries no subs; YtArtist.subs is always ''),
              // - Albums/Singles rails (no artist browse; parseSearch
              //   drops album cards by design; playlistTracks needs VL
              //   ids search never returns),
              // - About/bio (no channel-about/description endpoint).
              : AnimatedSwitcher(
                  duration: Duration(
                      milliseconds: state.motionMs(titleSlideMs)),
                  child: CustomScrollView(
                    key: const ValueKey('artist-body'),
                    slivers: [
                      // Header: big art + name + honest count line.
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                              24, 20, 24, 4),
                          child: Column(
                            children: [
                              _ArtistHeaderArt(thumb: widget.thumb),
                              const SizedBox(height: 12),
                              AdaptiveText(
                                data: widget.name,
                                background: bg,
                                align: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(
                                        fontWeight:
                                            FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              AdaptiveText(
                                data: songs.isEmpty
                                    ? 'Artist'
                                    : 'Artist • ${songs.length} top songs',
                                background: bg,
                                secondary: true,
                                align: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Shuffle (shuffled top songs) + Radio (artist
                      // radio via the existing state API). 48px targets.
                      if (songs.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(
                                24, 16, 24, 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 48,
                                    child: FilledButton.icon(
                                      style:
                                          spotifyPlayStyle(),
                                      icon: const Icon(
                                          Icons.shuffle),
                                      label:
                                          const Text('Shuffle'),
                                      onPressed: () {
                                        final order =
                                            List<int>.generate(
                                                songs.length,
                                                (i) => i)
                                              ..shuffle();
                                        state.actPlay(
                                            [
                                              for (final i
                                                  in order)
                                                songs[i]
                                            ],
                                            0,
                                            origin: 'Artist');
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: SizedBox(
                                    height: 48,
                                    child:
                                        OutlinedButton.icon(
                                      icon: _radioBusy
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child:
                                                  CircularProgressIndicator(
                                                      strokeWidth:
                                                          2),
                                            )
                                          : const Icon(Icons
                                              .radio),
                                      label:
                                          const Text('Radio'),
                                      onPressed: _radioBusy
                                          ? null
                                          : () async {
                                              if (mounted) {
                                                setState(() =>
                                                    _radioBusy =
                                                        true);
                                              }
                                              try {
                                                await state
                                                    .startRadio(
                                                        songs.first);
                                              } catch (_) {}
                                              if (mounted) {
                                                setState(() =>
                                                    _radioBusy =
                                                        false);
                                              }
                                            },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // Top songs: ranked rows, tap-to-play, songs-only.
                      if (songs.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(
                                    24, 20, 24, 4),
                            child: AdaptiveText(
                              data: 'Top songs',
                              background: bg,
                              maxLines: 1,
                              overflow:
                                  TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(
                                      fontWeight:
                                          FontWeight.w700),
                            ),
                          ),
                        ),
                        SliverList.builder(
                          itemCount: songs.length,
                          itemBuilder: (_, i) => Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 52,
                                child: Center(
                                  child: AdaptiveText(
                                    data: '${i + 1}',
                                    background: bg,
                                    secondary: true,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                            fontWeight:
                                                FontWeight
                                                    .w600),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: TrackRow(
                                    track: songs[i],
                                    contextQueue: songs,
                                    index: i,
                                    origin: 'Artist'),
                              ),
                            ],
                          ),
                        ),
                      ],
                      // Videos rail: cards open in-sheet video mode
                      // (same actPlay + openPlayerSheet(video:true)
                      // pattern as the trending rows).
                      if (videos.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(
                                    24, 20, 24, 8),
                            child: AdaptiveText(
                              data: 'Videos',
                              background: bg,
                              maxLines: 1,
                              overflow:
                                  TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(
                                      fontWeight:
                                          FontWeight.w700),
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 188,
                            child: ListView.builder(
                              scrollDirection:
                                  Axis.horizontal,
                              padding:
                                  const EdgeInsets.symmetric(
                                      horizontal: 24),
                              itemCount: videos.length,
                              itemBuilder: (_, i) {
                                final v = videos[i];
                                return _ArtistVideoCard(
                                    track: v,
                                    queue: videos,
                                    index: i);
                              },
                            ),
                          ),
                        ),
                      ],
                      const SliverToBoxAdapter(
                        child: SizedBox(height: 32),
                      ),
                    ],
                  ),
                ),
    );
  }
}

/// Artist header art: 168px circle, cached channel thumb with a
/// theme-derived fallback (never a broken-image box).
class _ArtistHeaderArt extends StatelessWidget {
  final String thumb;
  const _ArtistHeaderArt({required this.thumb});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 168,
      height: 168,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surfaceContainerHighest,
      ),
      child: ClipOval(
        child: thumb.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: sharpThumb(thumb),
                fit: BoxFit.cover,
                width: 168,
                height: 168,
                errorWidget: (_, _, _) => Icon(
                    Icons.person,
                    size: 72,
                    color: scheme.onSurfaceVariant),
              )
            : Icon(Icons.person,
                size: 72, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Videos-rail card (160px art + title/artist): tap plays the video
/// queue from here and opens the player sheet with video in the art
/// slot — the in-sheet video entry stays one trivial hop away.
class _ArtistVideoCard extends StatelessWidget {
  final YtTrack track;
  final List<YtTrack> queue;
  final int index;
  const _ArtistVideoCard(
      {required this.track, required this.queue, required this.index});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: track.title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          try {
            state.actPlay(queue, index, origin: 'Artist videos');
            openPlayerSheet(context, video: true);
          } catch (_) {}
        },
        child: Container(
          width: 160,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: TrackArt(track: track, size: 160),
              ),
              const SizedBox(height: 6),
              AdaptiveText(
                  data: track.title,
                  background: scheme.surface,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              AdaptiveText(
                  data: track.displayArtist(),
                  background: scheme.surface,
                  secondary: true,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
