# U5 — Queue + Lyrics + Video (Days 9–10)

> Owner: one agent. Depends on: U4 (player chrome patterns). Unblocks: U8 (toast reuse), U10 (a11y sweep).
> Goal: queue reorder discoverable with undo, lyrics never fight the finger, video closes first tap.

---

## 1. Why this phase exists

The three sheets orbiting the player each hide their core interaction:

1. **Queue reorder needs discovery + safety.** `lib/app/widgets/queue_sheet.dart` already has `SliverReorderableList` with drag handles and long-press — but no haptic, no Undo. A mis-drag destroys curation with no recovery; the vibe-queue promise ("Up Next matched to the mood") dies if the queue feels fragile.
2. **Lyrics hold is silent.** `lib/app/widgets/lyrics_panel.dart` pauses auto-scroll for a 3 s manual hold — but nothing tells the user auto-scroll will resume and yank the lines back. Tap-to-seek misfires mid-hold.
3. **Video close is soft.** `lib/app/widgets/video_sheet.dart` (1700+ lines) buries close behind gestures; quality picker + prefetch work, but users get stuck on portrait-locked phones.

All three are high-emotion surfaces (sing-along, "play next", watch). Friction here costs retention disproportionately.

---

## 2. Current-state map

| File | Owns | Keep vs add |
|---|---|---|
| `queue_sheet.dart` | Up Next list, vibe-queue ordering, remove/swipe, `SliverReorderableList` with handles, long-press-drag reorder, tap-to-play, gapless auto-advance | KEEP list + handles; ADD haptic + Undo |
| `lyrics_panel.dart` | Karaoke highlight, tap-to-seek, 3 s manual-scroll hold, translation/romanization tools, gap dots | KEEP hold + tools; ADD explicit Resume pill |
| `video_sheet.dart` | Embedded `video_player`, 1080p DASH + quality picker, next-video prefetch, music-transport sync | KEEP picker + prefetch; ADD labelled Close + semantics |
| `track_row.dart` | Row visuals reused in queue | `StaggerEntrance` cap, `PressScale`, cached thumbs |

Do not touch: queue scoring, lyrics sources, video streaming stack. U5 is interaction + chrome only.

---

## 3. Design decisions and non-goals

- Visible drag handles AND long-press-drag both work (already exist on `SliverReorderableList` — verify, do not rebuild). U5 adds haptic on grab + Snackbar-Undo.
- Lyrics auto-scroll already yields for a 3 s manual hold; U5 replaces the silent hold with an explicit "Resume" pill. No auto-resume timer (timers that yank are the bug).
- Video keeps prefetch + picker; adds one labelled Close. No landscape/fullscreen redesign (portrait lock stays).

---

## 4. Day 1 — Implementation

### Step 1 — Queue: verify handles, add haptic + undo (1 h)
Handles + `SliverReorderableList` + long-press already exist — do not rebuild the list. Add what's missing:
1. Confirm each row exposes its reorder handle with a `Semantics(label:)`; fix any row keyed by index (key by `track.id`).
2. Fire `HapticFeedback.lightImpact()` on grab (once per grab, never on move ticks).
3. After reorder or remove, Snackbar-Undo (5 s), snapshot before mutation:
```dart
final removed = MapEntry(index, item);
library.remove(item);
ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(
    content: Text('Moved "${track.title}"'),
    action: SnackBarAction(label: 'Undo', onPressed: () => library.insert(removed.key, removed.value)),
  ));
```
Keep swipe-to-remove; its Undo uses the same path. One snackbar at a time (hide-before-show).

### Step 2 — Lyrics: finger always wins, pill says so (1–2 h)
1. Keep the existing manual hold; add explicit state: on `ScrollStartNotification` (touch) set `userScrolling=true` + cancel auto-scroll ticker; show "Resume" pill (bottom-center, `Glass` chip, `PressScale`):
```dart
if (userScrolling) Positioned(bottom: clearance, child: ResumePill(onTap: resumeAutoScroll))
```
2. `resumeAutoScroll()`: scroll to current line (animated 220 ms, honoring `motionOn`), set `userScrolling=false`, hide pill.
3. Tap-to-seek: only fires on tap (not scroll); guard with `if (userScrolling) return` on drag, and require `tapUp` within 300 ms + <8 dp movement to count as tap. Gap dots + translation toggles unchanged. Reset `userScrolling=false` on `track.id` change.

### Step 3 — Video: one-tap close (1 h)
1. Add top-leading labelled Close:
```dart
Semantics(button: true, label: 'Close video', child: IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)))
```
Keep drag-to-dismiss. Close pops one route level only (never kills the player beneath).
2. Semantics sweep of the sheet: quality picker options, transport buttons, prefetch indicator all get labels. Picker itself unchanged.
3. Confirm portrait lock holds — video never forces rotation in U5.

### Step 4 — Self-check
- `flutter analyze` clean.
- `grep -rn "ReorderableDragStartListener" lib/app/widgets/queue_sheet.dart` present; `grep -rn "Resume" lib/app/widgets/lyrics_panel.dart` present; `grep -rn "Close video" lib/app/widgets/video_sheet.dart` present.

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
3. Screenshots: (a) queue with handles visible, (b) Undo snackbar after reorder, (c) lyrics with Resume pill, (d) video sheet + quality picker open, (e) dark-mode pass of queue.
4. `uiautomator dump` per sheet: handles (`Reorder …`), Resume pill, Close video, picker options — all with content-desc.
5. Interactions: reorder 5 tracks + Undo each; remove + Undo; lyrics manual scroll (auto-scroll must freeze), tap Resume (glides to current line), tap-to-seek 5×; video open/close 5×, picker open/close 2×. Playback 403s are env noise — open/close and labels are the check. Watch SwiftShader blur cost: sheets must not stack blurs (U9 enforces; note any stacking seen here for U9).
6. Force-stop + relaunch: queue order persists per session semantics (engine-owned), lyrics default to auto-scroll on fresh open.

### 5.3 Limits
No tap injection; dumps + screenshots. Fresh profile = short queue; seed via recents or accept short list. Clean up artifacts.

---

## 6. Edge cases

| Symptom | Cause | Fix |
|---|---|---|
| Reorder handle dead on some rows | Row keyed by index, not id | Key by `track.id`, not index |
| Undo restores to wrong slot | Index captured post-mutation | Snapshot `(track, fromIndex)` before mutation |
| Lyrics Resume pill never hides | Flag not cleared on track change | Reset `userScrolling=false` on `track.id` change |
| Tap-to-seek fires while scrolling | Tap vs drag not distinguished | Movement + duration gate above |
| Video Close kills player | `pop` too deep | Pop exactly one route; assert player still mounted in dump |

---

## 7. Exit criteria
- [ ] Handles verified + labelled; long-press still works; haptic on grab; Undo on reorder/remove.
- [ ] Finger scroll always beats auto-scroll; Resume pill appears/disappears correctly.
- [ ] Video closes first tap; picker + prefetch intact.
- [ ] `analyze` + `test` green; launch clean.

## 8. Rollback
Remove haptic/Undo if reorder regresses (keep handles — they predate U5). Keep Close button and Resume pill — both are pure additions.

## 9. Handoff to U6/U8
Report handle widget for reuse in playlists (U7), Resume-pill pattern for any auto-scroll surface, and any blur stacking observed for U9.

---

## 10. Shared process (normative)
Runbook, copy deck, test matrix (T1–T14), sign-off log, working agreements, and branching rules live in `phases/ui-shared-appendix.md` and are not copied here. Follow that file for process; this doc owns scope. Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder — guard with `context.mounted`.

## 11. Appendix F — Queue/lyrics/video deep dive

- Queue engine boundary: the sheet owns presentation order; the queue engine owns playback order. Reorder commits to the engine on drop (not on hover), and Undo re-commits the inverse. If dumps show the playing index drifting after Undo, the commit ordering is wrong — fix the commit, never the highlight.
- Lyrics timing: karaoke highlight advances on position ticks scoped to the lyrics widget (U9 rule). Gap dots render for breaks >4 s; tapping a dot seeks to the next line start. Translation/romanization toggles never reset scroll position.
- Video lifecycle: opening video pauses artwork wash work (MeshBackdrop frozen, U9) and prefetch starts muted. Closing disposes the controller — verify no `video_player` instance survives after 5 open/close cycles.
- Haptic budget: one `lightImpact` per grab, none on move ticks. Haptics on every reorder tick drain battery and annoy — resist.
