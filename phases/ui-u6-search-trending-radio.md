# U6 — Search / Trending / Radio (Days 11–12)

> Owner: one agent. Depends on: U3 (sliver + state patterns). Unblocks: U7 (copies these states).
> Goal: no stale results ever, every list implements Loading / Content / Empty / Error.

---

## 1. Why this phase exists

Discovery surfaces share three defects:

1. **Stale-result guard must be proven.** `lib/app/screens/search_screen.dart` already debounces (250 ms) music-only queries with instant cached rows and a `_gen` guard that drops late arrivals — but no test pins the race. Fast typists are the trust test: only the last query may paint.
2. **Errors must read as errors.** `see_all.dart` and the radio/trending rails need per-rail error slots. Offline must read as "couldn't load", never as "no music".
3. **Radio never ends.** `lib/app/screens/radio_screen.dart` nests square-card endless scroll with no terminal state — the spinner spins forever at feed end, implying content that never arrives.

Search is the app's front door on a YouTube-backed player with no catalog guarantees; it must be the most honest surface.

---

## 2. Current-state map

| File | Owns | Keep |
|---|---|---|
| `search_screen.dart` | Debounced (250 ms) music-only search, instant cached rows, `_gen` stale-query guard, artist row, recent searches | Debounce timing, music-only filter, cache-first, `_gen` |
| `trending_screen.dart` | Top 100 Global/Hindi/Intl/Telugu/Punjabi + video rails | Rail set, ranking |
| `radio_screen.dart` | Song-radio sessions, square cards, endless scroll | Session engine (`radio_store.dart`), card art |
| `state.dart` | Query/search/rails loading flags | Single-flight discipline |
| `see_all.dart` (U3-verified) | Paginator with `_moreError` + Retry | Reuse its `ErrorRetry` / `InlineRetryBanner` widgets here |

---

## 3. Design decisions and non-goals

- Gen-token stays as-is (debounce decides when to fire, token decides what may paint). No request-cancellation refactor of the network layer — dropping stale futures on arrival IS the cancellation.
- Four states per list, shared widgets from U3 (import, do not duplicate).
- Radio end footer copy: "You're all caught up". No infinite sentinel.

---

## 4. Day 1 — Implementation

### Step 1 — Search: audit the existing gen-token, prove it (1 h)
`search_screen.dart` already debounces (250 ms) and guards with `_gen` (stale futures dropped on arrival — that IS the cancellation, the repo has no cancel token). Do not add a second guard. Your job: re-read the guard, write the 10-queries-in-5-seconds test (only the last query paints), and fix only what the test exposes. Cached instant rows still render synchronously; network errors still never clear the cache (inline banner over stale rows, full `ErrorRetry` when the cache is empty).
Reference pattern (already in file — verify, don't duplicate):
```dart
int _gen = 0;
Future<void> _runQuery(String q) async {
  final gen = ++_gen;
  setState(() => _status = SearchStatus.loading);
  final res = await repo.searchMusic(q);
  if (!mounted || gen != _searchGen) return; // stale — drop silently
  setState(() { _rows = res; _status = ...; });
}
```
Rules: every keystroke invalidates in-flight (`_gen++` on change, upstream of debounce). Log errors to `crash.dart`. Copy discipline: true empty shows "No results for 'xyz'"; error shows "Couldn't load 'xyz' — Retry" — never conflate.

### Step 2 — Shared state widgets (1 h)
Ensure these exist once (import from U3, do not duplicate):
- `LoadingState`: `DelayedSpinner` 300 ms + skeleton rows.
- `EmptyState`: icon + title + subtitle.
- `ErrorRetry`: icon + message + Retry button wired to the same loader.
- `InlineRetryBanner`: one-line banner atop stale-but-visible rows.
- `EndFooter`: spinner while `hasMore`, terminal copy when done.

### Step 3 — Trending per-rail errors (45 min)
Each rail (Global/Hindi/Intl/Telugu/Punjabi/video) gets independent status. One rail's 403/offline must not blank the others: failed rail shows `InlineRetryBanner` in place, successful rails render. Page-level failure (all rails) → full `ErrorRetry`.

### Step 4 — Radio ending + de-nesting (1 h)
1. Replace the nested vertical list in `radio_screen.dart` with the U3 sliver pattern (`CustomScrollView`, square-card horizontals or `SliverGrid`).
2. End: when the session engine reports `hasMore == false`, render `EndFooter(done: true)`. Remove any sentinel spinner that fires `loadMore` unconditionally at max extent — gate on `hasMore && !loading`.

### Step 5 — Self-check
- `grep -rn "_gen" lib/app/screens/search_screen.dart` present (single guard, not doubled).
- `grep -rn "shrinkWrap" lib/app/screens/radio_screen.dart lib/app/screens/search_screen.dart` empty.
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
3. Screenshots: (a) search with results, (b) search true-empty ("No results for 'zzzqwerty'"), (c) search error + Retry (airplane mode), (d) trending with one failed rail banner, (e) radio end footer.
4. `uiautomator dump`: search field node, result rows with titles, empty/error text nodes, rail banners, end-footer text.
5. Stress: type 10 queries in <5 s (only last query paints — verify via dumps, not taps); airplane on → search → Retry visible → airplane off → Retry → rows return; scroll each feed to absolute end (footer reached, no infinite spinner); force-stop + relaunch preserves recent searches.
6. Airplane toggling: `adb shell cmd connectivity airplane-mode enable/disable`.

### 5.3 Limits
Emulator 403s inflate error states — distinguish test-induced (airplane) from env (403): both must show Retry, but do not file 403s as regressions. Clean up artifacts.

---

## 6. Edge cases

| Symptom | Cause | Fix |
|---|---|---|
| Wrong-query rows flash | Stale future paints | Gen-token drop (never paint when stale) — verify, don't double-guard |
| Error wipes good cache | `rows = []` on failure | Never clear on error; banner over stale rows |
| Empty vs error conflated | Single "no data" widget | Separate copy: "No results for X" vs "Couldn't load X — Retry" |
| Radio spinner forever | Ungated `loadMore` at extent | Gate on `hasMore && !loading`; terminal footer |
| One rail kills the page | Shared status flag | Per-rail status; page error only when all fail |

---

## 7. Exit criteria
- [ ] 10-query burst test proves only final results paint; no stale flash.
- [ ] All four states reachable on demand per surface (screenshots prove each).
- [ ] Radio terminates with footer; no endless spinner.
- [ ] `analyze` + `test` green; launch clean.

## 8. Rollback
Do not touch the debounce/token — proven working. Radio footer is additive; keep it regardless.

## 9. Handoff to U7
U7 copies `EmptyState`/`ErrorRetry`/`EndFooter` verbatim. Report the test added for the stale guard + any rail that needed independent status.

---

## 10. Shared process (normative)
Runbook, copy deck, test matrix (T1–T14), sign-off log, working agreements, and branching rules live in `phases/ui-shared-appendix.md` and are not copied here. Follow that file for process; this doc owns scope. Toast calls need a context inside the tab body (under `BottomChromeScope`); never call from a route builder — guard with `context.mounted`.

## 11. Appendix F — Search-specific deep dive

- Debounce stays (current timing kept). The gen-token sits downstream of debounce: debounce decides when to fire, token decides what may paint. Do not "fix" staleness by lengthening debounce — that trades correctness for latency and punishes fast typists twice.
- Cache-first rendering: instant cached rows paint synchronously in the same frame as the keystroke where possible (no `DelayedSpinner` for cache hits). The spinner covers network refinement only, and only past 300 ms.
- Artist row: tapping an artist navigates to the artist deep-search (existing behavior). The row itself gets `Semantics(label: 'Artist <name>')` — U10 verifies, U6 adds the label.
- Query echo discipline: empty copy always includes the query ("No results for 'xyz'"), error copy always includes scope ("Couldn't load search for 'xyz'"). Reviewers reject paraphrases in PR review — the shared copy deck is normative.
