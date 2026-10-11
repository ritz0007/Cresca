// Pure-Dart motion + cross-cutting numbers.
// Native refs: Motion.kt (kill-switch, tab drift, press-scale .94),
// RESTRUCTURE.md section 3 (single source of truth).

/// SharedPreferences key for the motion kill-switch (default ON).
const String motionPrefKey = 'motion_on';

/// Catalog motion specs in milliseconds (A4).
/// Call-site map (verified Oct 2026 — every spec below has at least
/// one live caller; nothing is dead):
/// - tabEnter/tabExit: app.dart tab crossfade + design.dart tab tint.
/// - artSlide: player_sheet + mini_player art swaps.
/// - titleSlide: player_sheet title slides.
/// - lyricRoll: lyrics_panel line rolls.
/// - press: design.dart PressScale + player/mini press feedback.
/// - splashHold/splashFade/taglineFade/taglineDelay: app.dart boot.
const int tabEnterMs = 220;
const int tabExitMs = 180;
const int artSlideMs = 450;
const int titleSlideMs = 320;
const int lyricRollMs = 280;
const int pressMs = 120;
const double pressedScale = 0.94;
const int splashHoldMs = 1200;
const int splashFadeMs = 400;
const int taglineFadeMs = 600;
const int taglineDelayMs = 250;

/// Sheet + chrome specs: bottom-sheet enter (slide-up + fade,
/// easeOutCubic), exit fade, stagger step, shimmer pulse, bar slide.
/// Call-site map (verified Oct 2026 — every spec has a live caller):
/// - sheetEnter: design.dart SheetEntrance/FadeSlide entrance.
/// - sheetExit: bottom-sheet route exit fade.
/// - stagger: design.dart StaggerColumn + audio/video sheets (40ms).
/// - shimmer: design.dart PulseOpacity + updates.dart progress shimmer.
/// - barSlide: updates.dart UpdateBannerMotion enter.
const int sheetEnterMs = 320;
const int sheetExitMs = 220;
const int staggerMs = 40;
const int shimmerMs = 800;
const int barSlideMs = 220;

/// List-entrance budget: only the first N rows in any scrollable ever
/// animate (StaggerEntrance.maxItems mirrors this). Deeper rows render
/// directly so long lists settle fast and scroll without timer churn.
const int staggerCapItems = 8;

/// Shared curve names (Flutter [Curves] references — kept as docs here
/// because this file is pure-Dart with no flutter imports).
/// - sheet enter: Curves.easeOutCubic
/// - sheet exit / section switch: Curves.easeOut
/// - press back (spring): Curves.easeOutBack (or easeOut, scale-only)
/// - shimmer pulse: Curves.easeInOut
const String curveSheetEnter = 'Curves.easeOutCubic';
const String curveSheetExit = 'Curves.easeOut';
const String curvePressBack = 'Curves.easeOutBack';
const String curveShimmer = 'Curves.easeInOut';

/// When motion is OFF every spec collapses to a 1 ms fade.
int motionMs(bool on, int ms) => on ? ms : 1;

/// Double-value twin of [motionMs]: returns [b] when motion is on,
/// [a] (rest value) when off. Use for scales/opacities that must snap
/// when the kill-switch is off.
double motionDouble(bool on, double a, double b) => on ? b : a;

/// Search / gesture numbers (S1-S2, T1-H2).
const int searchDebounceMs = 250;
const int suggestDebounceMs = 180;
const int hardPullPx = 200;
const int doubleTapMs = 350;
const int manualHoldSec = 3;
const int lyricGapSec = 9;

/// Queue / resolve / sync numbers (P12-C4).
const int resolveCapSec = 45;
const int maxSkips = 5;
const int maxRetries = 3;
const int recentCap = 300;
const int playlistTrackCap = 2000;
const int playlistCap = 200;
const int artistCap = 500;
const int radioCap = 30;
const int radioTrackCap = 200;
const int radioSessionCap = 200;
const int jamQueueCap = 60;
const int jamMemberCap = 12;
const int jamRoomCap = 100;
const int stateFloorMs = 800;
const int queueFloorMs = 1000;
const int sessionTickSec = 5;
const int liveTickSec = 10;
