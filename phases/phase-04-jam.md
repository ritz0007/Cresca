# Phase 04 — JAM lockdown (Must fix)
Scope: `cresca-flutter/lib/jam/protocol.dart:12`, `lib/jam/client.dart:225-228`, `lib/jam/session.dart`, `jam-server/server.js`, `jam-server-python/server.py`
Tasks:
1. Transport: move `jamServerUrl` to config, document WSS + reverse proxy. Add Origin allow-list on both servers. Use CSPRNG room codes.
2. AuthZ: gate `play/pause` like `next/prev/seek` when allowGuests=false. Enforce server-side allow-list.
3. Validation: clamp `pos` to 0..24h, allow only `https:` thumb/url, require `op` (no empty-op bypass). Fix Python `set.pop()` arbitrary evict -> FIFO. Copy Node snapshot-list broadcast pattern to Node.
4. Caps: total-socket + per-IP-socket cap, handshake timeout. Fix Python buffered_amount dead check.
Done when: guest-cannot-control test, replay without op dropped, ws load test with slow guest passes.
