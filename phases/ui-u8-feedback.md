# U8 — Feedback System (Days 15–16)

> Owner: one agent. Depends on: U4–U7 (all user actions exist). Unblocks: U10 (a11y announces these).
> Goal: every tap answers within 300 ms; zero silent failures on user-initiated work.

---

## 1. Why this phase exists

The codebase catches generously and tells the user nothing. `lib/auth/spotify.dart` holds 30+ bare `catch` clauses; `app.dart` wraps even `setState` in silent catches; sheets, share, update, and import paths fail without a word. Result: taps that do nothing, logouts that half-wipe, shares that silently fail, updates that stall — and users who assume the app is frozen and force-stop it, corrupting the very state that failed.

Background work (prefetch, discovery paging, palette swaps) must stay silent — toasting every prefetch would spam. The line is: **user-initiated → always feedback; system-initiated → silent with logs.**

---

## 2. Current-state map

| Area | Files | Current behavior |
|---|---|---|
| Toasts | No shared helper; ad-hoc `SnackBar`s in queue/playlist (`queue_sheet.dart`, `playlist_screen.dart` Undo) | Inconsistent style, stacking, placement |
| Silent catches | `lib/auth/spotify.dart` (30+), `lib/app/app.dart`, sheets, `lib/data/*`, `lib/podcasts/*` | `catch (_) {}` with no log or UI |
| Logging | `lib/app/crash.dart` file-logger (wired in `main`) | Keep as the log target |
| Loading faces | `DelayedSpinner` (300 ms), `IosSpinner`, `PulseOpacity`, `UpdateProgressShimmer` | Keep; U8 adds the rule for when each shows |
| Update flow | `lib/app/updates.dart` | Banner + shimmer exist; failure silent |

---

## 3. Design decisions and non-goals

- One helper, one style, one placement: `showCrescaToast()` (new file) — short, above MiniPlayer (U1 clearance so it never hides behind chrome), dismiss-previous-first.
- No toast queue, no action buttons on toasts (actions belong in Snackbars with Undo — U5/U7 already cover those; toasts are informational).
- No network-layer rewrite, no error taxonomy beyond user-facing copy. U8 is a feedback shell over existing engines.
- Copy rule: say what happened + what to do ("Couldn't open player — Retry", "Signed out", "Share failed — offline?"). Never "Something went wrong" alone.

---

## 4. Day 1 — Implementation

### Step 1 — Create the helper (30 min)
New `lib/app/widgets/cresca_toast.dart`:
```dart
Future<void> showCrescaToast(BuildContext context, String message) async {
  // Call only with a context inside the tab body (under BottomChromeScope).
  if (!context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
        // sits above MiniPlayer + tab bar via U1 clearance
        margin: EdgeInsets.only(
          left: 16, right: 16,
          bottom: BottomChromeScope.clearanceOf(context) + 8,
        ),
      ),
    );
}
```
One style. Short copy only. For loading >300 ms, use `DelayedSpinner` in place — never a toast saying "Loading…".

### Step 2 — Wire user actions (2–3 h)
Replace silent catches on exactly these paths (audit with `grep -rn "catch" lib/auth lib/app lib/data`):
1. Open sheet (player/queue/lyrics/video/downloads): `catch → showCrescaToast('Could not open …')` + log to `crash.dart`.
2. Logout / session wipe (`auth/` + `session_sheet`/`profile_sheet`): success toast ("Signed out") + failure toast with retry; verify wipe completeness (cookies + secure storage + in-memory) per phase-01.
3. Share (`track_menu` share action): failure → "Couldn't share — try again".
4. Spotify import/sync: failure → "Import paused — will resume" (import resumes per README; say so).
5. Update check/install (`updates.dart`): failure → banner copy changes to "Update check failed — Retry", tap retries; never silent.
6. Download start/fail: failure → toast + inline Retry in sheet (U7 owns the sheet; U8 owns the toast).
Pattern per call site:
```dart
try {
  await action();
} catch (e, st) {
  logToCrash(e, st); // crash.dart
  if (context.mounted) showCrescaToast(context, 'Could not open player — Retry');
}
```
`context.mounted` guards everywhere; never toast from a disposed or route-level context (helper requires tab-body context).

### Step 3 — Silence discipline (30 min)
Explicitly allowlist silence: prefetch, discovery paging, palette generation, translation fetch fallbacks, image cache misses. Mark each with a comment:
```dart
} catch (_) {
  // silent: background prefetch, surfaced on next explicit load if persistent
}
```
Any silent catch NOT matching the allowlist is a U8 defect — convert it.

### Step 4 — Self-check
- `grep -rn "catch" lib/auth lib/app lib/data` → only allowlisted background paths remain silent (each with the comment).
- `grep -rn "showCrescaToast" lib/` → present on all six user paths.
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
1. Boot if needed; fresh RELEASE build + `install --release`.
2. Launch, sleep 12, `pidof` + logcat FATAL scan.
3. Screenshots: (a) toast after failed share (airplane on), (b) toast after failed sheet open if inducible, (c) update-failed banner state, (d) toast placement above MiniPlayer (track loaded + toast visible — clearance proof).
4. `uiautomator dump` during toast: toast text node present with exact copy; after 3 s: node gone (no sticky toast).
5. Failure matrix (airplane mode on/off per row):

| Action | Offline behavior | Online recovery |
|---|---|---|
| Open player/queue/lyrics | Sheet still opens (local UI) or toast | — |
| Share | Toast "Couldn't share" | Toast gone, share succeeds |
| Logout | Toast + complete wipe even offline | Login screen clean |
| Update check | Banner "failed — Retry" | Retry succeeds |
| Search | `ErrorRetry` (U6), no toast spam | Content returns |
| Background prefetch | Zero toasts | Zero toasts |

6. Rapid-fire: trigger 3 failures in 2 s — exactly one toast visible at a time (hide-before-show), no stacking, no overflow exception.

### 5.3 Limits
Emulator 403s will trigger error paths — treat them as free failure injection for toast verification, not regressions. Clean up artifacts.

---

## 6. Edge cases

| Symptom | Cause | Fix |
|---|---|---|
| Toast behind MiniPlayer | Fixed bottom margin | Margin from `BottomChromeScope.clearanceOf(context) + 8` |
| Toast after navigation | Disposed / route-level context | `context.mounted` guard; tab-body context only |
| Toast spam on scroll | Prefetch wired to toast | Prefetch stays silent; audit allowlist |
| "Something went wrong" copy | Lazy message | Action-specific copy per Step 2 (what + next step) |
| Double toast (snackbar + toast) | Undo flows also toasting | Undo flows use Snackbar only; toasts never carry actions |

---

## 7. Exit criteria
- [ ] Six user paths toasted + logged; allowlisted background silence only.
- [ ] Every tap answers ≤300 ms (spinner or toast — verify by feel on jam16 + dumps).
- [ ] One toast at a time; placement above chrome; auto-dismiss.
- [ ] `analyze` + `test` green; launch clean.

## 8. Rollback
Revert the noisiest caller to silent (keep helper + other five). Never revert the helper itself — it is additive.

## 9. Handoff to U9/U10
U9 checks toast repaint cost (opacity-only, no blur — confirm); U10 announces toasts to TalkBack (`liveRegion` where appropriate). Report helper path + final copy strings.

---

## 10. Shared process (normative)
Runbook, copy deck, test matrix (T1–T14), sign-off log, working agreements, and branching rules live in `phases/ui-shared-appendix.md` and are not copied here. Follow that file for process; this doc owns scope. Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder — guard with `context.mounted`.
