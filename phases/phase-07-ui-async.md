# Phase 07 — UI async + playback sheets (Must fix)
Scope: `lib/app/widgets/lyrics_panel.dart:64-229,1107-1278`, `lib/app/widgets/player_sheet.dart:2093-2261,1727-1735,969-983,1552-1559`, `lib/app/widgets/video_sheet.dart:741-756,1188-1198,1321-1324,1514`, `lib/app/widgets/mini_player.dart:74-83,142-144,464-467,494-563`
Tasks:
1. Lyrics: close old http/Explode, add gen token, parallel lookups first-good. Throttle position rebuilds.
2. Details/Artist: gen token, move out of player_sheet.dart. Guard snap fire with mounted.
3. Video: single live decoder, fix seek split (seek both), slot-width decode, await handoff.
4. Mini/seek: direct slider value (no Tween restart), Transform drag, delete dead _EqBars + timer-in-build + useless mixin.
Done: skip-fast shows correct lyrics/art, no leak, no flicker.
