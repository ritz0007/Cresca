# Phase 08 — UI lists + perf (Should fix)
Scope: `lib/app/widgets/queue_sheet.dart:51-177,409,769`, `lib/app/screens/*` AnimatedBuilder roots, `lib/app/design.dart:1174-1349`, `lib/app/screens/podcast_screen.dart:187-192`, `lib/core/motion.dart:60`, `lib/app/app.dart:354-378,477-516`, `lib/app/screens/home_screen.dart:51-55,162-201,315-353`, `lib/app/screens/trending_screen.dart:171`
Tasks:
1. Queue: SliverReorderableList, stable id keys, test reorder math.
2. Scope rebuilds: replace screen-root + per-row AnimatedBuilder with ValueListenable on currentId/playing. Cache crescaTheme, hoist RegExp/math.pow.
3. Motion: single helper, debounce fixed 250ms, instant when off.
4. Scroll: no nested fixed-height lists, mini collapses to zero, fix trend keys, remove scroll listener leak.
Done: flutter analyze clean, long-queue + home scroll smooth on jam16.
