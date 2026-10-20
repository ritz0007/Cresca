# UI Refresh — Shared Appendix (normative for U1–U10)

This file owns the runbook, copy deck, test matrix, sign-off log, and working agreements. Phase docs link here instead of copying. If this file and a phase doc disagree, this file wins for process (how to verify) and the phase doc wins for scope (what to build).

## A — Agent runbook (follow exactly, in order)

A1. Sync: `git pull --rebase`, `cd cresca-flutter`, `flutter pub get`. Record the commit hash at the top of your work log.
A2. Read the two files you will touch most end to end before editing (no skim-driven edits). Note existing `Semantics`, `RepaintBoundary`, `motionOn` gates you must preserve. Cite symbols (`AppState.motionOn`, `BottomChromeScope.clearanceOf`), never line numbers — lines rot, names don't.
A3. Implement Day 1 steps in the listed order. After each step run `flutter analyze` on the touched files — do not batch three steps then debug the union.
A4. Write or update the widget/golden test that pins the new behavior (states, tokens, undo, labels). If no test harness covers the surface, add a minimal `test/` case asserting the state machine (loading/content/empty/error) rather than pixels.
A5. Day 2 morning: full `flutter analyze && flutter test`. Baseline: the overview records today's lint output; only NEW warnings block. Never add `// ignore:` without a `shortcut:` comment (`shortcut: <limit>, <when to upgrade>`).
A6. Day 2 midday: emulator pass per the phase's §5 (fresh release build, never cached). Capture every screenshot and dump listed; missing artifacts = phase incomplete.
A7. Day 2 evening: fill the sign-off log (§D), update CHANGELOG line, push the branch, file the handoff note for the next phase.

## B — Copy deck (exact strings, do not paraphrase)

- Loading: no copy (spinner only, `DelayedSpinner` 300 ms). Never a "Loading…" toast.
- True empty: "No results for '<query>'" / "Nothing here yet" + one action ("Browse trending", "Import playlists").
- Transport error: "Couldn't load '<scope>' — check connection" + [Retry]. Inline variant when stale rows remain: "Couldn't refresh — showing saved rows" + [Retry].
- Destructive undo: 'Removed "<title>"' + [Undo 5 s]. Download-delete variant: 'Deleted "<file>" — needs re-download' + [Undo].
- Toasts: "Could not open <sheet> — Retry", "Signed out", "Couldn't share — try again", "Import paused — will resume", "Update check failed — Retry".
- Terminal footers: "You're all caught up". Resume pill: "Resume". Close buttons: "Close <sheet>".

## C — Test matrix (all rows must pass on jam16)

| # | Case | Steps | Expect |
|---|---|---|---|
| T1 | Cold boot | Force-stop, launch, 12 s | Splash → content, no FATAL, skeleton no-jump |
| T2 | First-frame clearance | Fresh launch, dump | Last row above tab bar (estimator holds) |
| T3 | Light/dark | `uimode night yes/no` + screencap | Contrast legible, glass intact, labels readable |
| T4 | 200% text | Largest font + large display | Ellipsis, no overflow exception, Close reachable |
| T5 | Airplane on | Enable, exercise surface | Error/Retry states, toasts where specified, zero spam from background |
| T6 | Airplane off + Retry | Disable, tap Retry | Content returns, single-flight (no duplicate pages) |
| T7 | Rapid stress | 10 fast queries / 20 tab switches / 10 seeks | Only latest paints, no stuck fade, no post-dispose `setState` |
| T8 | Kill + relaunch | `force-stop` mid-download/reorder | State resumes or honest Retry; no corruption |
| T9 | TalkBack/dump | Dumps per screen | Every interactive node labelled; inactive tabs excluded |
| T10 | Release only | `build apk --release` + `install --release`, retest | No ANR, no blank rows, no stacked-blur stutter |
| T11 | Download resume | Start 2 downloads, `force-stop`, relaunch | Resume/complete, sheet + banner agree |
| T12 | Library Undo | Delete/reorder playlist, unlike, clear recent | Each undoable ≤5 s with accurate copy |
| T13 | Auth wipe | Logout (online + offline) | Complete wipe (cookies + secure storage + memory), clean login screen |
| T14 | Offline playback | Airplane on, play downloads | Plays offline-first, no stream attempt |

## D — Sign-off log (paste into the PR)

```
Phase: Ux (dates)
Commit: <hash> | flutter analyze: clean (new warnings: none) | flutter test: green (n tests)
Emulator: jam16 release build <apk> | pid live | FATAL: none
Screenshots: <list .png captured + previewed + deleted>
Dumps: <list .xml> | content-desc audit: pass/fail
T1..T14 (run applicable rows): pass/fail each with notes
Deviations from phase doc (with reason):
Carryover to next phase:
```

## E — Working agreements

- Smallest diff that fully solves the phase. No refactors outside the listed files; no new dependencies (a new package needs its own phase proposal).
- Never commit APKs, `build/` output, pulled PNG/XML, or secrets. Clean the repo root before pushing.
- Never animate blur sigma, `fontSize`, or layout constraints per frame — transform/opacity only. Never add `BackdropFilter` without removing one elsewhere.
- Every `catch` either toasts+logs (user path) or carries the `// silent: background …` comment (system path). Bare `catch (_) {}` with neither is a defect.
- If a step contradicts the live code (renamed file, moved logic), trust the code, do the equivalent fix, and note the deviation in the sign-off log.
- Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder or after navigation — guard with `context.mounted`.
- One branch per phase: `ui-uN-<slug>`. U1 first and alone (it changes the shell everyone builds on). U2→U3 sequential (shared shell files). U4–U7 may run parallel on separate sheets. U8–U10 sequential (they touch everything).
- Perf claims need numbers: `flutter run --profile`, DevTools performance view, p90 frame time + worst frame per screen. Eyeballing is not a pass.
