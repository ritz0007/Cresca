// U6 per-rail status contract: canonical rail slots resolved from
// primary (video) + fallback (state chart) tracks and their failure
// sets. Pure for tests — screens render slots.tracks, raise
// InlineRetryBanner when failed && tracks empty, and hide genuinely
// empty rails. Zero Flutter imports so package:test pins the state
// machine without the widget closure.

import 'track.dart';

/// One canonical rail slot: resolved tracks plus whether this rail's
/// fetch failed. Paint order follows the input titles — a failed rail
/// banners in place instead of shifting its siblings up.
class RailSlot {
  final String title;
  final List<YtTrack> tracks;
  final bool failed;
  const RailSlot(
      {required this.title, required this.tracks, required this.failed});
}

/// Resolves canonical slots in [titles] order. [primary] wins when
/// non-empty, else [fallback]; a rail is failed only when it has no
/// tracks AND its fetch threw (either source). Never throws.
List<RailSlot> resolveRailSlots({
  required List<String> titles,
  required Map<String, List<YtTrack>> primary,
  required Map<String, List<YtTrack>> fallback,
  required Set<String> failedPrimary,
  required Set<String> failedFallback,
}) {
  try {
    final out = <RailSlot>[];
    for (final title in titles) {
      try {
        final p = primary[title] ?? const <YtTrack>[];
        final f = fallback[title] ?? const <YtTrack>[];
        final tracks = p.isNotEmpty ? p : f;
        final failed = tracks.isEmpty &&
            (failedPrimary.contains(title) ||
                failedFallback.contains(title));
        out.add(RailSlot(title: title, tracks: tracks, failed: failed));
      } catch (_) {}
    }
    return out;
  } catch (_) {
    return const [];
  }
}
