# U2 — Shell, Tabs, Mini-Player (Days 3–4)

> Owner: one agent. Depends on: U1 (live clearance, motion ON). Unblocks: U3–U7.
> Goal: no hidden gestures, tab bar survives 200% text scale, MiniPlayer actions match the Spotify-green system.

---

## 1. Why this phase exists

The app shell (`lib/app/app.dart` + `lib/app/design.dart` `FloatingTabBar` + `lib/app/widgets/mini_player.dart`) is the frame every screen lives in. Three defects undermine it:

1. **Undiscoverable search focus.** Double-tap-Search-to-focus is wired with a Tooltip + long-press hint + one-time SnackBar (`app.dart` `_onTab` / `FloatingTabBar` wrapper). A hidden gesture that needs three overlapping hints is a failed gesture — first-time users never find it.
2. **Tab labels clip at large text scale.** `FloatingTabBar` pins labels to `labelSmall 11 SB` with a `10.5` compact override (`design.dart` label block) because Montserrat runs wide. At 200% text scale the five labels (`Listen Now / Trending / Radio / Library / Search`) truncate or clip against the 25 dp icons. The tint-only selection rule (no pill indicator) is correct iOS behavior and stays — legibility must come from layout, not a redesign.
3. **MiniPlayer speaks the wrong color.** The play button renders Cresca red while every other primary action in the app uses `spotifyPlayStyle()` (green pill, black glyph). Users learn green = go; a red play button reads as record/stop. Swipe L/R (next/prev glide + snap-back + peek chevrons) works but is also undiscoverable on first run.

Fix the frame now; U3–U7 build screens inside it.

---

## 2. Current-state map

| File | Owns | Notes |
|---|---|---|
| `lib/app/app.dart` | `CrescaApp`, 5-tab `_TabStack` (mounted, Offstage + ExcludeSemantics, fade + 12 px rise, enter 220 ms / exit 180 ms), bottom chrome overlay (MiniPlayer above `FloatingTabBar`), `BottomChromeScope` publishing, splash + intro overlay, double-tap-search logic | Tabs never unmount — scroll state survives switches. Keep it. |
| `lib/app/design.dart` (`FloatingTabBar`) | Full-bleed Apple-glass bar, `ClipRect`-bounded `BackdropFilter` (sigma 24, static), tint-only selection (color + 4 dp dot), `TweenAnimationBuilder` tint lerp, `AnimatedDefaultTextStyle` labels, `AnimatedOpacity` dot | Compositor rule: `BackdropFilter` must NOT sit under `ClipRRect` (jam16 paint-bisect). Keep `ClipRect` + `RepaintBoundary`. |
| `lib/app/widgets/mini_player.dart` | Swipe `_dx` ValueNotifier (rebuilds offset transform only), tap opens `openPlayerSheet`, equalizer bars, progress bar, loading/error states | `AppScope` never re-notifies (mutable singleton) — widgets subscribe to `ChangeNotifier` directly via `AnimatedBuilder`. Keep that pattern. |

Do not change: tab order, 5-tab set, mounted-stack retention, glass material recipe, motion durations.

---

## 3. Design decisions and non-goals

- Search focus becomes visible: one hint chip replaces the Tooltip/long-press/SnackBar trio. No new tutorial screens.
- Tab bar keeps tint-only selection, full-bleed glass, no pill. Fix is layout (ellipsis), not style.
- MiniPlayer adopts `spotifyPlayStyle()`. Cresca red stays brand-only (splash/logo).
- Peek chevrons show on first 3 MiniPlayer appearances, then never again. In-memory counter, no settings flag.

---

## 4. Day 1 — Implementation

### Step 1 — Visible search affordance (1–2 h)
1. Replace the existing trio (Tooltip + long-press hint + one-time SnackBar in `_onTab`/`FloatingTabBar` wrapper) with a single visible affordance: a hint chip on the Search tab ("Tap to type") with `PressScale`, visible until the search field first gains focus, then dismissed for the session (session flag in `AppState`, not persisted). Delete the SnackBar timer path once the chip lands — never both at once.
2. Search field itself gets a focus ring: `InputDecorator` focused border in `spotifyGreen`, plus `autofocus: false` (never steal focus on tab switch — that breaks screen-reader flow).
3. Acceptance: a first-time user can discover search without tapping twice or reading a tooltip.

### Step 2 — Tab labels at 200% scale (1–2 h)
1. Keep `labelBase` derivation from theme (`labelSmall 11 SB` → 10.5 compact). Guarantee layout: `Expanded` per item, icon 25 dp fixed, label `maxLines:1` + `softWrap:false` + `overflow:ellipsis`. At 200%, labels ellipsize rather than overflow or clip — screen readers still announce the full `Semantics(label:)`.
2. Keep selection animation exactly as-is (`TweenAnimationBuilder` color lerp + `AnimatedDefaultTextStyle` + dot `AnimatedOpacity`, duration from `motion.tabExitMs`). Do not animate `fontSize` (relayout every frame — banned in the `FloatingTabBar` comments).
3. Unselected color stays full `onSurfaceVariant` (no dimming alpha — 0.65 alpha measured ~3:1 over glass and failed AA).

### Step 3 — MiniPlayer green action + chevron onboarding (1 h)
1. Play/pause button → `spotifyPlayStyle()` (green pill, black glyph, `FilledButton`).
2. Keep swipe: `_dx` ValueNotifier + `ValueListenableBuilder` transform, glide + snap-back, threshold ~64 dp to trigger next/prev. Add: on first 3 appearances, overlay peek chevrons (`Icons.chevron_left/right`, `onSurfaceVariant` 50%) that fade after 1.2 s. Counter in memory; never persist.
3. Keep loading/error states (spinner / retry) and progress bar. Progress bar color: `spotifyGreen` when trackable, `onSurfaceVariant` when indeterminate.

### Step 4 — Self-check
- `flutter analyze` clean.
- `grep -rn "_lastSearchTap" lib/app/app.dart` — expect zero (timer path deleted).
- `grep -rn "spotifyPlayStyle" lib/app/widgets/mini_player.dart` — present.

---

## 5. Day 2 — Verification + mandatory emulator check

### 5.1 Static gates
```powershell
cd cresca-flutter
C:\Android\flutter\flutter\bin\flutter.bat analyze
C:\Android\flutter\flutter\bin\flutter.bat test
```

### 5.2 Emulator check (jam16)
1. Boot if needed (`emulator.exe -avd jam16 -no-snapshot-load` in background; `getprop sys.boot_completed` → 1).
2. Fresh `build apk --release` + `install --release -d emulator-5554`. Read Gradle errors if any.
3. Launch `com.cresca.cresca_app/.MainActivity`, sleep 12, `pidof` + logcat FATAL scan.
4. Screenshots (light + dark via `cmd uimode night yes/no`): (a) full tab bar close-up, (b) Search tab with hint chip, (c) MiniPlayer with track loaded. Note: streams may 403 on emulator — load a cached/recent track or verify MiniPlayer empty-state layout; UI presence is the check, not audio.
5. `uiautomator dump` checks:
   - 5 tabs each expose `content-desc` (Listen Now, Trending, Radio, Library, Search).
   - Search hint chip node present on first launch, absent after first search focus.
   - MiniPlayer play/pause node has content-desc; swipe chevrons present on first 3 shows.
6. Text-scale stress: emulator Settings → Accessibility → font size largest + display size large. Confirm: no label overflow exception, no tab-bar height growth covering content (clearance from U1 absorbs it), ellipsis where needed.
7. Switch tabs 20× rapidly, background/foreground once, load/unload track (MiniPlayer appear/disappear) — no stuck fade, no ghost chrome.

### 5.3 Limits
Emulator 403s, generic seeds on fresh profile, no tap injection (dumps only). Clean up PNG/XML afterward.

---

## 6. Edge cases

| Symptom | Cause | Fix |
|---|---|---|
| Hint chip reappears every launch | Flag persisted as false / reset in `init` | Session-only flag, set on first focus |
| Search steals focus on tab switch | `autofocus: true` left in | `autofocus: false`; focus only on explicit tap |
| Labels overlap icons at 200% | Fixed-height row too short | Row height wraps content; clearance absorbs growth |
| Chevron never hides | Counter persisted / not incremented | In-memory counter, increment on each show |
| Red button returns | Hardcoded color in MiniPlayer copy | Route all primary actions through `spotifyPlayStyle()` |

---

## 7. Exit criteria
- [ ] Zero hidden-gesture code (no double-tap timer, no one-time SnackBar, no Tooltip-as-tutorial).
- [ ] 200% scale: 5 labels visible with ellipsis, no overflow errors in logcat.
- [ ] MiniPlayer green action; chevrons auto-hide after 3 shows.
- [ ] `analyze` + `test` green; launch clean.

## 8. Rollback
Restore old MiniPlayer color in one hunk if green fails contrast on any theme. Keep label + chip fixes regardless.

## 9. Handoff to U3
U3 assumes the shell is stable. Report: chip dismissal behavior, 200%-scale screenshots, MiniPlayer measured heights with/without chevrons.

---

## 10. Shared process (normative)
Runbook, copy deck, test matrix (T1–T14), sign-off log, working agreements, and branching rules live in `phases/ui-shared-appendix.md` and are not copied here. Follow that file for process; this doc owns scope. Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder — guard with `context.mounted`.
