// Profile sheet (L4): account, Spotify client-ID setup + connect /
// disconnect + status, engine Fast/Stable, appearance, motion,
// download location, clear cache, crash-log share, update rows,
// about. Update-check backend (Y4) follows; the row is present.

import 'package:flutter/material.dart';

import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'cresca_toast.dart';
import 'session_sheet.dart';

Future<void> openProfileSheet(BuildContext context) async {
  try {
    bool motionOn = true;
    try {
      motionOn = AppScope.of(context).motionOn;
    } catch (_) {
      // silent: motion probe, animation default (on) is safe
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scroll) => GlassSheetSurface(
          motionOn: motionOn,
          child: ProfileSheet(scroll: scroll),
        ),
      ),
    );
  } catch (e, st) {
    await logUserFailure(context, 'open settings failed', e, st);
    await showCrescaToast(context, 'Could not open settings — Retry');
  }
}

class ProfileSheet extends StatefulWidget {
  final ScrollController scroll;
  const ProfileSheet({super.key, required this.scroll});

  @override
  State<ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<ProfileSheet> {
  bool _busySpotify = false;

  @override
  void dispose() {
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
        // Pinned header needs an opaque backing: the sheet glass is
        // translucent at the top, so scrolled rows would ghost through
        // the title. surfaceContainer at 0.94 reads as the same
        // material fading to opaque.
        final headerBg = Theme.of(context)
            .colorScheme
            .surfaceContainer
            .withValues(alpha: 0.94);
        final dark =
            Theme.of(context).brightness == Brightness.dark;
        return CustomScrollView(
          controller: widget.scroll,
          slivers: [
            const SliverToBoxAdapter(
              child: SheetGrabHandle(),
            ),
            SliverAppBar(
              pinned: true,
              backgroundColor: headerBg,
              automaticallyImplyLeading: false,
              title: Text('Profile & settings',
                  style:
                      TextStyle(color: glassText(dark))),
              actions: [
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close profile',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
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
                    ListTile(
                      leading: const Icon(
                          Icons.music_note_outlined),
                      title: Text(sp.isConnected
                          ? 'Spotify: ${sp.displayName.isEmpty ? 'connected' : sp.displayName}'
                          : 'Spotify: not connected'),
                      subtitle:
                          const Text('Import + sync lands next'),
                      trailing: _busySpotify
                          // Delayed fade-in (300 ms): no flicker on
                          // fast connects; slot pre-sized, no jump.
                          ? DelayedSpinner(
                              motionOn: state.motionOn)
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
                            // Selected appearance row tints smoothly
                            // (AnimatedContainer, 180 ms).
                            AnimatedContainer(
                              duration: Duration(
                                  milliseconds:
                                      state.motionMs(
                                          180)),
                              curve: Curves.easeOut,
                              decoration: BoxDecoration(
                                color: state.appearance ==
                                        m
                                    ? Theme.of(context)
                                        .colorScheme
                                        .primary
                                        .withValues(
                                            alpha:
                                                0.12)
                                    : Colors
                                        .transparent,
                                borderRadius:
                                    BorderRadius
                                        .circular(12),
                              ),
                              child:
                                  RadioListTile<String>(
                                title: Text(m[0]
                                        .toUpperCase() +
                                    m.substring(1)),
                                value: m,
                              ),
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
                    SwitchListTile(
                      title: const Text('Live Updates'),
                      subtitle: const Text(
                          'Progress chip on Android 16+. Needs notification permission.'),
                      value: state.liveEnabled,
                      onChanged: (v) =>
                          state.setLiveEnabled(v),
                    ),
                    ListTile(
                      leading: const Icon(
                          Icons.notifications_outlined),
                      title:
                          const Text('Notification settings'),
                      subtitle: const Text(
                          'Enable notifications + Live Updates here.'),
                      trailing:
                          const Icon(Icons.chevron_right),
                      onTap: () async {
                        try {
                          await state.live
                              .openNotificationSettings();
                        } catch (e, st) {
                          await state.crash.log(
                              'notification settings failed',
                              e,
                              st);
                        }
                      },
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
                            await showCrescaToast(
                                context, msg);
                          }
                        } catch (e, st) {
                          await state.crash.log(
                              'clear cache failed', e, st);
                          if (context.mounted) {
                            await showCrescaToast(context,
                                'Could not clear cache — Retry');
                          }
                        }
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
                            await showCrescaToast(context,
                                'No crash log yet');
                          }
                        } catch (e, st) {
                          await state.crash.log(
                              'share crash log failed',
                              e,
                              st);
                          if (context.mounted) {
                            await showCrescaToast(context,
                                'No crash log yet');
                          }
                        }
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
                              ? (state.updateCheckFailed
                                  ? 'Update check failed — Retry'
                                  : 'You are on the latest release.')
                              : prog >= 0
                                  ? 'Downloading ${u.tag}… ${prog.round()}%'
                                  : downloaded
                                      ? '${u.tag} downloaded — ready to install.'
                                      : 'Cresca Music ${u.tag} available.';
                      return Column(
                        children: [
                          ListTile(
                            leading: const Icon(
                                Icons.system_update_outlined),
                            title: Text(u == null
                                ? 'Check for updates'
                                : 'Cresca Music ${u.tag} available'),
                            subtitle: prog >= 0
                                ? Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      // Status line crossfades on
                                      // state flips (150 ms,
                                      // motion-gated).
                                      AnimatedSwitcher(
                                        duration: Duration(
                                            milliseconds:
                                                state.motionMs(
                                                    150)),
                                        switchInCurve:
                                            Curves.easeOut,
                                        switchOutCurve:
                                            Curves.easeOut,
                                        child: Text(
                                          subtitle,
                                          key: ValueKey(
                                              subtitle),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      // Download bar sweeps smoothly
                                      // toward each value (tween, no
                                      // jump) with an opacity-only
                                      // shimmer while active.
                                      PulseOpacity(
                                        motionOn:
                                            state.motionOn,
                                        child:
                                            RepaintBoundary(
                                          child:
                                              _UpdateProgress(
                                            value:
                                                prog / 100,
                                            ms: state.motionMs(
                                                180),
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                // Status line crossfades on state flips
                                // (150 ms, motion-gated).
                                : AnimatedSwitcher(
                                    duration: Duration(
                                        milliseconds:
                                            state.motionMs(
                                                150)),
                                    switchInCurve:
                                        Curves.easeOut,
                                    switchOutCurve:
                                        Curves.easeOut,
                                    child: Text(
                                      subtitle,
                                      key:
                                          ValueKey(subtitle),
                                    ),
                                  ),
                            trailing: checking
                                // Delayed fade-in (300 ms); slot
                                // pre-sized, no jump.
                                ? DelayedSpinner(
                                    motionOn: state.motionOn)
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
                                                      content: Semantics(liveRegion: true, child: Text(
                                                          msg))));
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
                                      // Action label crossfades on
                                      // state flips (180 ms).
                                      label: AnimatedSwitcher(
                                        duration: Duration(
                                            milliseconds:
                                                state.motionMs(
                                                    180)),
                                        switchInCurve:
                                            Curves.easeOut,
                                        switchOutCurve:
                                            Curves.easeOut,
                                        child: Text(
                                          key: ValueKey(
                                              downloaded
                                                  ? 'install'
                                                  : prog >=
                                                          0
                                                      ? 'busy'
                                                      : 'dl'),
                                          downloaded
                                              ? 'Install'
                                              : prog >= 0
                                                  ? 'Downloading…'
                                                  : 'Download',
                                        ),
                                      ),
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
                                                              content: Semantics(liveRegion: true, child: Text(
                                                                  msg))));
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
                      title: Text('Cresca Music 2.0.0 (Flutter)'),
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
      // No Client ID field: the ID is bundled at build time
      // (--dart-define=SPOTIFY_CLIENT_ID) and must never ship in git.
      if (!state.spotify.hasClientId) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Semantics(liveRegion: true, child: Text(
                      'Spotify is not configured in this build'))));
        }
        return;
      }
      final ok = await state.spotify.connect();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Semantics(liveRegion: true, child: Text(ok
                ? 'Spotify connected'
                : 'Spotify connect failed — try again'))));
        setState(() {});
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Semantics(liveRegion: true, child: Text('Spotify connect failed'))));
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

/// Update download bar: tweens toward each new value (retargeted
/// begin, no sweep-from-zero), opacity shimmer applied by the caller.
class _UpdateProgress extends StatefulWidget {
  final double value;
  final int ms;
  const _UpdateProgress(
      {required this.value, required this.ms});

  @override
  State<_UpdateProgress> createState() =>
      _UpdateProgressState();
}

class _UpdateProgressState extends State<_UpdateProgress> {
  double _prev = 0;

  @override
  void didUpdateWidget(covariant _UpdateProgress old) {
    super.didUpdateWidget(old);
    _prev = old.value;
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: _prev, end: widget.value),
      duration: Duration(milliseconds: widget.ms),
      curve: Curves.easeOut,
      builder: (_, v, child) => LinearProgressIndicator(
        value: v.clamp(0.0, 1.0),
      ),
    );
  }
}
