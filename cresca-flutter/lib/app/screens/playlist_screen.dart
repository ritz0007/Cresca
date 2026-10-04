// Playlist screen (P16): mosaic cover, Play/Shuffle/Edit/Delete,
// removable rows, Suggested from playlist artists. Custom cover picker
// lands with L6 polish (needs an image-picker dep).

import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../app.dart';
import '../library.dart';
import '../state.dart';
import '../widgets/mini_player.dart';
import '../widgets/track_row.dart';
import 'library_screen.dart' show MosaicArt;

Future<void> openPlaylistScreen(
    BuildContext context, String playlistId) async {
  try {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlaylistScreen(playlistId: playlistId)));
  } catch (_) {}
}

class PlaylistScreen extends StatefulWidget {
  final String playlistId;
  const PlaylistScreen({super.key, required this.playlistId});

  @override
  State<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends State<PlaylistScreen> {
  List<YtTrack> _suggested = [];
  bool _suggesting = false;

  UserPlaylist? _of(AppState state) {
    try {
      return state.library.playlists
          .firstWhere((p) => p.id == widget.playlistId);
    } catch (_) {
      return null;
    }
  }

  Future<void> _suggest(AppState state, UserPlaylist p) async {
    if (_suggesting) return;
    setState(() => _suggesting = true);
    try {
      // Suggested from playlist artists (native: computed at open).
      final artists = <String>{};
      for (final t in p.tracks.take(10)) {
        final a = t.displayArtist();
        if (a != 'Unknown Artist') artists.add(a);
        if (artists.length >= 3) break;
      }
      final out = <YtTrack>[];
      for (final a in artists) {
        try {
          final hits = await state.repo.searchMusic('$a songs', max: 6);
          for (final h in hits) {
            if (out.length >= 12) break;
            if (p.tracks.any((e) => e.id == h.id)) continue;
            if (out.any((e) => e.id == h.id)) continue;
            out.add(h);
          }
        } catch (_) {}
      }
      if (mounted) setState(() => _suggested = out);
    } catch (_) {}
    if (mounted) setState(() => _suggesting = false);
  }

  Future<void> _rename(
      BuildContext context, AppState state, UserPlaylist p) async {
    try {
      final c = TextEditingController(text: p.name);
      final name = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Rename playlist'),
          content: TextField(
              controller: c, autofocus: true),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(d, c.text),
                child: const Text('Save')),
          ],
        ),
      );
      if (name == null) return;
      await state.library.renamePlaylist(p.id, name);
      if (mounted) setState(() {});
    } catch (_) {}
  }

  Future<void> _delete(
      BuildContext context, AppState state, UserPlaylist p) async {
    try {
      final yes = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text('Delete "${p.name}"?'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(d, false),
                child: const Text('Cancel')),
            TextButton(
                onPressed: () => Navigator.pop(d, true),
                child: const Text('Delete')),
          ],
        ),
      );
      if (yes != true) return;
      await state.library.deletePlaylist(p.id);
      if (mounted) Navigator.pop(context);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final p = _of(state);
        if (p == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(
                child: Text('Playlist not found')),
          );
        }
        if (_suggested.isEmpty && !_suggesting) {
          _suggest(state, p);
        }
        return Scaffold(
          appBar: AppBar(
            title: Text(p.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: 'Rename',
                onPressed: () => _rename(context, state, p),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                onPressed: () => _delete(context, state, p),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 120,
                            height: 120,
                            child: ClipRRect(
                              borderRadius:
                                  BorderRadius.circular(12),
                              child: MosaicArt(tracks: p.tracks),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(p.name,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge),
                                Text('${p.tracks.length} songs',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodySmall),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    FilledButton.icon(
                                      icon: const Icon(
                                          Icons.play_arrow),
                                      label:
                                          const Text('Play'),
                                      onPressed: p.tracks.isEmpty
                                          ? null
                                          : () => state.actPlay(
                                              p.tracks, 0),
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton.icon(
                                      icon: const Icon(
                                          Icons.shuffle),
                                      label: const Text(
                                          'Shuffle'),
                                      onPressed: p.tracks.isEmpty
                                          ? null
                                          : () {
                                              final order =
                                                  List<int>.generate(
                                                      p.tracks.length,
                                                      (i) => i)
                                                ..shuffle();
                                              state.actPlay(
                                                  [
                                                    for (final i
                                                        in order)
                                                      p.tracks[i]
                                                  ],
                                                  0);
                                            },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    for (var i = 0; i < p.tracks.length; i++)
                      Dismissible(
                        key: ValueKey('pl-${p.tracks[i].id}'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(
                                right: 16),
                            child: const Icon(
                                Icons.delete_outline)),
                        onDismissed: (_) async {
                          try {
                            await state.library.removeFromPlaylist(
                                p.id, p.tracks[i].id);
                          } catch (_) {}
                        },
                        child: TrackRow(
                          track: p.tracks[i],
                          contextQueue: p.tracks,
                          index: i,
                        ),
                      ),
                    if (_suggesting)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(
                            child:
                                CircularProgressIndicator()),
                      ),
                    if (_suggested.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                            16, 8, 16, 4),
                        child: Text('Suggested',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium),
                      ),
                      for (var i = 0;
                          i < _suggested.length;
                          i++)
                        TrackRow(
                          track: _suggested[i],
                          contextQueue: _suggested,
                          index: i,
                        ),
                    ],
                  ],
                ),
              ),
              const MiniPlayer(),
            ],
          ),
        );
      },
    );
  }
}
