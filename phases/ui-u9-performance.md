# U9 — Performance: Blur + Lists + Images (Days 17–18)

> Owner: one agent. Depends on: U1–U8 (all surfaces exist in final form). Unblocks: release.
> Goal: ≤2 live blurs per frame, 60 fps scroll on jam16, zero image flicker on re-scroll.

---

## 1. Why this phase exists

The Liquid Glass system looks premium and costs dearly. Four live `BackdropFilter` sites (`design.dart:230 Glass, 260 GlassBar, 339 GlassSheetSurface, 854 FloatingTabBar`) plus the `MeshBackdrop` artwork wash plus per-row effects stack blur passes over the same pixels. On SwiftShader (jam16 emulator) and low-end Mali/Adreno GPUs this means: compositor-unsafe passes (documented `ClipRRect`-over-filter paint-bisect), per-frame `CustomPaint` drift, whole-list rebuilds via `AppScope` + `AnimatedBuilder`, and `CachedNetworkImage` thrash without an LRU (phase-02 memo pattern exists for downloads, not images). Symptoms: first-scroll jank, blank rows that pop in, white flashes on re-scroll, sheets that stutter open.

U9 is a budget enforcement phase: count every blur, scope every rebuild, cache every image. No visuals change — the same pixels cost fewer passes.

---

## 2. Current-state map

| Cost center | File | Current mitigation (keep) |
|---|---|---|
| `Glass` blur σ24 | `design.dart:230` | `ClipRect` bounds + `RepaintBoundary`, static sigma |
| `GlassBar` blur σ26 | `design.dart:260` | Same bounding pattern |
| `GlassSheetSurface` blur σ30 | `design.dart:339` | Static sigma, entrance animates opacity/transform only |
| `FloatingTabBar` blur σ24 | `design.dart:854` | Solo filter, `ClipRect`, never `ClipRRect` over it |
| `MeshBackdrop` wash | `design.dart:413-619` | One-shot ~1.2 s drift then rest, static scrim outside `AnimatedBuilder`, radial-gradient painter (no per-frame `MaskFilter`) |
| Row entrances | `track_row.dart` `StaggerEntrance` | First 8 only, 220 ms / 40 ms stagger cap 320 ms |
| Spinners | `DelayedSpinner` | Size reserved frame one, fade after 300 ms |
| Shimmer | `PulseOpacity` | Opacity-only, hoisted curve, gated on `motionOn && pulsing` |

Anti-patterns to kill: stacked blurs (sheet + row + scrim in one frame), `fontSize` animation (relayout per frame — already banned), `AnimatedBuilder` around whole lists, white-placeholder image flash, per-frame `MaskFilter`.

---

## 3. Design decisions and non-goals

- Blur budget: 2 live filters max per frame (bar + active sheet). Everything else uses `TextScrim` (static gradient, zero filter).
- No glass redesign, no removing the wash. Freeze cost, don't flatten character.
- Release-build profiling only — debug builds lie about jank (asserts + unoptimized shaders).
- Image fix is cache + placeholder, not a new image stack (`cached_network_image` stays).

---

## 4. Day 1 — Implementation

### Step 1 — Enforce the blur budget (2 h)
1. Audit every `BackdropFilter` in `lib/`:
   ```
   grep -rn "BackdropFilter" cresca-flutter/lib
   ```
   Allowed survivors: `GlassBar`, `FloatingTabBar`, and ONE active `GlassSheetSurface`. All other call sites (row cards, chips over art, pill backgrounds) convert to `TextScrim` + translucent `Container`:
   ```dart
   // before: blur behind every card
   BackdropFilter(filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12), child: card)
   // after: static legibility, zero filter
   TextScrim(child: card)
   ```
2. `MeshBackdrop`: when the sheet settles (drift controller completed AND palette stable), freeze the wash — set a `settled` flag that builds the last painted frame as a static `RepaintBoundary` child with no `AnimatedBuilder` tick. On track/palette change, unfreeze for one glide, then re-freeze. When `motionOn == false`, wash is already static — verify, don't duplicate.
3. Entrance rule (already code, now enforce in review): entrances animate transform/opacity only; blur sigma is `const`/final, never tweened. `grep -rn "sigmaX.*anim\|blur.*tween" lib/` must be empty.

### Step 2 — Scope rebuilds (1–2 h)
1. Artwork rows: wrap art + title in `RepaintBoundary` so drift/blur repaints never propagate into row content. One boundary per row, not per pixel — over-bounding wastes memory.
2. Lists: state reads scoped to the row (`ValueListenableBuilder` / per-row `AnimatedBuilder` on its own notifier), never a top-level `AnimatedBuilder(animation: state)` around the whole list. `AppScope` (mutable singleton, never re-notifies) + direct `ChangeNotifier` subscription stays — but subscriptions attach at row granularity for high-churn values (position, progress %).
3. Thumbs: `gaplessPlayback: true` on all `CachedNetworkImage`/`Image` so re-scroll keeps the old frame until the new one resolves (kills white flash). Placeholder = mosaic/gradient fallback (dark green fallback hues per `track_row.dart` docs), never white, never spinner inside the thumb box.

### Step 3 — Image LRU (1 h, phase-02 pattern)
Add a small memo cache for thumbs (count + byte cap, e.g. 200 entries / 48 MB — tune on jam16, document the values):
```dart
// image_memo.dart: Map<url, ImageProvider> LRU + eviction; callers ask memo first.
```
Prefetch next-viewport thumbs (rails + queue next 3) during idle; cancel on scroll fling (don't fight the finger — same principle as U5 lyrics). Confirm `background_downloader` memo style is mirrored, not forked.

### Step 4 — Self-check
- `grep -rn "BackdropFilter" lib/` → exactly the budgeted sites.
- `grep -rn "gaplessPlayback" lib/app/widgets/track_row.dart lib/app/screens/*.dart` → present on thumbs.
- `flutter analyze` clean; release build compiles.

---

## 5. Day 2 — Verification + mandatory emulator check

### 5.1 Static gates (release!)
```powershell
cd cresca-flutter
C:\Android\flutter\flutter\bin\flutter.bat analyze
C:\Android\flutter\flutter\bin\flutter.bat test
C:\Android\flutter\flutter\bin\flutter.bat build apk --release
C:\Android\flutter\flutter\bin\flutter.bat install --release -d emulator-5554
```
Profile the release APK. Debug numbers are inadmissible for U9 sign-off.

### 5.2 Emulator check (jam16)
1. Boot if needed; install release (step above); launch, sleep 12, `pidof` + logcat FATAL scan.
2. Screenshots: (a) Home mid-rail scrolled (no blank rows), (b) Library scrolled, (c) player art (wash frozen post-settle), (d) rapid re-scroll position (thumbs intact, no white flash).
3. `uiautomator dump` before/after scroll: row counts stable, keys unique, no duplicated nodes.
4. Scroll torture on the RELEASE profile build only (`flutter run --profile`, DevTools performance view): Home end-to-end 2×, Library 2×, queue 2×; open/close player 10×. Record p90 frame time + worst frame per screen (budget: p90 ≤ 32 ms on jam16; worst frame noted, not eyeballed). Debug-build numbers are inadmissible.
5. Kill + cold start: skeleton → content with no image pop-in storm (LRU warm vs cold documented).

### 5.3 Limits
SwiftShader lies upward about cost (real devices are faster) and downward about correctness (paint-bisect is emulator-specific). Both directions: report numbers, don't over-tune to the emulator. 403 streams ≠ perf failure. Clean up artifacts.

---

## 6. Edge cases

| Symptom | Cause | Fix |
|---|---|---|
| Blank rows on first scroll | No prefetch + cold cache | Viewport-ahead prefetch; skeleton reserves size |
| White flash on re-scroll | `gaplessPlayback: false` / white placeholder | `gaplessPlayback: true` + dark fallback hues |
| Sheet stutters open | Blur tweened or stacked | Static sigma; budget check — sheet + bar only |
| Whole list rebuilds on position tick | Top-level `AnimatedBuilder(state)` | Scope ticks to progress/position widgets |
| OOM on long sessions | Unbounded image cache | LRU count + byte caps with eviction; document values |
| `ClipRRect` over filter blanks content | Compositor-unsafe nesting (jam16-proven) | `ClipRect` bounds only; never `ClipRRect` over `BackdropFilter` |

---

## 7. Exit criteria
- [ ] `BackdropFilter` count = budget (bar + active sheet + wash-frozen); no stacked frames observed.
- [ ] Re-scroll instant, no flicker; cold start has no pop-in storm; p90 ≤ 32 ms recorded per screen.
- [ ] Release scroll torture passes on jam16 with no ANR/FATAL.
- [ ] `analyze` + `test` green; cache caps documented in code.

## 8. Rollback
Restore blur on the single sheet that looks worst if flattening reads cheap (keep scoping + cache — both independent wins). Never restore stacked blurs to "fix" legibility — use `TextScrim` instead.

## 9. Handoff to U10
U10 profiles TalkBack + text-scale on top of this budget (a11y repaints must also stay scoped). Report: final filter count, LRU caps, any frame that still exceeds budget and why.

---

## 10. Shared process (normative)
Runbook, copy deck, test matrix (T1–T14), sign-off log, working agreements, and branching rules live in phases/ui-shared-appendix.md and are not copied here. Follow that file for process; this doc owns scope. Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder — guard with `context.mounted`.
