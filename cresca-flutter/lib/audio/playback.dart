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
import '../data/cache.dart';
import '../data/resolve.dart';
import '../data/streamkit/bundle.dart' as sk;

/// Position broadcast throttle (C5, event-driven).
///
/// Native pushes progress on state changes + a 10s ticker; the old 150ms
/// polling Timer kept the CPU awake 6.6x more often for a number the OS
/// interpolates itself. Position/duration/buffered/player-state/index
/// streams now drive broadcasts, throttled to at most 1/s while playing
/// (force-broadcast on play/pause/track change).
const Duration positionBroadcastFloor = Duration(seconds: 1);

/// Session persistence cadence (P13, 5s position-only ticker).
const Duration sessionTick = Duration(seconds: 5);

/// Polling clock retired in favor of event streams; kept for API compat.
@Deprecated('Use event-driven positionStream broadcasts instead.')
const Duration positionClock = Duration(milliseconds: 150);

/// 4GB LRU audio budget, 10MB per-track cap (C2). VideoId-keyed files
/// mirror the native customCacheKey ("yt:"+id) so replays hit disk.
/// Canonical values live in data/cache.dart; these aliases stay for
/// existing importers.
const int audioDiskBudgetBytes = audioCacheBudgetBytes;
const int audioTrackCapBytes = audioCacheTrackCapBytes;
const String audioCacheDirName = 'exoplayer';

/// Resolve/open retry budget per track (native PlayerQueue retriesLeft).
const int maxLoadRetries = 3;

/// Backoff base between resolve re-tries (400ms << attempt).
const Duration loadRetryBase = Duration(milliseconds: 400);

/// Per-URL timeout when filling the gapless tail.
const Duration windowFillTimeout = Duration(seconds: 8);

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
        // ROOT-CAUSE FIX (R5): MediaItem carried no duration, so the
        // audio_service media notification had no total — no seekbar /
        // progress on the shade + lockscreen, and the "live" alert read
        // as dead. Duration is nullable; null (still loading) is fine.
        Duration? total;
        try {
          total = c.player.duration;
        } catch (_) {
          total = null;
        }
        mediaItem.add(MediaItem(
          id: track.id,
          title: track.title,
          artist: track.displayArtist(),
          duration: total,
          artUri: track.thumbUrl.isEmpty
              ? null
              : Uri.tryParse(track.thumbUrl),
        ));
      }
      final p = c.player;
      // Notification like heart (screenshot parity): filled when the
      // current track is liked, outline otherwise. Compact slot keeps
      // prev/play/next; the heart rides the expanded view.
      var liked = false;
      try {
        liked = c.isCurrentLiked?.call() ?? false;
      } catch (_) {}
      final likeControl = MediaControl.custom(
        androidIcon: liked
            ? 'drawable/ic_cresca_heart'
            : 'drawable/ic_cresca_heart_outline',
        label: liked ? 'Unlike' : 'Like',
        name: actionLike,
      );
      playbackState.add(playbackState.valueOrNull?.copyWith(
            controls: [
              MediaControl.skipToPrevious,
              if (p.playing) MediaControl.pause else MediaControl.play,
              MediaControl.skipToNext,
              likeControl,
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
              likeControl,
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
          // Re-broadcast so the heart flips to its new state.
          try {
            await c.handler.broadcastState();
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

  /// Transient-focus resume arm (headset/focus matrix in call_gate.dart).
  final FocusResumeGate focusGate = FocusResumeGate();

  /// Battery-kind session ticker gate: 5s cadence, writes only when
  /// sounding and the position actually moved (no paused-overnight IO).
  final SessionTickPolicy tickPolicy = SessionTickPolicy();

  /// Call gate: mid-call taps prepare + pause, never play (P14).
  bool deferPlay = false;

  /// Parked tap while a call held focus (started on call end).
  Future<void> Function()? parkedAction;

  String? errorLine;
  bool resolving = false;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _bufSub;
  StreamSubscription<Duration?>? _durSub;
  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<PlayerException>? _errorSub;
  Timer? _sessionTimer;
  int _loadGen = 0;
  int _lastBroadcastMs = 0;

  /// Live gapless window: track ids in playlist order, mirrored with the
  /// player playlist ([player.audioSources]). Tail fills append live (no
  /// rebuild = no jank); manual loads replace the playlist wholesale.
  /// Length mismatch against the player playlist means a foreign write —
  /// bail to the slow resolve path rather than mis-adopting.
  final List<String> _windowIds = [];

  /// Hooks the app layer wires: persistence, like toggles, errors.
  Future<void> Function(Map<String, dynamic>? session)? onSaveSession;
  Future<void> Function()? onLikeToggle;

  /// Like state for the notification heart (wired by app layer to
  /// LibraryStore.isLiked for the current track). Null = outline.
  bool Function()? isCurrentLiked;
  void Function(String message)? onError;

  /// Local-file override (offline downloads): when set and non-null
  /// for the current track id, the file plays instead of resolving.
  /// Replay prefers file (L5).
  File? Function(String trackId)? localFileFor;

  /// Fired after every successful track load and transport advance so
  /// the app layer can top up autoplay tails (radio endless).
  Future<void> Function()? onAdvanced;

  // ----- Endless-queue refill hook (ADDITIVE ONLY) -----
  // The app layer wires [refillFor] to repository.endlessRefillFor and
  // calls [maybeRefill] from onAdvanced (after EVERY played song). When
  // engine.needsRefill() fires (≤2 remaining) a fresh related batch is
  // appended via engine.appendAuto (dupe-safe, skip-safe) so playback
  // never dead-ends — even from a single song. Existing playback paths
  // below are untouched.
  //
  /// Fresh-batch fetcher: (current, queueIds, skipIds) → ranked tracks.
  /// Every hop inside is timeout-bounded + never-throw (repository).
  Future<List<YtTrack>> Function(
    YtTrack current,
    Set<String> queueIds,
    Set<String> skipIds,
  )? refillFor;

  /// Fired after a refill batch lands (UI persist/paint hook).
  Future<void> Function(List<YtTrack> fresh)? onRefilled;

  /// Re-entrancy guard: one refill flight at a time (battery-kind).
  bool refillInFlight = false;

  /// No-repeat-of-skipped memory for refills (fed by UI skip taps).
  final Set<String> refillSkipIds = <String>{};

  /// Record a skip for refill decay (clamped, never throws).
  void noteRefillSkipped(YtTrack t) {
    try {
      if (t.id.isEmpty) return;
      refillSkipIds.add(t.id);
      if (refillSkipIds.length > 500) {
        refillSkipIds.remove(refillSkipIds.first);
      }
      try {
        engine.noteSkipped(t);
      } catch (_) {}
    } catch (_) {}
  }

  /// Fired synchronously after every engine mutation (setQueue, playAt,
  /// next, previous) so the UI paints instantly without awaiting the
  /// (potentially minutes-long) resolve cascade. The app layer hooks
  /// this to notifyListeners.
  void Function()? onQueueChanged;

  /// Fired on transport state flip (play/pause within a track) — JAM
  /// host broadcasts pause/play to the room on it.
  void Function()? onTransportChanged;

  /// Fired right after a bundle resolves (track + full bundle: ranked
  /// audio, muxed video, meta). App layer memos meta for zero-request
  /// About panels. Not fired for offline-file playback (no bundle).
  /// Never throws (invocation is guarded).
  void Function(YtTrack track, sk.StreamBundle bundle)? onBundleResolved;

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
              // Native fetch parity: ExoPlayer sends the app UA directly
              // (no localhost proxy — sources carry no custom headers).
              userAgent: 'Cresca/1.0 (Android)',
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
    isCurrentLiked = null;
  }

  Future<void> init() async {
    try {
      _stateSub = player.playerStateStream.listen(_onPlayerState);
      _indexSub = player.currentIndexStream.listen(_onIndex);
      // Event-driven position updates (no polling): the OS interpolates
      // progress between broadcasts; streams fire natively (16–200ms)
      // and the floor below throttles notification traffic to 1/s.
      _posSub = player.positionStream.listen((_) => _maybeBroadcast());
      _bufSub =
          player.bufferedPositionStream.listen((_) => _maybeBroadcast());
      _durSub = player.durationStream
          .listen((_) => _maybeBroadcast(force: true));
      // Player errors (open failures, decoder faults) route to the same
      // silent-skip path as unresolvable tracks — never a crash, never a
      // stuck spinner. Load-path errors are owned by _loadCurrent
      // (resolving == true) so they are ignored here.
      _errorSub = player.errorStream.listen(_onPlayerError);
      _sessionTimer =
          Timer.periodic(sessionTick, (_) => savePositionTick());
      await sweepAudioCache();
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      _sessionTimer?.cancel();
      await _posSub?.cancel();
      await _bufSub?.cancel();
      await _durSub?.cancel();
      await _stateSub?.cancel();
      await _indexSub?.cancel();
      await _errorSub?.cancel();
      _windowIds.clear();
      await player.dispose();
    } catch (_) {}
  }

  /// Throttled notification/lockscreen broadcast. Force on transport +
  /// track changes; position ticks ride the 1/s floor.
  void _maybeBroadcast({bool force = false}) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!force && now - _lastBroadcastMs < positionBroadcastFloor.inMilliseconds) {
        return;
      }
      _lastBroadcastMs = now;
      unawaited(handler.broadcastState());
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
      // Repeat-one never re-resolves: rewind + play in place.
      if (engine.repeatMode == repeatOne && engine.current != null) {
        try {
          await player.seek(Duration.zero);
          if (!deferPlay) {
            try {
              await player.play();
            } catch (_) {}
          }
        } catch (_) {}
        _emit();
        return;
      }
      // Instant path: the next item is already buffered behind current
      // (gapless window) — seek over, no resolve, no spinner.
      final want = engine.upcomingIds(1);
      if (want.isNotEmpty && await _tryInstantAdvance(want.first, 1)) {
        final r = engine.next();
        _emit();
        if (r.step == NextStep.play) {
          unawaited(saveSessionNow());
          _maybeBroadcast(force: true);
          unawaited(_slideWindow(1));
          unawaited(_precacheNext());
          try {
            await onAdvanced?.call();
          } catch (_) {}
        } else if (r.step == NextStep.exhausted) {
          await _onExhausted(r.exhaustedTrack);
        }
        return;
      }
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
      // Instant path: previous item still sits in the window behind us.
      final prev = engine.previousIds(1);
      if (prev.isNotEmpty && await _tryInstantAdvance(prev.first, -1)) {
        final idx = engine.previous();
        _emit();
        if (idx >= 0) {
          skipBudget.reset();
          unawaited(saveSessionNow());
          _maybeBroadcast(force: true);
          unawaited(_trimTail());
          unawaited(_precacheNext());
        }
        return;
      }
      final idx = engine.previous();
      _emit();
      if (idx >= 0) {
        skipBudget.reset();
        await _loadCurrent(autoplay: true);
      }
    } catch (_) {}
  }

  /// Seeks within the live window when [want] is the adjacent item
  /// ([dir] +1 next, -1 prev). True on success (caller adopts the engine
  /// index without resolving); false to take the slow resolve path.
  /// Never throws.
  Future<bool> _tryInstantAdvance(YtTrack want, int dir) async {
    try {
      if (_windowIds.isEmpty) return false;
      if (player.audioSources.length != _windowIds.length) return false;
      final ci = player.currentIndex;
      if (ci == null) return false;
      final ti = ci + dir;
      if (ti < 0 || ti >= _windowIds.length) return false;
      if (_windowIds[ti] != want.id) return false;
      if (dir > 0) {
        await player.seekToNext();
      } else {
        await player.seekToPrevious();
      }
      if (deferPlay) {
        try {
          await player.pause();
        } catch (_) {}
      } else {
        try {
          await player.play();
        } catch (_) {}
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> togglePlay() async {
    try {
      if (player.playing) {
        noteUserPause();
        await player.pause();
      } else {
        if (deferPlay) {
          parkedAction = () async => togglePlay();
          try {
            await player.pause();
          } catch (_) {}
          return;
        }
        focusGate.armed = false;
        await player.play();
      }
    } catch (_) {}
  }

  /// 5s position ticker (P13): position-only save, gated by
  /// [SessionTickPolicy] — no write when paused or unmoved.
  Future<void> savePositionTick() async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!tickPolicy.shouldSave(
        playing: player.playing,
        positionMs: player.position.inMilliseconds,
        nowMs: now,
      )) {
        return;
      }
      final f = File('${cacheDir.path}/$sessionFile');
      if (!await f.exists()) return;
      final pos = player.position.inMilliseconds;
      final text = await f.readAsString();
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final root = decoded.cast<String, dynamic>();
      root['positionMs'] = pos < 0 ? 0 : pos;
      root['savedAt'] = now;
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
        focusGate.armed = false;
        if (sounding) unawaited(player.pause());
        return;
      }
      // Native parity: every return to NORMAL drains parked taps after
      // the settle (not only when auto-resuming) — mid-call taps start
      // here, when the foreground service + focus are safe again.
      if (shouldNotifyOnCallEnd(mode)) {
        Future<void>.delayed(settle, () async {
          try {
            if (shouldResume &&
                !callGate.userPausedDuringCall &&
                !focusGate.armed) {
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
    try {
      focusGate.noteUserPause();
    } catch (_) {}
  }

  // ---------- audio-focus / headset interruptions ----------

  /// Headset unplug / A2DP loss (native setHandleAudioBecomingNoisy):
  /// pause, never auto-resume. The platform shell calls this from the
  /// becoming-noisy callback. Never throws.
  void handleBecomingNoisy() {
    try {
      focusGate.onInterrupt(AudioInterrupt.becomingNoisy, false);
      if (player.playing) unawaited(player.pause());
    } catch (_) {}
  }

  /// Audio-focus / interruption report from the platform shell (focus
  /// loss/gain, ducking). Transient pauses arm a resume that fires on
  /// [AudioInterrupt.focusGain] unless the user paused meanwhile or a
  /// call holds focus. Permanent loss and noisy disarm. Never throws.
  void handleFocusEvent(AudioInterrupt kind) {
    try {
      final action = actionForInterrupt(kind);
      switch (action) {
        case InterruptAction.keepPlaying:
          return;
        case InterruptAction.pauseOnly:
          focusGate.onInterrupt(kind, false);
          if (player.playing) unawaited(player.pause());
          return;
        case InterruptAction.pauseAndArmResume:
          final sounding = player.playing;
          focusGate.onInterrupt(kind, sounding);
          if (sounding) unawaited(player.pause());
          return;
        case InterruptAction.resumeIfArmed:
          if (focusGate.onInterrupt(kind, false) &&
              !deferPlay &&
              !callGate.userPausedDuringCall) {
            unawaited(player.play());
          }
          return;
      }
    } catch (_) {}
  }

  // ---------- internals ----------

  /// Loads the current track: resolve ranked URLs then build the
  /// 2-ahead gapless window. Playback starts the moment the current URL
  /// opens (instant-start — the tail fills behind via [_fillWindow], so a
  /// slow +1/+2 resolve never blocks time-to-first-byte).
  ///
  /// Resolve retries with exponential backoff (400ms << attempt, ×3 —
  /// native retriesLeft); each URL opens directly at the player (native
  /// ResolvingDataSource parity: no Range-probe gate, which burns the
  /// per-URL quota the player itself needs and double-resolves on
  /// throttled nets). YouTube 403s some legs' URLs at open on flagged
  /// IPs (GVS poToken rollout), so fall through to the race's other-leg
  /// URLs then extractor URLs instead of skipping the track. Every open
  /// failure consumes one engine retry and drops the dead URL
  /// (maxRetries respected). All fail → silent auto-skip (≤5, then an
  /// honest error).
  Future<void> _loadCurrent(
      {required bool autoplay, int seekMs = 0}) async {
    final gen = ++_loadGen;
    final track = engine.current;
    if (track == null) return;
    resolving = true;
    errorLine = null;
    try {
      engine.resetRetries();
      tickPolicy.reset();
      // Offline-first: a downloaded file wins over the network (L5).
      File? local;
      try {
        local = localFileFor?.call(track.id);
      } catch (_) {
        local = null;
      }
      if (local != null) {
        if (gen != _loadGen) return;
        await _setFileWindow(track, local.path, seekMs: seekMs);
        if (gen != _loadGen) return;
        await _startPlayback(autoplay: autoplay);
        skipBudget.reset();
        unawaited(saveSessionNow());
        _maybeBroadcast(force: true);
        unawaited(_fillThenPrecache(gen, track));
        try {
          await onAdvanced?.call();
        } catch (_) {}
        return;
      }
      // Bundle first: one parallel race returns ranked audio + muxed
      // video + metadata (seeded for metadata gaps), with backoff
      // between re-resolves. Then the race losers' URLs, then the
      // deciphered manifest once. Each tier opens at most until retries
      // run out.
      final vid = extractVideoId(track.watchUrl);
      if (vid == null) {
        await _onUnresolvable(track);
        return;
      }
      final bundle = await _resolveBundle(track, vid, gen);
      if (gen != _loadGen) return;
      if (bundle == null || !bundle.hasAudio) {
        await _onUnresolvable(track);
        return;
      }
      try {
        onBundleResolved?.call(track, bundle);
      } catch (_) {}
      // Try each ranked URL in order; 403s throw at open. The first
      // opener wins instantly; the tail fills behind. Fresh-first
      // order: ONE memo URL (fast path), then live tiers, then the
      // memo remainder — a stale memo row must never burn the whole
      // retry budget before a fresh manifest gets its chance (that
      // produced phantom auto-skips on IP rotation).
      var working = await _openFirst(
          track, bundle.audioUrls.take(1).toList(), gen, seekMs);
      if (gen != _loadGen) return;
      // Tier 1.5: the winner's URLs all 403'd at open — the race's
      // LOSING legs kept flying in parallel, harvest them now
      // (near-zero added latency).
      if (working == null && engine.retriesLeft > 0) {
        try {
          final extra = await resolver
              .extraAudioUrls(vid, exclude: bundle.audioUrls)
              .timeout(const Duration(seconds: 12));
          working = await _openFirst(track, extra, gen, seekMs);
        } catch (_) {}
        if (gen != _loadGen) return;
      }
      // Tier 2 (native parity): deciphered extractor manifest once —
      // the native app plays these where InnerTube URLs 403 at fetch.
      if (working == null && engine.retriesLeft > 0) {
        try {
          final murls = await resolver
              .manifestAudioUrls(vid)
              .timeout(const Duration(seconds: 40));
          final fresh = <String>[];
          for (final u in murls) {
            if (u.isEmpty || bundle.audioUrls.contains(u)) continue;
            fresh.add(u);
          }
          working = await _openFirst(track, fresh, gen, seekMs);
        } catch (_) {}
        if (gen != _loadGen) return;
      }
      // Tier 2b: memo remainder — only after fresh tiers had their
      // chance (see head attempt above).
      if (working == null && engine.retriesLeft > 0) {
        working = await _openFirst(
            track, bundle.audioUrls.skip(1).toList(), gen, seekMs);
        if (gen != _loadGen) return;
      }
      if (working == null) {
        await _onUnresolvable(track);
        return;
      }
      // Remember the URL that actually opened (not just the first).
      try {
        resolver.urlCache.remember(track.watchUrl, working,
            DateTime.now().millisecondsSinceEpoch);
      } catch (_) {}
      if (gen != _loadGen) return;
      await _startPlayback(autoplay: autoplay);
      skipBudget.reset();
      unawaited(saveSessionNow());
      _maybeBroadcast(force: true);
      unawaited(_fillThenPrecache(gen, track));
      try {
        await onAdvanced?.call();
      } catch (_) {}
    } catch (_) {
      if (gen == _loadGen) await _onUnresolvable(track);
    } finally {
      if (gen == _loadGen) resolving = false;
    }
  }

  /// Serial tail warming: fill the gapless +1/+2 window first
  /// (append-live into the player playlist, no rebuild), then top up
  /// URL memos + sweep the 4GB LRU. Serialized — not concurrent — so
  /// the precache wave mem-hits the fill wave's rows instead of
  /// re-racing the same tracks on throttled networks (battery-kind:
  /// one wave per track load, each leg self-bounded). Gapless
  /// untouched ([_fillWindow] still appends live). Never throws.
  Future<void> _fillThenPrecache(int gen, YtTrack track) async {
    try {
      await _fillWindow(gen, track);
    } catch (_) {}
    try {
      if (gen != _loadGen) return;
      await _precacheNext();
    } catch (_) {}
  }

  /// Starts or holds playback after a successful open. Mid-call taps
  /// prepare + pause, never play (P14 foreground-service rule).
  Future<void> _startPlayback({required bool autoplay}) async {
    try {
      if (autoplay && !deferPlay) {
        try {
          await player.play();
        } catch (_) {}
      } else {
        try {
          await player.pause();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Bundle resolve with exponential backoff between re-resolves
  /// (400ms << attempt, ×[maxLoadRetries]). A tight spin would hammer a
  /// struggling network into 429s; backing off also gives a flapping
  /// leg time to answer. Drops the cached URL before each re-try; stale
  /// generations bail immediately. Null when nothing resolved.
  Future<sk.StreamBundle?> _resolveBundle(
      YtTrack track, String vid, int gen) async {
    sk.StreamBundle? bundle;
    for (var attempt = 0; attempt < maxLoadRetries; attempt++) {
      if (gen != _loadGen) return null;
      try {
        if (attempt > 0) {
          try {
            resolver.dropCachedUrl(track.watchUrl);
          } catch (_) {}
          try {
            await Future<void>.delayed(Duration(
                milliseconds: loadRetryBase.inMilliseconds << (attempt - 1)));
          } catch (_) {}
          if (gen != _loadGen) return null;
        }
        bundle = await resolver.bundleFor(vid,
            seedTitle: track.title,
            seedArtist: track.displayArtist(),
            seedThumb: track.thumbUrl);
      } catch (_) {
        bundle = null;
      }
      if (bundle != null && bundle.hasAudio) return bundle;
    }
    return (bundle != null && bundle.hasAudio) ? bundle : null;
  }

  /// Opens the first URL that plays, setting the current-only window so
  /// audio starts instantly; the tail fills behind via [_fillWindow].
  /// Each open failure drops the dead URL and consumes one engine retry
  /// (maxRetries respected). A superseded load
  /// ([PlayerInterruptedException] / stale gen) returns null WITHOUT
  /// burning retries or cache rows. Returns the opener, or null.
  Future<String?> _openFirst(
      YtTrack track, List<String> urls, int gen, int seekMs) async {
    for (final url in urls) {
      if (gen != _loadGen) return null;
      if (url.isEmpty) continue;
      if (engine.retriesLeft <= 0) return null;
      try {
        await _setCurrent(track, url, seekMs: seekMs);
        return url;
      } on PlayerInterruptedException {
        return null;
      } catch (_) {
        if (gen != _loadGen) return null;
        try {
          engine.retriesLeft--;
        } catch (_) {}
        try {
          resolver.dropCachedUrl(track.watchUrl);
        } catch (_) {}
      }
    }
    return null;
  }

  /// Single local file window (offline replay). Still goes through
  /// setAudioSources so window bookkeeping stays uniform.
  Future<void> _setFileWindow(YtTrack track, String path,
      {int seekMs = 0}) async {
    final src = AudioSource.uri(Uri.file(path), tag: _mediaTag(track));
    _windowIds
      ..clear()
      ..add(track.id);
    await player.setAudioSources(
      [src],
      initialIndex: 0,
      initialPosition:
          seekMs > 0 ? Duration(milliseconds: seekMs) : Duration.zero,
    );
  }

  /// Sets the current-only window: audio starts loading/playing NOW while
  /// the +1/+2 tail resolves behind ([_fillWindow]). Awaiting the tail
  /// before setAudioSources was the old time-to-first-byte killer (two
  /// full bundle races serialized ahead of play on a cold queue).
  Future<void> _setCurrent(YtTrack track, String url,
      {int seekMs = 0}) async {
    _windowIds
      ..clear()
      ..add(track.id);
    await player.setAudioSources(
      [_cachedSource(track, url)],
      initialIndex: 0,
      initialPosition:
          seekMs > 0 ? Duration(milliseconds: seekMs) : Duration.zero,
    );
  }

  /// Fills the 2-ahead gapless tail behind the already-playing current
  /// item: prime bundles first (mem-hit reads), resolve in ONE parallel
  /// wave, append live into the player playlist (no rebuild, no blip —
  /// ExoPlayer flips gaplessly on auto-advance). Stale generations and
  /// desynced windows bail silently.
  Future<void> _fillWindow(int gen, YtTrack current) async {
    try {
      if (gen != _loadGen) return;
      if (_windowIds.isEmpty || _windowIds.first != current.id) return;
      if (player.audioSources.length != _windowIds.length) return;
      final upcoming = pickPrefetch(
          engine.upcomingIds(audioPrefetchCount),
          skipIds: _windowIds.toSet());
      if (upcoming.isEmpty) return;
      try {
        unawaited(resolver.primeNext(upcoming));
      } catch (_) {}
      final resolved = await Future.wait([
        for (final t in upcoming)
          resolver
              .audioUrl(t.watchUrl)
              .timeout(windowFillTimeout)
              .catchError((_) => null),
      ]);
      for (var k = 0; k < upcoming.length; k++) {
        if (gen != _loadGen) return;
        if (player.audioSources.length != _windowIds.length) return;
        final t = upcoming[k];
        final u = resolved[k];
        if (u == null || u.isEmpty) continue;
        if (_windowIds.contains(t.id)) continue;
        try {
          await player
              .addAudioSource(_cachedSource(t, u))
              .timeout(windowFillTimeout);
          _windowIds.add(t.id);
        } on PlayerInterruptedException {
          return;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Slides the window after a gapless auto-advance onto playlist index
  /// [consumed] (native confirmAdvanced): drops the consumed head so the
  /// window stays [current, +1, +2], then tops up the new tail. Never
  /// throws; stale generations bail.
  Future<void> _slideWindow(int consumed) async {
    final gen = _loadGen;
    try {
      if (consumed <= 0) return;
      var n = consumed;
      while (n > 0 &&
          player.audioSources.length > 1 &&
          _windowIds.length > 1) {
        if (gen != _loadGen) return;
        if (player.audioSources.length != _windowIds.length) return;
        try {
          await player
              .removeAudioSourceAt(0)
              .timeout(const Duration(seconds: 3));
          _windowIds.removeAt(0);
          n--;
        } catch (_) {
          return;
        }
      }
      final cur = engine.current;
      if (cur != null && gen == _loadGen) {
        if (player.audioSources.length != _windowIds.length) return;
        await _fillWindow(gen, cur);
      }
    } catch (_) {}
  }

  /// Trims the far tail after a back-skip so the window stays bounded
  /// ([prev, current, +1, +2]): drops from the end only, never the head —
  /// the playing index is untouched. Never throws.
  Future<void> _trimTail() async {
    try {
      while (_windowIds.length > 3 && player.audioSources.length > 1) {
        if (player.audioSources.length != _windowIds.length) return;
        try {
          await player
              .removeAudioSourceAt(player.audioSources.length - 1)
              .timeout(const Duration(seconds: 3));
          _windowIds.removeLast();
        } catch (_) {
          return;
        }
      }
    } catch (_) {}
  }

  AudioSource _cachedSource(YtTrack t, String url) {
    // VideoId-keyed lock-cached file (native customCacheKey "yt:"+id
    // parity): replays + back-skips hit disk instead of re-downloading,
    // and the 4GB sweep below enforces the budget. No headers → no
    // localhost proxy: googlevideo streams direct with the player UA
    // (which is what 403'd the old proxied fetches), every byte cached
    // while it plays. Experimental API (pinned, reviewed on each
    // just_audio bump).
    try {
      final safeId = t.id.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final file = File('${cacheDir.path}/$audioCacheDirName/yt_$safeId');
      // ignore: experimental_member_use
      return LockCachingAudioSource(Uri.parse(url),
          cacheFile: file, tag: _mediaTag(t));
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
      // Eager expiry prune bounds the map on long sessions; near-expiry
      // rows re-resolve behind on next hit (stale-while-revalidate).
      try {
        resolver.urlCache
            .pruneExpired(DateTime.now().millisecondsSinceEpoch);
      } catch (_) {}
      final upcoming = pickPrefetch(
          engine.upcomingIds(audioPrefetchCount),
          skipIds: _windowIds.toSet());
      if (upcoming.isNotEmpty) {
        await Future.wait([
          for (final t in upcoming)
            resolver
                .audioUrl(t.watchUrl)
                .timeout(windowFillTimeout)
                .catchError((_) => null),
        ]);
      }
      await sweepAudioCache();
    } catch (_) {}
  }

  Future<void> _onUnresolvable(YtTrack track) async {
    try {
      if (skipBudget.take()) {
        // Visible skip: the sheet shows errorLine, so an unavailable
        // track never looks like an automatic mystery skip. Cleared
        // by the next successful load (_loadCurrent resets it).
        errorLine = 'Skipping unavailable track…';
        try {
          onError?.call(errorLine!);
        } catch (_) {}
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
      _maybeBroadcast(force: true);
      onTransportChanged?.call();
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

  /// Player errors that escape the load path (decoder faults, mid-play
  /// render failures): drop the dead URL and take the same silent-skip
  /// path as unresolvable tracks — never a crash, never stuck at ENDED.
  /// Load-path failures are owned by [_loadCurrent] ([resolving]) and
  /// ignored here to avoid double-skipping. Never throws.
  void _onPlayerError(PlayerException e) {
    try {
      if (resolving) return;
      final track = engine.current;
      if (track == null) return;
      // Only the sounding index can kill playback: tail-prefetch opens
      // fail here too, and skipping the good current track for a dead
      // +1/+2 would be wrong. Unknown index → assume current (safe).
      try {
        final ci = player.currentIndex;
        if (e.index != null && ci != null && e.index != ci) return;
      } catch (_) {}
      try {
        resolver.dropCachedUrl(track.watchUrl);
      } catch (_) {}
      unawaited(_onUnresolvable(track));
    } catch (_) {}
  }

  void _onIndex(int? i) {
    // Gapless auto-advance landed inside the window (native
    // confirmAdvanced): the playlist tag at [i] identifies the new
    // current — adopt the matching engine index, slide the window so it
    // stays [current, +1, +2], persist. Tag-driven (not positional), so
    // a repeat-all wrap or a rebuilt window can never mis-adopt.
    try {
      // Stale-event guard (phantom auto-skip root cause): manual
      // next()/prev() adopt the engine synchronously AND mutate the
      // window (slide/trim/fill re-index the player). A queued index
      // event from BEFORE the mutation arrives late with a dead
      // snapshot — adopting it would jump an extra track. The engine
      // is source of truth for manual ops, so only honor the event
      // when the live player index still matches it.
      try {
        if (player.currentIndex != i) return;
      } catch (_) {}
      if (i == null || i <= 0 || i >= _windowIds.length) return;
      final id = _windowIds[i];
      if (id.isEmpty) return;
      final idx = engine.items.indexWhere((e) => e.id == id);
      if (idx < 0 || idx == engine.currentIndex) return;
      engine.playAt(idx);
      _emit();
      unawaited(saveSessionNow());
      _maybeBroadcast(force: true);
      unawaited(_slideWindow(i));
      unawaited(_precacheNext());
      unawaited(onAdvanced?.call());
    } catch (_) {}
  }

  /// 4GB LRU sweep + 10MB per-track cap (C2, native ExoCache parity).
  /// Plan is pure ([planCacheEviction]) — IO here only deletes victims.
  Future<void> sweepAudioCache() async {
    try {
      final dir = Directory('${cacheDir.path}/$audioCacheDirName');
      try {
        await dir.create(recursive: true);
      } catch (_) {}
      final entries = await dir.list().toList();
      final rows = <CacheFileRow>[];
      var total = 0;
      for (final e in entries) {
        try {
          if (e is! File) continue;
          final st = await e.stat();
          rows.add(CacheFileRow(
              e.path, st.size, st.modified.millisecondsSinceEpoch));
          total += st.size;
        } catch (_) {}
      }
      final victims = planCacheEviction(rows, total).toSet();
      if (victims.isEmpty) return;
      for (final e in entries) {
        try {
          if (e is File && victims.contains(e.path)) {
            await e.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ----- Endless-queue refill (ADDITIVE ONLY; no existing path touched) -----

  /// True when the queue is about to exhaust (≤ [threshold] remaining).
  /// Pure check over the engine; never throws.
  bool needsRefill({int threshold = endlessRefillThreshold}) {
    try {
      return engine.needsRefill(threshold: threshold);
    } catch (_) {
      return false;
    }
  }

  /// Appends a fresh related batch when [needsRefill] fires. No-op when
  /// the queue is healthy, a refill is in flight, or no [refillFor] is
  /// wired. Returns true when tracks landed. Never throws.
  Future<bool> maybeRefill({int threshold = endlessRefillThreshold, int max = 20}) async {
    try {
      if (refillInFlight) return false;
      final cur = engine.current;
      if (cur == null) return false;
      if (!needsRefill(threshold: threshold)) return false;
      final fetch = refillFor;
      if (fetch == null) return false;
      refillInFlight = true;
      try {
        Set<String> queueIds = {};
        try {
          queueIds = engine.snapshot().map((e) => e.id).toSet();
        } catch (_) {}
        Set<String> skipIds = {};
        try {
          skipIds = {...refillSkipIds, ...engine.skipCounts.keys};
        } catch (_) {}
        List<YtTrack> fresh = const [];
        try {
          fresh = await fetch(cur, queueIds, skipIds);
        } catch (_) {
          fresh = const [];
        }
        if (fresh.isEmpty) return false;
        final before = engine.items.length;
        try {
          engine.appendAuto(fresh.take(max).toList());
        } catch (_) {}
        final landed = engine.items.length > before;
        if (landed) {
          _emit();
          try {
            await onRefilled?.call(fresh);
          } catch (_) {}
        }
        return landed;
      } finally {
        refillInFlight = false;
      }
    } catch (_) {
      try {
        refillInFlight = false;
      } catch (_) {}
      return false;
    }
  }
}
