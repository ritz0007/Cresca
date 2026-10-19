// Podcast-grade playback support WITHOUT touching audio/playback.dart:
// variable speed (via the existing just_audio player.setSpeed — the
// coordinator adapts the real player to [SpeedPlayer]), a cancelable
// sleep timer (Timer → pause callback), and per-episode resume tracking
// (persist periodically + on pause, restore on play).
//
// Pure-Dart (no Flutter, no plugins): the coordinator wires these to
// PlayerController/player in app/state.dart. All fallible paths are
// never-throw.

import 'dart:async';

/// Rate steps offered in the episode sheet (0.8–2.0×, research P1).
const List<double> podcastSpeeds = [0.8, 1.0, 1.2, 1.5, 1.8, 2.0];

/// Minimum duck-under before a position is worth persisting.
const int resumePersistMinMs = 5000;

/// Within this much of the end, the episode counts as finished and the
/// bookmark is cleared instead of saved.
const int resumeNearEndMs = 15000;

/// Clamp a requested rate into the supported range. Never throws.
double clampPodcastSpeed(double rate) {
  try {
    if (rate.isNaN) return 1.0;
    return rate.clamp(podcastSpeeds.first, podcastSpeeds.last);
  } catch (_) {
    return 1.0;
  }
}

/// Next rate step above [current] (wraps to the first). Never throws.
double nextPodcastSpeed(double current) {
  try {
    for (final s in podcastSpeeds) {
      if (s > current + 1e-9) return s;
    }
    return podcastSpeeds.first;
  } catch (_) {
    return 1.0;
  }
}

/// Screen-reader label for the speed control (U7: icon-only is not
/// enough — "Playback speed, 1.5x"). Never throws.
String podcastSpeedLabel(double speed) {
  try {
    return 'Playback speed, ${clampPodcastSpeed(speed).toStringAsFixed(1)}x';
  } catch (_) {
    return 'Playback speed';
  }
}

/// Visible + screen-reader sleep text (U7: "Sleep: 20 min" /
/// "Sleep: off" — minutes ceiling so 19:01 still reads 20 min).
/// Never throws.
String podcastSleepLabel(int leftMs) {
  try {
    if (leftMs <= 0) return 'Sleep: off';
    return 'Sleep: ${(leftMs + 59999) ~/ 60000} min';
  } catch (_) {
    return 'Sleep: off';
  }
}

/// Minimal surface the speed helper needs from the real player
/// (just_audio's AudioPlayer satisfies this structurally: setSpeed +
/// speed + playbackEvent-less synchronous getter).
abstract class SpeedPlayer {
  Future<void> setSpeed(double speed);
  double get speed;
}

/// Apply [rate] (clamped) to [player]. Returns the applied rate.
/// Never throws.
Future<double> applyPodcastSpeed(
    SpeedPlayer? player, double rate) async {
  try {
    if (player == null) return clampPodcastSpeed(rate);
    final clamped = clampPodcastSpeed(rate);
    await player.setSpeed(clamped);
    return clamped;
  } catch (_) {
    return clampPodcastSpeed(rate);
  }
}

/// Cancelable sleep timer: fires [onFire] (coordinator passes
/// `controller.player.pause`) once after [duration], or never after
/// [cancel]. Restarting replaces the pending deadline. Never throws.
class SleepTimer {
  final Future<void> Function() onFire;
  Timer? _timer;
  DateTime? _deadline;

  SleepTimer({required this.onFire});

  bool get isActive {
    try {
      return _timer?.isActive ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Milliseconds until fire. 0 when idle. Never throws.
  int remainingMs() {
    try {
      final d = _deadline;
      if (d == null || !(_timer?.isActive ?? false)) return 0;
      final left = d.difference(DateTime.now()).inMilliseconds;
      return left > 0 ? left : 0;
    } catch (_) {
      return 0;
    }
  }

  void start(Duration duration) {
    try {
      cancel();
      if (duration.inMilliseconds <= 0) return;
      _deadline = DateTime.now().add(duration);
      _timer = Timer(duration, () {
        try {
          _deadline = null;
          onFire();
        } catch (_) {}
      });
    } catch (_) {}
  }

  void startMinutes(int minutes) {
    try {
      start(Duration(minutes: minutes));
    } catch (_) {}
  }

  void cancel() {
    try {
      _timer?.cancel();
    } catch (_) {}
    _timer = null;
    _deadline = null;
  }

  void dispose() => cancel();
}

/// Sleep-timer presets offered in the UI (minutes). Never throws on use.
const List<int> sleepTimerPresetsMin = [5, 10, 15, 30, 45, 60];

/// Per-episode resume tracker: in-memory bookmarks with persist policy.
/// The coordinator persists via PodcastStore.saveProgress on
/// [shouldPersist] ticks + on pause, and restores via [resumeFor] on play.
class ResumeTracker {
  final Map<String, int> _positions = {};

  void seed(Map<String, int> saved) {
    try {
      _positions
        ..clear()
        ..addAll(saved);
    } catch (_) {}
  }

  Map<String, int> snapshot() {
    try {
      return Map.of(_positions);
    } catch (_) {
      return {};
    }
  }

  /// Bookmark for [episodeId] (0 = fresh). Never throws.
  int resumeFor(String episodeId) {
    try {
      return _positions[episodeId] ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Record a position tick. Returns true when the coordinator should
  /// persist (crossed the fresh window, or reached the finished zone so
  /// the bookmark can be cleared). Finished (within [resumeNearEndMs]
  /// of the end) drops the bookmark. Never throws.
  bool notePosition(String episodeId, int positionMs, int durationSec) {
    try {
      if (episodeId.isEmpty || positionMs < 0) return false;
      if (durationSec > 0) {
        final total = durationSec * 1000;
        if (positionMs >= total - resumeNearEndMs) {
          if (_positions.remove(episodeId) != null) return true;
          return true;
        }
      }
      if (positionMs < resumePersistMinMs) return false;
      _positions[episodeId] = positionMs;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Explicit pause-time persist: records even short positions ≥1 s so a
  /// quick pause never loses the spot (store still drops <10 s on read).
  bool notePause(String episodeId, int positionMs, int durationSec) {
    try {
      if (episodeId.isEmpty || positionMs < 1000) return false;
      if (durationSec > 0) {
        final total = durationSec * 1000;
        if (positionMs >= total - resumeNearEndMs) {
          _positions.remove(episodeId);
          return true;
        }
      }
      _positions[episodeId] = positionMs;
      return true;
    } catch (_) {
      return false;
    }
  }

  void clear(String episodeId) {
    try {
      _positions.remove(episodeId);
    } catch (_) {}
  }
}
