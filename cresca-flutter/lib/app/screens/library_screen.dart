// Library tab, G1 slice: hero counts + YouTube session tile + liked /
// recent shortcuts. Full folders/mosaics/playlists UI lands with L1–L3;
// this screen owns the session entry point the login flow needs.

import 'package:flutter/material.dart';

import '../app.dart';
import '../widgets/session_sheet.dart';
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
          body: ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '${state.library.liked.length} liked • '
                  '${state.library.recent.length} recent • '
                  '${state.library.playlists.length} playlists',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: Text(loggedIn
                    ? 'YouTube session (signed in)'
                    : 'YouTube session (signed out)'),
                subtitle: Text(loggedIn
                    ? 'Tap to manage or log out'
                    : 'Sign in for full-quality playback'),
                trailing: loggedIn
                    ? const Icon(Icons.check_circle,
                        color: Colors.green)
                    : const Icon(Icons.chevron_right),
                onTap: () => openSessionSheet(context),
              ),
              ListTile(
                leading: const Icon(Icons.favorite),
                title: const Text('Liked'),
                subtitle: Text(
                    '${state.library.liked.length} songs'),
                onTap: () => openSeeAllStatic(
                    context, 'Liked', state.library.liked, ''),
              ),
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Recent'),
                subtitle: Text(
                    '${state.library.recent.length} songs'),
                onTap: () => openSeeAllStatic(
                    context, 'Recent', state.library.recent, ''),
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: const Text('New playlist'),
                onTap: () async {
                  try {
                    final name = await _askName(context);
                    if (name == null) return;
                    await state.library.createPlaylist(name);
                  } catch (_) {}
                },
              ),
            ],
          ),
        );
      },
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
