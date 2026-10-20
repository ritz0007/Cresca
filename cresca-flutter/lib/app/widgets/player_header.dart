// Player header (U4 split): "Playing from X" origin line, art-mode
// title block (marquee title + artist + overflow/more), live lyric
// preview (tap expands), lyric-mode karaoke containers. Extracted
// verbatim from player_sheet.dart — layout and behavior unchanged.

import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/track.dart';
import '../../data/lyrics.dart';
import '../../data/translate.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'lyrics_panel.dart';
import 'player_credits.dart';
import 'video_sheet.dart';

/// Player layout language (Apple-Music-grade rhythm): one gutter down
/// the whole sheet, one spacing scale, deliberate type steps.
/// Single home for the player spacing constants (U4) — imported by
/// player_sheet/transport/menu/credits, never duplicated.
const playerGutter = 24.0;
const playerGapXs = 4.0;
const playerGapSm = 8.0;
const playerGapMd = 12.0;
const playerGapLg = 16.0;

/// "Playing from X" origin caption: plain text + shadow over the dark
/// wash — never a pill/scrim box (black rectangles read as boxes on
/// the dark wash). Contrast rides white-over-dark + shadow.
class PlayerOriginLine extends StatelessWidget {
  final String sourceLabel;
  const PlayerOriginLine({super.key, required this.sourceLabel});

  @override
  Widget build(BuildContext context) {
    return Text('Playing from $sourceLabel',
        style: TextStyle(
            color: subtextOn(const Color(0xFF000000)),
            fontSize: 12,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            shadows: const [
              Shadow(blurRadius: 8, color: Colors.black87)
            ]));
  }
}


/// Art mode: static edge-to-edge art is above (in the sheet), then the
/// left-aligned marquee title + overflow, artist, lyric preview.
class PlayerHeader extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  final ValueNotifier<List<LyricLine>> lines;
  final ValueNotifier<List<LyricLine>> display;
  final ValueChanged<List<LyricLine>> onRaw;
  final VideoHandle? handle;
  final VoidCallback onExpandLyrics;
  final bool videoActive;
  final VoidCallback onToggleVideo;
  final VoidCallback onMore;
  const PlayerHeader(
      {super.key,
      required this.state,
      required this.track,
      required this.lines,
      required this.display,
      required this.onRaw,
      this.handle,
      required this.onExpandLyrics,
      this.videoActive = false,
      required this.onToggleVideo,
      required this.onMore});

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
              const EdgeInsets.fromLTRB(playerGutter, playerGapXs, playerGutter, 0),
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
              const SizedBox(width: playerGapSm),
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
                  onPressed: onMore,
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
            const EdgeInsets.fromLTRB(playerGutter, playerGapXs, playerGutter, playerGapXs),
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
