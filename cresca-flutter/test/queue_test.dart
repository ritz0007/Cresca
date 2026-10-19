import 'dart:math';

import 'package:test/test.dart';

import 'package:cresca_app/core/discovery.dart';
import 'package:cresca_app/core/queue.dart';
import 'package:cresca_app/core/track.dart';

YtTrack t(String id, [String artist = 'A']) => YtTrack(
      id: id,
      title: 'Title $id',
      artist: artist,
      thumbUrl: '',
      watchUrl: 'https://www.youtube.com/watch?v=$id',
    );

void main() {
  group('QueueEngine order', () {
    test('setQueue identity order + playAt', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')], 1);
      expect(q.currentIndex, 1);
      expect(q.playOrder(), [0, 1, 2]);
      expect(q.playAt(2), 2);
      expect(q.current?.id, 'c');
    });

    test('generation-cancel taps bump', () {
      final q = QueueEngine();
      expect(q.generation, 0);
      q.setQueue([t('a')]);
      expect(q.generation, 1);
      q.cancelPending();
      expect(q.generation, 2);
    });

    test('next walks order, exhausts once per track', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b')]);
      var r = q.next();
      expect(r.step, NextStep.play);
      expect(q.current?.id, 'b');
      r = q.next();
      expect(r.step, NextStep.exhausted);
      expect(r.exhaustedTrack?.id, 'b');
      r = q.next();
      expect(r.step, NextStep.none);
    });

    test('repeat one replays, repeat all wraps', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b')]);
      q.cycleRepeat(); // all
      q.playAt(1);
      var r = q.next();
      expect(r.step, NextStep.play);
      expect(q.current?.id, 'a');
      q.cycleRepeat(); // one
      r = q.next();
      expect(r.step, NextStep.play);
      expect(q.current?.id, 'a');
      q.cycleRepeat(); // off
      expect(q.repeatMode, repeatOff);
    });

    test('previous walks back, all wraps to tail', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')]);
      q.playAt(0);
      expect(q.previous(), -1);
      q.cycleRepeat(); // all
      expect(q.previous(), 2);
    });

    test('shuffle cycles OFF->ON->SMART->OFF, current first', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c'), t('d')], 2);
      expect(q.cycleShuffle(random: Random(1)), shuffleOn);
      expect(q.playOrder().first, 2);
      expect(q.playOrder().toSet(), {0, 1, 2, 3});
      expect(q.cycleShuffle(random: Random(1)), shuffleSmart);
      expect(q.cycleShuffle(), shuffleOff);
      expect(q.playOrder(), [0, 1, 2, 3]);
    });

    test('playNext inserts after current in both lists', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')], 0);
      q.playNext(t('x'));
      expect(q.items[1].id, 'x');
      expect(q.playOrder(), [0, 1, 2, 3]);
      final r = q.next();
      expect(r.step, NextStep.play);
      expect(q.current?.id, 'x');
    });

    test('removeAt current resolves to collapsed index', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')], 1);
      final at = q.removeAt(1);
      expect(at, 1);
      expect(q.current?.id, 'c');
      expect(q.playOrder().toSet(), {0, 1});
    });

    test('moveInOrder + applyOrder guard', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')]);
      q.moveInOrder(0, 2);
      expect(q.playOrder(), [1, 2, 0]);
      q.applyOrder([0, 1]); // wrong size: ignored
      expect(q.playOrder(), [1, 2, 0]);
      q.applyOrder([2, 1, 0]);
      expect(q.playOrder(), [2, 1, 0]);
    });

    test('reorder snapshot + applyOrder restores exact order (Undo)', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c'), t('d')], 1);
      final prev = q.playOrder();
      q.moveInOrder(1, 3);
      expect(q.playOrder(), isNot(prev));
      q.applyOrder(prev); // void; must not throw
      expect(q.playOrder(), prev);
      expect(q.current?.id, 'b'); // sounding track untouched
    });

    test('restoreRemoved re-inserts + restores order (remove Undo)', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')], 1);
      final prev = q.playOrder();
      q.removeAt(0);
      expect(q.items.map((e) => e.id).toList(), ['b', 'c']);
      expect(
          q.restoreRemoved(index: 0, track: t('a'), prevOrder: prev),
          isTrue);
      expect(q.items.map((e) => e.id).toList(), ['a', 'b', 'c']);
      expect(q.playOrder(), prev);
      expect(q.current?.id, 'b'); // still sounding, no yank
    });

    test('restoreRemoved of sounding row rejoins as upcoming', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')], 1);
      final prev = q.playOrder();
      q.removeAt(1); // sounding row gone; playback moves on
      expect(q.current?.id, 'c');
      expect(
          q.restoreRemoved(index: 1, track: t('b'), prevOrder: prev),
          isTrue);
      expect(q.items.map((e) => e.id).toList(), ['a', 'b', 'c']);
      expect(q.current?.id, 'c'); // never yanks back to 'b'
    });

    test('restoreRemoved no-ops on shape change, never throws', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')], 0);
      final prev = q.playOrder();
      q.removeAt(0);
      q.removeAt(0); // second mutation: stale snapshot
      expect(
          q.restoreRemoved(index: 0, track: t('a'), prevOrder: prev),
          isFalse);
      expect(
          q.restoreRemoved(index: 99, track: t('z'), prevOrder: prev),
          isFalse);
      expect(q.items.map((e) => e.id).toList(), ['c']);
    });

    test('adoptJamQueue keeps sounding seat, caps 60, silent', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')], 1);
      final gen = q.generation;
      q.adoptJamQueue([t('x'), t('b'), t('y')], 'y');
      expect(q.current?.id, 'b');
      expect(q.generation, gen); // silent: no cancel
      q.adoptJamQueue([t('p'), t('q')], 'q');
      expect(q.current?.id, 'q');
      final many = List.generate(80, (i) => t('k$i'));
      q.adoptJamQueue(many, 'k0');
      expect(q.items.length, 60);
    });

    test('setQueueSilent restores without autoplay side-effects', () {
      final q = QueueEngine();
      final idx = q.setQueueSilent(
          [t('a'), t('b'), t('c')], 2, true, repeatAll);
      expect(idx, 2);
      expect(q.shuffleMode, shuffleOn);
      expect(q.repeatMode, repeatAll);
      expect(q.playOrder().first, 2);
    });

    test('auto tail append/replace keeps user tracks', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b')], 0);
      q.appendAuto([t('b'), t('c'), t('d')]); // dup dropped
      expect(q.items.map((e) => e.id).toList(), ['a', 'b', 'c', 'd']);
      expect(q.upcomingCount(), 3);
      q.playAt(1);
      q.clearAutoTail(random: Random(2));
      expect(q.items.map((e) => e.id).toList(), ['a', 'b']);
      expect(q.current?.id, 'b');
    });

    test('upcoming/previous windows + 2-ahead peek', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c'), t('d')], 1);
      expect(q.upcomingIds(2).map((e) => e.id).toList(), ['c', 'd']);
      expect(q.previousIds(5).map((e) => e.id).toList(), ['a']);
      expect(q.peekIndexAhead(0), 2);
      expect(q.peekIndexAhead(1), 3);
      expect(q.peekIndexAhead(2), isNull);
    });

    test('hasNext dead-end rule', () {
      final q = QueueEngine();
      q.setQueue([t('a')]);
      expect(q.hasNext(exhaustHookArmed: false), false);
      expect(q.hasNext(exhaustHookArmed: true), true);
    });

    test('single next = single advance under late index event', () {
      // Controller contract (double-skip fix): next() adopts the
      // engine index BEFORE seeking the gapless window, so the late
      // currentIndexStream event (_onIndex tag-adopt) finds
      // idx == currentIndex and returns instead of advancing again.
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')], 0);
      final predicted = q.upcomingIds(1).first.id;
      final r = q.next();
      expect(r.step, NextStep.play);
      expect(q.current?.id, predicted);
      // Late index event adopts the same id by tag: no second advance.
      final idx = q.items.indexWhere((e) => e.id == predicted);
      q.playAt(idx);
      expect(q.current?.id, 'b');
    });

    test('single previous = single step back under late index event', () {
      final q = QueueEngine();
      q.setQueue([t('a'), t('b'), t('c')], 2);
      final predicted = q.previousIds(1).first.id;
      expect(q.previous(), 1);
      expect(q.current?.id, predicted);
      final idx = q.items.indexWhere((e) => e.id == predicted);
      q.playAt(idx);
      expect(q.current?.id, 'b');
    });
  });

  group('discovery scoring', () {
    test('vibeQueries mood-first, max 3', () {
      final qs = vibeQueries(const YtTrack(
        id: 'x',
        title: 'Dil Diyan Gallan (Official Video) | Love Story',
        artist: 'Atif Aslam',
        thumbUrl: '',
        watchUrl: '',
      ));
      expect(qs.isNotEmpty, isTrue);
      expect(qs.length, lessThanOrEqualTo(3));
      expect(qs.first.contains('romantic'), isTrue);
    });

    test('detectMood buckets', () {
      expect(detectMood('lofi chill beats'), 'lofi');
      expect(detectMood('gym workout mix'), 'workout');
      expect(detectMood('bhangra hits'), 'punjabi');
      expect(detectMood('plain song xyz'), isNull);
    });

    test('isSameName echo vs distinct', () {
      YtTrack n(String title) => YtTrack(
          id: 'i',
          title: title,
          artist: 'a',
          thumbUrl: '',
          watchUrl: '');
      expect(isSameName(n('Diamond'), n('Diamond (Official Video)')), isTrue);
      expect(isSameName(n('Diamond'), n('Diamond Eyes')), isFalse);
      expect(isSameName(n('x'), n('y')), isFalse);
    });

    test('rankByVibe related first, same-name sunk', () {
      final seed = t('s', 'SeedArtist');
      final rel = YtTrack(
          id: 'r', title: 'Calm Nights', artist: 'Other', thumbUrl: '', watchUrl: '');
      final echo = YtTrack(
          id: 'e', title: 'Title s', artist: 'SeedArtist', thumbUrl: '', watchUrl: '');
      final ranked = rankByVibe(seed, [echo, rel],
          relatedIds: {'r'}, random: Random(7));
      expect(ranked.first.id, 'r');
      expect(ranked.last.id, 'e');
    });

    test('smartOrder prefers liked, current first', () {
      final items = [t('a', 'Loved'), t('b', 'Stranger'), t('c', 'Loved')];
      final order = smartOrderFor(
        items: items,
        currentIndex: 1,
        likedArtists: {'loved'},
        recentArtists: ['stranger'],
        random: Random(3),
      );
      expect(order.first, 1);
      expect(order.toSet(), {0, 1, 2});
      // Both liked tracks outrank nothing-else; order keeps tier shuffle only.
      expect(order.sublist(1).toSet(), {0, 2});
    });
  });
}
