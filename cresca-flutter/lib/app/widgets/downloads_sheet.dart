// Downloads sheet (L5): list with MB, progress, offline-first rows,
// clean delete, in-app vs device-Music switch. Native ref:
// DownloadsSheet.kt + DownloadStore location switch.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../app.dart';
import '../design.dart';
import '../downloads.dart';
import '../state.dart';
import 'track_row.dart';

Future<void> openDownloadsSheet(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    bool motionOn = true;
    try {
      motionOn = AppScope.of(context).motionOn;
    } catch (_) {}
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scroll) => GlassSheetSurface(
          motionOn: motionOn,
          child: DownloadsSheet(scroll: scroll),
        ),
      ),
    );
  } catch (_) {
    try {
      messenger.showSnackBar(
          SnackBar(content: Semantics(liveRegion: true, child: Text('Could not open downloads'))));
    } catch (_) {}
  }
}

class DownloadsSheet extends StatefulWidget {
  final ScrollController scroll;
  const DownloadsSheet({super.key, required this.scroll});

  @override
  State<DownloadsSheet> createState() => _DownloadsSheetState();
}

/// Stashed files + row for one swiped-away download, held on disk (not
/// RAM — audio files are tens of MB) until the Undo SnackBar expires so
/// a slip restores the exact file.
class _TrashedDownload {
  /// (original path, trash path) pairs, one per moved copy.
  final List<(String, String)> moved;
  final DownloadEntry? entry;
  _TrashedDownload({
    required this.moved,
    required this.entry,
  });
}

class _DownloadsSheetState extends State<DownloadsSheet> {
  final Map<String, _TrashedDownload> _trash = {};

  /// Moves [src] to [dst], falling back to copy+delete across volumes.
  /// Returns true on success. Never throws.
  Future<bool> _moveFile(File src, String dst) async {
    try {
      final d = File(dst);
      try {
        await d.parent.create(recursive: true);
      } catch (_) {}
      try {
        await src.rename(dst);
        return true;
      } catch (_) {}
      try {
        await src.copy(dst);
        await src.delete();
        return true;
      } catch (_) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }

  /// Deletes every trash file stashed for [trackId] (Undo expired or
  /// sheet disposed — no disk leak). Never throws.
  Future<void> _dropTrash(String trackId) async {
    final trashed = _trash.remove(trackId);
    if (trashed == null) return;
    for (final (_, trashPath) in trashed.moved) {
      try {
        final f = File(trashPath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    // Undo window dies with the sheet: drop stashed files, not RAM.
    try {
      for (final trackId in _trash.keys.toList()) {
        unawaited(_dropTrash(trackId));
      }
    } catch (_) {}
    super.dispose();
  }

  void unawaited(Future<void> f) {}

  /// Swipe-delete with Undo: moves the file(s) aside on disk first (the
  /// store has no restore API), deletes the row, then offers Undo for
  /// 5 s. Both delete and restore are announced for screen readers.
  Future<void> _deleteWithUndo(
      BuildContext context, AppState state, int index) async {
    final items = state.downloads.listAll();
    if (index < 0 || index >= items.length) return;
    final (track, _, _) = items[index];
    final messenger = ScaffoldMessenger.of(context);
    final direction = Directionality.of(context);
    final view = View.of(context);
    // Move EVERY copy (app + device dirs) aside before the row delete
    // drops them all — restoring one copy would lose the other.
    final moved = <(String, String)>[];
    try {
      var n = 0;
      for (final (t, file, _) in state.downloads.listAll()) {
        if (t.id != track.id) continue;
        try {
          final trashPath =
              '${file.parent.path}/.trash/${track.id}_${DateTime.now().millisecondsSinceEpoch}_${n++}_${file.path.split(RegExp(r'[/\\]')).last}';
          if (await _moveFile(file, trashPath)) {
            moved.add((file.path, trashPath));
          }
        } catch (_) {}
      }
    } catch (_) {}
    DownloadEntry? entry;
    try {
      entry = state.downloads.rows[track.id];
    } catch (_) {}
    if (moved.isNotEmpty) {
      _trash[track.id] =
          _TrashedDownload(moved: moved, entry: entry);
    }
    try {
      await state.downloads.delete(track.id);
    } catch (_) {}
    try {
      SemanticsService.sendAnnouncement(
          view, 'Deleted ${track.title}', direction);
    } catch (_) {}
    try {
      messenger.clearSnackBars();
      messenger
          .showSnackBar(
            SnackBar(
              content: Semantics(liveRegion: true, child: Text('Deleted ${track.title}')),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () =>
                    _restore(context, state, track.id,
                        track.title),
              ),
            ),
          )
          .closed
          .then((_) {
        // Grace period over — drop the stash (files too).
        unawaited(_dropTrash(track.id));
      });
    } catch (_) {}
  }

  Future<void> _restore(BuildContext context, AppState state,
      String trackId, String title) async {
    final trashed = _trash.remove(trackId);
    if (trashed == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final view = View.of(context);
    final direction = Directionality.of(context);
    try {
      var ok = false;
      for (final (origPath, trashPath) in trashed.moved) {
        try {
          if (await _moveFile(File(trashPath), origPath)) ok = true;
        } catch (_) {}
      }
      if (!ok) throw StateError('no files restored');
      if (trashed.entry != null) {
        try {
          state.downloads.rows[trackId] = trashed.entry!;
        } catch (_) {}
      }
      try {
        state.downloads.onChanged?.call();
      } catch (_) {}
      try {
        SemanticsService.sendAnnouncement(view,
            'Restored $title', direction);
      } catch (_) {}
      try {
        messenger.showSnackBar(
            SnackBar(content: Semantics(liveRegion: true, child: Text('Restored $title'))));
      } catch (_) {}
    } catch (_) {
      // Partial move-back: clean the leftovers, report honestly.
      for (final (_, trashPath) in trashed.moved) {
        try {
          final f = File(trashPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      try {
        messenger.showSnackBar(
            SnackBar(
                content: Semantics(liveRegion: true, child: Text('Could not restore download'))));
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final items = state.downloads.listAll();
        final loc = state.downloads.location;
        final ms = state.motionMs(180);
        final d = Duration(milliseconds: ms);
        // Pinned header needs an opaque backing: the sheet glass is
        // translucent at the top, so scrolled rows would ghost through
        // the title. surfaceContainer at 0.94 reads as the same
        // material fading to opaque.
        final headerBg = Theme.of(context)
            .colorScheme
            .surfaceContainer
            .withValues(alpha: 0.94);
        final dark =
            Theme.of(context).brightness == Brightness.dark;
        return CustomScrollView(
          controller: widget.scroll,
          slivers: [
            const SliverToBoxAdapter(
              child: SheetGrabHandle(),
            ),
            SliverAppBar(
              pinned: true,
              backgroundColor: headerBg,
              automaticallyImplyLeading: false,
              title: Text('Downloads',
                  style:
                      TextStyle(color: glassText(dark))),
              actions: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close downloads',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 0, 16, 8),
                // Segmented save-location: selection pill tint
                // crossfades via AnimatedContainer (180 ms).
                child: Row(
                  children: [
                    const Text('Save to: '),
                    const SizedBox(width: 8),
                    _LocChip(
                      label: 'In-app',
                      selected: loc == 'app',
                      ms: ms,
                      motionOn: state.motionOn,
                      onTap: () =>
                          state.setDownloadLocation('app'),
                    ),
                    const SizedBox(width: 8),
                    _LocChip(
                      label: 'Device Music',
                      selected: loc == 'device',
                      ms: ms,
                      motionOn: state.motionOn,
                      onTap: () => state
                          .setDownloadLocation('device'),
                    ),
                  ],
                ),
              ),
            ),
            // Empty ⇄ list crossfade (180 ms, opacity only).
            SliverToBoxAdapter(
              child: AnimatedSwitcher(
                duration: d,
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeOut,
                child: items.isEmpty
                    ? Padding(
                        key: const ValueKey('dl-empty'),
                        padding:
                            const EdgeInsets.fromLTRB(
                                32, 24, 32, 16),
                        child: Column(
                          mainAxisSize:
                              MainAxisSize.min,
                          children: [
                            Icon(
                                Icons
                                    .offline_pin_outlined,
                                size: 40,
                                color: Theme.of(
                                        context)
                                    .colorScheme
                                    .onSurfaceVariant),
                            const SizedBox(
                                height: 12),
                            Text(
                              'Nothing downloaded yet',
                              textAlign:
                                  TextAlign.center,
                              style: Theme.of(
                                      context)
                                  .textTheme
                                  .titleMedium,
                            ),
                            const SizedBox(
                                height: 4),
                            Text(
                              'Use Download on any song to keep it offline.',
                              textAlign:
                                  TextAlign.center,
                              style: Theme.of(
                                      context)
                                  .textTheme
                                  .bodySmall,
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('dl-list')),
              ),
            ),
            SliverList.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final (track, file, mb) = items[i];
                final pct =
                    state.downloads.progressFor(track.id);
                // First-frame stagger: rows fade + rise on sheet open
                // (40 ms steps, capped at 8 — transform/opacity only).
                return FadeSlide(
                  motionOn: state.motionOn,
                  delay: Duration(
                      milliseconds: state.motionOn
                          ? (i > 8 ? 8 : i) * 40
                          : 0),
                  child: Dismissible(
                  key: ValueKey('dl-${track.id}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                      alignment: Alignment.centerRight,
                      padding:
                          const EdgeInsets.only(right: 16),
                      child: Icon(Icons.delete_outline,
                          color: Theme.of(context)
                              .colorScheme
                              .error)),
                  onDismissed: (_) =>
                      _deleteWithUndo(context, state, i),
                  // 120Hz polish: each row paints behind its own
                  // boundary so progress tweens + art loads never
                  // repaint the whole list at 120 Hz.
                  child: RepaintBoundary(
                  child: ListTile(
                    leading: SizedBox(
                      width: 48,
                      height: 48,
                      child: TrackArt(
                          track: track, size: 48),
                    ),
                    title: Text(track.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${track.displayArtist()} • ${mb.toStringAsFixed(1)} MB'
                        '${pct >= 0 && pct < 100 ? ' • $pct%' : ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                    trailing: pct >= 0 && pct < 100
                        ? SizedBox(
                            width: 24,
                            height: 24,
                            // Smooth progress sweep (180 ms tween
                            // retargeted toward each new value) +
                            // opacity-only pulse while downloading.
                            child: PulseOpacity(
                              motionOn:
                                  state.motionOn,
                              child: _SmoothProgress(
                                value: pct / 100,
                                ms: state
                                    .motionMs(180),
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.offline_pin_outlined),
                    onTap: () {
                      try {
                        state.controller.playQueue([track], 0);
                      } catch (_) {}
                    },
                  ),
                  ),
                ),
                );
              },
            ),
            // Gesture-strip clearance matches jam/profile (32dp).
            const SliverToBoxAdapter(
              child: SizedBox(height: 32),
            ),
          ],
        );
      },
    );
  }
}

/// Segmented save-location chip: AnimatedContainer tints the selected
/// pill (180 ms); tap target wrapped in [PressScale].
class _LocChip extends StatelessWidget {
  final String label;
  final bool selected;
  final int ms;
  final bool motionOn;
  final VoidCallback onTap;
  const _LocChip({
    required this.label,
    required this.selected,
    required this.ms,
    required this.motionOn,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PressScale(
      motionOn: motionOn,
      onTap: onTap,
      child: AnimatedContainer(
        duration: Duration(milliseconds: ms),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(
            horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.18)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.5)
                : Colors.transparent,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontWeight:
                selected ? FontWeight.w700 : FontWeight.w400,
            color: scheme.onSurface,
          ),
        ),
      ),
    );
  }
}

/// Download progress ring that tweens toward each new value (no
/// sweep-from-zero on updates): keeps the last displayed value as the
/// next tween's begin.
class _SmoothProgress extends StatefulWidget {
  final double value;
  final int ms;
  const _SmoothProgress({required this.value, required this.ms});

  @override
  State<_SmoothProgress> createState() => _SmoothProgressState();
}

class _SmoothProgressState extends State<_SmoothProgress> {
  double _prev = 0;

  @override
  void didUpdateWidget(covariant _SmoothProgress old) {
    super.didUpdateWidget(old);
    _prev = old.value;
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: _prev, end: widget.value),
      duration: Duration(milliseconds: widget.ms),
      curve: Curves.easeOut,
      builder: (_, v, child) => CircularProgressIndicator(
        value: v.clamp(0.0, 1.0),
        strokeWidth: 2,
      ),
    );
  }
}
