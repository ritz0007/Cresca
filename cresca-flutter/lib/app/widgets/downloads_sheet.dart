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
import '../../core/track.dart';
import 'track_row.dart';

Future<void> openDownloadsSheet(BuildContext context) async {
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
  } catch (_) {}
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
  /// Copy follows the deck: 'Removed "<title>"' when the stash
  /// restores the exact file, 'Deleted "<title>" — needs re-download'
  /// when the bytes were already unreadable (Undo re-downloads).
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
      } catch (_) {}
      trashed = _TrashedDownload(
          path: file.path, bytes: bytes, entry: entry);
      _trash[track.id] = trashed;
    } catch (_) {}
    try {
      await state.downloads.delete(track.id);
    } catch (_) {}
    final restorable = _trash.containsKey(track.id);
    final msg = restorable
        ? 'Removed "${track.title}"'
        : 'Deleted "${track.title}" — needs re-download';
    try {
      SemanticsService.sendAnnouncement(
          View.of(context), msg, direction);
    } catch (_) {}
    try {
      messenger.clearSnackBars();
      messenger
          .showSnackBar(
            SnackBar(
              content: Text(msg),
              duration: const Duration(seconds: 5),
              action: SnackBarAction(
                label: 'Undo',
                onPressed: () => restorable
                    ? _restore(context, state, track.id,
                        track.title)
                    : _redownload(context, state, track),
              ),
            ),
          )
          .closed
          .then((_) {
        // Grace period over — drop the stash.
        _trash.remove(track.id);
      });
    } catch (_) {}
  }

  /// Fresh stream URL for a sheet row (stored URLs expire — same
  /// fallback the episode coordinator uses). Never throws.
  Future<String?> _freshUrl(AppState state, YtTrack track) {
    try {
      return state.resolver.audioUrl(track.watchUrl.isEmpty
          ? 'https://www.youtube.com/watch?v=${track.id}'
          : track.watchUrl);
    } catch (_) {
      return Future.value(null);
    }
  }

  /// Undo when the bytes were already gone: re-enqueue through the
  /// store with a freshly resolved URL (stored URLs expire). Failure
  /// surfaces an honest message, never a silent no-op.
  Future<void> _redownload(BuildContext context, AppState state,
      YtTrack track) async {
    try {
      final ok = await state.downloads.retry(
        track,
        () => _freshUrl(state, track),
      );
      if (!context.mounted) return;
      try {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ok
                ? 'Re-downloading ${track.title}'
                : 'Could not restore download')));
      } catch (_) {}
    } catch (_) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Could not restore download')));
      } catch (_) {}
    }
  }

  /// Inline Retry for a failed row (U7: per-file Retry). Same
  /// re-resolve path as the delete-Undo above.
  Future<void> _retry(BuildContext context, AppState state,
      YtTrack track) async {
    try {
      final ok = await state.downloads.retry(
        track,
        () => _freshUrl(state, track),
      );
      if (!ok && context.mounted) {
        try {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content:
                      Text('Download failed to start')));
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _restore(BuildContext context, AppState state,
      String trackId, String title) async {
    final trashed = _trash.remove(trackId);
    if (trashed == null) return;
    try {
      final f = File(trashed.path);
      try {
        await f.parent.create(recursive: true);
      } catch (_) {}
      await f.writeAsBytes(trashed.bytes, flush: true);
      if (trashed.entry != null) {
        try {
          state.downloads.rows[trackId] = trashed.entry!;
        } catch (_) {}
      }
      try {
        state.downloads.onChanged?.call();
      } catch (_) {}
      try {
        SemanticsService.sendAnnouncement(View.of(context),
            'Restored $title', Directionality.of(context));
      } catch (_) {}
      try {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Restored $title')));
      } catch (_) {}
    } catch (_) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Could not restore download')));
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
        // U7 aggregate: in-flight files summarized on one line (the
        // per-file rows below carry the exact %).
        var activeN = 0;
        var activeSum = 0;
        for (final (t, _, _) in items) {
          final pct = state.downloads.progressFor(t.id);
          if (pct >= 0 && pct < 100) {
            activeN++;
            activeSum += pct;
          }
        }
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
            // U7: the sheet is the single progress surface. The app
            // update APK (when pending) reads the same AppState fields
            // the home banner reads — one state, two readers.
            if (state.pendingUpdate != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      16, 0, 16, 8),
                  child: _UpdateProgressRow(
                      state: state),
                ),
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
            // Aggregate progress line (U7): only while files are in
            // flight. Reads the same DownloadStore the rows read.
            if (activeN > 0)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                      16, 0, 16, 4),
                  child: Text(
                    'Downloading $activeN file${activeN == 1 ? '' : 's'} — ${(activeSum / activeN).round()}%',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
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
                // U7: failed rows show an inline Retry (per file),
                // never a global dead end. Filename-only rows (no
                // store row) are complete by construction — isFailed
                // reports false for those.
                final failed =
                    state.downloads.isFailed(track.id);
                final active = pct >= 0 && pct < 100;
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
                    trailing: failed
                        ? SizedBox(
                            width: 48,
                            height: 48,
                            child: Semantics(
                              button: true,
                              label:
                                  'Retry download of ${track.title}',
                              child: IconButton(
                                tooltip:
                                    'Retry download',
                                iconSize: 22,
                                onPressed: () =>
                                    _retry(context,
                                        state, track),
                                icon: Icon(
                                    Icons.refresh,
                                    color: Theme.of(
                                            context)
                                        .colorScheme
                                        .primary),
                              ),
                            ),
                          )
                        : active
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

/// App-update row inside the downloads sheet (U7): status + action
/// for the pending APK, reading the same AppState fields as the home
/// banner (single state, two readers). No progress plumbing here —
/// the sheet never fetches, it only reads.
class _UpdateProgressRow extends StatelessWidget {
  final AppState state;
  const _UpdateProgressRow({required this.state});

  @override
  Widget build(BuildContext context) {
    final u = state.pendingUpdate;
    if (u == null) return const SizedBox.shrink();
    final prog = state.updateProgress;
    final downloaded = state.updateDownloaded;
    final active = prog >= 0;
    final status = active
        ? 'Downloading… ${prog.round()}%'
        : downloaded
            ? 'Downloaded — ready to install.'
            : 'Tap Update to download.';
    return Semantics(
      label: 'App update ${u.tag}. $status',
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: spotifyGreen.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
              color: spotifyGreen.withValues(alpha: 0.35)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.system_update_outlined,
                    color: spotifyGreen, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('App update ${u.tag}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w700)),
                ),
                FilledButton(
                  style: spotifyPlayStyle(),
                  onPressed: active
                      ? null
                      : () => _run(context),
                  child: Text(
                      downloaded ? 'Install' : 'Update'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(status,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall),
            if (active)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: (prog / 100).clamp(0.0, 1.0),
                    minHeight: 4,
                    backgroundColor: spotifyGreen.withValues(
                        alpha: 0.2),
                    valueColor:
                        const AlwaysStoppedAnimation<Color>(
                            spotifyGreen),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _run(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final msg = state.updateDownloaded
          ? await state.installUpdate()
          : await state.downloadUpdate();
      if (msg.isEmpty) return;
      try {
        messenger.showSnackBar(SnackBar(content: Text(msg)));
      } catch (_) {}
    } catch (_) {}
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
