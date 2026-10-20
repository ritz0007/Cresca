# Phase 06 — UI correctness (Must fix)
Scope: `lib/app/widgets/track_menu.dart:103-104`, `lib/app/screens/playlist_screen.dart:352,360-406,233-235`, `lib/app/screens/search_screen.dart:272,404-497`, `lib/app/widgets/downloads_sheet.dart:75-135`, `lib/app/screens/radio_screen.dart:128-188`, `lib/app/state.dart:1915-1931,379-385`
Tasks:
1. Play -1 crash: fallback to single-track play. Add test for search/radio track.
2. Playlist keys by row id, save order after move, Undo at same index. Test dupes + kill-restore.
3. Search stale: show `_rows` when query set, clear artists on change.
4. Downloads trash: move file to .trash path, not RAM. Clear on dispose.
5. Suggest out of build into initState with cache. Radio heart stopPropagation.
6. Episode bookmark save on track change/finish.
Done: flutter test green, no data-loss paths left.
