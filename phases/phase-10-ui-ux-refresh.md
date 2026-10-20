# Cresca UI/UX Optimisation — 10 Phases / 20 Days

Target: `cresca-flutter/` (active rewrite). Native `app/` frozen — no UI work there.
Cadence: 1 phase = 2 days. Day 1 = implement, Day 2 = verify on jam16 emulator + `flutter analyze` + `flutter test`.

Existing system (don't reinvent): `lib/app/design.dart` (Montserrat + Spotify green `1DB954` + Liquid Glass `Glass`/`GlassBar`/`GlassSheetSurface`/`FloatingTabBar`/`MeshBackdrop`), `lib/app/app.dart` 5-tab `_TabStack` + `BottomChromeScope`, `lib/core/motion.dart` kill-switch.

## Phase U1 — Foundation tokens + motion ON (Days 1–2)
**Problem:** `motionOn=false` default (`AppState.motionOn` field + prefs fallback) ships app feeling dead; `BottomChromeScope.legacyClearance=210` fallback causes first-frame overlap; light-theme glass tints drift.
**Touch:** `state.dart`, `design.dart`, `app.dart`, `core/motion.dart`.
- Day 1: default `motionOn=true`; delete `legacyClearance` fallback, use `BottomChromeScope.estimate()` pre-measure; pin light/dark glass alphas + `glassText`/`glassSubtext` as single source (remove ad-hoc `withValues` in screens).
- Day 2: cold-boot on emulator, toggle light/dark/system, screenshot Home + tab bar; verify no overlap on small screen.
**Exit:** motion on by default, zero `bottom: 210` literals (`grep`), light/dark contrast ≥4.5:1 via `textOn`/`subtextOn`.

## Phase U2 — Shell, tabs, mini-player (Days 3–4)
**Problem:** undiscoverable double-tap-Search-focus crutch (`app.dart:200-246`), tab labels `10.5sp` clip at large text scale (`design.dart:682-687`), MiniPlayer red button vs green system (`mini_player.dart`).
**Touch:** `app.dart`, `design.dart:625-862`, `widgets/mini_player.dart`.
- Day 1: replace double-tap hint with visible search affordance (focus ring + persistent hint chip, delete one-time SnackBar); tab labels `maxLines:1` + `AutoSize` floor, keep tint-only selection; MiniPlayer play button → `spotifyPlayStyle()`, swipe L/R keeps glide+snap but add visible chevrons on first 3 loads.
- Day 2: switch tabs 50×, background/foreground, track load/unload; TalkBack pass on tab bar.
**Exit:** no hidden gestures; labels survive 200% text scale; MiniPlayer actions match theme.

## Phase U3 — Home / Listen Now (Days 5–6)
**Problem:** nested `shrinkWrap`+`NeverScrollableScrollPhysics` lists (`screens/home_screen.dart:473`, `library_screen.dart:216,361`, `radio_screen.dart:87`, `search_screen.dart:363`), `addPostFrameCallback` in 5 screens, refresh dissolve only on Home.
**Touch:** `screens/home_screen.dart`, `screens/see_all.dart`, `widgets/track_row.dart`.
- Day 1: Home → single `CustomScrollView` + slivers (header, hero, rails as `SliverToBoxAdapter` with horizontal `ListView`); `StaggerEntrance` cap 8 stays; `see_all.dart` transport errors → surface Retry instead of `[]` (currently swallows).
- Day 2: pull-refresh 10×, offline → Retry, scroll rails to end (prefetch `loadMoreDiscovery` still fires at 1.5 viewports).
**Exit:** no nested scrollables on Home; skeleton → content with no jump (`DelayedSpinner` 300ms kept); offline shows Retry.

## Phase U4 — Full player sheet slimdown (Days 7–8)
**Problem:** `widgets/player_sheet.dart` ~2900 lines — layout + lyrics + video + menu in one file; seekbar/slider gen-token leaks noted in phase-07; volume row + output pill + overflow menu compete.
**Touch:** `widgets/player_sheet.dart` (split only, no redesign), `widgets/track_menu.dart`.
- Day 1: extract-only split: `player_header.dart`, `player_transport.dart` (seek + 3-button + volume), `player_menu.dart` — layout identical except the overflow row gains labels; seekbar: single `Slider` with remaining-time label, cancel gen-token on dispose; move Shuffle/Repeat/Like/Download/Video into one overflow row with labels (discoverable, not hidden).
- Day 2: play/pause/seek 20×, rotate (portrait lock holds), lyrics-expand crossfade, TalkBack on transport (slider announces position).
**Exit:** file <800 lines each, no behaviour change, `flutter analyze` clean, no leaked timers.

## Phase U5 — Queue + Lyrics + Video (Days 9–10)
**Problem:** long-press-drag queue reorder hidden; karaoke scroll fights user scroll (`lyrics_panel.dart`); video sheet 1700+ lines (`video_sheet.dart:1711` semantics only there).
**Touch:** `widgets/queue_sheet.dart`, `widgets/lyrics_panel.dart`, `widgets/video_sheet.dart`.
- Day 1: queue rows get visible drag handles + haptic; lyrics: manual scroll pauses auto-scroll with "Resume" pill (already partial — make explicit); video: quality picker stays, prefetch next kept, add explicit close button + semantics.
- Day 2: reorder 10 tracks + undo; karaoke tap-to-seek 10×; video open/close 10× on low-end emulator (SwiftShader blur check).
**Exit:** reorder discoverable + undo works; lyrics never yank under finger; video closes with one tap.

## Phase U6 — Search / Trending / Radio (Days 11–12)
**Problem:** search debounce + stale results (`state.dart` + phase-06), pager swallows errors (`see_all.dart:256`), radio endless-scroll cards with no end state.
**Touch:** `screens/search_screen.dart`, `screens/trending_screen.dart`, `screens/radio_screen.dart`.
- Day 1: search: cancel stale request on new keystroke (gen-token), cached instant rows first, explicit Empty ("No results for X") + Error+Retry states; radio: end-of-feed footer ("You're all caught up") instead of infinite spinner.
- Day 2: type 20 queries fast, airplane-mode search, scroll each feed to end.
**Exit:** no stale results ever shown; every list has Loading / Content / Empty / Error states.

## Phase U7 — Library / Playlists / Podcasts (Days 13–14)
**Problem:** playlist reorder + undo fragile (phase-06), mosaic header heavy, downloads progress split across banner/sheet/notification (`updates.dart`, `downloads_sheet.dart`).
**Touch:** `screens/library_screen.dart`, `screens/playlist_screen.dart`, `screens/podcast_screen.dart`, `widgets/downloads_sheet.dart`.
- Day 1: single download/progress surface (sheet is source of truth, banner deep-links to it); playlist reorder with Snackbar-Undo; podcast resume + speed/sleep controls get labels (not icon-only).
- Day 2: create/rename/reorder/delete playlist + undo; download 5 tracks, kill app, resume.
**Exit:** one progress UI; destructive actions always undoable; podcast controls labelled.

## Phase U8 — Feedback system: kill silent failures (Days 15–16)
**Problem:** 30+ bare `catch (_){}` in `lib/auth/spotify.dart` alone; sheet-open/logout/share/update failures silent (phase-09 notes).
**Touch:** all `catch (_){}` in `app/`, `auth/`, `data/`; `updates.dart` (`UpdateBannerMotion`, `UpdateProgressShimmer`).
- Day 1: shared `showCrescaToast()` helper (one file, wraps `ScaffoldMessenger`); replace silent catches on user-initiated actions only (open sheet, logout, share, import, install) with toast + log to `crash.dart`; background/prefetch stays silent.
- Day 2: trigger each failure offline; confirm toast every time, no toast spam on background prefetch.
**Exit:** `grep "catch (_) {}"` shows only background paths; every tap gives feedback within 300ms (`DelayedSpinner`).

## Phase U9 — Performance: blur + lists + images (Days 17–18)
**Problem:** 4 live `BackdropFilter` sites (`design.dart:230,260,339,854`) + `MeshBackdrop` wash = heaviest overdraw on low-end; `CachedNetworkImage` with no memo LRU (phase-02); rebuild storms via `AppScope` + `AnimatedBuilder`.
**Touch:** `design.dart`, `core/motion.dart`, `widgets/track_row.dart`, image cache.
- Day 1: cap concurrent blurs to 2 (bar + active sheet only; rows/cards use `TextScrim`, never blur); `MeshBackdrop` static when `motionOn=false` already — extend: freeze wash when sheet settled; `RepaintBoundary` around artwork + `gaplessPlayback` on thumbs; memo LRU for thumbs (phase-02 pattern).
- Day 2: profile on jam16: scroll Home + Library at 120Hz, open player 10×; accept: no jank on first scroll, blur never stacks.
**Exit:** ≤2 active blurs; scroll holds 60fps on emulator; no image flicker on re-scroll.

## Phase U10 — Accessibility + release gates (Days 19–20)
**Problem:** Semantics only in a handful of files; some sheets lack close-button labels/slider announcements; release blockers open (`phases/production-readiness-checklist.md` §§1-3: debug signing, Flutter/native applicationId story, `usesCleartextTraffic=true` with a compat claim to prove, icon/logo assets).
**Touch:** all sheets, `production-readiness-checklist.md`.
- Day 1: every sheet gets labelled Close + `Drag handle` already there; transport slider + speed/sleep sliders announce values; verify 200% text scale + TalkBack on Home → Player → Queue path; fix checklist §1-3 (release signing, single applicationId, cleartext=false unless proven needed, label "Cresca").
- Day 2: full cold-boot → search → play → lyrics → queue → download → update-check pass; `flutter analyze`, `flutter test` green; bump version, tag APK.
**Exit:** TalkBack path complete; checklist §§1-3 signed off; release APK installs side-by-side-free.

---
**Verify each phase:** `cd cresca-flutter && flutter analyze && flutter test` + jam16 release run per the phase's §5. If a phase slips, cut scope, never quality gates.
**Skipped (deliberate):** iOS build, landscape player, server/JAM UI, new features — polish ships first. JAM sheets, Spotify import/sync, YouTube-login WebView, updater flow, and notification/Live-Updates surfaces are explicitly out of scope for U1–U10; they get their own track afterwards.

## Success metrics (the 20 days worked if all four hold)

1. Cold-boot to interactive Home ≤ 8 s failsafe never trips on jam16 release (splash dismisses on readiness, not timeout).
2. Scroll p90 frame time ≤ 32 ms on jam16 release build, Home + Library + queue (DevTools profile, U9 records numbers).
3. Zero silent failures on user-initiated actions (share/logout/import/install/open-sheet all answer ≤300 ms or toast — U8 proves per path).
4. TalkBack golden path (cold-boot → search → play → lyrics → queue reorder → download) completes with zero dead ends (U10 Dump-verified or TalkBack-verified, method stated).

## Execution order

U1 first and alone (shell everyone builds on). U2→U3 sequential (shared shell files). U4–U7 may run parallel on separate sheets. U8–U10 sequential (they touch everything). One branch per phase: `ui-uN-<slug>`.

## Lint baseline

Zero-new-warnings policy: record today's `flutter analyze` output before U1 starts; only NEW warnings block. Old ones are listed, not fixed mid-phase.

## Shared process (normative)

Runbook, copy deck, test matrix T1–T14, sign-off log, and working agreements live in `phases/ui-shared-appendix.md` — phase docs link it instead of copying.

---
Per-phase agent docs (follow in order, emulator check is mandatory in each):
- `phases/ui-u1-foundation.md`
- `phases/ui-u2-shell.md`
- `phases/ui-u3-home.md`
- `phases/ui-u4-player.md`
- `phases/ui-u5-queue-lyrics-video.md`
- `phases/ui-u6-search-trending-radio.md`
- `phases/ui-u7-library.md`
- `phases/ui-u8-feedback.md`
- `phases/ui-u9-performance.md`
- `phases/ui-u10-a11y-release.md`
