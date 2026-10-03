import 'dart:io';

import 'package:test/test.dart';

import 'package:cresca_app/app/library.dart';
import 'package:cresca_app/core/home_feed.dart';
import 'package:cresca_app/core/track.dart';

void main() {
  group('home feed catalog', () {
    test('top seed rotates, never same page twice in a row', () {
      final a = HomeFeed.topSeed(0);
      final b = HomeFeed.topSeed(1);
      expect(a.query, isNot(b.query));
      expect(HomeFeed.topSeed(6).query, a.query); // wraps
      expect(HomeFeed.topSeeds.length, 6);
    });

    test('core order + discovery cycle keys', () {
      expect(HomeFeed.core.first.title, 'Charts Right Now');
      expect(HomeFeed.core.length, 7);
      final d0 = HomeFeed.discoveryAt(0, 0);
      final d1 = HomeFeed.discoveryAt(0, 1);
      expect(d0.query, isNot(d1.query)); // cycle shifts start
      expect(d0.cacheKey, contains('_c0'));
      expect(d1.cacheKey, contains('_c1'));
      expect(HomeFeed.releasedPlaylistId, isNotEmpty);
      expect(HomeFeed.moods.length, 4);
    });

    test('artistSeeds drops labels, ranks by frequency', () {
      final seeds = HomeFeed.artistSeeds([
        'T-Series',
        'Arijit Singh',
        'Arijit Singh feat. Shreya Ghoshal',
        'Shreya Ghoshal',
        'Sony Music India',
        'YouTube',
        'Unknown Artist',
        'Diljit Dosanjh & Badshah',
      ], 4);
      expect(seeds.contains('T-Series'), isFalse);
      expect(seeds.contains('Sony Music India'), isFalse);
      expect(seeds.contains('YouTube'), isFalse);
      expect(seeds.first, 'Arijit Singh');
      expect(seeds, contains('Shreya Ghoshal'));
    });

    test('personalized sections shape', () {
      final secs = HomeFeed.personalized(['Arijit Singh'], ['Shreya'], max: 2);
      expect(secs.length, 2);
      expect(secs.first.title, startsWith('More like'));
      expect(secs.first.subtitle, 'Because you listened');
    });
  });

  group('library store', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cresca-lib-test');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    YtTrack t(String id, [String artist = 'A']) => YtTrack(
        id: id,
        title: 't',
        artist: artist,
        thumbUrl: '',
        watchUrl: 'https://www.youtube.com/watch?v=$id');

    test('like toggle + persist + reload', () async {
      final lib = LibraryStore(dir);
      await lib.load();
      await lib.toggleLike(t('a'));
      expect(lib.isLiked('a'), isTrue);
      final lib2 = LibraryStore(dir);
      await lib2.load();
      expect(lib2.isLiked('a'), isTrue);
      await lib.toggleLike(t('a'));
      expect(lib.isLiked('a'), isFalse);
    });

    test('recent dedupes + caps at 300', () async {
      final lib = LibraryStore(dir);
      await lib.load();
      for (var i = 0; i < 305; i++) {
        await lib.pushRecent(t('k$i'));
      }
      expect(lib.recent.length, 300);
      expect(lib.recent.first.id, 'k304');
      await lib.pushRecent(t('k0'));
      expect(lib.recent.first.id, 'k0');
      expect(lib.recent.length, 300);
    });

    test('playlists create/add/dedupe/persist native schema', () async {
      final lib = LibraryStore(dir);
      await lib.load();
      final p = await lib.createPlaylist('Road');
      expect(await lib.addToPlaylist(p.id, t('a')), isTrue);
      expect(await lib.addToPlaylist(p.id, t('a')), isTrue); // idempotent
      expect(p.tracks.length, 1);
      final lib2 = LibraryStore(dir);
      await lib2.load();
      expect(lib2.playlists.first.name, 'Road');
      expect(lib2.playlists.first.tracks.first.id, 'a');
    });
  });
}
