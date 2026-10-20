# U1 — Foundation Tokens + Motion ON (Days 1–2)

> Owner: one agent. Depends on: nothing. Unblocks: U2–U10.
> Goal: ship an app that feels alive on first boot — motion on by default, no first-frame overlap under the bottom chrome, one source of truth for glass tints and text colors.

---

## 1. Why this phase exists

Three foundation bugs make every later UI phase look broken even when it is correct:

1. **Motion ships OFF.** `AppState.motionOn` in `cresca-flutter/lib/app/state.dart` defaults `false` (field plus the prefs fallback `prefs?.getBool(motionPrefKey) ?? false`). Every entrance (`FadeSlide`, `StaggerEntrance`, `SheetEntrance`), press scale, tab crossfade, and `MeshBackdrop` drift reads the kill-switch in `lib/core/motion.dart` (`motionMs`, `motionDouble`). With the flag off, the app renders instantly but feels dead — splash flashes, tabs snap, sheets pop. The design system in `lib/app/design.dart` was tuned motion-ON (220 ms enter / 180 ms exit / 40 ms stagger / 320 ms sheet). Reviewers testing U2–U9 with motion off will misjudge timing, and the CHANGELOG already flags this mismatch.
2. **Chrome clearance is a magic constant.** Screens pad lists with `bottom: 210`. The real chrome height varies: `FloatingTabBar` (~76 dp) + `MiniPlayer` (~68 dp, only when a track is loaded) + system gesture inset (varies by device). `BottomChromeScope` in `lib/app/app.dart:81-135` already measures the chrome Column post-frame and publishes `clearanceOf(context)`, but most screens still use the literal, and pre-measure falls back to `legacyClearance = 210`. On small screens / first frame before measurement, the last list row hides under the tab bar or floats with a gap.
3. **Glass + text tokens drift.** `Glass` / `GlassBar` / `GlassSheetSurface` in `design.dart` pin alphas per brightness, but several screens add their own `withValues(alpha: …)` overlays. Light-theme glass then washes out secondary text (`onSurfaceVariant` over mid translucency fails AA — noted in `GlassSheetSurface` docs). Text helpers `textOn` / `subtextOn` / `AdaptiveText` / `TextScrim` / `glassText(dark)` / `glassSubtext(dark)` already guarantee ≥4.5:1; screens must use them instead of hand-rolled colors.

User impact: first-launch overlap + dead motion = "app feels broken" in the first 10 seconds. Fix once here, never revisit.

---

## 2. Current-state map (read before touching)

| File | Owns | Do not touch in U1 |
|---|---|---|
| `lib/app/state.dart` | `AppState` ChangeNotifier, `motionOn`, `homeStatus`, `topPicks`, `rails`, `loadHome()`, `loadMoreDiscovery()` | Home loading logic, queue, downloads |
| `lib/app/app.dart` | `AppScope`, `BottomChromeScope`, `CrescaApp`, 5-tab `_TabStack` (Offstage + ExcludeSemantics), chrome measurement, splash (1200 ms hold, 8 s failsafe), double-tap-search | Tab order, splash copy |
| `lib/app/design.dart` | `crescaTheme()`, `Glass`, `GlassBar`, `GlassSheetSurface`, `FloatingTabBar`, `PressScale`, `DelayedSpinner`, `FadeSlide`, `SheetEntrance`, `textOn`/`subtextOn`, `TextScrim` | Component APIs — only adjust alpha constants |
| `lib/core/motion.dart` | `motionMs(on, ms)`, `motionDouble(on, v)`, `pressMs`, `sheetEnterMs`, `tabExitMs`, `shimmerMs` | Duration values |

Key patterns to preserve:
- Motion off must still work (accessibility / low-end): `motionMs(false, x)` → 1 ms step, except splash crossfade floor 150 ms (`_splashMinFadeMs` in `app.dart`).
- `BottomChromeScope.clearanceOf(context)` never throws; returns measured height once known.
- `DelayedSpinner` reserves size from frame one, fades in after 300 ms — no layout jump.

---

## 3. Design decisions and non-goals

- Motion default becomes `true`. The kill-switch stays for users who need it (settings toggle untouched).
- No new color tokens. Spotify green `0xFF1DB954` actions, Cresca red `0xFFFA243C` brand-only, `onSurfaceVariant` secondary. If a screen needs a new color, it is out of scope — flag it for U8.
- No per-screen glass redesign. U1 only pins alphas and replaces ad-hoc overlays with shared helpers.
- `legacyClearance` is deleted, not deprecated. Keeping it invites regressions via copy-paste.

---

## 4. Day 1 — Implementation (step by step)

### Step 1 — Motion default ON (15 min)
In `lib/app/state.dart`, change the `motionOn` field default to `true` AND the prefs fallback to `true` (returning users otherwise keep the old `false` forever — this is a one-time migration, not just a default):
```dart
// before
bool motionOn = false;
// after
bool motionOn = true;
```
Check for any test or settings seed that forces `false`:
```
grep -rn "motionOn" cresca-flutter/lib cresca-flutter/test
```
Update seeds/fixtures that assert the old default. Keep the settings toggle writing through to the same field so users can still opt out.

### Step 2 — Kill `bottom: 210` (2–3 h, the bulk of U1)
1. Find every literal:
   ```
   grep -rn "bottom: 210\|legacyClearance\|clearanceOf" cresca-flutter/lib/app/screens cresca-flutter/lib/app/widgets
   ```
2. For each screen (`home_screen.dart`, `library_screen.dart`, `search_screen.dart`, `radio_screen.dart`, `trending_screen.dart`, `see_all.dart`, `playlist_screen.dart`, `podcast_screen.dart`):
   - Replace bottom padding with the live value:
     ```dart
     // before
     padding: const EdgeInsets.only(bottom: 210),
     // after
     padding: EdgeInsets.only(
       bottom: BottomChromeScope.clearanceOf(context),
     ),
     ```
   - If the screen builds padding outside a `BuildContext` with scope access (e.g. inside a helper), thread `context` through or read clearance at the build root and pass it down. Never cache it in a field — chrome height changes when MiniPlayer appears/disappears.
3. In `app.dart`, replace the `legacyClearance` fallback with the estimator:
   ```dart
   double get clearance =>
       chromeHeight > 0
           ? chromeHeight
           : estimate(bottomInset: bottomInset, hasTrack: hasTrack);
   ```
   Delete `static const double legacyClearance = 210.0` once no caller references it. `grep` must return zero hits.
4. Verify the measurement path: `_CrescaAppState` measures the chrome Column post-frame and publishes via `BottomChromeScope`. Do not add a second measurement pass. If the first frame still overlaps, the estimator (inset + 76 + optional 68) covers it — do not reintroduce a magic constant.

### Step 3 — Pin glass + text tokens (1–2 h)
1. In `design.dart`, confirm `Glass` tint/rim/shadow, `GlassBar` gradient, `GlassSheetSurface` stops are the only alpha definitions. Adjust light-theme alphas only if body text over glass measures <4.5:1 (use `textOn`/`subtextOn` helpers to check, not eyeballing).
2. Sweep screens for hand-rolled glass colors:
   ```
   grep -rn "withValues(alpha" cresca-flutter/lib/app/screens cresca-flutter/lib/app/widgets
   ```
   Replace with:
   - Primary text on glass → `glassText(dark)` or `AdaptiveText(data:…, background:…)`.
   - Secondary text → `glassSubtext(dark)` with `subtextOn(bg)` fallback.
   - Text over artwork/photos → wrap in `TextScrim` (static gradient, no blur).
3. Delete any `Container(color: Colors.white…)` solid fills masquerading as glass — Axiom rule: glass is translucent material + blur, never a solid fill.

### Step 4 — Self-check before commit
- `cd cresca-flutter && flutter analyze` clean.
- `grep -rn "210" lib/app/screens` returns nothing meaningful.
- Light + dark theme compile (no hardcoded `Colors.white` text on light glass).

---

## 5. Day 2 — Verification + mandatory emulator check

### 5.1 Static gates
```powershell
cd cresca-flutter
C:\Android\flutter\flutter\bin\flutter.bat analyze
C:\Android\flutter\flutter\bin\flutter.bat test
```

### 5.2 Emulator check (jam16 — do not skip)
Tool paths: ADB `C:\Android\sdk\platform-tools\adb.exe`, emulator `C:\Android\sdk\emulator\emulator.exe`, AVD `jam16`, app id `com.cresca.cresca_app`, workdir `cresca-flutter/`.

1. **Boot** (only if `adb devices` is empty). Run in background, do not poll in a loop:
   ```powershell
   C:\Android\sdk\emulator\emulator.exe -avd jam16 -no-snapshot-load
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 shell getprop sys.boot_completed
   # expect 1
   ```
2. **Fresh build + install** (never trust a cached APK):
   ```powershell
   cd cresca-flutter
   C:\Android\flutter\flutter\bin\flutter.bat build apk --release
   C:\Android\flutter\flutter\bin\flutter.bat install --release -d emulator-5554
   ```
   If Gradle fails, read the error output first — do not retry blindly.
3. **Launch + crash check:**
   ```powershell
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 shell am start -n com.cresca.cresca_app/.MainActivity
   Start-Sleep -Seconds 12
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 shell pidof com.cresca.cresca_app
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 logcat -d | Select-String -Pattern "FATAL EXCEPTION.*cresca|E/flutter"
   ```
   Live pid + no FATAL = clean launch.
4. **Screenshots (light + dark):**
   ```powershell
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 shell screencap -p /sdcard/u1-light.png
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 pull /sdcard/u1-light.png u1-light.png
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 shell cmd uimode night yes
   Start-Sleep -Seconds 5
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 shell screencap -p /sdcard/u1-dark.png
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 pull /sdcard/u1-dark.png u1-dark.png
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 shell cmd uimode night no
   ```
   Show each PNG with `browser.preview`. Delete local copies after (`Remove-Item u1-*.png`) so they never pollute the repo.
5. **Structure check** (no tap injection — `/dev/input` denies it; use dumps):
   ```powershell
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 shell uiautomator dump /sdcard/u1.xml
   C:\Android\sdk\platform-tools\adb.exe -s emulator-5554 pull /sdcard/ui.xml u1.xml
   ```
   Parse `content-desc`: 5 tabs present, Home rails present, last list item bounds sit above tab-bar bounds (no overlap). Force-stop and relaunch once to confirm first-frame clearance via estimator.
6. **Motion sanity:** tabs crossfade + rise, sheets slide + fade, press scales respond. Toggle motion off in settings → everything collapses to instant steps with no crash.

### 5.3 Known emulator limits (say out loud in the report)
- YouTube streams return HTTP 403 on emulator IPs — "unavailable" here does NOT mean broken code. Confirm streams on a real phone.
- Fresh emulator profile has no recents/likes → taste rails fall back to generic seeds. That is expected.
- Clean up pulled PNG/XML/helper scripts from the repo root.

---

## 6. Edge cases and failure catalogue

| Symptom | Cause | Fix |
|---|---|---|
| Last row hidden under tab bar on first frame | Screen still uses literal / scope missing | Thread `BottomChromeScope.clearanceOf(context)` from build root |
| Gap above tab bar after MiniPlayer dismisses | Clearance cached in a field | Read live every build; never store |
| Light-theme secondary text unreadable | Ad-hoc alpha over glass | Use `glassSubtext(dark)` / `subtextOn(bg)` |
| Splash flashes with motion off | 1 ms fade | Keep `_splashMinFadeMs = 150` floor |
| Tests assert `motionOn == false` | Old seed | Update fixture to `true` |

---

## 7. Exit criteria (sign-off checklist)
- [ ] `motionOn` defaults `true`; opt-out toggle still works.
- [ ] Zero `210` / `legacyClearance` references in `lib/`.
- [ ] Light + dark screenshots legible; body text ≥4.5:1.
- [ ] `analyze` + `test` green; emulator launch clean (pid + no FATAL).
- [ ] Dumps confirm no overlap on first frame and after MiniPlayer toggle.

## 8. Rollback
Revert the `motionOn` default only. Keep the clearance fix — overlap is worse than stillness. If glass alphas regress legibility, revert that hunk separately.

## 9. Handoff to U2
U2 assumes live clearance + motion ON. Report: (a) measured chrome heights on jam16 (with/without MiniPlayer), (b) any screen that needed context threading, (c) final glass alpha values.

---

## 10. Shared process (normative)
Runbook, copy deck, test matrix (T1–T14), sign-off log, working agreements, and branching rules live in phases/ui-shared-appendix.md and are not copied here. Follow that file for process; this doc owns scope. Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder — guard with `context.mounted`.
