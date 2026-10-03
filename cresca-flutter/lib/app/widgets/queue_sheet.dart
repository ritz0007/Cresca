// Queue sheet (P11): prev/Now/next split, opens at Now, tap-to-play,
// per-row remove, long-press drag reorder, smart-shuffle label,
// gapless auto-advance + instant skip, repeat labels.

import 'package:flutter/material.dart';

import '../../core/queue.dart';
import '../../core/track.dart';
import '../app.dart';
import '../state.dart';
import 'track_menu.dart';
import 'track_row.dart';

Future<void> openQueueSheet(BuildContext context) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (_, scroll) => QueueSheet(scroll: scroll),
      ),
    );
  } catch (_) {}
}

class QueueSheet extends StatelessWidget {
  final ScrollController scroll;
  const QueueSheet({super.key, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final engine = state.controller.engine;
        final order = engine.playOrder();
        final pos = order.indexOf(engine.currentIndex);
        final prev = pos <= 0
            ? <int>[]
            : order.sublist(0, pos).reversed.toList();
        final next = pos < 0 || pos >= order.length - 1
            ? <int>[]
            : order.sublist(pos + 1);
        final cur = engine.current;
        return CustomScrollView(
          controller: scroll,
          slivers: [
            SliverAppBar(
              pinned: true,
              title: Text(
                  'Queue${engine.shuffleMode == shuffleSmart ? ' • smart shuffled' : ''}'),
              actions: [
                if (engine.repeatMode != repeatOff)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Chip(
                        label: Text(engine.repeatMode == repeatAll
                            ? 'Repeat all'
                            : 'Repeat one')),
                  ),
              ],
            ),
            if (prev.isNotEmpty) ...[
              const SliverToBoxAdapter(
                  child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Previously'))),
              SliverList.builder(
                itemCount: prev.length,
                itemBuilder: (_, i) => _row(
                    context, state, engine, prev[i], false),
              ),
            ],
            if (cur != null) ...[
              const SliverToBoxAdapter(
                  child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Now'))),
              SliverToBoxAdapter(
                child: Card(
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  child: _row(context, state, engine,
                      engine.currentIndex, true),
                ),
              ),
            ],
            if (next.isNotEmpty) ...[
              const SliverToBoxAdapter(
                  child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('Next'))),
              SliverReorderableListHack(
                  state: state, engine: engine, next: next),
            ],
          ],
        );
      },
    );
  }

  Widget _row(BuildContext context, AppState state, QueueEngine engine,
      int itemIndex, bool isNow) {
    final t =
        (itemIndex >= 0 && itemIndex < engine.items.length)
            ? engine.items[itemIndex]
            : null;
    if (t == null) return const SizedBox.shrink();
    return Dismissible(
      key: ValueKey('q-$itemIndex'),
      direction: DismissDirection.endToStart,
      background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 16),
          child: const Icon(Icons.delete_outline)),
      onDismissed: (_) => state.controller.engine.removeAt(itemIndex),
      child: TrackRow(
        track: t,
        contextQueue: engine.snapshot(),
        index: itemIndex,
        onTap: () {
          try {
            state.controller.playAt(itemIndex);
          } catch (_) {}
        },
      ),
    );
  }
}

/// Reorderable next-list (long-press drag). Flutter's SliverReorderableList
/// needs a different delegate shape, so the next window renders as a
/// shrink-wrapped ReorderableListView inside the sliver.
class SliverReorderableListHack extends StatelessWidget {
  final AppState state;
  final QueueEngine engine;
  final List<int> next;
  const SliverReorderableListHack(
      {super.key,
      required this.state,
      required this.engine,
      required this.next});

  @override
  Widget build(BuildContext context) {
    return SliverToBoxAdapter(
      child: ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: next.length,
        onReorderItem: (a, b) {
          try {
            final order = engine.playOrder();
            final pos = order.indexOf(engine.currentIndex);
            state.controller.engine
                .moveInOrder(pos + 1 + a, pos + 1 + b);
          } catch (_) {}
        },
        itemBuilder: (_, i) {
          final itemIndex = next[i];
          final t = engine.items[itemIndex];
          return Dismissible(
            key: ValueKey('qn-$itemIndex'),
            direction: DismissDirection.endToStart,
            background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16),
                child: const Icon(Icons.delete_outline)),
            onDismissed: (_) =>
                state.controller.engine.removeAt(itemIndex),
            child: TrackRow(
              track: t,
              contextQueue: engine.snapshot(),
              index: itemIndex,
              onTap: () {
                try {
                  state.controller.playAt(itemIndex);
                } catch (_) {}
              },
            ),
          );
        },
      ),
    );
  }
}

Future<void> showQueueRowMenu(BuildContext context, AppState state,
    YtTrack track, List<YtTrack> queue) async {
  try {
    await showTrackMenu(context, state, track, queue);
  } catch (_) {}
}
