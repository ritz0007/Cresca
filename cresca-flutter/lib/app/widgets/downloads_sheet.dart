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
import 'cresca_toast.dart';
import 'track_row.dart';

Future<void> openDownloadsSheet(BuildContext context) async {
  try {
    bool motionOn = true;
    try {
      motionOn = AppScope.of(context).motionOn;
    } catch (_) {
      // silent: motion probe, animation default (on) is safe
    }
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
  } catch (e, st) {
    await logUserFailure(context, 'open downloads failed', e, st);
    await showCrescaToast(context, 'Could not open downloads — Retry');
  }
}

class DownloadsSheet extends StatefulWidget {
  final ScrollController scroll;
  const DownloadsSheet({super.key, required this.scroll});

  @override
  State<DownloadsSheet> createState() => _DownloadsSheetState();
}

/// Stashed bytes + row for one swiped-away download, held until the
/// Undo SnackBar expires so a slip restores the exact file.
class _TrashedDownload {
  final String path;
  final List<int> bytes;
  final DownloadEntry? entry;
  _TrashedDownload({
    required this.path,
    required this.bytes,
    required this.entry,
  });
}

class _DownloadsSheetState extends State<DownloadsSheet> {
  final Map<String, _TrashedDownload> _trash = {};

  /// Swipe-delete with Undo: stash the file bytes + row first (the
  /// store has no restore API), delete, then offer Undo for 5 s.
  /// Both delete and restore are announced for screen readers.
  Future<void> _deleteWithUndo(
      BuildContext context, AppState state, int index) async {
    final items = state.downloads.listAll();
    if (index < 0 || index >= items.length) return;
    final (track, file, _) = items[index];
    final messenger = ScaffoldMessenger.of(context);
    final direction = Directionality.of(context);
    _TrashedDownload? trashed;
    try {
      final bytes = await file.readAsBytes();
      DownloadEntry? entry;
      try {
        entry = state.downloads.rows[track.id];
      } catch (_) {
        // silent: row snapshot probe, restore proceeds without it
      }
      trashed = _TrashedDownload(
          path: file.path, bytes: bytes, entry: entry);
      _trash[track.id] = trashed;
    } catch (e, st) {
      await state.crash.log('download stash failed', e, st);
    }
    try {
      await state.downloads.delete(track.id);
    } catch (e, st) {
      await state.crash.log('download delete failed', e, st);
      if (context.mounted) {
        await showCrescaToast(
            context, "Couldn't delete download — Retry");
      }
      return;
    }
    try {
      SemanticsService.sendAnnouncement(
          View.of(context), 'Deleted ${track.title}', direction);
    } catch (_) {
      // silent: screen-reader announcement only, Undo bar still shows
    }
    try {
      messenger.clearSnackBars();
      messenger
          .showSnackBar(
            SnackBar(
              content: Text('Deleted ${track.title}'),
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
        // Grace period over — drop the stash.
        _trash.remove(track.id);
      });
    } catch (e, st) {
      await state.crash
          .log('download undo bar failed', e, st);
    }
  }

  Future<void> _restore(BuildContext context, AppState state,
      String trackId, String title) async {
    final trashed = _trash.remove(trackId);
    if (trashed == null) return;
    try {
      final f = File(trashed.path);
      try {
        await f.parent.create(recursive: true);
      } catch (_) {
        // silent: dir probe, write below recreates or fails loudly
      }
      await f.writeAsBytes(trashed.bytes, flush: true);
      if (trashed.entry != null) {
        try {
          state.downloads.rows[trackId] = trashed.entry!;
        } catch (_) {
          // silent: row snapshot probe, file restore already done
        }
      }
      try {
        state.downloads.onChanged?.call();
      } catch (_) {
        // silent: change notify only, file restore already done
      }
      try {
        SemanticsService.sendAnnouncement(View.of(context),
            'Restored $title', Directionality.of(context));
      } catch (_) {
        // silent: screen-reader announcement only
      }
      if (context.mounted) {
        await showCrescaToast(context, 'Restored $title');
      }
    } catch (e, st) {
      await state.crash.log('download restore failed', e, st);
      if (context.mounted) {
        await showCrescaToast(
            context, 'Could not restore download — Retry');
      }
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
            SliverToBoxAdapter(
              child: Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            SliverAppBar(
              pinned: true,
              backgroundColor: headerBg,
              automaticallyImplyLeading: false,
              title: Text('Downloads',
                  style:
                      TextStyle(color: glassText(dark))),
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
                      } catch (e, st) {
                        state.crash.log(
                            'offline play failed', e, st);
                        showCrescaToast(
                            context, 'Could not play — Retry');
                      }
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
