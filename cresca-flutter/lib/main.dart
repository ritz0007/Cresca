// Entry: crash-guarded boot (A9), dirs, audio service, session restore.

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
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

Future<void> _boot() async {
  WidgetsFlutterBinding.ensureInitialized();
  await lockPortrait();
  final dir = await _filesDir();
  final state = AppState(dir);
  await state.init();
  // Foreground audio service (Y1): notification + lockscreen + custom
  // prev/like/next actions. Handler instance belongs to the controller.
  try {
    await AudioService.init(
      builder: () => state.controller.handler,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.cresca.audio',
        androidNotificationChannelName: 'Cresca playback',
        androidNotificationOngoing: true,
        androidStopForegroundOnPause: true,
      ),
    );
  } catch (_) {}
  runApp(CrescaApp(state: state));
}

void main() {
  runZonedGuarded(
    () {
      _boot().catchError((Object e, StackTrace st) async {
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
      });
    },
    (Object e, StackTrace st) async {
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
    },
  );
}
