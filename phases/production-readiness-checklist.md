# Production-readiness checklist — Cresca Flutter (2.1.0+23)

Source of truth for release gates: `RESTRUCTURE.md` §5 / `phases/phase-05-release.md`.
U10 sign-off (Oct 2026): `cresca-flutter/pubspec.yaml` `2.1.0+23`;
release signing wired (no debug key in release builds when
`android/key.properties` is present); AGP/KGP pinned. Check each box
only with evidence (command output, screenshot, artifact hash).

## 1. Signing (CLOSED by U10 — verified, fingerprint pending Day-2 build)
- [x] `cresca-flutter/android/key.properties` created, gitignored
      (`git check-ignore` confirms; storeFile points OUTSIDE the repo:
      `C:/Users/Rish/keys/cresca-release.keystore`; store/key
      passwords + alias filled).
- [x] `cresca-flutter/android/app/build.gradle.kts` release block reads
      `key.properties` (`hasReleaseKey` gate, lines 15–24) and uses the
      `release` signing config when present, debug ONLY as a local-dev
      fallback (lines 72–82, loud comment: "Never publish that APK/AAB").
- [ ] `flutter build apk --release` (+ `--split-per-abi`) and
      `flutter build appbundle` succeed with release signature;
      `apksigner verify --print-certs` recorded below. (Day-2 emulator
      build; paste line here.)
- [x] No `key.properties` / keystore contents committed
      (`git status --short` clean of secrets, `check-ignore` passes).

Release cert fingerprint: ____________________  Date: __________  By: ______

## 2. Version + identity (CLOSED by U10 — decision: KEEP side-by-side)
- [x] `pubspec.yaml` bumped to `2.1.0+23` with U1–U10 CHANGELOG entry
      (root `CHANGELOG.md ## 2.1.0`).
- [x] Application ID story decided: Flutter `com.cresca.cresca_app`
      (`android/app/build.gradle.kts:27,41`) vs native `com.cresca.app`
      = side-by-side install, no upgrade path. Decision: KEEP both ids
      (U10 doc §4.2: renaming Flutter to the native id would collide on
      user phones). No release under either id without checklist sign.
- [x] `android:label` = "Cresca Music" (verified in
      `AndroidManifest.xml`; never rename).
- [x] Motion default: `lib/app/state.dart` `motionOn = true` (U1 turned
      the default ON with kill-switch in Profile). Decision: ON.

## 3. Permissions + manifest (CLOSED by U10 — Day-2 on-device verify pending)
- [x] Declared permissions reviewed (Flutter manifest):
      INTERNET, FOREGROUND_SERVICE, FOREGROUND_SERVICE_MEDIA_PLAYBACK,
      POST_NOTIFICATIONS + REQUEST_INSTALL_PACKAGES (added by U10: the
      in-app updater `installApk` requests it at runtime before
      `OpenFile.open`; system installer always prompts — no silent
      installs). No location/storage/contacts.
- [x] `usesCleartextTraffic="true"` proven host-by-host in the manifest
      comment (U10 grep audit): cleartext ONLY to 127.0.0.1 (just_audio
      localhost proxy) and JAM hosts (default
      `http://209.126.81.22:13009`, user-overridable incl. LAN; ws/wss
      upgrade). All API/media/artwork/lyrics/update hosts HTTPS-only.
- [ ] Notifications runtime permission (33+) exercised on jam16.
- [ ] `cresca://` deep-link filters (Spotify PKCE + JAM) verified
      on-device (tap-back returns to app, no chooser dead-end).
- [ ] Portrait lock + edge-to-edge + fullscreen-landscape video (A2)
      verified; no restart-on-rotate regression.

## 4. Build warnings (record, don't ignore)
- [ ] Release build log captured with pinned AGP `9.1.0` + KGP
      `org.jetbrains.kotlin.android 2.4.0` + `kotlin { compilerOptions
      { jvmTarget = JVM_17 } }` DSL (`android/settings.gradle.kts:24-26`,
      `app/build.gradle.kts:48-52`); all KGP/AGP deprecation or migration
      warnings pasted into the release notes appendix (exact text).
- [ ] `flutter analyze` clean at release commit (paste tail).

Warning appendix: ____________________ (or "none observed on <date>")

## 5. Performance / size / battery
- [ ] Cold start → interactive on jam16 timed (target ≤ native parity;
      record ms): __________
- [ ] Search→play tap latency + skip latency spot-checked on LTE
      (record ms): __________
- [ ] APK/AAB per-ABI sizes recorded (arm64-v8a / armeabi-v7a / x86_64):
      __________ / __________ / __________
- [ ] Background playback 30 min: no ANR, notification controls live,
      Live Updates path (Y2) sane on <36 fallback device.
- [ ] Cache budgets sane post-soak: 4 GB audio LRU + 10 MB/track cap,
      TTLs per C1 (12 h / 30 min / 7 d / 5 h+6 h).

## 6. QA regression sweep (catalog sweep on jam16, per Phase 5 exit)
- [ ] Cold restore (queue + position, no autoplay) — P13
- [ ] Search → play → queue → shuffle (incl. SMART) → repeat — S1-S4/P11-P12
- [ ] Offline: downloads list with MB, file-backed replay, delete — L5
- [ ] Lyrics karaoke (synced + ≥9 s gap dots + tap-to-seek) — P7
- [ ] Video mode incl. fullscreen landscape + quality picker — P9
- [ ] YouTube login WebView + logout wipe; Spotify connect/import — G1/G2
- [ ] JAM host + guest join, queue sync; both JAM suites green — Phase 4
- [ ] Update check path (banner + download/install) — Y4
- [ ] `flutter test` full suite green (count: __________).
- [ ] Screenshot per sweep step archived at: ____________________

## 7. Docs + archive (Phase 5 exit)
- [ ] CHANGELOG `1.5.1` entry finalized (remove "unreleased", confirm
      commit/test counts).
- [ ] README + RESTRUCTURE status updated; `app/` → `app-legacy/` archived.
- [ ] Tag `v1.5.1-flutter` (or agreed scheme) pushed; GitHub release with
      per-ABI APKs + AAB attached.

## Sign-off
| Role | Name | Date | Go / No-go |
|---|---|---|---|
| Eng (build+signing) | | | |
| QA (device sweep) | | | |
| Release owner | | | |

Blocked-ship items (must be Go): §1 signing, §2 ID/version decision,
§4 warning log, §6 full sweep green. Everything else needs a written waiver.
