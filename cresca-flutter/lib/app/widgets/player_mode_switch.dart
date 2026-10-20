// Player mode switch (U4): lyrics/video-mode chrome — the compact
// header, the karaoke container the sheet cross-fades to, the compact
// video strip, and the art swipe (prev/next gesture shared by the art
// slot and the strip). Extracted verbatim from player_sheet.dart —
// layout and behavior unchanged.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/track.dart';
import '../../data/lyrics.dart';
import '../design.dart';
import '../state.dart';
import 'lyrics_panel.dart';
import 'player_header.dart';
import 'track_menu.dart';
import 'track_row.dart';
import 'video_sheet.dart';


/// Lyrics mode: full karaoke (with translation tools + attribution).
/// Forwards the karaoke's display lines + an optional video clock so
/// the collapsed preview matches the expanded language and keeps
/// moving in video mode.
class LyricsMode extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  final ValueNotifier<List<LyricLine>> lines;
  final ValueNotifier<List<LyricLine>> display;
  final ValueListenable<int>? clockMs;
  final ValueChanged<List<LyricLine>>? onDisplay;
  final ValueChanged<List<LyricLine>> onRaw;
  final VoidCallback onCollapse;
  const LyricsMode(
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

/// Compact header (BitChord): 48dp art + title/artist + overflow.
class MiniHeader extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  const MiniHeader({required this.state, required this.track});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: playerGutter),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: TrackArt(track: track, size: 44),
          ),
          const SizedBox(width: playerGapMd),
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

/// Compact video strip for VIDEO-MODE expanded lyrics: the same
/// [VideoEmbed] element as the art slot (shared [videoKey] — one
/// controller ever lives, no reload), cropped to a 200px strip on top
/// while the karaoke fills below. Swipe prev/next still works.
class CompactVideoStrip extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  final Key videoKey;
  final VideoHandle handle;
  final VoidCallback onAudioOnly;
  final VoidCallback onExpand;
  const CompactVideoStrip(
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
          playerGutter, playerGapXs, playerGutter, playerGapSm),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: SizedBox(
          height: 200,
          width: double.infinity,
          child: OverflowBox(
            alignment: Alignment.topCenter,
            maxHeight: 4000,
            child: ArtSwipe(
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
class ArtSwipe extends StatefulWidget {
  final AppState state;
  final Widget child;
  const ArtSwipe({required this.state, required this.child});

  @override
  State<ArtSwipe> createState() => ArtSwipeState();
}

class ArtSwipeState extends State<ArtSwipe>
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
