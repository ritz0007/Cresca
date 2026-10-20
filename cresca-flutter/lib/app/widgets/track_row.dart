// Shared track row (every list) + skeleton placeholder (H8/A4).
// Artwork: cached thumbs with mosaic/gradient fallback (same fallback
// hues as native ArtGradients). Press-scale .94 when motion is on.
// Motion: one-shot entrances only (fade + 12px slide, 220ms, 40ms
// stagger capped); transform/opacity only so scroll never blocks.
// StaggerEntrance lives here and is reused by screens (no new files).

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../app.dart';
import 'track_menu.dart';

/// One-shot cascade entrance: fade + 12px rise, 220ms, 40ms stagger.
/// Delay caps so long lists don't crawl (max ~8 steps). Rests after
/// completing — no per-frame work. When motion is off, renders child
/// directly. Key by section+item so section changes re-run it.
///
/// Smooth-scroll rule: only the first [maxItems] (8) in a list ever
/// animate — deeper rows render directly with zero controllers,
/// zero delayed setStates, zero AnimatedBuilder ticks.
class StaggerEntrance extends StatefulWidget {
  final Widget child;
  final int index;
  final int staggerMs;
  final int maxStaggerMs;
  final double slidePx;

  /// How many leading items may animate; at/after this, [child]
  /// renders directly (no entrance cost for long tails).
  static const int maxItems = 8;

  const StaggerEntrance({
    super.key,
    required this.child,
    this.index = 0,
    this.staggerMs = 40,
    this.maxStaggerMs = 320,
    this.slidePx = 12,
  });

  @override
  State<StaggerEntrance> createState() => _StaggerEntranceState();
}

class _StaggerEntranceState extends State<StaggerEntrance> {
  bool _in = false;

  @override
  void initState() {
    super.initState();
    // Beyond-cap rows never animate: mark in so a late rebuild
    // (e.g. list recycle) never schedules a timer.
    if (widget.index >= StaggerEntrance.maxItems) {
      _in = true;
      return;
    }
    // Motion flag is read lazily on first frame (context-safe).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      bool on = true;
      try {
        on = AppScope.of(context).motionOn;
      } catch (_) {}
      if (!mounted) return;
      if (!on) {
        setState(() => _in = true);
        return;
      }
      final i = widget.index < 0 ? 0 : widget.index;
      var delay = i * widget.staggerMs;
      if (delay > widget.maxStaggerMs) delay = widget.maxStaggerMs;
      if (delay <= 0) {
        setState(() => _in = true);
        return;
      }
      Future<void>.delayed(Duration(milliseconds: delay)).then((_) {
        if (mounted) setState(() => _in = true);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    bool on = true;
    try {
      on = AppScope.of(context).motionOn;
    } catch (_) {}
    // Long-tail bypass: no controllers/timers/implicit animations
    // past the cap — the row paints once and rests.
    if (!on || widget.index >= StaggerEntrance.maxItems) {
      return widget.child;
    }
    final d = Duration(milliseconds: AppScope.of(context).motionMs(220));
    // RepaintBoundary keeps the one-shot entrance off the scrolling
    // list's repaint scope; after [_in] flips both implicits rest.
    return RepaintBoundary(
      child: AnimatedOpacity(
        duration: d,
        opacity: _in ? 1 : 0,
        child: AnimatedContainer(
          duration: d,
          curve: Curves.easeOutCubic,
          transform:
              Matrix4.translationValues(0, _in ? 0 : widget.slidePx, 0),
          transformAlignment: Alignment.center,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Press-scale wrapper: 0.94 / 120ms on tap-down, honors kill-switch.
/// Transform-only, never blocks scroll (no scroll listener here).
class _PressScale extends StatefulWidget {
  final Widget child;
  const _PressScale({required this.child});

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    bool on = true;
    try {
      on = AppScope.of(context).motionOn;
    } catch (_) {}
    if (!on) return widget.child;
    final d = Duration(milliseconds: AppScope.of(context).motionMs(120));
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.94 : 1.0,
        duration: d,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

class TrackRow extends StatelessWidget {
  final YtTrack track;
  final List<YtTrack> contextQueue;
  final int index;
  final VoidCallback? onTap;
  final bool showArt;

  /// Player "Playing from X" origin (Search / Home / …). Null keeps
  /// the previous origin.
  final String? origin;
  const TrackRow({
    super.key,
    required this.track,
    required this.contextQueue,
    required this.index,
    this.onTap,
    this.showArt = true,
    this.origin,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return _PressScale(
      // RepaintBoundary: the per-row AnimatedBuilder below subscribes
      // to AppState, so without this every notify (playhead, download
      // progress) repaints the whole visible list in one scope.
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: state,
          builder: (_, _) {
          String? currentId;
          bool playing = false;
          try {
            currentId = state.controller.engine.current?.id;
            playing = state.controller.player.playing;
          } catch (_) {}
          final isCurrent = currentId != null && currentId == track.id;
          // Row sits on the theme surface: title/subtitle derive
          // from onSurface / onSurfaceVariant. Green stays only on
          // the playing indicator below.
          final scheme = Theme.of(context).colorScheme;
          return Container(
            // AnimatedContainer highlight for the playing row; static
            // color when motion is off (duration collapses to 1ms).
            decoration: null,
            child: AnimatedContainer(
              duration: Duration(milliseconds: state.motionMs(220)),
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: isCurrent
                    ? Theme.of(context)
                        .colorScheme
                        .primaryContainer
                        .withValues(alpha: 0.35)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListTile(
                minLeadingWidth: 48,
                minVerticalPadding: 4,
                leading: showArt
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isCurrent)
                            _EqDots(active: playing, motionOn: state.motionOn)
                          else
                            _Art(track: track),
                          if (isCurrent) const SizedBox(width: 8),
                          if (isCurrent) _Art(track: track),
                        ],
                      )
                    : (isCurrent
                        ? _EqDots(active: playing, motionOn: state.motionOn)
                        : null),
                title: Text(
                  track.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.onSurface),
                ),
                subtitle: Text(
                  isCurrent
                      ? 'Playing • ${track.displayArtist()}'
                      : track.displayArtist(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(
                          color: scheme.onSurfaceVariant),
                ),
                trailing: SizedBox(
                  width: 48,
                  height: 48,
                  child: IconButton(
                    icon: const Icon(Icons.more_vert),
                    color: scheme.onSurfaceVariant,
                    tooltip: 'More actions',
                    // IconButton is 48px by default; the SizedBox
                    // guarantees the ≥48px hit-target.
                    onPressed: () =>
                        showTrackMenu(context, state, track, contextQueue),
                  ),
                ),
                onTap: onTap ??
                    () {
                      try {
                        state.actPlay(contextQueue, index, origin: origin);
                      } catch (_) {}
                    },
              ),
            ),
          );
        },
        ),
      ),
    );
  }
}

/// Pulsing playing indicator: 3 bars. Animates only while the track
/// is actually playing; static equalizer glyph when paused or motion
/// is off. Only one row is current at a time, so the single looping
/// controller never multiplies per-item.
class _EqDots extends StatelessWidget {
  final bool active;
  final bool motionOn;
  const _EqDots({required this.active, required this.motionOn});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    if (!active || !motionOn) {
      return Icon(Icons.equalizer, size: 20, color: color);
    }
    return _EqPulse(color: color);
  }
}

class _EqPulse extends StatefulWidget {
  final Color color;
  const _EqPulse({required this.color});

  @override
  State<_EqPulse> createState() => _EqPulseState();
}

class _EqPulseState extends State<_EqPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Opacity-only pulse; cheap single-row loop.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Opacity(
          opacity: 0.55 + 0.45 * _c.value,
          child: Icon(Icons.equalizer, size: 20, color: widget.color),
        ),
      ),
    );
  }
}

class _Art extends StatelessWidget {
  final YtTrack track;
  final double size;
  final int maxPx;
  final String fallbackUrl;
  const _Art(
      {required this.track,
      this.size = 48,
      this.maxPx = 480,
      this.fallbackUrl = ''});

  @override
  Widget build(BuildContext context) {
    if (track.thumbUrl.isEmpty) return _Fallback(size: size);
    // Tight decode: never unpack a 1080px upload into a small slot.
    // ~3x the layout size stays crisp on xxxhdpi without the full
    // native decode + resize pass per scroll frame. Hero slots pass
    // a bigger maxPx (poster) instead of changing this default.
    final px = (size * 3).ceil().clamp(48, maxPx);
    final fadeMs = AppScope.of(context).motionMs(150);
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: AnimatedSwitcher(
          duration: Duration(
              milliseconds: AppScope.of(context).motionMs(220)),
          // Fade-in only: the old fade+scale ran a transform tick on
          // every row as art arrived mid-scroll.
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: child,
          ),
          // Crossfade on load/change: key on the URL so a track swap
          // fades instead of popping.
          child: CachedNetworkImage(
            key: ValueKey('art-${track.thumbUrl}'),
            imageUrl: track.thumbUrl,
            width: size,
            height: size,
            fit: BoxFit.cover,
            // Tight in-memory + disk decode for the slot.
            memCacheWidth: px,
            memCacheHeight: px,
            maxWidthDiskCache: px,
            maxHeightDiskCache: px,
            fadeInDuration: Duration(milliseconds: fadeMs),
            fadeOutDuration: const Duration(milliseconds: 1),
            placeholder: (_, _) => _Fallback(size: size),
            // Hero art (maxres) 404s on some videos: fall back to the
            // provably-loading thumb instead of the gradient.
            errorWidget: (_, _, _) => fallbackUrl.isNotEmpty &&
                    fallbackUrl != track.thumbUrl
                ? CachedNetworkImage(
                    imageUrl: fallbackUrl,
                    width: size,
                    height: size,
                    fit: BoxFit.cover,
                    fadeInDuration:
                        Duration(milliseconds: fadeMs),
                    fadeOutDuration:
                        const Duration(milliseconds: 1),
                    errorWidget: (_, _, _) =>
                        _Fallback(size: size),
                  )
                : _Fallback(size: size),
          ),
        ),
      ),
    );
  }
}

/// Gradient fallback until real thumbs load (native ArtGradients hues).
/// Dark greens in BOTH modes: overlay cards render white titles on top
/// of this before art arrives — a light gradient here (light-mode
/// primaryContainer) is white-on-white until thumbs load.
class _Fallback extends StatelessWidget {
  final double size;
  const _Fallback({required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: const LinearGradient(
          colors: [Color(0xFF0E5C2E), Color(0xFF08351B)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(Icons.music_note,
          size: size * 0.45, color: Colors.white),
    );
  }
}

/// Public artwork tile (cached thumb + gradient fallback).
class TrackArt extends StatelessWidget {
  final YtTrack track;
  final double size;
  final int maxPx;
  final String fallbackUrl;
  const TrackArt(
      {super.key,
      required this.track,
      this.size = 48,
      this.maxPx = 480,
      this.fallbackUrl = ''});

  @override
  Widget build(BuildContext context) =>
      _Art(track: track, size: size, maxPx: maxPx, fallbackUrl: fallbackUrl);
}

/// Skeleton shimmer placeholder (first load, H8; static when motion off).
class TrackSkeleton extends StatelessWidget {
  const TrackSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    final tile = ListTile(
      leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
              color: base, borderRadius: BorderRadius.circular(6))),
      title: Container(height: 14, color: base),
      subtitle: Container(height: 12, color: base),
    );
    if (!state.motionOn) return tile;
    return _Shimmer(child: tile);
  }
}

class _Shimmer extends StatefulWidget {
  final Widget child;
  const _Shimmer({required this.child});

  @override
  State<_Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<_Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    // Opacity pulse, 800ms loop, transform/opacity only.
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 800))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // RepaintBoundary: skeleton shimmer ticks at 120Hz during first
    // load — keep the opacity pulse off the list's repaint scope so
    // offscreen rows never pay for it.
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, child) => Opacity(
          opacity: 0.45 + 0.35 * _c.value,
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}
