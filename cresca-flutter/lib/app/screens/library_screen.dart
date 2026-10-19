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
        // U7/F per-section counts (engine-backed, re-synced every
        // frame — no stale counts after kill/relaunch).
        final dlCount = state.downloads.listAll().length;
        final dlSize = _fmtSize(state.downloads.totalBytes());
        // U7: U3 sliver pattern — no nested scrollables; the folder
        // grid is a real SliverGrid, the artists rail keeps its
        // bounded height inside a box adapter. Clearance rides a
        // trailing SliverPadding.
        return Scaffold(
          appBar: AppBar(title: const Text('Library')),
          body: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverToBoxAdapter(
                  child: StaggerEntrance(
                    child: Text(
                      '${state.library.liked.length} liked • '
                      '${state.library.recent.length} recent • '
                      '${state.library.playlists.length} playlists • '
                      '$dlCount downloads • $dlSize offline',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium,
                    ),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: _QuickTiles(
                    state: state, loggedIn: loggedIn),
              ),
              const SliverToBoxAdapter(
                  child: _SectionTitle('Folders')),
              SliverPadding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16),
                sliver: _FolderGrid(state: state),
              ),
              if (state.library.artists.isNotEmpty)
                SliverToBoxAdapter(
                  child: StaggerEntrance(
                    key: ValueKey(
                        'lib-artists-${state.library.artists.length}'),
                    index: 2,
                    child: _FavArtists(state: state),
                  ),
                ),
              SliverPadding(
                // Bottom chrome (mini player + pill) is app-shell;
                // lists scroll under the glass. Live measured
                // clearance (210 fallback pre-measure).
                padding: EdgeInsets.only(
                    bottom: BottomChromeScope.clearanceOf(
                        context)),
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
    // U7: real sliver — no shrinkWrap, no nested scroll physics.
    return SliverGrid.builder(
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
    // U7/F: missing art gets the gradient fallback immediately —
    // never a white flash, never a network fetch during scroll.
    final scheme = Theme.of(context).colorScheme;
    if (thumbs.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primaryContainer,
              scheme.surfaceContainerHighest,
            ],
          ),
        ),
        child: const Center(
            child: Icon(Icons.music_note, size: 40)),
      );
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
    // ~100px mem cache is plenty — never the full upload. Missing art
    // gets the gradient fallback (U7/F), never white.
    if (track.thumbUrl.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primaryContainer,
              scheme.surfaceContainerHighest,
            ],
          ),
        ),
      );
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

/// Storage size for the hero counts (U7/F): KB below 1 MB, else MB
/// with one decimal. Never throws — blank on failure.
String _fmtSize(int bytes) {
  try {
    if (bytes < 1024 * 1024) return '${bytes ~/ 1024} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  } catch (_) {
    return '';
  }
}



