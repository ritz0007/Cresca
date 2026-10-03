// Pure-Dart call-guard + auto-skip policy (P14, P12).
// Native refs: CallGuard.kt (tap routing, foreground-service rule,
// pause-on-call / resume-after-call with 400ms settle, user-pause
// memory), PlayerQueue retryWithNextUrl/auto-skip (403 → drop + ×3,
// skip ≤5 then error), STATE_ENDED dead-end fix.

// Android AudioManager modes (no Android import needed for the math).
const int audioModeNormal = 0;
const int audioModeRingtone = 1;
const int audioModeInCall = 2;
const int audioModeInCommunication = 3;

bool isCallMode(int mode) {
  try {
    return mode == audioModeInCall ||
        mode == audioModeInCommunication ||
        mode == audioModeRingtone;
  } catch (_) {
    return false;
  }
}

/// What a play tap should do during a call.
enum CallPlayAction { startNow, deferUntilCallEnd }

/// Play taps during a call must defer (focus locked); the UI prepares +
/// pauses and the tap parks until the call ends.
CallPlayAction actionForTap(bool isInCall) =>
    isInCall ? CallPlayAction.deferUntilCallEnd : CallPlayAction.startNow;

/// Foreground-service starts mid-call crash the app (focus locked →
// RemoteServiceException). Only start off-call.
bool shouldStartForegroundService(bool isInCall) => !isInCall;

/// Pause/resume state machine for the mode listener (API 31 surface in
/// the platform shell; logic pure here). 400ms settle + user-pause
/// memory live in the controller; this decides the outcomes.
class CallResumeGate {
  bool resumeAfterCall = false;
  bool userPausedDuringCall = false;

  /// Returns true when the controller should auto-resume (was sounding
  /// at call start, user didn't pause mid-call).
  bool onMode(int mode, bool sounding) {
    try {
      if (isCallMode(mode)) {
        resumeAfterCall = sounding;
        userPausedDuringCall = false;
        return false;
      }
      if (mode == audioModeNormal) {
        final should = resumeAfterCall && !userPausedDuringCall;
        resumeAfterCall = false;
        return should;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  void noteUserPause() {
    try {
      userPausedDuringCall = true;
    } catch (_) {}
  }
}

/// Auto-skip budget: unresolvable tracks skip silently up to [maxSkips],
/// then the run surfaces an honest error (P5). 403 retry ×3 per track
/// is the queue engine's retriesLeft; this counts consecutive dead
/// tracks across the run.
class SkipBudget {
  final int maxSkips;
  int used = 0;
  SkipBudget({this.maxSkips = 5});

  /// Returns true while another silent skip is allowed.
  bool take() {
    try {
      if (used >= maxSkips) return false;
      used++;
      return true;
    } catch (_) {
      return false;
    }
  }

  void reset() {
    try {
      used = 0;
    } catch (_) {}
  }
}

/// Track-end decision (STATE_ENDED dead-end fix): advance when the engine
/// has somewhere to go, else rewind-to-0 + pause (replayable, never stuck
/// at ENDED with the seek bar pinned at the end).
enum EndAction { advance, rewindPause }

EndAction endAction(bool hasNext) =>
    hasNext ? EndAction.advance : EndAction.rewindPause;
