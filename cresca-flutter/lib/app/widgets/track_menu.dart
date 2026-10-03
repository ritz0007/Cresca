// Per-row overflow menu, identical on every screen (M1): Play, Play
// next, Add to queue, Add to playlist (picker + inline create),
// Download, Like, Share sheet, Start radio, Open in YouTube.

import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../state.dart';

Future<void> showTrackMenu(BuildContext context, AppState state,
    YtTrack track, List<YtTrack> contextQueue) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.play_arrow),
                title: const Text('Play'),
                onTap: () {
                  Navigator.pop(sheet);
                  state.actPlay(contextQueue, contextQueue
                      .indexWhere((e) => e.id == track.id));
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_play_next),
                title: const Text('Play next'),
                onTap: () {
                  Navigator.pop(sheet);
                  state.actPlayNext(track);
                  _toast(sheet, 'Will play next');
                },
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: const Text('Add to queue'),
                onTap: () {
                  Navigator.pop(sheet);
                  state.actAddToQueue(track);
                  _toast(sheet, 'Added to queue');
                },
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('Add to playlist'),
                onTap: () {
                  Navigator.pop(sheet);
                  showPlaylistPicker(context, state, track);
                },
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Download'),
                onTap: () {
                  Navigator.pop(sheet);
                  _toast(sheet, state.downloadStub);
                },
              ),
              ListTile(
                leading: Icon(state.library.isLiked(track.id)
                    ? Icons.favorite
                    : Icons.favorite_border),
                title: Text(state.library.isLiked(track.id)
                    ? 'Unlike'
                    : 'Like'),
                onTap: () {
                  Navigator.pop(sheet);
                  state.actToggleLike(track);
                },
              ),
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: const Text('Share'),
                onTap: () {
                  Navigator.pop(sheet);
                  state.actShare(track);
                },
              ),
              ListTile(
                leading: const Icon(Icons.radio_outlined),
                title: const Text('Start radio'),
                onTap: () {
                  Navigator.pop(sheet);
                  state.startRadio(track);
                },
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new),
                title: const Text('Open in YouTube'),
                onTap: () {
                  Navigator.pop(sheet);
                  state.actOpenYouTube(track);
                },
              ),
            ],
          ),
        ),
      ),
    );
  } catch (_) {}
}

/// Playlist picker + inline create (row-menu entry point).
Future<void> showPlaylistPicker(
    BuildContext context, AppState state, YtTrack track) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('New playlist'),
                onTap: () async {
                  Navigator.pop(sheet);
                  final name = await _askName(context);
                  if (name == null) return;
                  try {
                    final p = await state.library.createPlaylist(name);
                    await state.library.addToPlaylist(p.id, track);
                    if (context.mounted) _toast(context, 'Saved');
                  } catch (_) {}
                },
              ),
              for (final p in state.library.playlists)
                ListTile(
                  leading: const Icon(Icons.queue_music_outlined),
                  title: Text(p.name),
                  subtitle: Text('${p.tracks.length} songs'),
                  onTap: () async {
                    Navigator.pop(sheet);
                    try {
                      await state.library.addToPlaylist(p.id, track);
                      if (context.mounted) _toast(context, 'Saved');
                    } catch (_) {}
                  },
                ),
            ],
          ),
        ),
      ),
    );
  } catch (_) {}
}

Future<String?> _askName(BuildContext context) async {
  try {
    final c = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('New playlist'),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration:
              const InputDecoration(hintText: 'Playlist name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(d, c.text),
              child: const Text('Create')),
        ],
      ),
    );
    final t = (name ?? '').trim();
    return t.isEmpty ? null : t;
  } catch (_) {
    return null;
  }
}

void _toast(BuildContext context, String message) {
  try {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  } catch (_) {}
}
