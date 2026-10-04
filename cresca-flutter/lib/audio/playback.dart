// Audio binding: QueueEngine + just_audio + audio_service (Y1 basic).
// Native refs: PlaybackService.kt (buffers 1500/30000/500/1000, UA,
// prev/like/next custom commands, 10s progress tick), ExoCache.kt (4GB
// LRU), PlayerQueue primeNext/confirmAdvanced (2-ahead window, gapless),
// CallGuard (defer/park/resume), PlaybackStateStore (5s position ticker).
//
// Plugin-touching code: compile-verified via analyze; behavior lands on
// jam16 with the player UI (Phase-2 exit). Pure policy (session codec,
// call gate, skip budget) is unit-tested in core/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';

import '../core/call_gate.dart';
import '../core/queue.dart';
import '../core/session.dart';
import '../core/track.dart';
import '../data/resolve.dart';

/// Position clock (C5) + session ticker (P13).
const Duration positionClock = Duration(milliseconds: 150);
const Duration sessionTick = Duration(seconds: 5);

/// 4GB LRU audio budget, 10MB per-track cap (C2). VideoId-keyed files
/// mirror the native customCacheKey ("yt:"+id) so replays hit disk.
const int audioDiskBudgetBytes = 4 * 1024 * 1024 * 1024;
const int audioTrackCapBytes = 10 * 1024 * 1024;
const String audioCacheDirName = 'exoplayer';

/// Custom action names (prev/like/next always visible, Y1).
const String actionLike = 'cresca_like';
const String actionNext = 'cresca_next';
const String actionPrev = 'cresca_prev';

/// audio_service foreground handler: delegates transport to the
/// controller, broadcasts MediaItem + PlaybackState for the system
/// notification + lockscreen (Y1). Custom like rides customAction.
class CrescaAudioHandler extends BaseAudioHandler {
  PlayerController? controller;

  Future<void> broadcastState() async {
    try {
      final c = controller;
      if (c == null) return;
      final track = c.engine.current;
      if (track != null) {
        mediaItem.add(MediaItem(
          id: track.id,
          title: track.title,
          artist: track.displayArtist(),
          artUri: track.thumbUrl.isEmpty
              ? null
              : Uri.tryParse(track.thumbUrl),
        ));
      }
      final p = c.player;
      playbackState.add(playbackState.valueOrNull?.copyWith(
            controls: [
              MediaControl.skipToPrevious,
              if (p.playing) MediaControl.pause else MediaControl.play,
              MediaControl.skipToNext,
            ],
            systemActions: const {MediaAction.seek},
            androidCompactActionIndices: const [0, 1, 2],
            processingState: _toAudioProcessing(p.processingState),
            playing: p.playing,
            updatePosition: p.position,
            bufferedPosition: p.bufferedPosition,
            speed: p.speed,
          ) ??
          PlaybackState(
            controls: [
              MediaControl.skipToPrevious,
              if (p.playing) MediaControl.pause else MediaControl.play,
              MediaControl.skipToNext,
            ],
            systemActions: const {MediaAction.seek},
            androidCompactActionIndices: const [0, 1, 2],
            processingState: _toAudioProcessing(p.processingState),
            playing: p.playing,
            updatePosition: p.position,
            bufferedPosition: p.bufferedPosition,
            speed: p.speed,
          ));
    } catch (_) {}
  }

  AudioProcessingState _toAudioProcessing(ProcessingState s) {
    try {
      return switch (s) {
        ProcessingState.idle => AudioProcessingState.idle,
        ProcessingState.loading => AudioProcessingState.loading,
        ProcessingState.buffering => AudioProcessingState.buffering,
        ProcessingState.ready => AudioProcessingState.ready,
        ProcessingState.completed => AudioProcessingState.completed,
      };
    } catch (_) {
      return AudioProcessingState.idle;
    }
  }

  @override
  Future<void> play() => controller?.togglePlay() ?? Future.value();

  @override
  Future<void> pause() async {
    try {
      await controller?.player.pause();
    } catch (_) {}
  }

  @override
  Future<void> skipToNext() async {
    try {
      await controller?.next();
    } catch (_) {}
  }

  @override
  Future<void> skipToPrevious() async {
    try {
      await controller?.previous();
    } catch (_) {}
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await controller?.player.seek(position);
    } catch (_) {}
  }

  @override
  Future<dynamic> customAction(String name,
      [Map<String, dynamic>? extras]) async {
    try {
      final c = controller;
      if (c == null) return null;
      switch (name) {
        case actionLike:
          try {
            await c.onLikeToggle?.call();
          } catch (_) {}
          return true;
        case actionNext:
          await c.next();
          return true;
        case actionPrev:
          await c.previous();
          return true;
      }
    } catch (_) {}
    return super.customAction(name, extras);
  }
}

/// Player controller: owns the engine, the just_audio window, and call/
/// session policy. The UI calls playQueue()/transport methods; the engine
/// decides order, the resolver feeds URLs, the handler faces the OS.
class PlayerController {
  final QueueEngine engine;
  final StreamResolver resolver;
  final AudioPlayer player;
  final Directory cacheDir;
  final CrescaAudioHandler handler;

  final CallResumeGate callGate = CallResumeGate();
  final SkipBudget skipBudget = SkipBudget();

  /// Call gate: mid-call taps prepare + pause, never play (P14).
  bool deferPlay = false;

  /// Parked tap while a call held focus (started on call end).
  Future<void> Function()? parkedAction;

  String? errorLine;
  bool resolving = false;

  Timer? _clock;
  Timer? _sessionTimer;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<int?>? _indexSub;
  int _loadGen = 0;

  /// Hooks the app layer wires: persistence, like toggles, errors.
  Future<void> Function(Map<String, dynamic>? session)? onSaveSession;
  Future<void> Function()? onLikeToggle;
  void Function(String message)? onError;

  /// Fired after every successful track load and transport advance so
  /// the app layer can top up autoplay tails (radio endless).
  Future<void> Function()? onAdvanced;

  /// Fired synchronously after every engine mutation (setQueue, playAt,
  /// next, previous) so the UI paints instantly without awaiting the
  /// (potentially minutes-long) resolve cascade. The app layer hooks
  /// this to notifyListeners.
  void Function()? onQueueChanged;

  void _emit() {
    try {
      onQueueChanged?.call();
    } catch (_) {}
  }

  PlayerController({
    required this.engine,
    required this.resolver,
    required this.cacheDir,
    CrescaAudioHandler? handler,
    AudioPlayer? player,
  })  : handler = handler ?? CrescaAudioHandler(),
        player = player ??
            AudioPlayer(
              audioLoadConfiguration: const AudioLoadConfiguration(
                androidLoadControl: AndroidLoadControl(
                  minBufferDuration: Duration(milliseconds: 1500),
                  maxBufferDuration: Duration(seconds: 30),
                  bufferForPlaybackDuration: Duration(milliseconds: 500),
                  bufferForPlaybackAfterRebufferDuration:
                      Duration(seconds: 1),
                ),
              ),
            ) {
    this.handler.controller = this;
    onLikeToggle = null;
  }

  Future<void> init() async {
    try {
      _stateSub = player.playerStateStream.listen(_onPlayerState);
      _indexSub = player.currentIndexStream.listen(_onIndex);
      _clock = Timer.periodic(positionClock, (_) {
        try {
          unawaited(handler.broadcastState());
        } catch (_) {}
      });
      _sessionTimer =
          Timer.periodic(sessionTick, (_) => savePositionTick());
      await sweepAudioCache();
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      _clock?.cancel();
      _sessionTimer?.cancel();
      await _stateSub?.cancel();
      await _indexSub?.cancel();
      await player.dispose();
    } catch (_) {}
  }

  // ---------- queue entry points (UI + handler) ----------

  Future<void> playQueue(List<YtTrack> tracks, int start) async {
    try {
      engine.setQueue(tracks, start);
      skipBudget.reset();
      _emit();
      await _loadCurrent(autoplay: true);
    } catch (_) {}
  }

  Future<void> playAt(int index) async {
    try {
      engine.playAt(index);
      skipBudget.reset();
      _emit();
      await _loadCurrent(autoplay: true);
    } catch (_) {}
  }

  Future<void> next() async {
    try {
      final r = engine.next();
      _emit();
      if (r.step == NextStep.play) {
        await _loadCurrent(autoplay: true);
      } else if (r.step == NextStep.exhausted) {
        await _onExhausted(r.exhaustedTrack);
      }
    } catch (_) {}
  }

  Future<void> previous() async {
    try {
      final idx = engine.previous();
      _emit();
      if (idx >= 0) {
        skipBudget.reset();
        await _loadCurrent(autoplay: true);
      }
    } catch (_) {}
  }

  Future<void> togglePlay() async {
    try {
      if (player.playing) {
        await player.pause();
      } else {
        if (deferPlay) {
          parkedAction = () async => togglePlay();
          try {
            await player.pause();
          } catch (_) {}
          return;
        }
        await player.play();
      }
    } catch (_) {}
  }

  /// 5s position ticker (P13): position-only save, no queue rewrite.
  Future<void> savePositionTick() async {
    try {
      final f = File('${cacheDir.path}/$sessionFile');
      if (!await f.exists()) return;
      final pos = player.position.inMilliseconds;
      final text = await f.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final root = decoded.cast<String, dynamic>();
      root['positionMs'] = pos < 0 ? 0 : pos;
      root['savedAt'] = DateTime.now().millisecondsSinceEpoch;
      await f.writeAsString(jsonEncode(root));
    } catch (_) {}
  }

  Future<void> saveSessionNow() async {
    try {
      final saver = onSaveSession;
      if (saver == null) return;
      await saver(encodeSession(
        tracks: engine.snapshot(),
        index: engine.currentIndex,
        current: engine.current,
        positionMs: player.position.inMilliseconds,
        shuffleOn: engine.shuffled,
        repeatModeEngine: engine.repeatMode,
        nowMs: DateTime.now().millisecondsSinceEpoch,
      ));
    } catch (_) {}
  }

  /// Cold restore: queue + position back, no autoplay (P13).
  Future<int> restore(Map<String, dynamic> root) async {
    try {
      final s = decodeSession(root);
      if (s == null) return -1;
      final idx = engine.setQueueSilent(
          s.tracks, s.index, s.shuffleOn, s.repeatMode);
      await _loadCurrent(autoplay: false, seekMs: s.positionMs);
      return idx;
    } catch (_) {
      return -1;
    }
  }

  // ---------- call handling (P14) ----------

  void setInCall(bool inCall) {
    try {
      deferPlay = inCall;
      if (inCall && player.playing) {
        unawaited(player.pause());
      }
    } catch (_) {}
  }

  void onCallMode(int mode) {
    try {
      const settle = Duration(milliseconds: 400);
      final sounding = player.playing;
      final shouldResume = callGate.onMode(mode, sounding);
      if (isCallMode(mode)) {
        if (sounding) unawaited(player.pause());
        return;
      }
      if (mode == audioModeNormal) {
        Future<void>.delayed(settle, () async {
          try {
            if (shouldResume && !callGate.userPausedDuringCall) {
              deferPlay = false;
              await player.play();
            }
            final parked = parkedAction;
            parkedAction = null;
            if (parked != null) await parked();
          } catch (_) {}
        });
      }
    } catch (_) {}
  }

  void noteUserPause() {
    try {
      callGate.noteUserPause();
    } catch (_) {}
  }

  // ---------- internals ----------

  /// Loads the current track: resolve URL (single-flight, 45s cap) then
  /// build the 2-ahead gapless window. 403 → drop + ×3 retry → auto-skip
  /// (≤5, then honest error).
  Future<void> _loadCurrent(
      {required bool autoplay, int seekMs = 0}) async {
    final gen = ++_loadGen;
    final track = engine.current;
    if (track == null) return;
    resolving = true;
    errorLine = null;
    try {
      engine.resetRetries();
      var url = await resolver.audioUrl(track.watchUrl);
      var tries = 0;
      while ((url == null || url.isEmpty) && tries < 3) {
        try {
          resolver.dropCachedUrl(track.watchUrl);
        } catch (_) {}
        tries++;
        url = await resolver.audioUrl(track.watchUrl);
      }
      if (gen != _loadGen) return;
      if (url == null || url.isEmpty) {
        await _onUnresolvable(track);
        return;
      }
      await _setWindow(track, url, seekMs: seekMs);
      if (gen != _loadGen) return;
      if (autoplay && !deferPlay) {
        try {
          await player.play();
        } catch (_) {}
      } else {
        try {
          await player.pause();
        } catch (_) {}
      }
      skipBudget.reset();
      unawaited(saveSessionNow());
      unawaited(handler.broadcastState());
      unawaited(_precacheNext());
      try {
        await onAdvanced?.call();
      } catch (_) {}
    } catch (_) {
      if (gen == _loadGen) await _onUnresolvable(track);
    } finally {
      if (gen == _loadGen) resolving = false;
    }
  }

  /// 3-item window [current, +1, +2]: gapless auto-advance inside the
  /// window, instant manual skip (mirrors primeNext). Sources are
  /// videoId-keyed cached files (stable cache key).
  Future<void> _setWindow(YtTrack track, String url,
      {int seekMs = 0}) async {
    final sources = <AudioSource>[_cachedSource(track, url)];
    for (final t in engine.upcomingIds(2)) {
      try {
        final u = await resolver.audioUrl(t.watchUrl);
        if (u != null && u.isNotEmpty) {
          sources.add(_cachedSource(t, u));
        }
      } catch (_) {}
    }
    final seq = sources;
    await player.setAudioSources(
      seq,
      initialIndex: 0,
      initialPosition:
          seekMs > 0 ? Duration(milliseconds: seekMs) : Duration.zero,
    );
  }

  AudioSource _cachedSource(YtTrack t, String url) {
    try {
      final safe = t.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File('${cacheDir.path}/$audioCacheDirName/$safe.m4a');
      // Experimental in just_audio 0.10, but it is the documented
      // videoId-keyed disk cache (mirrors native customCacheKey).
      // NOTE: no custom headers — headers force just_audio's localhost
      // proxy path; direct ExoPlayer fetch matches the native stack.
      // ignore: experimental_member_use
      return LockCachingAudioSource(
        Uri.parse(url),
        cacheFile: file,
        tag: _mediaTag(t),
      );
    } catch (_) {
      return AudioSource.uri(Uri.parse(url), tag: _mediaTag(t));
    }
  }

  MediaItem _mediaTag(YtTrack t) {
    try {
      return MediaItem(
        id: t.id,
        title: t.title,
        artist: t.displayArtist(),
        artUri:
            t.thumbUrl.isEmpty ? null : Uri.tryParse(t.thumbUrl),
      );
    } catch (_) {
      return MediaItem(id: t.id, title: t.title);
    }
  }

  Future<void> _precacheNext() async {
    try {
      for (final t in engine.upcomingIds(2)) {
        try {
          await resolver.audioUrl(t.watchUrl);
        } catch (_) {}
      }
      await sweepAudioCache();
    } catch (_) {}
  }

  Future<void> _onUnresolvable(YtTrack track) async {
    try {
      if (skipBudget.take()) {
        final r = engine.next();
        if (r.step == NextStep.play) {
          await _loadCurrent(autoplay: true);
          return;
        }
        if (r.step == NextStep.exhausted) {
          await _onExhausted(r.exhaustedTrack);
          return;
        }
      }
      errorLine = 'Could not resolve audio stream';
      try {
        onError?.call(errorLine!);
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _onExhausted(YtTrack? seed) async {
    // Autoplay top-up hook: the app layer fills related tracks (radio)
    // and calls engine.appendAuto; empty hook keeps current behavior.
    try {
      if (seed == null) return;
      errorLine = null;
    } catch (_) {}
  }

  void _onPlayerState(PlayerState s) {
    try {
      unawaited(handler.broadcastState());
      if (s.processingState == ProcessingState.completed) {
        final has = engine.hasNext(exhaustHookArmed: true);
        if (endAction(has) == EndAction.advance) {
          unawaited(next());
        } else {
          try {
            unawaited(player.seek(Duration.zero));
            unawaited(player.pause());
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  void _onIndex(int? i) {
    // Gapless auto-advance landed inside the window: adopt the matching
    // engine index (confirmAdvanced) and persist.
    try {
      if (i == null || i <= 0) return;
      final upcoming = engine.upcomingIds(2);
      if (upcoming.isEmpty) return;
      final landed = upcoming.first;
      final idx = engine.items.indexWhere((e) => e.id == landed.id);
      if (idx >= 0 && idx != engine.currentIndex) {
        engine.playAt(idx);
        unawaited(saveSessionNow());
      }
    } catch (_) {}
  }

  /// 4GB LRU sweep + 10MB per-track cap (C2).
  Future<void> sweepAudioCache() async {
    try {
      final dir = Directory('${cacheDir.path}/$audioCacheDirName');
      try {
        await dir.create(recursive: true);
      } catch (_) {}
      final entries = await dir.list().toList();
      final sized = <_SizedFile>[];
      for (final e in entries) {
        try {
          if (e is! File) continue;
          final st = await e.stat();
          if (st.size > audioTrackCapBytes) {
            try {
              await e.delete();
            } catch (_) {}
            continue;
          }
          sized.add(_SizedFile(e, st.size, st.modified));
        } catch (_) {}
      }
      sized.sort((a, b) => a.modified.compareTo(b.modified));
      var total = sized.fold<int>(0, (n, e) => n + e.size);
      for (final e in sized) {
        if (total <= audioDiskBudgetBytes) break;
        try {
          await e.file.delete();
          total -= e.size;
        } catch (_) {}
      }
    } catch (_) {}
  }
}

class _SizedFile {
  final File file;
  final int size;
  final DateTime modified;
  const _SizedFile(this.file, this.size, this.modified);
}
