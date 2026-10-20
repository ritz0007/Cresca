// U9 image budget: one shared disk/memory front for every artwork thumb.
//
// - Disk: dedicated CacheManager store ('crescaArt') mirroring the T7
//   policy in data/cache.dart — 2000 objects, 30-day stale.
// - Memory: Flutter ImageCache pinned to 200 entries / 48 MB (see
//   [initArtworkCache]; defaults are 1000 imgs / 100 MB).
// - Retention: CachedNetworkImage keeps the old frame across URL swaps
//   (3.4.1 exposes Image's gaplessPlayback as [useOldImageOnUrlChange]),
//   so re-scroll never flashes white.
// - Viewport-ahead prefetch ([prefetchArtwork] + [ArtPrefetch]) warms
//   rails + queue next-3 during idle; scroll motion skips it outright.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../core/track.dart';
import '../data/cache.dart';

/// Shared artwork disk store. Values mirror the T7 consts in
/// data/cache.dart ([artworkDiskMaxObjects], [artworkDiskStaleMs]);
/// the ~200 MB footprint is the cache-manager disk default plus the
/// tight per-slot memCacheWidth/Height decodes at each call site.
CacheManager get artworkCacheManager => _manager;
final CacheManager _manager = CacheManager(
  Config(
    'crescaArt',
    stalePeriod: Duration(milliseconds: artworkDiskStaleMs),
    maxNrOfCacheObjects: artworkDiskMaxObjects,
  ),
);

/// U9 LRU caps (tuned on jam16, documented): count cap 200 entries +
/// 48 MB byte cap. 200 × ~150px RGBA thumbs ≈ 18 MB resident; the byte
/// cap is the enforcer when hero/queue art decodes larger.
const int artworkMemCountCap = artworkMemCacheSize; // 200
const int artworkMemByteCap = 48 * 1024 * 1024; // 48 MB

/// Call once at boot (after ensureInitialized): pins the in-memory
/// ImageCache to the U9 caps instead of Flutter's 1000-img / 100-MB
/// defaults. Never throws.
void initArtworkCache() {
  try {
    final c = PaintingBinding.instance.imageCache;
    c.maximumSize = artworkMemCountCap;
    c.maximumSizeBytes = artworkMemByteCap;
  } catch (_) {}
}

/// Viewport-ahead prefetch: warms [urls] into the ImageCache during
/// idle, capped to [artworkPrefetchMax]. Skips flings (bytes would
/// arrive for rows already scrolled past — never fight the finger,
/// same principle as U5 lyrics) and swallows all errors
/// (offline/missing art is normal).
Future<void> prefetchArtwork(
    BuildContext context, List<String> urls) async {
  try {
    if (urls.isEmpty) return;
    // No prefetch while the enclosing scrollable is moving: bytes
    // would arrive for rows already scrolled past. (isScrollingNotifier
    // is the public scroll-activity signal — never fight the finger,
    // same principle as U5 lyrics.)
    try {
      final p = Scrollable.of(context).position;
      if (p.isScrollingNotifier.value) return;
    } catch (_) {}
    final take = urls.length > artworkPrefetchMax
        ? urls.sublist(0, artworkPrefetchMax)
        : urls;
    for (final u in take) {
      if (u.isEmpty) continue;
      try {
        await precacheImage(
          CachedNetworkImageProvider(
              u, cacheManager: artworkCacheManager),
          context,
        );
      } catch (_) {}
    }
  } catch (_) {}
}

/// Drop-in viewport-ahead hook: place in a rail / queue header with an
/// identity [tick]; prefetches [tracks] thumbs once per tick,
/// post-frame (never during build, never during flings). Renders
/// nothing.
class ArtPrefetch extends StatefulWidget {
  final String tick;
  final List<YtTrack> tracks;
  const ArtPrefetch(
      {super.key, required this.tick, required this.tracks});

  @override
  State<ArtPrefetch> createState() => _ArtPrefetchState();
}

class _ArtPrefetchState extends State<ArtPrefetch> {
  String _done = '';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybe();
  }

  @override
  void didUpdateWidget(covariant ArtPrefetch old) {
    super.didUpdateWidget(old);
    if (old.tick != widget.tick) _maybe();
  }

  void _maybe() {
    if (_done == widget.tick || widget.tracks.isEmpty) return;
    _done = widget.tick;
    final urls = pickArtworkPrefetch(widget.tracks);
    if (urls.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        prefetchArtwork(context, urls);
      } catch (_) {}
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
