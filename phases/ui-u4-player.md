# U4 — Full Player Slimdown (Days 7–8)

> Owner: one agent. Depends on: U1 (tokens, clearance). Unblocks: U5 (shares transport patterns).
> Goal: same pixels except one labelled row, smaller files. Extract-only split of `player_sheet.dart` (~2900 lines), fix seek gen-token leaks.

---

## 1. Why this phase exists

`lib/app/widgets/player_sheet.dart` (~2900 lines) is the largest UI file in the repo. It owns at least five jobs: header ("Playing from X", marquee title, lyric preview), artwork wash + edge-to-edge art, seek bar + remaining time + 3-button transport + volume, lyrics-mode crossfade, and the overflow menu (Shuffle / Repeat / Like / Download / Video). Consequences:

1. **Merge conflicts and review cost.** Every player tweak touches the same file; diffs are unreadable.
2. **Seek/slider leaks.** Phase-07 notes gen-token races: a slow duration/position future resolving after dispose or after track change jumps the slider. Volume-row listeners add to the leak surface.
3. **Competing actions.** Volume row + output pill ("This phone") + overflow menu + lyrics/output/queue pills fight for the same bottom zone; Shuffle/Repeat hide in the menu where new users never look.

This phase changes structure, not layout. Named screenshots before/after must show only the overflow row gaining labels — nothing else moves.

---

## 2. Current-state map

| File | Owns |
|---|---|
| `lib/app/widgets/player_sheet.dart` | `openPlayerSheet()` route (transparent `showModalBottomSheet`, `useSafeArea: false`, `DraggableScrollableSheet` 0.55–1.0), `PlayerSheet` state, layout constants `_gutter=24`, `_gapXs/Sm/Md/Lg`, artwork wash, marquee, seek, transport, volume, output pill, lyrics crossfade |
| `lib/app/widgets/track_menu.dart` | Row overflow menu (share, playlist, queue, download) — reuse, do not fork |
| `lib/app/widgets/queue_sheet.dart` | Up Next — opened from player; interface unchanged |
| `lib/app/widgets/lyrics_panel.dart` | Karaoke — embedded preview + full mode; interface unchanged |
| `lib/app/widgets/video_sheet.dart` | Video entry point from player menu; unchanged |
| `lib/app/design.dart` | `GlassSheetSurface`, `SheetGrabHandle`, `spotifyPlayStyle()` — reuse |

Keep: route parameters (`video` flag), drag-to-dismiss extents, `useSafeArea: false` bleed, lyrics-mode crossfade timing, all playback wiring (`just_audio` positions, `audio_service` state).

---

## 3. Design decisions and non-goals

- Extract-only. No new layout, no new theme, no transport redesign. New files are moves with import fixes.
- One overflow row with icon + text labels for Shuffle / Repeat / Like / Download / Video. Previously icon-only/hidden → now discoverable. Order stays. This is the phase's single deliberate visual change; everything else stays pixel-identical (verified by named screenshots).
- Seek keeps one `Slider` + remaining-time label. No custom painter rewrite.

---

## 4. Day 1 — Implementation

### Step 1 — Create three files (mechanical, 2–3 h)
1. `lib/app/widgets/player_header.dart` — move: "Playing from X" line, marquee title + overflow handling, artist line, lyric preview (tap expands), credits entry. Props: `track`, `sourceLabel`, `onExpandLyrics`, `motionOn`.
2. `lib/app/widgets/player_transport.dart` — move: thin seek bar + elapsed/remaining labels, 3-button transport (prev/play/next), volume row, output pill. Props: `positionStream`, `duration`, callbacks `onSeek`, `onPrev/Play/Next`, `onVolume`, `onOutputTap`. Owns its `StreamSubscription`s and cancels in `dispose`.
3. `lib/app/widgets/player_menu.dart` — move: overflow row (Shuffle / Repeat / Like / Download / Video / Share) with labels, wired to existing `track_menu.dart` actions where possible. Props: `track`, `state`.
4. `player_sheet.dart` keeps: route builder, `DraggableScrollableSheet` extents, crossfade between main/lyrics/video modes, sheet chrome (`SheetGrabHandle`, close Semantics). Target <800 lines per file. Shared constants `_gutter/_gap*` move to one home (imported by the others, never duplicated).

### Step 2 — Seek gen-token fix (1 h)
Pattern (apply to position/duration futures AND volume):
```dart
int _seekGen = 0;
Future<void> _loadDuration(Track t) async {
  final gen = ++_seekGen;
  final d = await resolveDuration(t);
  if (!mounted || gen != _seekGen) return; // stale or disposed
  setState(() => _duration = d);
}
@override
void dispose() {
  _seekGen++; // invalidate in-flight
  _posSub?.cancel();
  super.dispose();
}
```
Also increment gen in `didUpdateWidget` when `track.id` changes. Slider `onChanged` scrubs locally; `onChangeEnd` commits once — no per-tick commits.

### Step 3 — Overflow row with labels (1 h)
```dart
Row(
  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
  children: [
    _PlayerAction(icon: shuffleIcon, label: 'Shuffle', onTap: toggleShuffle, active: isShuffle),
    _PlayerAction(icon: repeatIcon, label: 'Repeat', ...),
    _PlayerAction(icon: likeIcon, label: 'Like', ...),
    _PlayerAction(icon: downloadIcon, label: 'Save', ...),
    _PlayerAction(icon: videoIcon, label: 'Video', ...),
  ],
)
```
Each action: `Semantics(button: true, label:)` + `PressScale`. Active state via tint (`spotifyGreen`), never size change.

### Step 4 — Self-check
- `flutter analyze` clean; no new public API beyond the three widgets.
- `grep -n "class .*Sheet\|class .*Header\|class .*Transport" lib/app/widgets/player_*.dart` shows one responsibility each.
- Named screenshots before/after at same track: only overflow labels differ.

---

## 5. Day 2 — Verification + mandatory emulator check

### 5.1 Static gates
```powershell
cd cresca-flutter
C:\Android\flutter\flutter\bin\flutter.bat analyze
C:\Android\flutter\flutter\bin\flutter.bat test
```

### 5.2 Emulator check (jam16)
1. Boot if needed; fresh RELEASE `build apk` + `install --release -d emulator-5554`.
2. Launch `com.cresca.cresca_app/.MainActivity`, sleep 12, `pidof` + logcat FATAL scan.
3. Screenshots light + dark: (a) player top (art + header), (b) transport zone (seek + 3 buttons + volume), (c) overflow row open, (d) lyrics-mode crossfade mid-state.
4. `uiautomator dump` with player open: seek slider has content-desc + value, Close button labelled, each transport/overflow button labelled, drag handle present.
5. Interactions (cached track; 403 streams are env noise): play/pause 10×, seek 10× (including seek-then-close-then-reopen — slider must not jump), open/close sheet 5×, expand/collapse lyrics 3×, toggle each overflow action once. Watch logcat for `setState after dispose` — zero tolerance.

### 5.3 Limits
No tap injection — dumps + screenshots only. Streams 403 ≠ failure. Clean up artifacts.

---

## 6. Edge cases

| Symptom | Cause | Fix |
|---|---|---|
| Slider jumps after track change | Stale duration future resolves late | Gen-token check + increment on track change |
| `setState after dispose` on fast close | Subscription/slider callback post-dispose | Cancel subs, bump gen in `dispose`, guard `mounted` |
| Volume row fights hardware keys | Two sources of truth | Volume row reflects `system_volume.dart`; never writes during hardware change events |
| Lyrics crossfade flashes | Blur animated per-frame | Blur sigma static; animate opacity/transform only |
| Overflow labels wrap at 200% scale | Fixed row width | `Expanded` per action, `maxLines:1`, ellipsis; instrument label still announced fully via Semantics |

---

## 7. Exit criteria
- [ ] Three new files, each <800 lines, `player_sheet.dart` slimmed to chrome + mode switching.
- [ ] Seek/volume race fixed; zero post-dispose callbacks in a 10-seek stress.
- [ ] TalkBack reads transport position + each overflow label.
- [ ] `analyze` + `test` green; launch clean.

## 8. Rollback
Re-merge extracted files into `player_sheet.dart` (imports make this mechanical). Keep the gen-token fix — it is independent and must survive any revert.

## 9. Handoff to U5
U5 reuses `player_transport.dart` slider semantics + `player_menu.dart` action pattern for queue/lyrics/video. Report: final file line counts, gen-token locations, overflow order.

---

## 10. Shared process (normative)
Runbook, copy deck, test matrix (T1–T14), sign-off log, working agreements, and branching rules live in `phases/ui-shared-appendix.md` and are not copied here. Follow that file for process; this doc owns scope. Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder — guard with `context.mounted`.

## 11. Appendix F — Player-specific deep dive

- Line-count proof: run `wc -l lib/app/widgets/player_*.dart` before and after; each file must read as one responsibility (chrome/mode-switch vs header vs transport vs menu). If `player_sheet.dart` still exceeds 800 lines, the overflow is lyrics-mode branching — extract the mode switch into `player_mode_switch.dart` rather than growing the chrome file.
- Slider math: position stream (ms) → slider 0.0–1.0 via `duration > 0 ? pos/duration : 0`. Guard divide-by-zero for unloaded tracks; remaining label shows `-–:––` until duration resolves, never `-0:00`.
- Marquee rule: title scrolls only when it would clip (measure with `TextPainter` once per track, not per frame). Short titles stay static — motion for its own sake is a U9 cost.
- Volume coexistence: the in-sheet volume row reflects `system_volume.dart`; hardware keys remain authoritative. If both move simultaneously, the engine value wins and the row snaps to it with a 150 ms crossfade — never fight the key event.
