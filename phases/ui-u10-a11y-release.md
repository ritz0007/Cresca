# U10 — Accessibility + Release Gates (Days 19–20)

> Owner: one agent. Depends on: U1–U9 (all surfaces final). Unblocks: release.
> Goal: TalkBack completes Home → Player → Queue with no dead ends; release blockers in `production-readiness-checklist.md` §§1–3 signed off; version bumped and APK tagged.

---

## 1. Why this phase exists

Two failure classes remain, and both block shipping:

1. **Accessibility is partial.** `Semantics` exists in only six places (`design.dart`, `app.dart` tab stack, `mini_player`, `player_sheet`, `lyrics_panel`, `search_screen:371`, `video_sheet:1711`). Sheets lack close-button labels, transport/speed/sleep sliders don't announce values, tab labels clip at large scale (U2 mitigates layout; announcements still need audit). An app that blind users cannot operate is unfinished regardless of visuals.
2. **Release gates are open.** `phases/production-readiness-checklist.md` §§1–3 list ship-blockers: debug signing key, the Flutter/native applicationId story (`com.cresca.cresca_app` vs `com.cresca.app` side-by-side — deliberate today, must be explicitly re-confirmed, not silently renamed), `usesCleartextTraffic=true` (kept for CDN/artwork compat per the manifest comment — must be proven host-by-host), adaptive icon / logo assets. Shipping U1–U9 polish on a debug-signed, cleartext-permitting APK wastes the entire 20 days.

U10 is the gate. Nothing merges after it without re-running its pass.

---

## 2. Current-state map

| Area | Files | Status from prior phases |
|---|---|---|
| Sheets chrome | `player_sheet`, `queue_sheet`, `video_sheet`, `track_menu`, `audio_output_sheet`, `audio_pipeline_sheet`, `downloads_sheet`, `jam_sheet`, `session_sheet`, `profile_sheet` | U4/U5/U7 gave Close buttons, handles, labels — U10 verifies announcements |
| Tab stack | `app.dart` `_TabStack` (Offstage + ExcludeSemantics), `design.dart` `FloatingTabBar` labels | U2 layout fix; U10 verifies tree |
| Sliders | Player seek/transport (U4), speed/sleep (U7) | Labels exist; values need announcement audit |
| Toasts | `cresca_toast.dart` (U8) | Need `liveRegion` where appropriate |
| Release | `AndroidManifest.xml`, `app/build.gradle`, signing config, checklist | Open — closed in U10 |
| Version | `pubspec.yaml` (`2.0.0+22` family), `CHANGELOG.md` | Bumped in U10 |

---

## 3. Design decisions and non-goals

- Full TalkBack path coverage, not exhaustive audit of every string. Path: cold-boot → search → play → lyrics → queue reorder → download → update-check. Every interactive node on this path gets role + label + value where applicable.
- No new features, no copy rewrite beyond labels. Release fixes are config-only except the appId migration (which needs an install-migration note).
- Text-scale bar: 200% font + large display. Ellipsis allowed, clipping/overflow exceptions are defects.

---

## 4. Day 1 — Implementation

### Step 1 — Sheet semantics sweep (2 h)
For EVERY sheet, verify all three exist:
1. Labelled Close:
   ```dart
   Semantics(
     button: true,
     label: 'Close <sheet name>', // e.g. 'Close queue', 'Close video'
     child: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
   )
   ```
2. `SheetGrabHandle` present (already `Semantics(label: 'Drag handle', container: true)` — confirm, don't duplicate).
3. All icon-only buttons carry `Semantics(label:)` or `IconButton(tooltip:)` (tooltip populates the a11y label — either is acceptable, pick one per file and be consistent).
Checklist per sheet: close, grab handle, primary actions, transport/slider if present, retry/error actions (U3/U6/U8 states must also announce — `ErrorRetry` button labelled "Retry", empty states not focusable traps).

### Step 2 — Sliders announce values (1 h)
- Player seek: `Slider(semanticFormatterCallback: (v) => '${formatTime(v)} of ${formatTime(total)}')` + `Semantics(label: 'Seek', value:)`. TalkBack reads position while scrubbing (U4 slider + this formatter).
- Podcast speed: `Semantics(label: 'Playback speed', value: '1.5x')`; sleep: `value: '20 minutes'` / `'Off'`. Update on every engine change (same notifier as the U7 visible label — one source).
- Toasts: error/success toasts get `liveRegion: true` semantics so TalkBack announces them once; loading spinners keep `Semantics(label: 'Loading', liveRegion: true)` via `DelayedSpinner` (already built — confirm wired).

### Step 3 — Tab stack + text scale (1 h)
1. Confirm inactive tabs remain `ExcludeSemantics` (only the visible tab + exiting mid-fade in the tree). MiniPlayer + tab bar always exposed with `button` roles and full labels (U2 content-desc work — re-verify after U4–U9 edits).
2. 200% scale pass on the golden path screens: tab labels (ellipsis OK), track rows (title ellipsizes, duration visible), podcast controls (labels wrap, never clip), sheets (Close stays reachable without horizontal scroll). Fix with `Expanded`/`Flexible` + `maxLines:1` + ellipsis — never `TextScaler.linear(1.0)` pinning.

### Step 4 — Release gates §§1–3 (2 h)
Work through `production-readiness-checklist.md` §§1–3 line by line:
1. **Signing:** release keystore, no debug key in release builds. Verify `flutter build apk --release` signs with release key (`apksigner verify --print-certs`); document fingerprint location (never commit the keystore password — reference the secret store).
2. **applicationId: DO NOT RENAME.** Flutter ships `com.cresca.cresca_app`; `com.cresca.app` is the stable native app (see CHANGELOG side-by-side note). Renaming Flutter to the native ID would collide on user phones. U10's job is to re-confirm the checklist decision (keep side-by-side / unify with migration plan), never to silently rename. No release under either id until the checklist owner signs the row.
3. **Cleartext:** `usesCleartextTraffic` is currently `true` with a manifest comment claiming CDN/artwork compat. Prove it host-by-host (list the HTTP-only hosts with reasons) or flip to `false`. Verify lyrics/podcast/update hosts all HTTPS either way.
4. **Label/icon:** manifest label is already "Cresca Music" — verify, don't rename. Check adaptive icon on API 26–35 and dark/light logo assets (`assets/logo_light.png` / `assets/logo_dark.png`).
5. **Version:** bump `pubspec.yaml` + `CHANGELOG.md` entry summarizing U1–U10 user-visible changes (motion on, discoverable reorder, honest errors, undo, a11y). Tag the APK (`Cresca-<ver>-<abi>.apk` convention per README).

### Step 5 — Self-check
- `grep -rn "ExcludeSemantics" lib/app/app.dart` present; `grep -rn "Close " lib/app/widgets/*.dart` covers all sheets.
- `grep -rn "usesCleartextTraffic" android/` → `false` or absent.
- `flutter analyze` clean.

---

## 5. Day 2 — Full verification + mandatory emulator check

### 5.1 Static gates
```powershell
cd cresca-flutter
C:\Android\flutter\flutter\bin\flutter.bat analyze
C:\Android\flutter\flutter\bin\flutter.bat test
```

### 5.2 Emulator check (jam16) — the full pass
1. Boot if needed. Fresh RELEASE build with the CONFIRMED appId + release signing; `install --release -d emulator-5554`. Confirm install shows ONE Cresca launcher entry for the Flutter id (the native `com.cresca.app` is a different app — do not uninstall it as "duplicate").
2. Launch `com.cresca.cresca_app/.MainActivity`, sleep 12, `pidof com.cresca.cresca_app` + logcat FATAL scan.
3. Screenshots light + dark, all four: Home, Player, Queue, Library. Preview each, delete after.
4. `uiautomator dump` per screen; automated audit:
   - Zero interactive nodes with empty/missing `content-desc` (scan dumps for `clickable=true` + `content-desc=""`).
   - Close buttons, sliders (with values), tabs, handles, Retry buttons all labelled.
   - Inactive-tab content absent from the tree (ExcludeSemantics holds).
5. Golden-path run: cold-boot → search → play (cached; 403 streams are env noise) → lyrics expand → queue reorder + Undo → download start → update-check. Enable TalkBack for one run if available on the emulator image (`Settings → Accessibility → TalkBack`); otherwise dump-verify each step's labels. Either way, report which method was used.
6. Text-scale run: largest font + large display → repeat golden path → no overflow exceptions in logcat, no horizontally-scrolling sheets, Close always reachable.
7. Update the checklist file: mark §§1–3 signed with date + APK name + `apksigner` fingerprint line.

### 5.3 Limits
Emulator TalkBack availability varies by image — dump verification is an acceptable substitute, but say so explicitly. 403s/genuine-seed limits from U1 still apply. Clean up ALL artifacts (PNG/XML/test downloads).

---

## 6. Edge cases

| Symptom | Cause | Fix |
|---|---|---|
| TalkBack dead-ends in a sheet | Close not labelled / focus trapped | Labelled Close + grab handle; error states focusable in order |
| Slider announces raw 0.0–1.0 | Missing formatter | `semanticFormatterCallback` + `value` on every slider |
| Duplicate app icons | Stale install of the other variant id | Uninstall the variant under test only; release notes name the supported id |
| Cleartext exception needed | One HTTP host | Pin exception to that host with reason comment; default stays false |
| Toast never announced | No live region | `liveRegion: true` on status toasts; keep loading spinners' existing announcement |

---

## 7. Exit criteria (release gate)
- [ ] Golden path completes with TalkBack (or dump-verified with method stated), zero dead ends.
- [ ] 200% scale: no overflow errors, Close reachable everywhere.
- [ ] Checklist §§1–3 signed; single appId; release-signed APK; label/icon correct.
- [ ] `analyze` + `test` green; version bumped; APK tagged.

## 8. Rollback
AppId: there is no rename to roll back — if the checklist decision ever changes, it needs its own migration plan, not a revert. A11y labels never revert — they are pure additions with no visual cost.

## 9. Ship it
Report: APK name + version, `apksigner` cert line, TalkBack method used, checklist diff, and any carryover for the next cycle (which must start with its own U1-style foundation check, not assumed green).

---

## 10. Shared process (normative)
Runbook, copy deck, test matrix (T1–T14), sign-off log, working agreements, and branching rules live in phases/ui-shared-appendix.md and are not copied here. Follow that file for process; this doc owns scope. Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder — guard with `context.mounted`.
