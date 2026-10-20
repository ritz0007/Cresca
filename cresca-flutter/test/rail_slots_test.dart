import 'package:test/test.dart';

import 'package:cresca_app/core/rail_slots.dart';
import 'package:cresca_app/core/track.dart';

YtTrack t(String id) => YtTrack(
      id: id,
      title: 'Title $id',
      artist: 'A',
      thumbUrl: '',
      watchUrl: 'https://www.youtube.com/watch?v=$id',
    );

// U6 per-rail status proof: one rail's 403 banners in place, its
// siblings still render; page-level failure is "all slots failed".
// Drives resolveRailSlots — the exact resolver the screen renders.
void main() {
  const titles = ['Hindi', 'International', 'Telugu', 'Punjabi'];

  Map<String, List<YtTrack>> tracksFor(List<String> ok) => {
        for (final title in ok)
          title: [t('id-$title-1'), t('id-$title-2')],
      };

  group('resolveRailSlots', () {
    test('all succeed: no failures, paint order kept', () {
      final slots = resolveRailSlots(
        titles: titles,
        primary: tracksFor(titles),
        fallback: const {},
        failedPrimary: const {},
        failedFallback: const {},
      );
      expect([for (final s in slots) s.title], titles);
      expect(slots.every((s) => !s.failed), isTrue);
      expect(slots.every((s) => s.tracks.isNotEmpty), isTrue);
    });

    test('one rail 403s: only it fails, siblings render', () {
      final ok = ['Hindi', 'Telugu', 'Punjabi'];
      final slots = resolveRailSlots(
        titles: titles,
        primary: tracksFor(ok),
        fallback: const {},
        failedPrimary: const {'International'},
        failedFallback: const {},
      );
      final byTitle = {for (final s in slots) s.title: s};
      // Siblings untouched by the failure.
      for (final title in ok) {
        expect(byTitle[title]!.failed, isFalse,
            reason: '$title must still render');
        expect(byTitle[title]!.tracks, isNotEmpty);
      }
      // Failed rail banners in place (same index, no tracks).
      final failed = byTitle['International']!;
      expect(failed.failed, isTrue);
      expect(failed.tracks, isEmpty);
      expect([for (final s in slots) s.title], titles);
    });

    test('failed primary falls back to state tracks: no banner', () {
      final slots = resolveRailSlots(
        titles: titles,
        primary: tracksFor(['Hindi']),
        fallback: {
          'International': [t('id-International-1')],
        },
        failedPrimary: const {'International'},
        failedFallback: const {},
      );
      final byTitle = {for (final s in slots) s.title: s};
      expect(byTitle['International']!.failed, isFalse);
      expect(byTitle['International']!.tracks.single.id,
          'id-International-1');
    });

    test('empty-but-not-failed stays hidden (not a failure)', () {
      final slots = resolveRailSlots(
        titles: titles,
        primary: tracksFor(['Hindi']),
        fallback: const {},
        failedPrimary: const {},
        failedFallback: const {},
      );
      final byTitle = {for (final s in slots) s.title: s};
      expect(byTitle['Telugu']!.failed, isFalse);
      expect(byTitle['Telugu']!.tracks, isEmpty);
    });

    test('state-side failure banners when video also misses', () {
      final slots = resolveRailSlots(
        titles: titles,
        primary: const {},
        fallback: const {},
        failedPrimary: const {},
        failedFallback: const {'Punjabi'},
      );
      final byTitle = {for (final s in slots) s.title: s};
      expect(byTitle['Punjabi']!.failed, isTrue);
      expect(byTitle['Hindi']!.failed, isFalse);
    });

    test('never throws on degenerate input', () {
      expect(
        resolveRailSlots(
          titles: const [],
          primary: const {},
          fallback: const {},
          failedPrimary: const {},
          failedFallback: const {},
        ),
        isEmpty,
      );
    });
  });
}
