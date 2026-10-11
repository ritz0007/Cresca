// Pure-Dart session codec (cold restore, no autoplay).
// Native ref: PlaybackStateStore.kt — file playback_state.json, schema
// 1:1 ({savedAt,index,trackId,positionMs,shuffleOn,repeatMode,
// items[200 cap]{id,title,artist,thumb,watch}}), trackId reconcile,
// empty→null. Repeat ints are Media3 (OFF=0, ONE=1, ALL=2); the engine
// uses OFF=0, ALL=1, ONE=2 (queue.dart) — mapped here for compat.

import 'queue.dart';
import 'track.dart';

const String sessionFile = 'playback_state.json';
const int sessionQueueCap = 200;

/// Media3 repeat int → engine repeat int.
int media3RepeatToEngine(int v) {
  switch (v) {
    case 2:
      return repeatAll;
    case 1:
      return repeatOne;
    default:
      return repeatOff;
  }
}

/// Engine repeat int → Media3 repeat int (for files the native app reads).
int engineRepeatToMedia3(int v) {
  switch (v) {
    case repeatAll:
      return 2;
    case repeatOne:
      return 1;
    default:
      return 0;
  }
}

class SavedSession {
  final List<YtTrack> tracks;
  final int index;
  final String trackId;
  final int positionMs;
  final bool shuffleOn;
  final int repeatMode; // engine ints (mapped on codec boundary)

  const SavedSession({
    required this.tracks,
    required this.index,
    required this.trackId,
    required this.positionMs,
    required this.shuffleOn,
    required this.repeatMode,
  });
}

/// Battery-kind 5s ticker policy (P13 position-only saves).
///
/// The native ticker rewrites the file every 5s unconditionally; on mobile
/// that is a disk write + JSON parse every 5s even when paused overnight.
/// This gate keeps the 5s cadence but skips no-op writes: only when
/// sounding, the interval elapsed, AND the position actually moved past
/// [minDeltaMs]. Pure so `dart test` covers it without a filesystem.
class SessionTickPolicy {
  /// Minimum position movement worth persisting (seek-bar jitter guard).
  final int minDeltaMs;

  /// Minimum gap between disk writes.
  final int intervalMs;

  int _lastSaveMs = -1;
  int _lastPositionMs = -1;

  SessionTickPolicy({this.minDeltaMs = 1000, this.intervalMs = 5000});

  /// True when the caller should perform the position-only save now.
  bool shouldSave({
    required bool playing,
    required int positionMs,
    required int nowMs,
  }) {
    try {
      if (!playing) return false;
      final pos = positionMs < 0 ? 0 : positionMs;
      if (_lastSaveMs < 0) {
        _lastSaveMs = nowMs;
        _lastPositionMs = pos;
        return true;
      }
      if (nowMs - _lastSaveMs < intervalMs) return false;
      var moved = pos - _lastPositionMs;
      if (moved < 0) moved = -moved;
      if (moved < minDeltaMs) return false;
      _lastSaveMs = nowMs;
      _lastPositionMs = pos;
      return true;
    } catch (_) {
      return false;
    }
  }

  void reset() {
    try {
      _lastSaveMs = -1;
      _lastPositionMs = -1;
    } catch (_) {}
  }
}

/// Encodes a session. Null when nothing to save (empty/no current).
/// Mirrors save(): index coerced, position floored, items capped at 200.
Map<String, dynamic>? encodeSession({
  required List<YtTrack> tracks,
  required int index,
  required YtTrack? current,
  required int positionMs,
  required bool shuffleOn,
  required int repeatModeEngine,
  required int nowMs,
}) {
  try {
    if (tracks.isEmpty || current == null) return null;
    final safeIndex =
        index.clamp(0, tracks.length - 1 < 0 ? 0 : tracks.length - 1);
    return {
      'savedAt': nowMs,
      'index': safeIndex,
      'trackId': current.id,
      'positionMs': positionMs < 0 ? 0 : positionMs,
      'shuffleOn': shuffleOn,
      'repeatMode': engineRepeatToMedia3(repeatModeEngine),
      'items': [
        for (final t in tracks.take(sessionQueueCap))
          {
            'id': t.id,
            'title': t.title,
            'artist': t.artist,
            'thumb': t.thumbUrl,
            'watch': t.watchUrl,
          },
      ],
    };
  } catch (_) {
    return null;
  }
}

/// Decodes a session. Null on missing/empty/corrupt (native).
/// trackId reconciles the index; index coerced into range.
SavedSession? decodeSession(Map<String, dynamic> root) {
  try {
    final arr = root['items'];
    if (arr is! List || arr.isEmpty) return null;
    final out = <YtTrack>[];
    for (final e in arr) {
      try {
        if (e is! Map) continue;
        final id = (e['id'] ?? '').toString();
        if (id.isEmpty) continue;
        out.add(YtTrack(
          id: id,
          title: (e['title'] ?? '').toString(),
          artist: (e['artist'] ?? '').toString(),
          thumbUrl: (e['thumb'] ?? '').toString(),
          watchUrl: (e['watch'] ?? '').toString(),
        ));
      } catch (_) {}
    }
    if (out.isEmpty) return null;
    final trackId = (root['trackId'] ?? '').toString();
    var index = int.tryParse(root['index'].toString()) ?? 0;
    if (trackId.isNotEmpty) {
      final byId = out.indexWhere((t) => t.id == trackId);
      if (byId >= 0) index = byId;
    }
    index = index.clamp(0, out.length - 1);
    final pos = int.tryParse(root['positionMs'].toString()) ?? 0;
    return SavedSession(
      tracks: out,
      index: index,
      trackId: trackId,
      positionMs: pos < 0 ? 0 : pos,
      shuffleOn: root['shuffleOn'] == true,
      repeatMode: media3RepeatToEngine(
          int.tryParse(root['repeatMode'].toString()) ?? 0),
    );
  } catch (_) {
    return null;
  }
}
