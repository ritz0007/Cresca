// Downloads sheet (L5): list with MB, progress, offline-first rows,
// clean delete, in-app vs device-Music switch. Native ref:
// DownloadsSheet.kt + DownloadStore location switch.

import 'package:flutter/material.dart';

import '../app.dart';
import 'track_row.dart';

Future<void> openDownloadsSheet(BuildContext context) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scroll) =>
            DownloadsSheet(scroll: scroll),
      ),
    );
  } catch (_) {}
}

class DownloadsSheet extends StatelessWidget {
  final ScrollController scroll;
  const DownloadsSheet({super.key, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final items = state.downloads.listAll();
        final loc = state.downloads.location;
        return CustomScrollView(
          controller: scroll,
          slivers: [
            SliverAppBar(
              pinned: true,
              title: const Text('Downloads'),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Text('Save to: '),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('In-app'),
                      selected: loc == 'app',
                      onSelected: (_) =>
                          state.setDownloadLocation('app'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('Device Music'),
                      selected: loc == 'device',
                      onSelected: (_) =>
                          state.setDownloadLocation('device'),
                    ),
                  ],
                ),
              ),
            ),
            if (items.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Nothing downloaded yet.\nUse Download on any song to keep it offline.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ),
            SliverList.builder(
              itemCount: items.length,
              itemBuilder: (_, i) {
                final (track, file, mb) = items[i];
                final pct =
                    state.downloads.progressFor(track.id);
                return Dismissible(
                  key: ValueKey('dl-${track.id}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                      alignment: Alignment.centerRight,
                      padding:
                          const EdgeInsets.only(right: 16),
                      child:
                          const Icon(Icons.delete_outline)),
                  onDismissed: (_) =>
                      state.downloads.delete(track.id),
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
                            child: CircularProgressIndicator(
                                value: pct / 100,
                                strokeWidth: 2),
                          )
                        : const Icon(
                            Icons.offline_pin_outlined),
                    onTap: () {
                      try {
                        state.controller.playQueue([track], 0);
                      } catch (_) {}
                    },
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}
