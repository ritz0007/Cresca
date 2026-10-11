// Live Updates driver (Y2) + notification permission (Y3): Dart side
// of the `cresca.live_updates` channel (see MainActivity.kt). API-36
// gated natively; below that every call is a silent no-op and the
// audio_service notification covers controls. 10 s ticker + transport
// events refresh progress; track change restarts the card.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String liveUpdatesChannel = 'cresca.live_updates';

/// 10 s ticker cadence (C5).
const Duration liveTick = Duration(seconds: 10);

class LiveUpdates {
  final MethodChannel _ch;
  LiveUpdates({MethodChannel? channel})
      : _ch = channel ?? const MethodChannel(liveUpdatesChannel);

  Timer? _ticker;
  bool _running = false;
  String _trackId = '';

  /// Last posted values (tests assert the wire shape via overrides).
  String lastTitle = '';
  String lastArtist = '';
  int lastDurationSec = 0;

  /// Starts (or restarts) the card for a track. No-op when nothing to
  /// show; never throws.
  ///
  /// ROOT-CAUSE FIX (R4): the old code set [_running] = true even when
  /// the native post() was a silent no-op (API < 36, or
  /// canPostPromotedNotifications() false, or POST_NOTIFICATIONS
  /// denied — MainActivity.post() returns false for all of these).
  /// That lied to callers and kept progress() spamming a dead channel.
  /// Now [_running] tracks the native result; the track memo is kept
  /// regardless so a later retry still knows what to show.
  Future<void> start({
    required String trackId,
    required String title,
    required String artist,
    required int durationSec,
  }) async {
    try {
      _trackId = trackId;
      lastTitle = title;
      lastArtist = artist;
      lastDurationSec = durationSec < 1 ? 1 : durationSec;
      final ok = await _ch.invokeMethod('start', {
        'title': title.isEmpty ? 'Cresca Music' : title,
        'artist': artist,
        'durationSec': lastDurationSec,
      });
      _running = ok != false;
    } catch (_) {}
  }

  /// Progress refresh: position + play state. Throttle lives with the
  /// caller (ticker / transport events). Clamped to [0, durationSec]
  /// (native post() coerceIn 1:1 — the card's Segment(pos) throws past
  /// the end, which would drop progress silently on long seeks).
  ///
  /// ROOT-CAUSE FIX (R3, additive): [durationSec] is an optional repair
  /// for the stale-duration card. state.dart reads player.duration at
  /// track-change time (usually still null → start() posts a 1 s card)
  /// and the ticker only ever sends pos/playing, so the card was stuck
  /// at 1 s forever. When the caller passes a known duration (>0) it is
  /// forwarded and MainActivity refreshes liveDurSec before re-posting.
  /// Old callers / old natives ignore it harmlessly.
  Future<void> progress(
      {required int posSec, required bool playing, int? durationSec}) async {
    try {
      if (!_running) return;
      await _ch.invokeMethod('progress', {
        'posSec': clampLivePos(posSec, lastDurationSec),
        'playing': playing,
        if (durationSec != null && durationSec > 0)
          'durationSec': durationSec,
      });
    } catch (_) {}
  }

  Future<void> stop() async {
    try {
      _running = false;
      _trackId = '';
      await _ch.invokeMethod('stop');
    } catch (_) {}
  }

  bool get running => _running;
  String get trackId => _trackId;

  /// 10 s ticker: [read] supplies (posSec, playing, alive) each tick.
  /// Caller keeps it cheap; overlapping ticks collapse.
  void startTicker(
      Future<(int, bool, bool)?> Function() read) {
    try {
      _ticker?.cancel();
      var busy = false;
      _ticker = Timer.periodic(liveTick, (_) async {
        if (busy) return;
        busy = true;
        try {
          final r = await read();
          if (r == null) return;
          final (pos, playing, alive) = r;
          if (!alive) {
            await stop();
            return;
          }
          await progress(posSec: pos, playing: playing);
        } catch (_) {
        } finally {
          busy = false;
        }
      });
    } catch (_) {}
  }

  void stopTicker() {
    try {
      _ticker?.cancel();
    } catch (_) {}
    _ticker = null;
  }

  /// Whether the OS can promote (API 36 + user grant). False
  /// everywhere else (caller hides Live Update UI).
  Future<bool> canPromote() async {
    try {
      final v = await _ch.invokeMethod('canPromote');
      return v == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> openNotificationSettings() async {
    try {
      await _ch.invokeMethod('openNotificationSettings');
    } catch (_) {}
  }

  /// Y3: notification permission (Android 13+), once. Returns true when
  /// posting is allowed (or platform needs no grant).
  Future<bool> ensurePermission() async {
    try {
      var st = await Permission.notification.status;
      if (st.isGranted || st.isLimited) return true;
      if (st.isPermanentlyDenied) return false;
      st = await Permission.notification.request();
      return st.isGranted || st.isLimited;
    } catch (_) {
      return true;
    }
  }

  /// One-shot Y3 gate used before first card post per install.
  ///
  /// ROOT-CAUSE FIX (R2): the old code returned true as soon as the
  /// `live_perm_asked` flag was set — WITHOUT checking the actual grant.
  /// So a user who denied once (or revoked later) sailed through the
  /// gate forever while every native notify() silently no-posted. Now
  /// the live OS status is always consulted first; the flag only stops
  /// us re-nagging, never overrides a denial.
  Future<bool> ensurePermissionOnce(SharedPreferences? prefs) async {
    try {
      // Live status first: granted (or non-Android) → pass regardless
      // of the flag; permanently denied → fail fast, never nag.
      try {
        final st = await Permission.notification.status;
        if (st.isGranted || st.isLimited) return true;
        if (st.isPermanentlyDenied) return false;
      } catch (_) {}
      if (prefs?.getBool('live_perm_asked') == true) {
        // Already asked once: re-check, don't re-request (nagging every
        // track change is worse than a missing card). Fall through to a
        // cheap status read so a grant given in Settings takes effect.
        try {
          final st = await Permission.notification.status;
          return st.isGranted || st.isLimited;
        } catch (_) {
          return false;
        }
      }
      final ok = await ensurePermission();
      try {
        await prefs?.setBool('live_perm_asked', true);
      } catch (_) {}
      return ok;
    } catch (_) {
      return true;
    }
  }
}

/// Clamps a progress position into the card range [0, durSec]
/// (native MainActivity post() `pos.coerceIn(0, liveDurSec)` 1:1).
/// Pure; never throws.
int clampLivePos(int posSec, int durSec) {
  try {
    if (posSec < 0) return 0;
    final dur = durSec < 1 ? 1 : durSec;
    return posSec > dur ? dur : posSec;
  } catch (_) {
    return 0;
  }
}
