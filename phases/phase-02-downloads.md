# Phase 02 — Downloads, no data loss (Must fix)
Scope: `cresca-flutter/lib/app/downloads.dart`, `lib/data/streamkit/chunks.dart:245-368`, `lib/data/details.dart:100-161`
Tasks:
1. `_active` leak: zero-byte branch `:483-489` must `_active.remove`. Move to finally. Add regression test: failed enqueue -> retry works.
2. `sanitizeFileName:40-63`: keep Unicode letters/numbers, fallback to track.id when empty. Fix listAll/delete collision.
3. Stream to file: replace BytesBuilder-then-write with append-per-chunk (RandomAccessFile/sink). Test with 50MB+ file, check RAM.
4. `DetailsStore.memo`: LRU cap 200 + canonical key (videoId only).
Done when: downloads tests green incl. non-Latin names + zero-byte retry.
