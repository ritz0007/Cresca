// Playlist screen (P16): mosaic cover, Play/Shuffle/Edit/Delete,
// removable rows, Suggested from playlist artists. Custom cover picker
// lands with L6 polish (needs an image-picker dep).

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../core/track.dart';
import '../app.dart';
import '../library.dart';
import '../state.dart';
import '../widgets/cresca_toast.dart';
import '../widgets/track_row.dart';
import 'library_screen.dart' show MosaicArt;

Future<void> openPlaylistScreen(
    BuildContext context, String playlistId) async {
  try {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlaylistScreen(playlistId: playlistId)));
  } catch (e, st) {
    await logUserFailure(context, 'open playlist failed', e, st);
    if (context.mounted) {
      await showCrescaToast(
          context, 'Could not open playlist — Retry');
    }
  }
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
      // silent: lookup miss, empty state renders below
      return null;
    }
  }

  Future<void> _suggest(AppState state, UserPlaylist p) async {
    if (_suggesting) return;
    setState(() => _suggesting = true);
    try {
      // Suggested from playlist artists (native: computed at open),
      // enriched with the related graph + repository new-release
      // scoring. Every source is defensive with fallback to plain
      // artist search; the merged list is songs-only, vibe-ranked
      // around the playlist seed, and excludes playlist tracks.
      final artists = <String>{};
      for (final t in p.tracks.take(10)) {
        final a = t.displayArtist();
        if (a != 'Unknown Artist') artists.add(a);
        if (artists.length >= 3) break;
      }
      final pool = <YtTrack>[];
      final relatedIds = <String>{};
      // Related graph from the first few playlist tracks.
      for (final t in p.tracks.take(3)) {
        try {
          final rel =
              await state.repo.relatedTracks(t.watchUrl, max: 6);
          for (final h in rel) {
            relatedIds.add(h.id);
            if (pool.length >= 24) break;
            if (pool.any((e) => e.id == h.id)) continue;
            pool.add(h);
          }
        } catch (_) {
          // silent: one related leg failed, next track tried
        }
        if (pool.length >= 24) break;
      }
      // Repository new-release scoring (round-robin per artist).
      if (artists.isNotEmpty) {
        try {
          final fresh =
              await state.repo.newReleases(artists.toList(), max: 12);
          for (final h in fresh) {
            if (pool.length >= 30) break;
            if (pool.any((e) => e.id == h.id)) continue;
            pool.add(h);
          }
        } catch (_) {
          // silent: new-release leg failed, artist search feeds below
        }
      }
      // Artist-search fallback (always runs; feeds thin graphs too).
      for (final a in artists) {
        try {
          final hits = await state.repo.searchMusic('$a songs', max: 6);
          for (final h in hits) {
            if (pool.length >= 36) break;
            if (pool.any((e) => e.id == h.id)) continue;
            pool.add(h);
          }
        } catch (_) {
          // silent: one artist search failed, next artist tried
        }
      }
      final inPlaylist = p.tracks.map((e) => e.id).toSet();
      var clean = songsOnlyTracks(pool)
          .where((t) => !inPlaylist.contains(t.id))
          .toList();
      try {
        if (p.tracks.isNotEmpty && clean.length > 1) {
          clean = rankByVibeDefensive(
            p.tracks.first,
            clean,
            relatedIds: relatedIds,
          );
        }
      } catch (_) {
        // silent: rank probe, unranked pool order stands
      }
      if (mounted) setState(() => _suggested = clean.take(12).toList());
    } catch (_) {
      // silent: suggestion build, section hides on empty pool
    }
    if (mounted) setState(() => _suggesting = false);
  }

  Future<void> _rename(
      BuildContext context, AppState state, UserPlaylist p) async {
    try {
      final c = TextEditingController(text: p.name);
      // One dialog idiom per platform (Cupertino on iOS, Material
      // elsewhere). Behavior identical.
      final String? name;
      if (_isIOS(context)) {
        name = await showCupertinoDialog<String>(
          context: context,
          builder: (d) => CupertinoAlertDialog(
            title: const Text('Rename playlist'),
            content: CupertinoTextField(
                controller: c,
                autofocus: true,
                placeholder: 'Playlist name'),
            actions: [
              CupertinoDialogAction(
                  onPressed: () => Navigator.pop(d),
                  child: const Text('Cancel')),
              CupertinoDialogAction(
                  isDefaultAction: true,
                  onPressed: () => Navigator.pop(d, c.text),
                  child: const Text('Save')),
            ],
          ),
        );
      } else {
        name = await showDialog<String>(
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
      }
      if (name == null) return;
      await state.library.renamePlaylist(p.id, name);
      if (mounted) setState(() {});
    } catch (e, st) {
      await state.crash.log('playlist rename failed', e, st);
      if (context.mounted) {
        await showCrescaToast(context, "Couldn't rename — Retry");
      }
    }
  }

  Future<void> _delete(
      BuildContext context, AppState state, UserPlaylist p) async {
    try {
      // One dialog idiom per platform. Behavior identical.
      final bool? yes;
      if (_isIOS(context)) {
        yes = await showCupertinoDialog<bool>(
          context: context,
          builder: (d) => CupertinoAlertDialog(
            title: Text('Delete "${p.name}"?'),
            actions: [
              CupertinoDialogAction(
                  onPressed: () => Navigator.pop(d, false),
                  child: const Text('Cancel')),
              CupertinoDialogAction(
                  isDestructiveAction: true,
                  onPressed: () => Navigator.pop(d, true),
                  child: const Text('Delete')),
            ],
          ),
        );
      } else {
        yes = await showDialog<bool>(
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
      }
      if (yes != true) return;
      await state.library.deletePlaylist(p.id);
      if (mounted) Navigator.pop(context);
    } catch (e, st) {
      await state.crash.log('playlist delete failed', e, st);
      if (context.mounted) {
        await showCrescaToast(context, "Couldn't delete — Retry");
      }
    }
  }

  bool _isIOS(BuildContext context) {
    try {
      return Theme.of(context).platform == TargetPlatform.iOS;
    } catch (_) {
      // silent: platform probe, Material fallback is correct default
      return false;
    }
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
                  // Bottom chrome is app-shell; live measured clearance
                  // (210 fallback) so tail rows never slide under it.
                  padding: EdgeInsets.only(
                      bottom:
                          BottomChromeScope.clearanceOf(context)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          AnimatedSwitcher(
                            duration: Duration(
                                milliseconds:
                                    state.motionMs(220)),
                            transitionBuilder:
                                (child, anim) =>
                                    FadeTransition(
                                        opacity: anim,
                                        child: child),
                            child: SizedBox(
                              key: ValueKey(
                                  'pl-art-${p.tracks.length}-${p.tracks.isEmpty ? 'empty' : p.tracks.first.id}'),
                              width: 120,
                              height: 120,
                              child: ClipRRect(
                                borderRadius:
                                    BorderRadius.circular(12),
                                child:
                                    MosaicArt(tracks: p.tracks),
                              ),
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
                                        .bodySmall
                                        ?.copyWith(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .onSurfaceVariant)),
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
                                          : () async {
                                              if (!await state.actPlay(
                                                  p.tracks, 0)) {
                                                if (context.mounted) {
                                                  await showCrescaToast(
                                                      context,
                                                      'Could not play — Retry');
                                                }
                                              }
                                            },
                                    ),
                                    const SizedBox(width: 8),
                                    OutlinedButton.icon(
                                      icon: const Icon(
                                          Icons.shuffle),
                                      label: const Text(
                                          'Shuffle'),
                                      onPressed: p.tracks.isEmpty
                                          ? null
                                          : () async {
                                              final order =
                                                  List<int>.generate(
                                                      p.tracks.length,
                                                      (i) => i)
                                                ..shuffle();
                                              if (!await state.actPlay(
                                                  [
                                                    for (final i
                                                        in order)
                                                      p.tracks[i]
                                                  ],
                                                  0)) {
                                                if (context.mounted) {
                                                  await showCrescaToast(
                                                      context,
                                                      'Could not play — Retry');
                                                }
                                              }
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
                          // Capture for Undo before mutating.
                          final removed = p.tracks[i];
                          final at = i;
                          try {
                            await state.library.removeFromPlaylist(
                                p.id, removed.id);
                          } catch (e, st) {
                            await state.crash.log(
                                'playlist remove failed', e, st);
                            if (context.mounted) {
                              await showCrescaToast(context,
                                  "Couldn't remove — Retry");
                            }
                            return;
                          }
                          if (!context.mounted) return;
                          try {
                            SemanticsService.sendAnnouncement(
                                View.of(context),
                                'Removed ${removed.title}. Undo available.',
                                TextDirection.ltr);
                          } catch (_) {
                            // silent: screen-reader announcement only
                          }
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context)
                              .showSnackBar(
                            SnackBar(
                              content: Text(
                                  'Removed ${removed.title}'),
                              action: SnackBarAction(
                                label: 'Undo',
                                onPressed: () async {
                                  try {
                                    // Re-add through the library so the
                                    // restore is persisted, then move it
                                    // back to its old slot in-memory for
                                    // identical order (a later library
                                    // write persists the order too).
                                    await state.library
                                        .addToPlaylist(
                                            p.id, removed);
                                    try {
                                      p.tracks.removeWhere((e) =>
                                          e.id ==
                                          removed.id);
                                      p.tracks.insert(
                                          at.clamp(0,
                                              p.tracks.length),
                                          removed);
                                    } catch (_) {
                                      // silent: order fix-up only,
                                      // restore already persisted
                                    }
                                  } catch (e, st) {
                                    await state.crash.log(
                                        'playlist undo failed',
                                        e,
                                        st);
                                    if (context.mounted) {
                                      await showCrescaToast(
                                          context,
                                          'Could not restore — Retry');
                                    }
                                  }
                                  if (mounted) {
                                    setState(() {});
                                  }
                                },
                              ),
                            ),
                          );
                        },
                        child: StaggerEntrance(
                          index: i,
                          child: TrackRow(
                            track: p.tracks[i],
                            contextQueue: p.tracks,
                            index: i,
                            origin: 'Playlist',
                          ),
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
                        child: StaggerEntrance(
                          child: Text('Suggested',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium),
                        ),
                      ),
                      for (var i = 0;
                          i < _suggested.length;
                          i++)
                        StaggerEntrance(
                          index: i,
                          child: TrackRow(
                            track: _suggested[i],
                            contextQueue: _suggested,
                            index: i,
                            origin: 'Playlist',
                          ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
