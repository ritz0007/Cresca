// Manual real-network smoke test (NOT part of `flutter test`).
// Usage: dart run tool/live_check.dart [<videoId> ...]
// Port of streamkit's tool/live_check.dart against the vendored
// StreamResolver: resolves audio+video+meta live, probes the best URL.
// With no args, discovers 3 real ids through the app's own InnerTube
// search path (same headers/session the app uses; never hardcodes).
import 'dart:async';
import 'dart:io';

import 'package:cresca_app/data/repository.dart';
import 'package:cresca_app/data/resolve.dart';

Future<void> check(StreamResolver r, String id) async {
  try {
    final sw = Stopwatch()..start();
    final b = await r
        .bundleFor(id)
        .timeout(const Duration(seconds: 60));
    sw.stop();
    if (b == null || !b.hasAudio) {
      // ignore: avoid_print
      print('RESOLVE FAILED for $id (${sw.elapsedMilliseconds}ms)');
      exitCode = 1;
      return;
    }
    // ignore: avoid_print
    print('[$id] resolve: ${sw.elapsedMilliseconds}ms');
    // ignore: avoid_print
    print('[$id] audio urls: ${b.audioUrls.length} (best bitrate first)');
    // ignore: avoid_print
    print('[$id] video qualities: ${b.videoUrls.map((e) => e.$2).toList()}');
    // ignore: avoid_print
    print('[$id] title: ${b.meta.title}');
    // ignore: avoid_print
    print('[$id] artist: ${b.meta.artist}');
    final psw = Stopwatch()..start();
    final alive = await r.probeUrl(b.audioUrls.first);
    psw.stop();
    // ignore: avoid_print
    print('[$id] probe: alive=$alive (${psw.elapsedMilliseconds}ms)');
    if (!alive) exitCode = 1;
  } catch (e) {
    // ignore: avoid_print
    print('SMOKE ERROR for $id: $e');
    exitCode = 1;
  }
}

Future<void> main(List<String> args) async {
  final r = StreamResolver();
  final repo = YoutubeRepository();
  try {
    final ids = args.isNotEmpty
        ? args.take(3).toList()
        : await repo
            .searchMusic('lofi hip hop mix', max: 10)
            .timeout(const Duration(seconds: 30))
            .then((tracks) => tracks
                .map((t) => t.id)
                .where((id) => id.length == 11)
                .toSet()
                .take(3)
                .toList())
            .catchError((_) => <String>['dQw4w9WgXcQ']);
    if (ids.length < 3 && args.isEmpty) {
      // ignore: avoid_print
      print('DISCOVERY yielded ${ids.length}, topping up');
      ids.add('dQw4w9WgXcQ');
    }
    for (final id in ids.take(3)) {
      await check(r, id);
    }
  } finally {
    r.dispose();
    repo.dispose();
  }
}
