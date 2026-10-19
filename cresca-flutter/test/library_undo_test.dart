// U7 Undo + label pins: restorePlaylist (slot + no-dup + persist),
// restoreLike (slot fidelity), DownloadStore.isFailed (failed vs
// complete vs row-less), podcast speed/sleep label copy. Zero
// network, tiny temp dirs, deleted after.

import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:test/test.dart';

import 'package:cresca_app/app/downloads.dart';
import 'package:cresca_app/app/library.dart';
import 'package:cresca_app/core/track.dart';
import 'package:cresca_app/podcasts/playback_support.dart';

YtTrack t(String id) => YtTrack(
    id: id,
    title: 't $id',
    artist: 'A',
    thumbUrl: '',
    watchUrl: 'https://www.youtube.com/watch?v=$id');

void main() {
  group('playlist delete undo', () {
    late Directory dir;
    setUp(() async {
      dir =
          await Directory.systemTemp.createTemp('cresca-u7-test');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('restorePlaylist reinserts at the snapshot index', () async {
      final lib = LibraryStore(dir);
      await lib.load();
      await lib.createPlaylist('A');
      final b = await lib.createPlaylist('B');
      await lib.addToPlaylist(b.id, t('x'));
      final snapshot = UserPlaylist(
        id: b.id,
        name: b.name,
        tracks: List.of(b.tracks),
        createdAt: b.createdAt,
      );
      await lib.deletePlaylist(b.id);
      expect(lib.playlists.map((e) => e.name), ['A']);
      expect(
          await lib.restorePlaylist(snapshot, index: 0), isTrue);
      expect(
          lib.playlists.map((e) => e.name), ['B', 'A']);
      expect(lib.playlists.first.tracks.first.id, 'x');
    });

    test('restorePlaylist rejects dupes and blank snapshots',
        () async {
      final lib = LibraryStore(dir);
      await lib.load();
      final b = await lib.createPlaylist('B');
      final snapshot = UserPlaylist(
        id: b.id,
        name: b.name,
        tracks: List.of(b.tracks),
        createdAt: b.createdAt,
      );
      expect(
          await lib.restorePlaylist(snapshot, index: 0), isFalse);
      expect(
          await lib.restorePlaylist(
              UserPlaylist(id: '', name: '', createdAt: 0)),
          isFalse);
    });

    test('restore survives reload', () async {
      final lib = LibraryStore(dir);
      await lib.load();
      final b = await lib.createPlaylist('B');
      await lib.addToPlaylist(b.id, t('x'));
      final snapshot = UserPlaylist(
        id: b.id,
        name: b.name,
        tracks: List.of(b.tracks),
        createdAt: b.createdAt,
      );
      await lib.deletePlaylist(b.id);
      await lib.restorePlaylist(snapshot, index: 0);
      final lib2 = LibraryStore(dir);
      await lib2.load();
      expect(lib2.playlists.first.name, 'B');
      expect(lib2.playlists.first.tracks.first.id, 'x');
    });
  });

  group('unlike undo', () {
    late Directory dir;
    setUp(() async {
      dir =
          await Directory.systemTemp.createTemp('cresca-u7-test');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('restoreLike keeps the pre-unlike slot', () async {
      final lib = LibraryStore(dir);
      await lib.load();
      await lib.toggleLike(t('a'));
      await lib.toggleLike(t('b'));
      await lib.toggleLike(t('c'));
      expect(lib.liked.map((e) => e.id), ['c', 'b', 'a']);
      await lib.toggleLike(t('b')); // unlike
      expect(lib.liked.map((e) => e.id), ['c', 'a']);
      expect(await lib.restoreLike(t('b'), index: 1), isTrue);
      expect(lib.liked.map((e) => e.id), ['c', 'b', 'a']);
    });

    test('restoreLike is a no-op when already liked', () async {
      final lib = LibraryStore(dir);
      await lib.load();
      await lib.toggleLike(t('a'));
      expect(await lib.restoreLike(t('a'), index: 0), isFalse);
      expect(
          await lib.restoreLike(
              YtTrack(
                  id: '',
                  title: '',
                  artist: '',
                  thumbUrl: '',
                  watchUrl: ''),
              index: 0),
          isFalse);
    });
  });

  group('download failure state', () {
    late Directory dir;
    setUp(() async {
      dir =
          await Directory.systemTemp.createTemp('cresca-u7-test');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    DownloadEntry row(String id, String task) => DownloadEntry(
        trackId: id,
        taskId: task,
        title: 't',
        artist: 'a',
        name: '$id.m4a',
        isPublic: false);

    test('failed row with no file is retryable', () async {
      final store = DownloadStore(dir);
      await store.load();
      store.rows['f1'] = row('f1', 't1');
      store.status['t1'] = TaskStatus.failed;
      expect(store.isFailed('f1'), isTrue);
      store.status['t1'] = TaskStatus.canceled;
      expect(store.isFailed('f1'), isTrue);
      store.status['t1'] = TaskStatus.running;
      expect(store.isFailed('f1'), isFalse);
    });

    test('complete file on disk is never failed', () async {
      final store = DownloadStore(dir);
      await store.load();
      store.rows['f1'] = row('f1', 't1');
      store.status['t1'] = TaskStatus.failed;
      final sub =
          Directory('${dir.path}/$downloadSubdir')..createSync();
      final f = File('${sub.path}/f1.m4a');
      f.writeAsBytesSync(List.filled(16, 1));
      expect(store.isFailed('f1'), isFalse);
    });

    test('row-less filename entries are not failed', () async {
      final store = DownloadStore(dir);
      await store.load();
      expect(store.isFailed('ghost'), isFalse);
    });
  });

  group('podcast control labels', () {
    test('speed label carries the value', () {
      expect(podcastSpeedLabel(1.5), 'Playback speed, 1.5x');
      expect(podcastSpeedLabel(1.0), 'Playback speed, 1.0x');
    });

    test('sleep label is minutes-ceiled or off', () {
      expect(podcastSleepLabel(0), 'Sleep: off');
      expect(podcastSleepLabel(-100), 'Sleep: off');
      expect(podcastSleepLabel(20 * 60 * 1000), 'Sleep: 20 min');
      expect(podcastSleepLabel(19 * 60 * 1000 + 1000),
          'Sleep: 20 min');
      expect(podcastSleepLabel(60 * 1000), 'Sleep: 1 min');
    });
  });
}
