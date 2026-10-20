# U7 — Library / Playlists / Podcasts (Days 13–14)

> Owner: one agent. Depends on: U3 (slivers), U5 (handles + undo), U6 (states). Unblocks: U10 (a11y labels build on these).
> Goal: one download progress surface, destructive actions undoable, podcast controls readable without icon literacy.

---

## 1. Why this phase exists

Library is where ownership lives (Liked Songs, recents, custom playlists, fav-artists, downloads, podcasts) — and where three trust bugs cluster:

1. **Split progress.** Download/update progress surfaces in three places: `downloads_sheet.dart`, the `updates.dart` banner/shimmer, and the system notification. They can disagree, and none deep-links to the others.
2. **Destructive actions without undo.** Playlist delete/reorder and download delete-to-disk: one mis-tap destroys curation with no recovery. Queue got Undo in U5; playlist already has an Undo snackbar for row removal (`playlist_screen.dart` "Removed … Undo available") — extend the pattern to every destructive path.
3. **Icon-only podcast controls.** Playback speed + sleep timer + download-for-offline render as bare glyphs in `podcast_screen.dart`. New users cannot guess them; screen readers announce "button" with no purpose.
4. **Same nested-list debt as Home.** `library_screen.dart` nests vertical lists; mosaic playlist headers rebuild per frame.

Library users are the most invested — data loss here churns permanently.

---

## 2. Current-state map

| File | Owns | Keep |
|---|---|---|
| `library_screen.dart` | Playlists/Liked/Recents, fav-artists strip, settings cards | Section set, settings entries |
| `playlist_screen.dart` | Mosaic header, rename, gallery covers, suggested-from-artists, existing row-remove Undo | Suggestions engine, cover picker, existing Undo (extend it) |
| `podcast_screen.dart` | Shows/episodes, resume-from-position, speed/sleep, offline download | Playback glue (`lib/podcasts/`), resume math |
| `downloads_sheet.dart` | Per-file progress, offline-first status, clean delete | `background_downloader` wiring |
| `updates.dart` | `UpdateBannerMotion`, `UpdateProgressShimmer`, GitHub release check | Check cadence, install flow |
| `library.dart`, `downloads.dart` | Library + download state | Engines untouched |

---

## 3. Design decisions and non-goals

- Sheet is source of truth for progress. Banner + notification become launchers (tap → open sheet). No progress logic duplicated.
- Every destructive action gets 5 s Snackbar-Undo (U5 pattern; playlist row-remove already shows the way). No confirmation dialogs — undo is faster and less annoying.
- Podcast speed/sleep/download get text labels next to icons. No icon redesign.
- No library reorganization, no new sort/filter, no playlist collaboration.

---

## 4. Day 1 — Implementation

### Step 1 — One progress surface (2 h)
1. `downloads_sheet.dart` owns all per-file + aggregate progress (it already subscribes to downloader events — keep subscriptions, fix leaks per U4 gen-token discipline).
2. `updates.dart` banner becomes: status line + "Details" affordance → `showDownloadsSheet(context)`. `UpdateProgressShimmer` stays as the banner's loading face but reads the same state object as the sheet (single state, two readers — never two fetchers).
3. Notification taps deep-link to the app's downloads surface (verify existing channel `PendingIntent` target; do not create a second channel).
4. States: queued / active % / paused / failed-Retry / done-offline-first. Failed files show inline Retry (per file), never a global dead end.

### Step 2 — Undo everywhere destructive (1–2 h)
Extend the existing playlist Undo pattern to: playlist reorder/delete, track-remove-from-playlist, liked-unlike, recent-clear, download delete (trash-to-disk per phase-06 — Undo restores the library entry; re-download only if the file was actually deleted, and say so in the snackbar copy: "Removed download — Undo" vs "Deleted file — Undo (needs re-download)").
```dart
final removed = MapEntry(index, item);
library.remove(item);
ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(
    content: Text('Removed "${item.title}"'),
    action: SnackBarAction(label: 'Undo', onPressed: () => library.insert(removed.key, removed.value)),
  ));
```
Snapshot before mutation; one snackbar at a time.

### Step 3 — Podcast labels + mosaic perf (1 h)
1. Speed control: `Semantics(label: 'Playback speed, 1.5x')` + visible text "1.5×" next to the icon. Sleep: "Sleep: 20 min" / "Sleep: off". Download-per-episode: icon + "Offline"/"Saved" state text. Keep `PressScale` + `motionOn` gating.
2. Mosaic header: build once per playlist (key on `playlist.id + coverVersion`), cache the composited image, never rebuild in `build()` per frame. Reuse `cached_network_image` with placeholder fallback; placeholder = mosaic/gradient fallback, never white flash.
3. `library_screen.dart` nesting → U3 sliver pattern (`CustomScrollView`, horizontal fav-artists rail, `SliverList` sections, clearance-aware `SliverPadding`).

### Step 4 — Self-check
- `grep -rn "showDownloadsSheet\|openDownloads" lib/app/updates.dart` — banner references sheet.
- `grep -rn "SnackBarAction.*Undo" lib/app/screens/library_screen.dart lib/app/screens/playlist_screen.dart lib/app/screens/podcast_screen.dart` — present on every destructive path.
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
3. Screenshots: (a) library top, (b) playlist mosaic + suggested row, (c) podcast show with labelled speed/sleep, (d) downloads sheet mid-progress + banner state simultaneously (must agree), (e) Undo snackbar after delete.
4. `uiautomator dump`: Undo action text, speed/sleep labels with values, per-file progress %, mosaic single node (not N rebuilding nodes).
5. Flows: create → rename → reorder → delete playlist + Undo each step; unlike + Undo; start 2 downloads → kill app (`am force-stop`) → relaunch (resume/complete); toggle speed/sleep and confirm labels update; banner tap → sheet opens.
6. Offline: downloaded files play with airplane mode on (offline-first proof).

### 5.3 Limits
Emulator storage is small — use 2 short tracks for download tests, delete after. 403s on streams ≠ download-code failure; use cacheable short media. Clean up artifacts + test downloads.

---

## 6. Edge cases

| Symptom | Cause | Fix |
|---|---|---|
| Banner/sheet disagree | Two progress sources | Single state object, sheet owns writes |
| Undo restores wrong slot | Index drift after concurrent mutation | Snapshot index pre-mutation; `hideCurrentSnackBar` serializes |
| Undo after file deleted | Entry restored but bytes gone | Copy distinguishes entry-restore vs re-download; failed-restore shows Retry |
| Mosaic flashes on scroll | Rebuilt per frame | Key + memoize; image cache below |
| Speed label stale | Icon-only state update | Label reads the same notifier as the engine |

---

## 7. Exit criteria
- [ ] One progress surface; banner tap opens sheet; progress agrees everywhere.
- [ ] Every destructive action undoable ≤5 s with accurate copy.
- [ ] Podcast speed/sleep/download readable without icons.
- [ ] `analyze` + `test` green; offline playback of downloads verified.

## 8. Rollback
Restore banner-local progress if single-sourcing regresses (keep Undo + labels — both independent wins).

## 9. Handoff to U8/U10
U8 wires toasts into these flows (share/delete failures); U10 audits these labels with TalkBack. Report: sheet state object name, Undo call sites, label strings.

---

## 10. Shared process (normative)
Runbook, copy deck, test matrix (T1–T14), sign-off log, working agreements, and branching rules live in `phases/ui-shared-appendix.md` and are not copied here. Follow that file for process; this doc owns scope. Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder — guard with `context.mounted`.

## 11. Appendix F — Library-specific deep dive

- Playlist cover rule: gallery covers and mosaic headers are built from downloaded art only (never network-fetch during scroll — that reintroduces U9 jank). Missing art gets the gradient fallback immediately; the real cover swaps in via `gaplessPlayback` when cached.
- Suggested-from-artists: suggestions render as a horizontal rail with Add buttons per row (not swipe). Adding shows the U5 Undo snackbar ("Added to <playlist>" + Undo). Never auto-navigate away after add — the user stays in context.
- Storage honesty: Library shows per-section counts (N playlists, M downloads, X MB offline). If the engine and the displayed count disagree after kill/relaunch, the engine wins and the UI re-syncs on the next frame with no error shown (self-healing, silent — the one sanctioned silent path in library).
- Settings cards: settings entries in library keep existing icons + labels; U7 only fixes their clearance/text-scale behavior, never their order or function.
