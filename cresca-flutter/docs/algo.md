# Cresca recommendation algorithm (Up Next + home cards)

One engine ranks everything: queue **Up Next** (`rankSuggestions` /
`rankUpNext` / `buildAutoplay`) and homescreen cards (`rankTopPicks` /
`topPicksFor`). Network only *expands the candidate pool*; **local taste
always re-ranks**. Every network hop is timeout-bounded, single-flight,
memoized, and never-throwing.

## Signal stack (in scoring order)

| # | Signal | Weight / rule | Rationale |
|---|--------|---------------|-----------|
| 1 | Seed-mood fit (`moodFitScore`) | same mood +4.0, same language +2.0 (mismatch −1.0), energy proximity ×2.5, same era +1.5, keyword overlap +0.8/word (cap 2.4), tempo agreement +1.0; **×1.25 when taste is empty** | Mood-first, explicitly not same-singer radio. The cold boost means a single song instantly opens mood radio with zero history. |
| 2 | Related-graph membership | +5.0 | YouTube's co-listen graph is the strongest "people who played this also played" evidence. |
| 3 | Multi-seed agreement (co-occurrence) | `co × 1.5 + co² × 0.75` per id | Superlinear: a track under 2 seeds ≈ +4.5, under 3 ≈ +9.75. Agreement across seeds (or across server sources — mix, artist radio, mood seeds) dominates single-source noise. |
| 4 | Global taste affinity | artist ×2.0, mood ×3.0 (recency-decayed `0.85^i`, 30-play window; likes +2.0/track) | Long-term you. |
| 5 | Session context (live tail) | artist ×1.5, mood ×2.0 over last 5, decayed `0.7^i` | *Tonight's* obsession outranks yesterday's loop: recent plays steer the current queue moment on top of global taste. |
| 6 | Liked-track hit | +2.5 | Exact liked songs float. |
| 7 | Seed-artist variety | same artist −2.0; token overlap +1.0/shared (cap 3) | The seed's singer never dominates; "feat." cousins still surface. Per-artist caps finish the job (Up Next 2, Top Picks 3). |
| 8 | Skip decay (escalating) | 1st skip −3.0, +−2.5 per repeat, floor −10; skip list hard-drops; skip-artist aversion −2.0 | One skip already outweighs mood/keyword nudges, so dislikes actually bury — the song *and* the singer. Repeat skips pile on. |
| 9 | Freshness / anti-repeat | recent-play −3.0; per-impression −0.6 (cap 4.0); `shownIds` + profile memory | Played or already-surfaced tracks sink; rotation salt re-rolls score ties so refreshes never repeat the same 10. |
| 10 | Mood-arc resequence | same-set reorder, no membership change | The picked set is greedily re-walked so the next 5 span moods instead of 3-in-a-row runs. Rails never go empty for variety's sake. |

Hard rules (never violated): seed, queued ids, skip ids, and
same-name echoes never suggest. Empty ids dedupe out.

## Fetch topology + budgets

```
autoplayFor / upNextFor / endlessRefillFor(seed)
└─ serverBlendFor (ONE Future.wait, ≤3 concurrent legs, each ≤8s,
   whole blend ≤8s, 30m memo + single-flight, never throws)
   ├─ relatedTracks: RDAMVM song-radio mix → plain watch-next → extractor
   ├─ artistRadioFor: artist's top songs as its own scored source
   └─ moodSeedsFor: ≤2 vibeQueries searches (mood-first, not singer)
├─ thin-graph tier: memoized mood leg (zero-RTT hit) → ≤2 raw searches
├─ offline tier: libraryFallback, mood-scored locally, zero network
└─ buildAutoplay → rankUpNext (pure, off hot path): hard rules + signals 1–10
   → engine.appendAuto when engine.needsRefill() (≤2 remaining, ANY song)

topPicksFor(recent)
└─ per-seed related pulls in concurrent batches of 3 (each ≤8s,
   whole assembly ≤25s) → poolCap 24 → rankTopPicksAsync
   (affinity + superlinear co-occurrence + session + arc + rotation)
```

Battery discipline: ≤3 concurrent fetches anywhere, ≤8s per hop,
≤25s per Top Picks assembly, 30m blend memo / 12h home memo / 5m
negatives, warm/dead rows skipped before any network, prefetch bounded
(`primeSuggestions`: top 3 only). Nothing refetches on a timer.

## Cold-start behavior

- **Single song → instant mood radio:** with empty taste, seed-mood fit
  ×1.25 carries ranking; graph + mood legs fill the pool; offline
  library tier covers airplane mode. No history needed.
- **Thin taste (< 2 seeds):** `topPicksFor` returns `[]` by contract and
  the caller falls back to seed-query rails — taste-first with the cold
  fallback preserved, never an empty rail.
- **Warm:** recency-decayed affinities + session context + agreement
  take over smoothly (no mode switch, just stacking terms).

## Anti-repeat design

1. **Shown memory**: every surfaced id is recorded (`noteShown` /
   `shownIds` / `shownCounts`) and sinks future rankings.
2. **Rotation salt**: `rotationSaltFor(refreshCount)` mixes the refresh
   count with a 6h time bucket (Knuth hash), re-rolling score ties every
   refresh and across the day.
3. **Mood arc**: same-set resequence breaks runs without dropping tracks.
4. **Skip memory**: track skips + artist aversions persist in the taste
   profile (`taste.json`, load-decayed ×0.98) and the engine
   (`skipCounts` / `skipArtists`, capped).

## Tuning knobs (`lib/core/discovery.dart` consts)

`tasteRecencyBase 0.85` / `tasteRecentWindow 30` (affinity shape);
`tasteArtistWeight 2.0` / `tasteMoodWeight 3.0` (taste strength);
`tasteRelatedWeight 5.0`, `tasteCoOccurWeight 1.5`,
`tasteCoOccurQuad 0.75` (graph vs agreement); `tasteSessionArtistWeight
1.5` / `tasteSessionMoodWeight 2.0` / `tasteSessionWindow 5` (moment vs
history); `tasteColdMoodBoost 1.25`; `tasteSkipFirst 3.0` /
`tasteSkipPerExtra 2.5` / `tasteSkipMax 8.0` / `tasteSkipArtistPenalty
2.0`; `tasteRecentPenalty 3.0`, `tasteShownPerImpression 0.6` /
`tasteShownMax 4.0`; `tasteTopPicksPerArtist 3` /
`tasteUpNextPerArtist 2`; mood fit consts (`moodSameBonus 4.0`,
`moodEnergyWeight 2.5`, …). Repository budgets: `tasteFetchTimeout 8s`,
`tasteOverallTimeout 25s`, `recoBlendTtlMs 30m`, `topPicksSeedCap 10`
× `topPicksPerSeed 3` → `topPicksPoolCap 24`.

## How to evaluate (feel each behavior)

- **Psychic Up Next**: play 3–4 songs by related artists in a row, open
  the queue sheet → Suggested Next should mirror the *session* artists,
  not just all-time taste (signal 5). Kill the app, replay one of them →
  suggestions stay close (signal 4 persisted).
- **Multi-seed agreement**: start radio from a song two of your recent
  plays both relate to → it should sit top-3 (signal 3, co² term).
- **Cold start**: fresh profile, play one lofi track → Up Next should be
  lofi/chill/slow, mixed artists, not the same singer (signals 1 + 7).
- **Skip burial**: skip a track twice → it and its artist vanish from
  suggestions; unlike (heart) an artist → they float (signals 8, 6).
- **No repeats**: pull-to-refresh home twice → Top Picks reorder
  (salt); play through a 20-song radio → no artist appears 3× in a row
  and moods alternate (arc + caps + shown memory).
- **Offline**: airplane mode, play anything → refill still appends from
  the library tier, mood-matched (tier 4).
