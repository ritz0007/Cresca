// Shared track row (every list) + skeleton placeholder (H8/A4).
// Artwork: cached thumbs with mosaic/gradient fallback (same fallback
// hues as native ArtGradients). Press-scale .94 when motion is on.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../app.dart';
import 'track_menu.dart';

class TrackRow extends StatelessWidget {
  final YtTrack track;
  final List<YtTrack> contextQueue;
  final int index;
  final VoidCallback? onTap;
  final bool showArt;
  const TrackRow({
    super.key,
    required this.track,
    required this.contextQueue,
    required this.index,
    this.onTap,
    this.showArt = true,
  });

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListTile(
      leading: showArt ? _Art(track: track) : null,
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
      trailing: IconButton(
        icon: const Icon(Icons.more_vert),
        onPressed: () => showTrackMenu(context, state, track, contextQueue),
      ),
      onTap: onTap ??
          () {
            try {
              state.actPlay(contextQueue, index);
            } catch (_) {}
          },
    );
  }
}

class _Art extends StatelessWidget {
  final YtTrack track;
  final double size;
  const _Art({required this.track, this.size = 48});

  @override
  Widget build(BuildContext context) {
    if (track.thumbUrl.isEmpty) return _Fallback(size: size);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedNetworkImage(
        imageUrl: track.thumbUrl,
        width: size,
        height: size,
        fit: BoxFit.cover,
        placeholder: (_, _) => _Fallback(size: size),
        errorWidget: (_, _, _) => _Fallback(size: size),
      ),
    );
  }
}

/// Gradient fallback until real thumbs load (native ArtGradients hues).
class _Fallback extends StatelessWidget {
  final double size;
  const _Fallback({required this.size});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(
          colors: [scheme.primary, scheme.primaryContainer],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Icon(Icons.music_note,
          size: size * 0.45, color: scheme.onPrimary),
    );
  }
}

/// Public artwork tile (cached thumb + gradient fallback).
class TrackArt extends StatelessWidget {
  final YtTrack track;
  final double size;
  const TrackArt({super.key, required this.track, this.size = 48});

  @override
  Widget build(BuildContext context) => _Art(track: track, size: size);
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
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: 0.45 + 0.35 * _c.value,
        child: child,
      ),
      child: widget.child,
    );
  }
}
