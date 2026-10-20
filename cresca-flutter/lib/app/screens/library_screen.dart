// Library tab, L1–L3 slice: hero counts, quick tiles (Profile,
// YouTube session, Downloads), 2-col folders (Liked heart-gradient,
// Recent + user mosaics), favorite artists row, virtual Liked/Recent
// folders, new-playlist dialog. Full custom covers land with L6 polish.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import '../widgets/downloads_sheet.dart';
import '../widgets/profile_sheet.dart';
import '../widgets/session_sheet.dart';
import '../widgets/track_row.dart';
import 'playlist_screen.dart';
import 'see_all.dart';

class LibraryScreen extends StatelessWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final loggedIn = state.ytSession.isLoggedIn;
        return Scaffold(
          appBar: AppBar(title: const Text('Library')),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: EdgeInsets.only(
                      // Bottom chrome (mini player + pill) is app-shell;
                      // lists scroll under the glass. Live measured
                      // clearance (estimator fallback pre-measure).
                      bottom:
                          BottomChromeScope.clearanceOf(context)),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: StaggerEntrance(
                        child: Text(
                          '${state.library.liked.length} liked • '
                          '${state.library.recent.length} recent • '
                          '${state.library.playlists.length} playlists',
                          style: Theme.of(context)
                              .textTheme
                              .titleMedium,
                        ),
                      ),
                    ),
                    _QuickTiles(state: state, loggedIn: loggedIn),
                    const _SectionTitle('Folders'),
                    StaggerEntrance(
                      key: ValueKey(
                          'lib-folders-${state.library.playlists.length}'),
                      index: 1,
                      child: _FolderGrid(state: state),
                    ),
                    if (state.library.artists.isNotEmpty)
                      StaggerEntrance(
                        key: ValueKey(
                            'lib-artists-${state.library.artists.length}'),
                        index: 2,
                        child: _FavArtists(state: state),
                      ),
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

class _QuickTiles extends StatelessWidget {
  final AppState state;
  final bool loggedIn;
  const _QuickTiles({required this.state, required this.loggedIn});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: StaggerEntrance(
              child: _Tile(
                icon: Icons.person_outline,
                label: 'Profile',
                onTap: () => openProfileSheet(context),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: StaggerEntrance(
              index: 1,
              child: _Tile(
                icon: Icons.account_circle_outlined,
                label: loggedIn ? 'Signed in' : 'Sign in',
                onTap: () => openSessionSheet(context),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: StaggerEntrance(
              index: 2,
              child: _Tile(
                icon: Icons.download_outlined,
                label:
                    'Downloads (${state.downloads.listAll().length})',
                onTap: () => openDownloadsSheet(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Tile(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    // Top user-visible bug was white-on-light-grey here: derive the
    // glyph + label from the actual tile bg, never hardcoded.
    final tileBg =
        Theme.of(context).colorScheme.surfaceContainerHighest;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: tileBg,
        ),
        child: Column(
          children: [
            Icon(icon, color: textOn(tileBg)),
            const SizedBox(height: 4),
            AdaptiveText(
                data: label,
                background: tileBg,
                secondary: true,
                style:
                    Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text,
          style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

class _FolderGrid extends StatelessWidget {
  final AppState state;
  const _FolderGrid({required this.state});

  @override
  Widget build(BuildContext context) {
    final folders = <_Folder>[
      _Folder(
        title: 'Liked',
        count: state.library.liked.length,
        tracks: state.library.liked,
        heart: true,
        onOpen: () => openSeeAllStatic(
            context, 'Liked', state.library.liked, ''),
      ),
      _Folder(
        title: 'Recent',
        count: state.library.recent.length,
        tracks: state.library.recent,
        onOpen: () => openSeeAllStatic(
            context, 'Recent', state.library.recent, ''),
      ),
      for (final p in state.library.playlists)
        _Folder(
          title: p.name,
          count: p.tracks.length,
          tracks: p.tracks,
          playlistId: p.id,
          onOpen: () => openPlaylistScreen(context, p.id),
        ),
    ];
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate:
          const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.85,
      ),
      itemCount: folders.length + 1,
      itemBuilder: (_, i) {
        if (i >= folders.length) {
          return StaggerEntrance(
            index: i,
            child: GestureDetector(
              onTap: () async {
                try {
                  final name = await _askName(context);
                  if (name == null) return;
                  await state.library.createPlaylist(name);
                } catch (_) {}
              },
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                      color:
                          Theme.of(context).colorScheme.outlineVariant),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add,
                        size: 32,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface),
                    AdaptiveText(
                        data: 'New playlist',
                        background: Theme.of(context)
                            .colorScheme
                            .surface),
                  ],
                ),
              ),
            ),
          );
        }
        return StaggerEntrance(
          index: i,
          child: _FolderCard(folder: folders[i]),
        );
      },
    );
  }
}

class _Folder {
  final String title;
  final int count;
  final List<YtTrack> tracks;
  final bool heart;
  final String? playlistId;
  final VoidCallback onOpen;
  _Folder({
    required this.title,
    required this.count,
    required this.tracks,
    this.heart = false,
    this.playlistId,
    required this.onOpen,
  });
}

class _FolderCard extends StatelessWidget {
  final _Folder folder;
  const _FolderCard({required this.folder});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Folder titles/counts sit on the page surface: derive from it.
    final pageBg = scheme.surface;
    // RepaintBoundary: folder cards hold mosaic image grids — keep
    // each card out of the list's repaint scope while scrolling.
    return RepaintBoundary(
      child: GestureDetector(
      onTap: folder.onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                // Neutral Liked tile (green is reserved for actions):
                // same surface treatment as Home, heart in primary.
                color: scheme.surfaceContainerHighest,
              ),
              clipBehavior: Clip.hardEdge,
              child: folder.heart
                  ? Center(
                      child: Icon(Icons.favorite,
                          size: 48,
                          color: scheme.primary))
                  : MosaicArt(tracks: folder.tracks),
            ),
          ),
          const SizedBox(height: 4),
          AdaptiveText(
              data: folder.title,
              background: pageBg,
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
          AdaptiveText(
              data: '${folder.count} songs',
              background: pageBg,
              secondary: true,
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
      ),
    );
  }
}

/// 2×2 artwork mosaic (+custom cover lands with L6 polish).
class MosaicArt extends StatelessWidget {
  final List<YtTrack> tracks;
  const MosaicArt({super.key, required this.tracks});

  @override
  Widget build(BuildContext context) {
    final thumbs = tracks
        .where((t) => t.thumbUrl.isNotEmpty)
        .take(4)
        .toList();
    if (thumbs.isEmpty) {
      return const Center(child: Icon(Icons.music_note, size: 40));
    }
    if (thumbs.length == 1) {
      return _MosaicTile(track: thumbs[0]);
    }
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate:
          const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2),
      itemCount: thumbs.length,
      itemBuilder: (_, i) => _MosaicTile(track: thumbs[i]),
    );
  }
}

class _MosaicTile extends StatelessWidget {
  final YtTrack track;
  const _MosaicTile({required this.track});

  @override
  Widget build(BuildContext context) {
    // Tight mosaic decode: tiles are ~1/4 of the folder card, so a
    // ~100px mem cache is plenty — never the full upload.
    if (track.thumbUrl.isEmpty) {
      return Container(color: Theme.of(context).colorScheme.primaryContainer);
    }
    return CachedNetworkImage(
      imageUrl: track.thumbUrl,
      fit: BoxFit.cover,
      memCacheWidth: 112,
      memCacheHeight: 112,
      maxWidthDiskCache: 224,
      maxHeightDiskCache: 224,
      fadeInDuration: const Duration(milliseconds: 150),
      fadeOutDuration: const Duration(milliseconds: 1),
      errorWidget: (_, _, _) => Container(
          color: Theme.of(context).colorScheme.primaryContainer),
    );
  }
}

class _FavArtists extends StatelessWidget {
  final AppState state;
  const _FavArtists({required this.state});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionTitle('Favorite artists'),
        SizedBox(
          // Room for 2-line names at 200% text scale.
          height: 112,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: state.library.artists.length,
            itemBuilder: (_, i) {
              final a = state.library.artists[i];
              return StaggerEntrance(
                index: i,
                child: Container(
                  width: 72,
                  margin: const EdgeInsets.only(right: 8),
                  child: RepaintBoundary(
                    child: Column(
                    children: [
                      // Tight 48px avatar decode (~144px mem cache),
                      // not the full upload.
                      SizedBox(
                        width: 48,
                        height: 48,
                        child: ClipOval(
                          child: a.thumbUrl.isEmpty
                              ? Container(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                  child: const Icon(Icons.person),
                                )
                              : CachedNetworkImage(
                                  imageUrl: a.thumbUrl,
                                  width: 48,
                                  height: 48,
                                  fit: BoxFit.cover,
                                  memCacheWidth: 144,
                                  memCacheHeight: 144,
                                  maxWidthDiskCache: 144,
                                  maxHeightDiskCache: 144,
                                  fadeInDuration: const Duration(
                                      milliseconds: 150),
                                  fadeOutDuration:
                                      const Duration(milliseconds: 1),
                                  errorWidget: (_, _, _) =>
                                      const Icon(Icons.person),
                                ),
                        ),
                      ),
                      Text(a.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant)),
                    ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

Future<String?> _askName(BuildContext context) async {
  try {
    final c = TextEditingController();
    // One dialog idiom per platform: Cupertino on iOS, Material
    // elsewhere. Behavior identical (trimmed name or null).
    if (_isIOS(context)) {
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
    }
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

bool _isIOS(BuildContext context) {
  try {
    return Theme.of(context).platform == TargetPlatform.iOS;
  } catch (_) {
    return false;
  }
}



