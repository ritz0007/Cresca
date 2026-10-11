// Entry: crash-guarded two-phase boot (A9) + dirs + audio service +
// session restore.
//
// Cold-start shape (startup crew):
// - Phase 0 (critical, pre-first-paint): binding + portrait lock +
//   support-dir lookup only. No repo/session/network/audio work here.
// - Phase 1 (first paint): a static branded bridge (_BootSplash,
//   theme-aware logo + Cresca Music wordmark) so the OS
//   launch background hands off with no flash and no jank.
// - Phase 2 (off first paint): AppState.init() — prefs, sessions,
//   library/downloads restore, staged home load (cached waves first,
//   then 4-way parallel +120ms rails; see AppState.loadHome) — then
//   the content shell (CrescaApp) swaps in via a second runApp. The
//   in-app splash overlay holds on homeStatus readiness (8s failsafe),
//   so content readiness — not a blind timer — lifts the splash.
// - Phase 3 (non-critical, post-content-paint): AudioService.init is
//   fired without awaiting after CrescaApp's first frame is scheduled,
//   so the media-notification bind never blocks paint. Playback before
//   the bind completes still works; only the OS notification is late.
//
// Portrait posture (A2): lockPortrait() pins portraitUp/Down +
// edge-to-edge. Video-fullscreen path (documented, not enabled): a
// future fullscreen video route opts into landscape for its own
// route via SystemChrome.setPreferredOrientations([...landscape...])
// and restores portrait on pop — the manifest already declares the
// orientation|screenSize|... configChanges set, so no manifest change
// is needed for that path.

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:path_provider/path_provider.dart';

import 'app/app.dart';
import 'app/state.dart';

Future<Directory> _filesDir() async {
  try {
    return await getApplicationSupportDirectory();
  } catch (_) {
    return Directory.current;
  }
}

Future<void> _writeCrash(Object e, StackTrace st) async {
  try {
    final dir = await _filesDir();
    final f = File(
        '${dir.path}/crash/zone-${DateTime.now().millisecondsSinceEpoch}.log');
    try {
      await f.parent.create(recursive: true);
    } catch (_) {}
    try {
      await f.writeAsString('$e\n$st');
    } catch (_) {}
  } catch (_) {}
}

Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Debug drives (uiautomator) need the semantics tree; release builds
  // enable it on demand via accessibility services.
  if (kDebugMode) {
    try {
      SemanticsBinding.instance.ensureSemantics();
    } catch (_) {}
  }
  await lockPortrait();
  final dir = await _filesDir();

  // Phase 1: first paint — static brand bridge, ~1 frame of work.
  runApp(const _BootSplash());

  // Phase 2: heavy init off first paint (staged home load inside).
  final state = AppState(dir);
  try {
    await state.init();
  } catch (_) {}

  // Content shell (in-app splash holds on homeStatus readiness).
  runApp(CrescaApp(state: state));

  // Phase 3: non-critical audio-service bind, never blocking paint.
  // Foreground audio service (Y1): notification + lockscreen + custom
  // prev/like/next actions. Handler instance belongs to the controller.
  unawaited(
    Future(() async {
      try {
        await AudioService.init(
          builder: () => state.controller.handler,
          config: const AudioServiceConfig(
            androidNotificationChannelId: 'com.cresca.audio',
            androidNotificationChannelName: 'Cresca Music playback',
            // Music-player standard: the shade notification (with
            // the like heart) survives pause instead of vanishing
            // the moment playback stops (R7). Non-ongoing pairs with
            // stop-on-pause=false (asserted by audio_service); the
            // notification stays until dismissed or the queue ends.
            androidNotificationOngoing: false,
            androidStopForegroundOnPause: false,
          ),
        );
      } catch (_) {}
    }),
  );
}

/// Pre-content brand bridge: static (no animation — first-paint speed),
/// theme-aware logo lockup so the handoff from the Android window
/// background through to _SplashOverlay is seamless: white surround in
/// light mode, black in dark (matches drawable(-night)/launch_background).
class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    final dark =
        MediaQuery.platformBrightnessOf(context) == Brightness.dark;
    final bg = dark ? Colors.black : Colors.white;
    final fg = dark ? Colors.white : Colors.black;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: bg,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Image.asset(
                dark
                    ? 'assets/logo_dark.png'
                    : 'assets/logo_light.png',
                width: 120,
                height: 120,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 16),
              Text(
                'Cresca Music',
                style: TextStyle(
                  color: fg,
                  fontSize: 32,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'your music, uninterrupted',
                style: TextStyle(
                    color: fg.withValues(alpha: 0.7)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void main() {
  runZonedGuarded(
    () {
      _boot().catchError((Object e, StackTrace st) async {
        await _writeCrash(e, st);
      });
    },
    (Object e, StackTrace st) async {
      await _writeCrash(e, st);
    },
  );
}
