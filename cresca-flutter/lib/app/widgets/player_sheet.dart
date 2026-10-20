// Full player (reference parity): full-bleed artwork wash + static
// edge-to-edge art, route + mode switching + pinned transport block.
// Header/transport/credits live in player_header/transport/credits.dart;
// the overflow row lives in player_menu.dart. Shuffle / repeat / like /
// download / video are one tap away in the labelled PlayerMenu row and
// the full track menu.

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/motion.dart';
import '../../core/track.dart';
import '../../data/lyrics.dart';
import '../app.dart';
import '../design.dart';
import 'player_header.dart';
import 'player_menu.dart';
import 'player_mode_switch.dart';
import 'player_transport.dart';
import 'track_menu.dart';
import 'track_row.dart';
import 'video_sheet.dart';

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

  /// Seek generation token (U4): bumped in [dispose] so any in-flight
  /// seek work can tell the sheet is gone. Track changes reset the
  /// scrub position instead (see build). Mirrors _MarqueeTitle's gen.
  int _seekGen = 0;

  /// Track id the scrub position belongs to. A slow position tick or a
  /// leftover finger drag must never paint the previous track's
  /// slider value onto the new track.
  String _seekTrackId = '';
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
    final gen = _seekGen;
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
    // Gen-token cancel (U4): the sheet was disposed while the
    // fullscreen route was on top — resolve to nothing.
    if (!mounted || gen != _seekGen) return;
    setState(() {
      // Audio-only from fullscreen drops video mode instead of
      // remounting the inline embed.
      if (res == 'audio') _videoMode = false;
      _videoFull = false;
    });
  }

  @override
  void dispose() {
    // Invalidate in-flight seeks first: nothing may resolve after this.
    _seekGen++;
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
        // Track change invalidates any in-flight scrub (plain field
        // writes, no setState: we are already building the new track).
        // The slider must never paint the previous track's drag pos.
        if (track.id != _seekTrackId) {
          _seekTrackId = track.id;
          _dragPos = null;
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
                        ArtSwipe(
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
                          const SizedBox(height: playerGapSm),
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
                          child: PlayerHeader(
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
                              onMore: () => showTrackMenu(
                                  context,
                                  state,
                                  track,
                                  state.controller.engine
                                      .snapshot()),
                            ),
                        ),
                        ] else ...[
                          const SizedBox(height: playerGapMd),
                          // VIDEO-MODE expanded lyrics: the karaoke lives
                          // in the BOTTOM area with the video still
                          // upfront — compact video strip on top, lyrics
                          // fill below. Never a fullscreen takeover; the
                          // strip reuses the art-slot VideoEmbed element
                          // (shared key), so the picture keeps playing.
                          if (_videoMode && !_videoFull)
                            CompactVideoStrip(
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
                          MiniHeader(
                              state: state, track: track),
                          LyricsMode(
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
                        const SizedBox(height: playerGapLg),
                      ],
                    ),
                  ),
                ],
              ),
                    ),
                    // PINNED transport block: never scrolls, never
                    // moves — seek, transport, volume, output row.
                    PlayerSeekBar(
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
                    PlayerTransport(
                        state: state,
                        handle: _videoHandle),
                    // Labelled overflow actions (U4): the phase's one
                    // deliberate visual change. Same callbacks as the
                    // track menu, now discoverable in the pinned block.
                    PlayerMenu(
                      state: state,
                      track: track,
                      videoActive: _videoMode,
                      onToggleVideo: () => setState(
                          () => _videoMode = !_videoMode),
                    ),
                    PlayerVolumeRow(state: state),
                    if (state.controller.errorLine !=
                        null)
                      Padding(
                        padding:
                            const EdgeInsets.symmetric(
                                horizontal: playerGutter),
                        child: Text(
                            state.controller
                                .errorLine!,
                            style: TextStyle(
                                color: Theme.of(context)
                                    .colorScheme
                                    .error)),
                      ),
                    const SizedBox(height: playerGapSm),
                    PlayerOutputPill(
                      state: state,
                      lyricsActive: _lyricsExpanded,
                      onLyrics: () => setState(
                          () => _lyricsExpanded =
                              !_lyricsExpanded),
                    ),
                    SizedBox(
                        height: playerGapLg + bottomPad),
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
                        PlayerOriginLine(
                            sourceLabel:
                                state.playOrigin),
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
