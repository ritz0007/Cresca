# Phase 5 — Release (Flutter replaces native)

## Steps

- [ ] Icons (`flutter_launcher_icons`), splash (`flutter_native_splash`),
  portrait lock, `cresca://` filters (spotify-callback + jam), permissions
  (notifications 33+, install packages)
- [ ] Signing: reuse `app/cresca-release.keystore` via
  `android/key.properties` (gitignored); release config (no minify v1)
- [ ] `flutter build apk --split-per-abi` + universal;
  `flutter build appbundle`
- [ ] Regression on jam16 (catalog sweep): cold restore, search→play→
  queue→shuffle/repeat, offline, lyrics, video, login, JAM host+guest,
  update-check; screenshot each; `flutter test` + both JAM suites green
- [ ] Version 1.5.0 / versionCode 20 (continuity from native 19/1.4.1)
- [ ] Archive: `app/` → `app-legacy/`, README + CHANGELOG + RESTRUCTURE
  status, tag `v1.5.0-flutter`

## Exit

Signed universal APK + AAB; regression green; native archived; docs done.
