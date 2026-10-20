import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cresca_app/app/library.dart';
import 'package:cresca_app/core/search_guard.dart';
import 'package:cresca_app/app/widgets/track_menu.dart';
import 'package:cresca_app/core/track.dart';

YtTrack t(String id, [String artist = 'A']) => YtTrack(
      id: id,
      title: 'Title $id',
      artist: artist,
      thumbUrl: '',
      watchUrl: 'https://www.youtube.com/watch?v=$id',
    );

void main() {
  group('play -1 fallback (search/radio stale context)', () {
    test('hit returns the row index', () {
      final q = [t('aaaaaaaaaaa'), t('bbbbbbbbbbb')];
      expect(playIndexFor(q, t('bbbbbbbbbbb')), 1);
    });

    test('stale track misses: caller plays it single', () {
      // Search/radio lists refresh under the menu; the row may no
      // longer be in the context queue. -1 means "play [track] at 0",
      // never clamp-to-0 (wrong song).
      expect(playIndexFor([t('aaaaaaaaaaa')], t('ccccccccccc')), -1);
      expect(playIndexFor(const [], t('ccccccccccc')), -1);
    });
  });

  group('search stale rows', () {
    test('query set: live rows own the list, even when empty', () {
      final cached = [t('aaaaaaaaaaa')];
      // Fresh query, results not yet back: show empty, not stale cache.
      expect(
          searchShownRows(query: 'abc', rows: const [], cached: cached),
          isEmpty);
      expect(
          searchShownRows(
              query: 'abc', rows: [t('bbbbbbbbbbb')], cached: cached)
              .first
              .id,
          'bbbbbbbbbbb');
    });

    test('no query: cached fills the idle list', () {
      final cached = [t('aaaaaaaaaaa')];
      expect(
          searchShownRows(query: '', rows: const [], cached: cached), cached);
      expect(
          searchShownRows(
              query: '', rows: [t('bbbbbbbbbbb')], cached: cached)
              .first
              .id,
          'bbbbbbbbbbb');
    });
  });

  group('playlist dupe + kill-restore', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('cresca-ui-corr');
    });
    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('removeTrackAt drops one row, Undo re-inserts at same index', () async {
      final lib = LibraryStore(dir);
      await lib.load();
      final p = await lib.createPlaylist('Road');
      for (final id in ['a', 'b', 'c']) {
        expect(await lib.addToPlaylist(p.id, t(id)), isTrue);
      }
      // Swipe the middle row away.
      expect(await lib.removeTrackAt(p.id, 1), isTrue);
      expect([for (final e in p.tracks) e.id], ['a', 'c']);
      // Undo: same slot, then persist (kill-safe order).
      p.tracks.insert(1, t('b'));
      await lib.persistPlaylists();
      // Kill-restore: reload from disk, order preserved.
      final lib2 = LibraryStore(dir);
      await lib2.load();
      expect(
          [for (final e in lib2.playlists.first.tracks) e.id],
          ['a', 'b', 'c']);
    });

    test('dupes: one swipe removes one row, keys stay unique', () async {
      final lib = LibraryStore(dir);
      await lib.load();
      final p = await lib.createPlaylist('Dupes');
      await lib.addToPlaylist(p.id, t('a'));
      await lib.addToPlaylist(p.id, t('b'));
      // Legacy/hand-built dupe (store dedupes on add).
      p.tracks.add(t('a'));
      expect(p.tracks.length, 3);
      // Row keys the UI builds must be unique per row.
      final keys = [
        for (var i = 0; i < p.tracks.length; i++)
          'pl-${p.id}-$i-${p.tracks[i].id}',
      ];
      expect(keys.toSet().length, keys.length);
      // Swipe one dupe row: its twin survives.
      expect(await lib.removeTrackAt(p.id, 2), isTrue);
      expect([for (final e in p.tracks) e.id], ['a', 'b']);
      // Legacy by-id remove drops a single occurrence too.
      p.tracks.add(t('a'));
      await lib.removeFromPlaylist(p.id, 'a');
      expect([for (final e in p.tracks) e.id], ['b', 'a']);
    });

    test('removeTrackAt rejects unknown playlist/index', () async {
      final lib = LibraryStore(dir);
      await lib.load();
      final p = await lib.createPlaylist('Road');
      await lib.addToPlaylist(p.id, t('a'));
      expect(await lib.removeTrackAt('nope', 0), isFalse);
      expect(await lib.removeTrackAt(p.id, 5), isFalse);
      expect(await lib.removeTrackAt(p.id, -1), isFalse);
      expect(p.tracks.length, 1);
    });
  });
}
