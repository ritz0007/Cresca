# U3 — Home / Listen Now (Days 5–6)

> Owner: one agent. Depends on: U1 (clearance), U2 (shell). Unblocks: U6 (shared list patterns).
> Goal: one scrollable, no nested-list jank, honest Loading / Content / Empty / Error states.

---

## 1. Why this phase exists

Home (`lib/app/screens/home_screen.dart`) is the first screen and the worst scroll offender:

1. **Nested scrollables.** Rails and sections use `shrinkWrap: true` + `NeverScrollableScrollPhysics` inside the outer scroll (same pattern in `library_screen.dart`, `radio_screen.dart`, `search_screen.dart`). Every inner list measures its full extent on each outer scroll frame — O(n²) layout on long rails, visibly janky on low-end devices and the SwiftShader emulator.
2. **Post-frame init in 5 screens.** `addPostFrameCallback` fires `loadHome()` / prefetch after first frame. Combined with missing spinner reservation on some paths, content pops with a jump.
3. **Honest states must be proven, not assumed.** `see_all.dart` already carries a `_moreError` + Retry path in `_more()` — but no test pins it, and the surrounding screens still risk showing empty where they mean broken. U3's job is to verify each state is reachable, not to rebuild the pager.

Home sets the pattern U6–U7 copy. Fix it canonically here.

---

## 2. Current-state map

| File | Owns |
|---|---|
| `lib/app/screens/home_screen.dart` | Header + spinner + pull hint, Top Picks + Play-all/Shuffle + See All, rails, moods → deep-search, hero Play/Shuffle, skeleton shimmer first load, offline error + Retry, endless discovery rails |
| `lib/app/screens/see_all.dart` | Paginated full list with continuation; `_moreError` + Retry already implemented in `_more()` — verify, pin with a test |
| `lib/app/widgets/track_row.dart` | Shared track row + skeleton placeholder, cached thumbs with mosaic/gradient fallback, `PressScale` .94, `StaggerEntrance` (first 8 only, 220 ms, 40 ms stagger cap 320 ms) |
| `lib/app/state.dart` | `homeStatus` (loading/content/error), `topPicks`, `rails`, `loadHome()`, `loadMoreDiscovery()` (single-flight, fires at 1.5 viewports remaining) |
| `lib/app/updates.dart` | `UpdateBannerMotion`, `UpdateProgressShimmer` (banner above rails — keep) |

Preserve: prefetch threshold (1.5 viewports), single-flight in state, `DelayedSpinner` 300 ms, `StaggerEntrance` caps, pull-refresh dissolve (opacity-only, 220 ms), hero Play/Shuffle behavior.

---

## 3. Design decisions and non-goals

- Single `CustomScrollView` + slivers on Home. Each rail = `SliverToBoxAdapter` wrapping one horizontal `ListView` (fixed height). Vertical stacking never nests vertical lists.
- No rail redesign, no new sorting, no taste-algorithm change. Pure structure + states.
- `see_all.dart` is verify-and-pin, not rebuild: the `_moreError` path exists — add the airplane-mode test that proves Retry appears and recovers.

---

## 4. Day 1 — Implementation

### Step 1 — Home → slivers (3–4 h)
Rewrite `HomeScreen.build` skeleton (keep all data calls identical):
```dart
CustomScrollView(
  controller: _scroll,
  physics: const AlwaysScrollableScrollPhysics(), // pull-refresh works even when short
  slivers: [
    SliverToBoxAdapter(child: Header(...)),
    if (loading && empty) SliverToBoxAdapter(child: SkeletonList()),
    if (error && empty) SliverToBoxAdapter(child: ErrorRetry(onRetry: state.loadHome)),
    if (content) ...[
      SliverToBoxAdapter(child: HeroPlayShuffle(...)),
      SliverToBoxAdapter(child: TopPicks(...)),
      for (final rail in rails)
        SliverToBoxAdapter(child: Rail(title: rail.title, horizontalList: ...)),
    ],
    SliverPadding(
      padding: EdgeInsets.only(bottom: BottomChromeScope.clearanceOf(context)),
      sliver: SliverToBoxAdapter(child: EndFooter(...)), // "You're all caught up" or spinner
    ),
  ],
)
```
Rules: horizontal rails = `SizedBox(height: 216, child: ListView.builder(scrollDirection: Axis.horizontal, …))` — inner scroll is orthogonal, no conflict. Never put a vertical `ListView` inside the `CustomScrollView`; vertical sections become `SliverList` directly. Keep `_maybePrefetch` unchanged (1.5 viewports; slivers fix `maxScrollExtent` accuracy). Keep the `refreshing` dissolve (`Dissolve`, opacity only).

### Step 2 — `see_all.dart`: verify the existing Retry path, don't rebuild it (45 min)
The pager already surfaces transport errors via `_moreError` + Retry (`_more()` sets `'Couldn’t load more — check your connection.'` when the pager returns `[]` without flipping exhausted). Your job: prove it with a test (airplane-mode page failure → Retry visible → Retry recovers), and only restructure if the test exposes a gap. Never regress this to a silent empty list.

### Step 3 — Row entrance hygiene (30 min)
Confirm `StaggerEntrance(index:)` caps at 8 (`maxItems`), `maxStaggerMs` 320, beyond-cap rows render directly with zero timers. Key rows by `section + trackId` so section changes re-run entrances without leaking controllers. No new animation.

### Step 4 — Self-check
- `grep -rn "shrinkWrap" lib/app/screens/home_screen.dart` → empty.
- `grep -rn "NeverScrollableScrollPhysics" lib/app/screens/home_screen.dart` → empty.
- `flutter analyze` clean.

---

## 5. Day 2 — Verification + mandatory emulator check

### 5.1 Static gates
```powershell
cd cresca-flutter
C:\Android\flutter\flutter\bin\flutter.bat analyze
C:\Android\flutter\flutter\bin\flutter.bat test
```

### 5.2 Emulator check (jam16)
1. Boot if needed; fresh `build apk --release` + `install --release -d emulator-5554`.
2. Launch, sleep 12, `pidof` + logcat FATAL scan.
3. Screenshots: (a) Home hero top, (b) mid-rails scrolled, (c) skeleton first-load (kill app, clear data, launch, capture within 1 s), (d) offline error + Retry (airplane mode via `adb shell cmd connectivity airplane-mode enable`, then disable after).
4. `uiautomator dump` at top, mid, end: rails present, See All nodes present, last item above tab-bar bounds, end footer text when list exhausted.
5. Interactions: pull-refresh 3×, scroll to end (prefetch fires, no duplicate pages — check logcat for single-flight), airplane on → Retry visible → airplane off → Retry → content returns.
6. Cold-boot twice (force-stop between) to verify skeleton → content with no jump.

### 5.3 Limits
Streams 403 on emulator — rails art + titles are the check, not playback. Generic seeds on fresh profile expected. Clean up PNG/XML.

---

## 6. Edge cases

| Symptom | Cause | Fix |
|---|---|---|
| Pull-refresh dead on short list | Missing scroll physics | `AlwaysScrollableScrollPhysics` on the `CustomScrollView` |
| Prefetch fires in a loop | `maxScrollExtent == 0` short list | Keep the short-list branch; single-flight in state prevents storms |
| Skeleton jumps to content | Spinner not reserving size | `DelayedSpinner` reserves `size` from frame one — keep |
| Endless spinner at feed end | No terminal state | `EndFooter`: spinner while `hasMore`, terminal copy when done |
| Retry loses scroll position | Full-list rebuild | Inline banner retry for page errors; full Retry only when list empty |

---

## 7. Exit criteria
- [ ] No vertical-in-vertical nesting on Home (`shrinkWrap`/`NeverScrollable` gone).
- [ ] Skeleton → content with no jump; refresh dissolve intact.
- [ ] Airplane-mode test proves Retry appears and recovers in `see_all.dart`; errors never render as silent empty.
- [ ] `analyze` + `test` green; launch clean; dumps confirm clearance.

## 8. Rollback
Revert rail-by-rail to inner lists if slivers regress on any device; keep the Retry verification regardless.

## 9. Handoff to U4/U6
Report the canonical sliver pattern + `EndFooter` widget for U6–U7 reuse, and any rail that needed a fixed-height exception.

---

## 10. Shared process (normative)
Runbook, copy deck, test matrix (T1–T14), sign-off log, working agreements, and branching rules live in `phases/ui-shared-appendix.md` and are not copied here. Follow that file for process; this doc owns scope. Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder — guard with `context.mounted`.

## 11. Appendix F — Home-specific deep dive

- Rail audit: list every rail builder in `home_screen.dart` and mark it horizontal-inner vs vertical-leak. Any rail returning a variable-height vertical list becomes a `SliverList` row or a fixed-height horizontal. Document each rail's chosen height (e.g. Top Picks 232 dp, charts 208 dp) so U6/U7 copy consistent numbers instead of inventing new ones.
- Hero contract: Play-all and Shuffle keep identical hit targets (min 48 dp), identical `spotifyPlayStyle()`, and identical loading behavior (spinner inside the button, list stays). Never disable the hero while rails load — stale rails + spinner is better than a dead hero.
- Prefetch tuning: keep the 1.5-viewport threshold. If dumps show double-fetch, the cause is `maxScrollExtent` changing mid-frame after new items insert — the single-flight flag in state already guards this; do not add a second debounce timer.
- Skeleton fidelity: skeleton rows mirror real row heights (art 56 + title/subtitle lines) so the swap to content moves zero pixels. If screenshots show a jump, fix the skeleton height first, never animate the swap.
