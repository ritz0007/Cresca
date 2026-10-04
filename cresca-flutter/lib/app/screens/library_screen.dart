// Library tab, L1–L3 slice: hero counts, quick tiles (Profile,
// YouTube session, Downloads), 2-col folders (Liked heart-gradient,
// Recent + user mosaics), favorite artists row, virtual Liked/Recent
// folders, new-playlist dialog. Full custom covers land with L6 polish.

import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../app.dart';
import '../state.dart';
import '../widgets/downloads_sheet.dart';
import '../widgets/mini_player.dart';
import '../widgets/session_sheet.dart';
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
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '${state.library.liked.length} liked • '
                        '${state.library.recent.length} recent • '
                        '${state.library.playlists.length} playlists',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium,
                      ),
                    ),
                    _QuickTiles(state: state, loggedIn: loggedIn),
                    const _SectionTitle('Folders'),
                    _FolderGrid(state: state),
                    if (state.library.artists.isNotEmpty)
                      _FavArtists(state: state),
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
            child: _Tile(
              icon: Icons.person_outline,
              label: 'Profile',
              onTap: () => _toast(context,
                  'Full profile arrives with settings in Phase 3'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Tile(
              icon: Icons.account_circle_outlined,
              label: loggedIn ? 'Signed in' : 'Sign in',
              onTap: () => openSessionSheet(context),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Tile(
              icon: Icons.download_outlined,
              label:
                  'Downloads (${state.downloads.listAll().length})',
              onTap: () => openDownloadsSheet(context),
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
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
        child: Column(
          children: [
            Icon(icon),
            const SizedBox(height: 4),
            Text(label,
                style: Theme.of(context).textTheme.bodySmall),
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
          return GestureDetector(
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
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add, size: 32),
                  Text('New playlist'),
                ],
              ),
            ),
          );
        }
        return _FolderCard(folder: folders[i]);
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
    return GestureDetector(
      onTap: folder.onOpen,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                gradient: folder.heart
                    ? const LinearGradient(colors: [
                        Color(0xFF1DB954),
                        Color(0xFF0D5C2B)
                      ])
                    : null,
                color: folder.heart
                    ? null
                    : Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
              ),
              clipBehavior: Clip.hardEdge,
              child: folder.heart
                  ? const Center(
                      child: Icon(Icons.favorite,
                          size: 48, color: Colors.white))
                  : MosaicArt(tracks: folder.tracks),
            ),
          ),
          const SizedBox(height: 4),
          Text(folder.title,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          Text('${folder.count} songs',
              style: Theme.of(context).textTheme.bodySmall),
        ],
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
    if (track.thumbUrl.isEmpty) {
      return Container(color: Theme.of(context).colorScheme.primaryContainer);
    }
    return Image.network(track.thumbUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
            color: Theme.of(context)
                .colorScheme
                .primaryContainer));
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
          height: 92,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: state.library.artists.length,
            itemBuilder: (_, i) {
              final a = state.library.artists[i];
              return Container(
                width: 72,
                margin: const EdgeInsets.only(right: 8),
                child: Column(
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundImage: a.thumbUrl.isEmpty
                          ? null
                          : NetworkImage(a.thumbUrl),
                      child: a.thumbUrl.isEmpty
                          ? const Icon(Icons.person)
                          : null,
                    ),
                    Text(a.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            Theme.of(context).textTheme.bodySmall),
                  ],
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
