# Phase 03 — Session integrity + updater (Must/Should)
Scope: `cresca-flutter/lib/audio/playback.dart:562-583`, `lib/app/state.dart:973-978,756-763`, `lib/app/updates.dart:78-105,252-290`
Tasks:
1. Single writer for `playback_state.json`: ticker updates memory only, session writer persists via atomicWrite. Remove plain write.
2. Update throttle: only stamp `update_last_check` on success. Separate last_attempt.
3. ABI: read real `Build.SUPPORTED_ABIS` via platform channel instead of always universal. Fix `pickApkAsset` fallback order.
4. Leaked `FileDownloader().updates` subscription: cancel on success, filter APK task out of DownloadStore maps.
Done when: kill-mid-write no torn JSON, update tests cover throttle + ABI.
