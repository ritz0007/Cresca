// Pure-Dart motion + cross-cutting numbers.
// Native refs: Motion.kt (kill-switch, tab drift, press-scale .94),
// RESTRUCTURE.md section 3 (single source of truth).

/// SharedPreferences key for the motion kill-switch (default ON).
const String motionPrefKey = 'motion_on';

/// Catalog motion specs in milliseconds (A4).
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

/// When motion is OFF every spec collapses to a 1 ms fade.
int motionMs(bool on, int ms) => on ? ms : 1;

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
