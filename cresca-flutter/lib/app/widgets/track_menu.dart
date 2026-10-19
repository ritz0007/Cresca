// Per-row overflow menu, identical on every screen (M1): Play, Play
// next, Add to queue, Add to playlist (picker + inline create),
// Download, Like, Share sheet, Start radio, Open in YouTube,
// playback controls (Shuffle / Repeat — they live here since the
// full player keeps the reference 3-button transport), Video,
// Listen together (JAM party).
// iOS presentation: CupertinoActionSheet with a Cancel button.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/discovery.dart';
import '../../core/motion.dart' as motion;
import '../../core/queue.dart';
import '../../core/track.dart';
import '../state.dart';
import 'jam_sheet.dart';
import 'player_sheet.dart';

/// Primary sheet: Play / Queue / Add (+ Like/Download) with a
/// "More actions…" row that opens the overflow sheet. All 13 actions
/// stay reachable with the same callbacks as before.
Future<void> showTrackMenu(BuildContext context, AppState state,
    YtTrack track, List<YtTrack> contextQueue) async {
  try {
    final liked = state.library.isLiked(track.id);
    final motionOn = state.motionOn;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(track.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        message: Text(track.displayArtist(),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          _actPlay(
              sheet, context, state, track, contextQueue, motionOn, 0),
          _actPlayNext(sheet, context, state, track, motionOn, 1),
          _actAddToQueue(sheet, context, state, track, motionOn, 2),
          _actAddToPlaylist(
              sheet, context, state, track, motionOn, 3),
          _actDownload(sheet, context, state, track, motionOn, 4),
          _actLike(sheet, context, state, track, liked, motionOn, 5),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(sheet);
              _showTrackMenuOverflow(context, state, track);
            },
            child: _m(
                const Text('More actions…'), 6, motionOn),
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

/// Overflow sheet: the remaining actions with identical callbacks.
Future<void> _showTrackMenuOverflow(
    BuildContext context, AppState state, YtTrack track) async {
  try {
    final motionOn = state.motionOn;
    await showCupertinoModalPopup<void>(
      context: context,
      builder: (sheet) => CupertinoActionSheet(
        title: Text(track.title,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        message: Text(track.displayArtist(),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          _actShare(sheet, state, track, motionOn, 0),
          _actStartRadio(sheet, state, track, motionOn, 1),
          _actOpenYouTube(sheet, state, track, motionOn, 2),
          _actShuffle(sheet, context, state, motionOn, 3),
          _actRepeat(sheet, context, state, motionOn, 4),
          _actVideo(sheet, context, state, track, motionOn, 5),
          _actJam(sheet, context, motionOn, 6),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(sheet),
          child: const Text('Cancel'),
        ),
      ),
    );
  } catch (_) {}
}

CupertinoActionSheetAction _actPlay(
    BuildContext sheet,
    BuildContext context,
    AppState state,
    YtTrack track,
    List<YtTrack> contextQueue,
    bool motionOn,
    int index) {
  return CupertinoActionSheetAction(
    onPressed: () {
      Navigator.pop(sheet);
      state.actPlay(contextQueue,
          contextQueue.indexWhere((e) => e.id == track.id));
    },
    child: _m(const Text('Play'), index, motionOn),
  );
}

CupertinoActionSheetAction _actPlayNext(
    BuildContext sheet,
    BuildContext context,
    AppState state,
    YtTrack track,
    bool motionOn,
    int index) {
  return CupertinoActionSheetAction(
    onPressed: () {
      Navigator.pop(sheet);
      // No dupes: relocating an existing row is announced distinctly
      // so "Will play next" always means a fresh insert.
      try {
        final engine = state.controller.engine;
        if (engine.containsId(track.id)) {
          String? peekId;
          try {
            final peek = engine.peekIndexAhead(0);
            if (peek != null &&
                peek >= 0 &&
                peek < engine.items.length) {
              peekId = engine.items[peek].id;
            }
          } catch (_) {}
          if (peekId == track.id) {
            _toast(context, 'Already up next');
            return;
          }
          state.actPlayNext(track);
          _toast(context, 'Moved to play next');
          return;
        }
      } catch (_) {}
      state.actPlayNext(track);
      _toast(context, 'Will play next');
    },
    child: _m(const Text('Play next'), index, motionOn),
  );
}

CupertinoActionSheetAction _actAddToQueue(
    BuildContext sheet,
    BuildContext context,
    AppState state,
    YtTrack track,
    bool motionOn,
    int index) {
  return CupertinoActionSheetAction(
    onPressed: () {
      Navigator.pop(sheet);
      // No dupes: a second tap announces instead of duplicating.
      try {
        if (state.controller.engine.containsId(track.id)) {
          _toast(context, 'Already in queue');
          return;
        }
      } catch (_) {}
      state.actAddToQueue(track);
      _toast(context, 'Added to queue');
    },
    child: _m(const Text('Add to queue'), index, motionOn),
  );
}

CupertinoActionSheetAction _actAddToPlaylist(
    BuildContext sheet,
    BuildContext context,
    AppState state,
    YtTrack track,
    bool motionOn,
    int index) {
  return CupertinoActionSheetAction(
    onPressed: () {
      Navigator.pop(sheet);
      showPlaylistPicker(context, state, track);
    },
    child: _m(const Text('Add to playlist'), index, motionOn),
  );
}

CupertinoActionSheetAction _actDownload(
    BuildContext sheet,
    BuildContext context,
    AppState state,
    YtTrack track,
    bool motionOn,
    int index) {
  return CupertinoActionSheetAction(
    onPressed: () async {
      Navigator.pop(sheet);
      try {
        final msg = await state.actDownload(track);
        if (context.mounted) _toast(context, msg);
      } catch (_) {}
    },
    child: _m(
        Text(state.downloads.isDownloaded(track.id)
            ? 'Downloaded ✓'
            : 'Download'),
        index,
        motionOn),
  );
}

CupertinoActionSheetAction _actLike(
    BuildContext sheet,
    BuildContext context,
    AppState state,
    YtTrack track,
    bool liked,
    bool motionOn,
    int index) {
  return CupertinoActionSheetAction(
    onPressed: () async {
      Navigator.pop(sheet);
      if (!liked) {
        state.actToggleLike(track);
        return;
      }
      // U7: unlike is destructive — snapshot the slot pre-mutation
      // and offer 5 s Undo that restores it exactly (§6).
      final at =
          state.library.liked.indexWhere((e) => e.id == track.id);
      await state.actToggleLike(track);
      if (!context.mounted) return;
      try {
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text('Removed "${track.title}"'),
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                try {
                  await state.library.restoreLike(track,
                      index: at < 0 ? 0 : at);
                  try {
                    await state.controller.handler
                        .broadcastState();
                  } catch (_) {}
                } catch (_) {}
              },
            ),
          ),
        );
      } catch (_) {}
    },
    child: _m(Text(liked ? 'Unlike' : 'Like'), index, motionOn),
  );
}

CupertinoActionSheetAction _actShare(
    BuildContext sheet, AppState state, YtTrack track, bool motionOn,
    int index) {
  return CupertinoActionSheetAction(
    onPressed: () {
      Navigator.pop(sheet);
      state.actShare(track);
    },
    child: _m(const Text('Share'), index, motionOn),
  );
}

CupertinoActionSheetAction _actStartRadio(
    BuildContext sheet, AppState state, YtTrack track, bool motionOn,
    int index) {
  return CupertinoActionSheetAction(
    onPressed: () {
      Navigator.pop(sheet);
      state.startRadio(track);
    },
    child: _m(const Text('Start radio'), index, motionOn),
  );
}

CupertinoActionSheetAction _actOpenYouTube(
    BuildContext sheet, AppState state, YtTrack track, bool motionOn,
    int index) {
  return CupertinoActionSheetAction(
    onPressed: () {
      Navigator.pop(sheet);
      state.actOpenYouTube(track);
    },
    child: _m(const Text('Open in YouTube'), index, motionOn),
  );
}

CupertinoActionSheetAction _actShuffle(BuildContext sheet,
    BuildContext context, AppState state, bool motionOn, int index) {
  return CupertinoActionSheetAction(
    onPressed: () {
      try {
        final engine = state.controller.engine;
        final m = engine.cycleShuffle();
        if (m == shuffleSmart) {
          final liked =
              state.library.liked.map((e) => e.displayArtist()).toSet();
          final recent = state.library.recent
              .map((e) => e.displayArtist())
              .toList();
          engine.applyOrder(smartOrderFor(
            items: engine.snapshot(),
            currentIndex: engine.currentIndex,
            likedArtists: liked,
            recentArtists: recent,
          ));
        }
        state.controller.saveSessionNow();
        if (context.mounted) {
          _toast(context,
              'Shuffle: ${m == shuffleOff ? 'off' : m == shuffleSmart ? 'smart' : 'on'}');
        }
      } catch (_) {}
    },
    child: _m(
        Text(
            'Shuffle: ${state.controller.engine.shuffleMode == shuffleOff ? 'off' : state.controller.engine.shuffleMode == shuffleSmart ? 'smart' : 'on'}'),
        index,
        motionOn),
  );
}

CupertinoActionSheetAction _actRepeat(BuildContext sheet,
    BuildContext context, AppState state, bool motionOn, int index) {
  return CupertinoActionSheetAction(
    onPressed: () {
      try {
        final engine = state.controller.engine;
        engine.cycleRepeat();
        state.controller.saveSessionNow();
        if (context.mounted) {
          _toast(context,
              'Repeat: ${engine.repeatMode == repeatOff ? 'off' : engine.repeatMode == repeatAll ? 'all' : 'one'}');
        }
      } catch (_) {}
    },
    child: _m(
        Text(
            'Repeat: ${state.controller.engine.repeatMode == repeatOff ? 'off' : state.controller.engine.repeatMode == repeatAll ? 'all' : 'one'}'),
        index,
        motionOn),
  );
}

CupertinoActionSheetAction _actVideo(
    BuildContext sheet,
    BuildContext context,
    AppState state,
    YtTrack track,
    bool motionOn,
    int index) {
  return CupertinoActionSheetAction(
    onPressed: () async {
      Navigator.pop(sheet);
      try {
        await openPlayerSheet(context, video: true);
      } catch (_) {}
    },
    child: _m(const Text('Video'), index, motionOn),
  );
}

CupertinoActionSheetAction _actJam(BuildContext sheet,
    BuildContext context, bool motionOn, int index) {
  return CupertinoActionSheetAction(
    onPressed: () {
      Navigator.pop(sheet);
      openJamSheet(context);
    },
    child: _m(
        const Text('Listen together (JAM)'), index, motionOn),
  );
}

/// Playlist picker + inline create (row-menu entry point).
Future<void> showPlaylistPicker(
    BuildContext context, AppState state, YtTrack track) async {
  try {
    final motionOn = state.motionOn;
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
            child: _m(const Text('New playlist'), 0, motionOn),
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
              child: _m(
                  Text('${p.name} (${p.tracks.length})'),
                  state.library.playlists.indexOf(p) + 1,
                  motionOn),
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
    // One dialog idiom per platform (Cupertino on iOS, Material
    // elsewhere). Behavior identical.
    final String? name;
    if (_isIOS(context)) {
      name = await showCupertinoDialog<String>(
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
    } else {
      name = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('New playlist'),
          content: TextField(
            controller: c,
            autofocus: true,
            decoration: const InputDecoration(
                hintText: 'Playlist name'),
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
    }
    final t = (name ?? '').trim();
    return t.isEmpty ? null : t;
  } catch (_) {
    return null;
  }
}

bool _isIOS(BuildContext context) {
  try {
    return Theme.of(context).platform == TargetPlatform.iOS;
  } catch (_) {
    return false;
  }
}

void _toast(BuildContext context, String message) {
  try {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  } catch (_) {}
}

/// Menu entrance helper: one-shot fade + 8px rise per action, 180ms
/// with a 30ms stagger (capped so 14 actions don't crawl). Inner
/// press-scale (0.94 / 120ms) rides on passive pointer events so the
/// native Cupertino tap handling is untouched. Transform/opacity
/// only; static passthrough when motion is off.
Widget _m(Widget child, int index, bool motionOn) {
  return _MenuStagger(
    index: index,
    motionOn: motionOn,
    child: _MenuPress(motionOn: motionOn, child: child),
  );
}

class _MenuStagger extends StatefulWidget {
  final Widget child;
  final int index;
  final bool motionOn;
  const _MenuStagger(
      {required this.child, required this.index, required this.motionOn});

  @override
  State<_MenuStagger> createState() => _MenuStaggerState();
}

class _MenuStaggerState extends State<_MenuStagger> {
  bool _in = false;

  @override
  void initState() {
    super.initState();
    if (!widget.motionOn) {
      _in = true;
      return;
    }
    var delay = widget.index * 30;
    if (delay > 360) delay = 360;
    if (delay <= 0) {
      _in = true;
      return;
    }
    Future<void>.delayed(Duration(milliseconds: delay)).then((_) {
      if (mounted) setState(() => _in = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.motionOn) return widget.child;
    // Duration collapses via motionMs so the kill-switch snaps.
    final d = Duration(
        milliseconds: motion.motionMs(widget.motionOn, 180));
    return AnimatedOpacity(
      duration: d,
      opacity: _in ? 1 : 0,
      child: AnimatedContainer(
        duration: d,
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(0, _in ? 0 : 8, 0),
        transformAlignment: Alignment.center,
        // RepaintBoundary: the stagger ticks during sheet enter only;
        // keep it off the sheet's own layer.
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}

class _MenuPress extends StatefulWidget {
  final Widget child;
  final bool motionOn;
  const _MenuPress({required this.child, required this.motionOn});

  @override
  State<_MenuPress> createState() => _MenuPressState();
}

class _MenuPressState extends State<_MenuPress> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.motionOn) return widget.child;
    return Listener(
      onPointerDown: (_) => setState(() => _down = true),
      onPointerUp: (_) => setState(() => _down = false),
      onPointerCancel: (_) => setState(() => _down = false),
      child: AnimatedScale(
        scale: _down ? 0.94 : 1.0,
        duration: Duration(
            milliseconds: motion.motionMs(widget.motionOn, 120)),
        child: widget.child,
      ),
    );
  }
}
