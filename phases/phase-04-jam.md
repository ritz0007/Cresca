# Phase 4 — JAM parity (Flutter)

Skill: docs/JAM.md (F1–F10, fallbacks, protocol §4, tests §5). No
one-sided protocol changes — Node + Python + suites move together.

## Steps

- [ ] Deps add: `qr_flutter`, `app_links`, `share_plus` (ws already in P1)
- [ ] `protocol.dart`: exact §4 catalog (create/join/state/queue/add/
  control/allow/sync_req/ping/leave/end + created/joined/members/state/
  queue/add/control/sync_req/allow/pong/ended/error/left); `st` server
  clock; caps 60/12/100/8 KB; floors 800 ms/1 s/2 s-room/10 s-client
- [ ] `client.dart`: JamClient port — internal server constant (no UI),
  NTP offset (5×400 ms + 10 s), expectedPos, throttles, bounded retry
  (1/2/4/8 s ×4 → manual), pendingCode, migration, leave/end
- [ ] `state.dart`: host event broadcast; guest event mirror + queue adopt
  (adoptJamQueue) + autoplay/top-up disabled; solo-pause + resume-at-host
  (+stale refresh); denial toasts; control/add wishes; JAM-hold retry
  (3×2.5 s → hold + 20 s sync_req); host answers controls/adds/sync_req
- [ ] UI: join form (name+code, auto-join pendingCode), gradient room card
  (QR `cresca://jam/CODE`, code, share link+code), members, guest switch,
  queue (host-local vs snapshot rule), leave/end; deep-link intent-filter
  + auto-join; player JAM button + dot; transport/seek/menu gates
- [ ] `test/jam_test.dart`: dart port of the 21 checks; run vs local Node,
  local Python AND hosted box
- [ ] Cross-check live: Flutter-host ↔ native-guest AND native-host ↔
  Flutter-guest on jam16 (+ emulator-5556 if cheap); screenshots; logcat clean

## Exit

Both directions verified; QR scan joins; link auto-joins; 21/21 dart
tests vs both servers; docs/JAM.md updated if anything moved.
