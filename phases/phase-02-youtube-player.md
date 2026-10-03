# Phase 2 — YouTube core + player

Covers: H1–H11, R1, S1–S4, M1, P1–P6, P10–P15 (audio path), C1–C5, Y1 (basic).

## Steps

- [ ] Deps add: `youtube_explode_dart`, `just_audio`, `audio_service`, `http`
- [ ] `YoutubeRepository` port: searchMusic/searchVideos/searchArtists/
  trending/chartTopVideos/related/autoplay (+vibeQueries/isSameName/rankByVibe,
  newReleases round-robin, playlistTracks, SearchPager/KioskPager w/ seen+exhausted)
  with S3 gates + C4 resolve (45 s cap, single-flight, 5 h/6 h URL cache,
  403 drop + ×3 retry)
- [ ] `PlayerQueue` port (P12): order list, generation-cancel, SHUFFLE
  OFF/ON/SMART + smart scoring, repeat OFF/ALL/ONE manual, playNext/add/
  remove/moveInOrder/applyOrder, 2-ahead priming (just_audio preload),
  adoptJamQueue silent swap, auto-tail rules, setQueueSilent restore
- [ ] Player UI: mini-player (P10: swipe L/R, glide+snap+chevrons, EqBars,
  progress), full sheet (P1–P6: art+backdrop+beat-idle-breathe, ticker,
  title/artist+artist-tap, seek bar tap+drag, transport, actions row incl.
  JAM entry → Phase-4 placeholder toast, More menu M1), queue sheet (P11:
  prev/Now/next, tap-play, remove, drag reorder, labels)
- [ ] Home (H1–H4,H6–H10): header+spinner+hint, hard-pull refresh (H2),
  Top Picks + Play-all/Shuffle + See All, rails (Released/Charts/moods/
  Because/personalized/discovery), moods → search, hero Play/Shuffle,
  skeleton/offline-Retry/reconnect, update banner hook (wiring Phase 3),
  staged paint + parallel waves
- [ ] Trending tab (R1): 5 rails, 7 d cache, parallel refresh
- [ ] Search (S1–S4): 250 ms debounce + cache-first, suggestions 180 ms,
  artist row + fallback, TrackRows + TrackMenu (M1 all 9 actions)
- [ ] See All page (H11): endless pager, Play-all/Shuffle-play, tap-more
- [ ] audio_service: notification + lockscreen + prev/like/next (Y1 basic);
  call-guard park/resume (P14); session restore cold-start (P13);
  auto-skip ≤5 + error text; 150 ms clock; buffers per C5

## Exit

Search→play→skip→queue→shuffle/repeat→restore all live on jam16;
simulated 403 skips cleanly; screenshots per screen; tests for queue
ordering + gates green.
