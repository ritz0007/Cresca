// Profile sheet (L4): account, Spotify client-ID setup + connect /
// disconnect + status, engine Fast/Stable, appearance, motion,
// download location, clear cache, crash-log share, update rows,
// about. Update-check backend (Y4) follows; the row is present.

import 'package:flutter/material.dart';

import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'session_sheet.dart';

Future<void> openProfileSheet(BuildContext context) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scroll) =>
            ProfileSheet(scroll: scroll),
      ),
    );
  } catch (_) {}
}

class ProfileSheet extends StatefulWidget {
  final ScrollController scroll;
  const ProfileSheet({super.key, required this.scroll});

  @override
  State<ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<ProfileSheet> {
  final TextEditingController _clientId = TextEditingController();
  bool _busySpotify = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      try {
        _clientId.text = AppScope.of(context).spotify.clientId;
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _clientId.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final loggedIn = state.ytSession.isLoggedIn;
        final sp = state.spotify;
        return CustomScrollView(
          controller: widget.scroll,
          slivers: [
            SliverAppBar(
              pinned: true,
              title: const Text('Profile & settings'),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.fromLTRB(16, 0, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _H('Account'),
                    ListTile(
                      leading: const Icon(
                          Icons.account_circle_outlined),
                      title: Text(loggedIn
                          ? 'YouTube: signed in'
                          : 'YouTube: signed out'),
                      subtitle: Text(loggedIn
                          ? 'Session stays on this device'
                          : 'Sign in for full-quality playback'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => openSessionSheet(context),
                    ),
                    _H('Spotify'),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16),
                      child: TextField(
                        controller: _clientId,
                        decoration: const InputDecoration(
                          labelText: 'Client ID',
                          hintText:
                              'From developer.spotify.com dashboard',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (v) =>
                            sp.setClientId(v),
                      ),
                    ),
                    ListTile(
                      leading: const Icon(
                          Icons.music_note_outlined),
                      title: Text(sp.isConnected
                          ? 'Spotify: ${sp.displayName.isEmpty ? 'connected' : sp.displayName}'
                          : 'Spotify: not connected'),
                      subtitle:
                          const Text('Import + sync lands next'),
                      trailing: _busySpotify
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2))
                          : TextButton(
                              onPressed: () =>
                                  _spotifyTap(state),
                              child: Text(sp.isConnected
                                  ? 'Disconnect'
                                  : 'Connect'),
                            ),
                    ),
                    _H('Playback engine'),
                    SwitchListTile(
                      title: const Text('Fast engine'),
                      subtitle: const Text(
                          'InnerTube fast path. Off = extractor only (Stable).'),
                      value: state.engineFast,
                      onChanged: (v) =>
                          state.setEngineFast(v),
                    ),
                    _H('Appearance'),
                    RadioGroup<String>(
                      groupValue: state.appearance,
                      onChanged: (v) {
                        if (v != null) state.setAppearance(v);
                      },
                      child: Column(
                        children: [
                          for (final m in [
                            'system',
                            'light',
                            'dark'
                          ])
                            RadioListTile<String>(
                              title: Text(m[0].toUpperCase() +
                                  m.substring(1)),
                              value: m,
                            ),
                        ],
                      ),
                    ),
                    SwitchListTile(
                      title: const Text('Motion'),
                      subtitle: const Text(
                          'Tab drift, art slides, shimmer. Off = instant.'),
                      value: state.motionOn,
                      onChanged: (v) => state.setMotion(v),
                    ),
                    _H('Downloads'),
                    ListTile(
                      leading:
                          const Icon(Icons.folder_outlined),
                      title: const Text('Download location'),
                      trailing: DropdownButton<String>(
                        value: state.downloads.location,
                        items: const [
                          DropdownMenuItem(
                              value: 'app',
                              child: Text('In-app')),
                          DropdownMenuItem(
                              value: 'device',
                              child: Text('Device Music')),
                        ],
                        onChanged: (v) {
                          if (v != null) {
                            state.setDownloadLocation(v);
                          }
                        },
                      ),
                    ),
                    ListTile(
                      leading:
                          const Icon(Icons.cleaning_services_outlined),
                      title: const Text('Clear cache'),
                      subtitle: const Text(
                          'Network caches + stream bytes. Keeps library, downloads, sessions.'),
                      onTap: () async {
                        try {
                          final msg =
                              await state.clearCache();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(SnackBar(
                                    content: Text(msg)));
                          }
                        } catch (_) {}
                      },
                    ),
                    _H('Diagnostics'),
                    ListTile(
                      leading: const Icon(
                          Icons.bug_report_outlined),
                      title:
                          const Text('Share crash log'),
                      subtitle: const Text(
                          'Newest on-device log via system sheet.'),
                      onTap: () async {
                        try {
                          final ok = await state.crash
                              .shareNewest();
                          if (context.mounted && !ok) {
                            ScaffoldMessenger.of(context)
                                .showSnackBar(const SnackBar(
                                    content: Text(
                                        'No crash log yet')));
                          }
                        } catch (_) {}
                      },
                    ),
                    _H('Updates'),
                    Builder(builder: (ctx) {
                      final u = state.pendingUpdate;
                      final checking = state.updateChecking;
                      final prog = state.updateProgress;
                      final downloaded = state.updateDownloaded;
                      final subtitle = checking
                          ? 'Checking for updates…'
                          : u == null
                              ? 'You are on the latest release.'
                              : prog >= 0
                                  ? 'Downloading ${u.tag}… ${prog.round()}%'
                                  : downloaded
                                      ? '${u.tag} downloaded — ready to install.'
                                      : 'Cresca ${u.tag} available.';
                      return Column(
                        children: [
                          ListTile(
                            leading: const Icon(
                                Icons.system_update_outlined),
                            title: Text(u == null
                                ? 'Check for updates'
                                : 'Cresca ${u.tag} available'),
                            subtitle: prog >= 0
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(subtitle),
                                      const SizedBox(height: 6),
                                      LinearProgressIndicator(
                                          value: prog / 100),
                                    ],
                                  )
                                : Text(subtitle),
                            trailing: checking
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child:
                                        CircularProgressIndicator(
                                            strokeWidth: 2))
                                : IconButton(
                                    icon: const Icon(
                                        Icons.refresh_outlined),
                                    tooltip:
                                        'Check for updates',
                                    onPressed: () async {
                                      try {
                                        final msg = await state
                                            .checkForUpdates(
                                                manual: true);
                                        if (ctx.mounted) {
                                          ScaffoldMessenger.of(
                                                  ctx)
                                              .showSnackBar(
                                                  SnackBar(
                                                      content: Text(
                                                          msg)));
                                        }
                                      } catch (_) {}
                                    },
                                  ),
                          ),
                          if (u != null)
                            Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(
                                      16, 0, 16, 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: FilledButton.icon(
                                      style:
                                          spotifyPlayStyle(),
                                      icon: Icon(downloaded
                                          ? Icons
                                              .install_mobile_outlined
                                          : Icons
                                              .download_outlined),
                                      label: Text(downloaded
                                          ? 'Install'
                                          : prog >= 0
                                              ? 'Downloading…'
                                              : 'Download'),
                                      onPressed: prog >= 0
                                          ? null
                                          : () async {
                                              try {
                                                final msg = downloaded
                                                    ? await state
                                                        .installUpdate()
                                                    : await state
                                                        .downloadUpdate();
                                                if (ctx.mounted) {
                                                  ScaffoldMessenger.of(
                                                          ctx)
                                                      .showSnackBar(
                                                          SnackBar(
                                                              content: Text(
                                                                  msg)));
                                                }
                                              } catch (_) {}
                                            },
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: OutlinedButton(
                                      child: const Text(
                                          'Release notes'),
                                      onPressed: () => state
                                          .openReleasePage(),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    }),
                    _H('About'),
                    const ListTile(
                      title: Text('Cresca 1.5.0 (Flutter)'),
                      subtitle: Text(
                          'Your music, uninterrupted.'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _spotifyTap(AppState state) async {
    if (_busySpotify) return;
    setState(() => _busySpotify = true);
    try {
      if (state.spotify.isConnected) {
        await state.spotify.disconnect();
        if (mounted) setState(() {});
        return;
      }
      final id = _clientId.text.trim();
      if (id.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text(
                      'Enter your Spotify Client ID first')));
        }
        return;
      }
      await state.spotify.setClientId(id);
      final ok = await state.spotify.connect();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(ok
                ? 'Spotify connected'
                : 'Spotify connect failed — check the Client ID')));
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Spotify connect failed')));
      }
    } finally {
      if (mounted) setState(() => _busySpotify = false);
    }
  }
}

class _H extends StatelessWidget {
  final String text;
  const _H(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .primary)),
    );
  }
}
