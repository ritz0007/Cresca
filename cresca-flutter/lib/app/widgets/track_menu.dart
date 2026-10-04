// Per-row overflow menu, identical on every screen (M1): Play, Play
// next, Add to queue, Add to playlist (picker + inline create),
// Download, Like, Share sheet, Start radio, Open in YouTube.
// iOS presentation: CupertinoActionSheet with a Cancel button.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../state.dart';

Future<void> showTrackMenu(BuildContext context, AppState state,
    YtTrack track, List<YtTrack> contextQueue) async {
  try {
    final liked = state.library.isLiked(track.id);
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(track.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        message: Text(track.displayArtist(),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              state.actPlay(contextQueue, contextQueue
                  .indexWhere((e) => e.id == track.id));
            },
            child: const Text('Play'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              state.actPlayNext(track);
              _toast(context, 'Will play next');
            },
            child: const Text('Play next'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              state.actAddToQueue(track);
              _toast(context, 'Added to queue');
            },
            child: const Text('Add to queue'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              showPlaylistPicker(context, state, track);
            },
            child: const Text('Add to playlist'),
          ),
          CupertinoActionSheetAction(
            onPressed: () async {
              Navigator.pop(sheet);
              try {
                final msg = await state.actDownload(track);
                if (context.mounted) _toast(context, msg);
              } catch (_) {}
            },
            child: Text(state.downloads.isDownloaded(track.id)
                ? 'Downloaded ✓'
                : 'Download'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              state.actToggleLike(track);
            },
            child: Text(liked ? 'Unlike' : 'Like'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              state.actShare(track);
            },
            child: const Text('Share'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              state.startRadio(track);
            },
            child: const Text('Start radio'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              state.actOpenYouTube(track);
            },
            child: const Text('Open in YouTube'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: const Text('Cancel'),
        ),
      ),
    );
  } catch (_) {}
}

/// Playlist picker + inline create (row-menu entry point).
Future<void> showPlaylistPicker(
    BuildContext context, AppState state, YtTrack track) async {
  try {
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: const Text('Add to playlist'),
        actions: [
          CupertinoActionSheetAction(
            onPressed: () async {
              Navigator.pop(sheet);
              final name = await _askName(context);
              if (name == null) return;
              try {
                final p =
                    await state.library.createPlaylist(name);
                await state.library.addToPlaylist(p.id, track);
                if (context.mounted) _toast(context, 'Saved');
              } catch (_) {}
            },
            child: const Text('New playlist'),
          ),
          for (final p in state.library.playlists)
            CupertinoActionSheetAction(
              onPressed: () async {
                Navigator.pop(sheet);
                try {
                  await state.library.addToPlaylist(p.id, track);
                  if (context.mounted) _toast(context, 'Saved');
                } catch (_) {}
              },
              child: Text('${p.name} (${p.tracks.length})'),
            ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: const Text('Cancel'),
        ),
      ),
    );
  } catch (_) {}
}

Future<String?> _askName(BuildContext context) async {
  try {
    final c = TextEditingController();
    final name = await showCupertinoDialog<String>(
      context: context,
      builder: (d) => CupertinoAlertDialog(
        title: const Text('New playlist'),
        content: CupertinoTextField(
          controller: c,
          autofocus: true,
          placeholder: 'Playlist name',
        ),
        actions: [
          CupertinoDialogAction(
              onPressed: () => Navigator.pop(d),
              child: const Text('Cancel')),
          CupertinoDialogAction(
              isDefaultAction: true,
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
