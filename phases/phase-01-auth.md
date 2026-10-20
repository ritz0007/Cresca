# Phase 01 — Auth + session privacy (Must fix)
Scope: `cresca-flutter/lib/auth/session.dart`, `lib/app/widgets/session_sheet.dart`, `lib/auth/spotify.dart`, `lib/app/state.dart:588-617`, `lib/data/innertube.dart:259`
Tasks:
1. Login: stop using `document.cookie` (misses HttpOnly SID/SAPISID). Read via CookieManager native side. Fix `loginUserAgent('')` fallback. Make `isLoggedIn(jar)` pure + test for SID-substring false positive.
2. Logout wipe: delete `_kPoToken`, `yt_seeds.json`, `resolver.urlCache` + all repo memos. Verify no `X-Goog-EOM-Visitor-Id` after logout.
3. Spotify: require `gotState==wantState && nonEmpty` in `spotify.dart:173-178`.
Done when: `flutter test` session/spotify green + manual WebView login/logout on device verified.
