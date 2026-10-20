# Phase 05 — Lean + hygiene (Should/Nice)
Scope: whole repo, no behavior change except deletes
Tasks:
1. `.gitignore`: add `.env`, `*.zip`, `__pycache__/`, confirm `*.apk *.keystore local.properties` ignored. Do NOT commit `.env`/zips.
2. Dedup: one `TubeClient` (delete `streamkit/client.dart` copy or re-export), one `UrlCache` (delete `bundle.dart` copy). Merge triple header clients, drop dead `canFetchInnerTube` gate + `DownloadStore._listen`.
3. Batch precache: reuse `primeNext` batches-of-3 in `state.dart:2019-2080`, `repository.dart:635-642,588-593`.
4. Config: `analysis_options.yaml` include `flutter_lints`, add Android `flutter test` CI, add `LICENSE`, fix iOS force-unwraps + fallback Invidious instance.
Done when: `flutter analyze` clean, duplicate grep zero hits, lean diff negative lines only.
