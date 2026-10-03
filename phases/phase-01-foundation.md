# Phase 1 — Foundation (live Flutter loop)

Covers: A1–A9 shell/theme/motion, catalog models, test harness.

## Steps

- [ ] Flutter 3.47.6 installed → `flutter doctor` clean (Android toolchain ✓,
  JDK 17 ✓, `C:\Android\sdk` ✓)
- [ ] `flutter create --org com.cresca --project-name cresca_app cresca-flutter`
  (same applicationId → future updates keep working)
- [ ] Deps now: `cached_network_image`, `palette_generator`, `shared_preferences`,
  `flutter_secure_storage`, `web_socket_channel`, `test`
- [ ] Port pure-Dart core (from YoutubeRepository.kt + JamClient.kt + Motion.kt):
  `YtTrack` (+json, `displayArtist`, `isMusicJunk`, `isArtistLike`,
  `isShortsUrl`, `fmtSubs`), `JamTrack` mapping, `fmtMs`, motion flag store
- [ ] Theme port (Color.kt/Type.kt/Theme.kt): red default, light/dark/system,
  `songAccentOf` + accent schemes, full type scale
- [ ] Scaffold: 5 tabs + glass bottom bar + double-tap-search-focus (T1–T2),
  splash + intro overlay (A1), portrait lock, edge-to-edge (A2),
  crash file-logger (A9)
- [ ] `flutter test` green (models, filters, accent math, queue-less utils)
- [ ] Boot jam16, `flutter run -d emulator-5554`, demo hot reload (`r`),
  screenshot home shell

## Exit

doctor ✓ · runs on jam16 · reload demoed · tests green · no native changes.
Maps to catalog: A1–A9, T1–T2 (+ model layer for S3/M1 later).
