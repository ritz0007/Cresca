// Video mode (embedded, YTM-style): the video plays INSIDE the player
// sheet in the thumbnail art slot (same position/size as _StaticArt,
// top-anchored full-bleed) instead of a separate window. The video
// camera button in the player sheet toggles this in place. This file
// owns the embeddable [VideoEmbed] widget plus the kept fullscreen
// expand route ([VideoFullscreenPage]); the old separate portrait page
// flow (quality-picker -> VideoPlayerPage route) is deleted.
//
// Per-rendition sounding element, never both audible (diagnosis kept
// from the page era):
//  1. bundle parse ranked BOTH `formats` (true progressive muxed) AND
//     `adaptiveFormats` (video-ONLY DASH) with no audio check, so the
//     tallest pick was usually silent 1080p+. Fixed: muxed reads
//     `formats` only; video-only lives in parseBundleVideoOnly() and
//     rides [StreamResolver.videoOnlyUrls].
//  2. The video element was ALWAYS muted with just_audio as master, but
//     the soundtrack started BEFORE the picture, so video_player's
//     ExoPlayer focus request ducked the engine into silence. Fixed:
//     picture plays first, soundtrack (re)starts LAST (focus-last).
// Muxed (<=720p) URLs carry their own track — the video element is the
// audible clock (seeded from the engine level) and the just_audio engine
// is parked. Taller DASH-only URLs keep muted picture + just_audio
// master, engine reasserted last. Pause/play/seek drive the sounding
// clock and mirror into the parked one, both directions; dispose hands
// the agreed position back so playback never stops. The engine volume
// is never reset here (no player.setVolume calls): the sounding video
// element is seeded from the engine level, the engine level itself is
// left alone for the system-volume crew.
// Continuation: while video mode is on, the sheet keeps the mode flag
// across tracks; [VideoEmbed.didUpdateWidget] reloads the new track's
// video in the background (spinner in slot, then picture). Video end
// (muxed) advances the queue via controller.next(). Turning video off
// disposes the embed, which hands position back to the engine.
// Orientation + system UI are owned by [VideoFullscreenPage] only:
// landscape + immersive while expanded, portrait + edge-to-edge
// restored on collapse/close (main.dart/app.dart untouched). The inline
// embed never touches orientation (portrait default).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../design.dart';
import '../state.dart';
import '../../core/track.dart';

/// True when a rendition height is a progressive-muxed (video+audio)
/// rendition. YouTube serves progressive muxed streams at most at ~720p;
/// taller renditions are DASH video-only (zero audio track).
/// Muxed renditions win their dedup slot, hence a <=720p entry is the
/// audible muxed URL and a taller one is picture-only.
bool videoHeightMuxed(int height) => height <= 720;

/// Bridge between the player sheet's shared transport and the embedded
/// video controller. The sheet owns one [VideoHandle]; the embed
/// registers its callbacks and publishes playing/loading state on it.
/// When [active] is false the sheet drives the audio engine as before.
class VideoHandle {
  /// True while a video controller is live (ready or opening).
  final ValueNotifier<bool> active = ValueNotifier(false);

  /// True while the picture is rolling.
  final ValueNotifier<bool> playing = ValueNotifier(false);

  /// True while resolving/opening (spinner in the art slot).
  final ValueNotifier<bool> loading = ValueNotifier(true);

  /// Sounding-clock position (ms) for lyric/karaoke followers: the
  /// video frame in muxed mode, the engine position in dual
  /// (video-only) mode. Updated on every sync tick — the parked
  /// engine's own positionStream freezes in video mode, so lyrics
  /// must follow THIS clock or they stop changing.
  final ValueNotifier<int> videoMs = ValueNotifier(0);

  /// Toggle picture (+ mirrored soundtrack). Null when inactive.
  Future<void> Function()? togglePlay;

  /// Scrub the picture to [ms] (the sheet seeks the engine itself, so
  /// both clocks land on the same frame).
  Future<void> Function(int ms)? seekToMs;

  void dispose() {
    try {
      active.dispose();
    } catch (_) {}
    try {
      playing.dispose();
    } catch (_) {}
    try {
      loading.dispose();
    } catch (_) {}
    try {
      videoMs.dispose();
    } catch (_) {}
    togglePlay = null;
    seekToMs = null;
  }
}

/// Compatibility shim for call sites owned elsewhere (trending rows,
/// track menu): opens the standalone fullscreen video route for [track].
/// The old separate portrait page flow is deleted; in-sheet video mode
/// lives in player_sheet.dart (_videoMode + [VideoEmbed]).
Future<void> openVideoSheet(
    BuildContext context, AppState state, YtTrack track) async {
  try {
    await Navigator.of(context, rootNavigator: true)
        .push(MaterialPageRoute<void>(
      builder: (_) =>
          VideoFullscreenPage(state: state, track: track),
    ));
  } catch (_) {}
}

/// Fullscreen expand route (kept): landscape + immersive while open,
/// portrait + edge-to-edge restored on close. Hosts a fresh [VideoEmbed]
/// (the inline one is unmounted while this is on top, so exactly one
/// video controller ever lives). Pops with 'audio' when the user picks
/// audio-only, so the sheet can drop video mode instead of remounting.
class VideoFullscreenPage extends StatefulWidget {
  final AppState state;
  final YtTrack track;
  const VideoFullscreenPage(
      {super.key, required this.state, required this.track});

  @override
  State<VideoFullscreenPage> createState() =>
      _VideoFullscreenPageState();
}

class _VideoFullscreenPageState extends State<VideoFullscreenPage> {
  final VideoHandle _handle = VideoHandle();

  static const _landscape = [
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];
  static const _portrait = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ];

  @override
  void initState() {
    super.initState();
    try {
      SystemChrome.setPreferredOrientations(_landscape);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    } catch (_) {}
  }

  @override
  void dispose() {
    // Orientation + system-UI ownership ends here: portrait and
    // edge-to-edge are always handed back (matches the app-wide lock;
    // main.dart/app.dart untouched).
    try {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
    try {
      SystemChrome.setPreferredOrientations(_portrait);
    } catch (_) {}
    try {
      _handle.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: VideoEmbed(
        state: widget.state,
        track: widget.track,
        handle: _handle,
        fullscreen: true,
        onCollapse: () {
          try {
            Navigator.of(context).pop();
          } catch (_) {}
        },
        onAudioOnly: () {
          try {
            Navigator.of(context).pop('audio');
          } catch (_) {}
        },
      ),
    );
  }
}

/// Embeddable video surface: lives in the player sheet's art slot
/// (inline) or fullscreen in [VideoFullscreenPage]. Reloads the video
/// for a new [track] in the background; survives nothing itself — the
/// sheet owns the mode flag, so mode persists across tracks until the
/// user toggles it off via [onAudioOnly].
class VideoEmbed extends StatefulWidget {
  final AppState state;
  final YtTrack track;
  final VideoHandle handle;
  final bool fullscreen;
  final VoidCallback? onAudioOnly;
  final VoidCallback? onExpand;
  final VoidCallback? onCollapse;
  const VideoEmbed({
    super.key,
    required this.state,
    required this.track,
    required this.handle,
    this.fullscreen = false,
    this.onAudioOnly,
    this.onExpand,
    this.onCollapse,
  });

  @override
  State<VideoEmbed> createState() => _VideoEmbedState();
}

class _VideoEmbedState extends State<VideoEmbed> {
  VideoPlayerController? _vp;
  bool _controls = true;
  bool _ready = false;
  // Stream failure (expired/throttled URL, 4xx/5xx): the slot shows an
  // error panel with Retry / next-quality / audio-only instead of an
  // endless spinner.
  bool _failed = false;
  bool _ended = false;
  int _resumeMs = 0;
  bool _wasPlaying = false;
  double _openVolume = 1.0;
  bool _muxed = true;
  Timer? _hideTimer;
  Timer? _syncTimer;
  StreamSubscription<dynamic>? _audioSub;
  bool _syncing = false;
  int _gen = 0;
  // Seamless-switch + sharp-picture state (all inside this slot; the
  // sheet's art slot itself is owned elsewhere).
  // Last laid-out slot width (logical px, set in build's LayoutBuilder
  // without setState) — drives the sharp-picture pick.
  double _slotW = 0;
  // Known stream aspect (0 = unknown → 16:9 fallback). Sizes the slot
  // to content so no dead band sits below the picture.
  double _videoAspect = 0;
  // First-frame fade 0→1 (no pop); previous controller held underneath
  // for a true crossfade with no blank frame.
  double _videoFade = 0;
  VideoPlayerController? _prevVp;
  Timer? _fadeTimer;
  // Single-flight guard: no parallel _openUrl initializations for the
  // same slot (choppy guard); generation tokens cancel superseded
  // flights before they swap.
  bool _opening = false;
  String _openingKey = '';
  // Background swap in progress while the old picture holds the slot
  // (spinner overlays instead of blanking).
  bool _swapping = false;
  // Play watch URL this load resolves (official-video URL when one
  // resolves, else the track's own stream). Keys memo eviction so a dead
  // URL is dropped everywhere after an open failure instead of re-served.
  String _playUrl = '';
  // Which tier opened first this load ('muxed' / 'only' / ''). A fast
  // video-only first frame upgrades to muxed behind when muxed lands.
  String _openedTier = '';
  // Late muxed win that landed while an open was still in flight:
  // consumed when the in-flight open lands (same-position upgrade).
  List<(String, int)> _pendingMuxed = const [];
  // Open URLs already attempted this load (failure never retries the
  // same dead URL twice) + whether the one fresh re-resolve ran.
  final Set<String> _triedUrls = {};
  bool _freshRetried = false;
  // Memoized sharp-picture picks per track+width+mode (no re-resolve).
  final Map<String, (String, int)> _bestMemo = {};

  String _url = '';
  int _height = 0;
  List<(String, int)> _options = const [];

  // Scrub-direction detection: last observed clocks.
  int _lastVideoMs = 0;
  int _lastAudioMs = 0;

  @override
  void initState() {
    super.initState();
    try {
      widget.handle.togglePlay = _togglePlay;
      widget.handle.seekToMs = _seekVideo;
    } catch (_) {}
    _loadFor(widget.track);
    try {
      // External pause (headset, mini/full sheet behind, noisy
      // event) pauses the picture too — vice-versa path.
      _audioSub = widget.state.controller.player.playerStateStream
          .listen(_onAudioState);
    } catch (_) {}
    _syncTimer = Timer.periodic(
        const Duration(milliseconds: 500), (_) => _syncTick());
  }

  @override
  void didUpdateWidget(covariant VideoEmbed old) {
    super.didUpdateWidget(old);
    try {
      widget.handle.togglePlay = _togglePlay;
      widget.handle.seekToMs = _seekVideo;
    } catch (_) {}
    // Track change / auto-advance / next / prev while video mode is on:
    // background-resolve the new track's video (spinner in the slot,
    // then picture). Mode itself is owned by the sheet, so it survives.
    if (old.track.id != widget.track.id) {
      _loadFor(widget.track);
    }
  }

  /// Sharp-picture pick: the smallest rendition at or above the slot's
  /// display width (no upscale fuzz), capping wasteful 1080p+ inline
  /// unless fullscreen. [opts] arrives best-first (tallest); the muxed
  /// ≤720p tier preference is preserved by the caller (extractor-first:
  /// muxed tried before video-only). Memoized per track+width+mode.
  (String, int) _pickBest(List<(String, int)> opts) {
    var fallback = opts.first;
    try {
      final key =
          '${widget.track.id}|${_slotW.round()}|${widget.fullscreen}|${opts.length}|${opts.map((o) => o.$2).join(",")}';
      final hit = _bestMemo[key];
      if (hit != null) return hit;
      final targetH = _slotW > 0 ? _slotW * 9 / 16 : 360.0;
      var cands = List<(String, int)>.of(opts);
      // Cap wasteful 1080p+ decode inline: when any ≤720p rendition
      // exists, ignore taller ones (fullscreen keeps the tallest).
      if (!widget.fullscreen) {
        final capped = cands.where((o) => o.$2 <= 720).toList();
        if (capped.isNotEmpty) cands = capped;
      }
      cands.sort((a, b) => a.$2.compareTo(b.$2));
      (String, int)? above;
      for (final o in cands) {
        if (o.$2 + 1 >= targetH) {
          above = o;
          break;
        }
      }
      fallback = above ?? cands.last;
      _bestMemo[key] = fallback;
      while (_bestMemo.length > 32) {
        _bestMemo.remove(_bestMemo.keys.first);
      }
    } catch (_) {}
    return fallback;
  }

  /// Background resolve for [track], then open the best rendition.
  /// Holds the last frame: the previous picture (if any) stays visible
  /// with a spinner overlay until the replacement first frame is ready,
  /// so audio never gaps and the slot never blanks.
  Future<void> _loadFor(YtTrack track) async {
    final myGen = ++_gen;
    final holding = _ready && _vp != null;
    if (!holding) {
      await _teardownController();
    }
    if (!mounted || myGen != _gen) return;
    // Handoff snapshot: wherever the main audio player is.
    try {
      _resumeMs =
          widget.state.controller.player.position.inMilliseconds;
    } catch (_) {}
    try {
      _wasPlaying = widget.state.controller.player.playing;
    } catch (_) {}
    try {
      _openVolume = widget.state.controller.player.volume
          .clamp(0.0, 1.0);
    } catch (_) {
      _openVolume = 1.0;
    }
    try {
      _lastAudioMs = _resumeMs;
      _lastVideoMs = _resumeMs;
    } catch (_) {}
    _ended = false;
    if (mounted) {
      setState(() {
        if (!holding) {
          _ready = false;
          _failed = false;
          _options = const [];
          _videoAspect = 0;
          _videoFade = 0;
        } else {
          // Keep the old picture; overlay a spinner until the swap.
          _swapping = true;
          _failed = false;
        }
      });
    }
    _syncHandle();
    // YTM parity: video mode plays the song's OFFICIAL music video, not
    // the queue entry's own (often static art-track) stream. Resolve the
    // video watch URL first (8s cap, memoized per track, '' = fall back
    // to the track's own stream exactly as before). The queue entry and
    // audio identity never change — only this picture stream switches —
    // so toggling video off hands the same position back to the original
    // audio track, and the next continuation resolves the same way via
    // didUpdateWidget → _loadFor. Off the hot path: the slot shows the
    // spinner meanwhile (loading handle above).
    var playUrl = track.watchUrl;
    try {
      var seedSecs = -1;
      try {
        seedSecs =
            widget.state.controller.player.duration?.inSeconds ?? -1;
      } catch (_) {}
      final mv = await widget.state.repo
          .resolveMusicVideo(track, seedDurationSec: seedSecs)
          .timeout(const Duration(seconds: 8));
      if (mv.isNotEmpty) playUrl = mv;
    } catch (_) {}
    // Extractor-first URLs (verified on-device): raw InnerTube `formats`
    // URLs 500 in ExoPlayer while the extractor's deciphered muxed URLs
    // play. Video-only DASH is the fallback tier (muted picture +
    // just_audio master).
    //
    // Both tiers fly IN PARALLEL (were sequential 45s + 45s), each
    // 8s-bounded inside the resolver with a 5m negative memo for total
    // misses — a cold open costs ~one hop, not two stacked, and N dead
    // tracks no longer stack minutes of spinner into a chain-skip storm.
    // The first tier with URLs opens immediately (first frame ASAP); a
    // fast video-only frame upgrades to muxed behind at the same
    // position when muxed lands. Muxed (audible ≤720p) wins ties.
    if (!mounted || myGen != _gen) return;
    _playUrl = playUrl;
    _openedTier = '';
    _pendingMuxed = const [];
    _triedUrls.clear();
    _freshRetried = false;
    final muxF = widget.state.resolver
        .videoMuxedUrls(playUrl)
        .catchError((_) => const <(String, int)>[]);
    final onlyF = widget.state.resolver
        .videoOnlyUrls(playUrl)
        .catchError((_) => const <(String, int)>[]);
    unawaited(muxF.then((m) {
      if (!mounted || myGen != _gen) return;
      if (m.isEmpty) return;
      if (_openedTier == 'muxed') return;
      if (_openedTier == 'only') {
        unawaited(_upgradeToMuxed(m));
        return;
      }
      _options = m.take(6).toList();
      _openedTier = 'muxed';
      // Position snapshots at open, not at load start: the audio kept
      // playing under the resolve, so a load-start offset would jump the
      // picture backwards after a slow resolve.
      unawaited(_openUrl(_pickBest(_options), initialMs: -1));
    }).catchError((_) {}));
    unawaited(onlyF.then((o) {
      if (!mounted || myGen != _gen) return;
      if (o.isEmpty || _openedTier.isNotEmpty) return;
      _options = o.take(6).toList();
      _openedTier = 'only';
      unawaited(_openUrl(_pickBest(_options), initialMs: -1));
    }).catchError((_) {}));
    try {
      await Future.wait([
        muxF.then((_) {}).catchError((_) {}),
        onlyF.then((_) {}).catchError((_) {}),
      ]).timeout(const Duration(seconds: 25));
    } catch (_) {}
    if (!mounted || myGen != _gen) return;
    if (_openedTier.isEmpty) {
      if (mounted) {
        try {
          setState(() => _swapping = false);
        } catch (_) {}
      }
      _fail();
      return;
    }
    // Picture is rolling (or opening): warm the next tracks' official-video muxed URLs
    // behind it so next/prev/auto-advance opens instantly. Background,
    // bounded, silent — never blocks the slot.
    _prefetchUpcoming();
  }

  /// Video-mode prefetch: warms the next 2 queue tracks' official-video
  /// muxed URLs (URL memo + bundle memo) in ONE parallel wave, 8s per
  /// hop, silent. Play-order aware (shuffle-safe) via [upcomingIds].
  /// URLs only — bytes ride ExoPlayer's own cache on play-through, so
  /// memory stays a few dozen strings (memo capped inside the resolver).
  /// Previous tracks stay warm from their own load (memo TTL 5h), so
  /// back-skips mem-hit too. Never throws.
  void _prefetchUpcoming() {
    try {
      final st = widget.state;
      final upcoming = st.controller.engine.upcomingIds(2);
      if (upcoming.isEmpty) return;
      unawaited(st.resolver.primeVideoNext(
        upcoming,
        (t) => st.repo.resolveMusicVideo(t),
        max: 2,
      ));
    } catch (_) {}
  }

  Future<void> _teardownController() async {
    try {
      _fadeTimer?.cancel();
    } catch (_) {}
    _fadeTimer = null;
    try {
      _vp?.removeListener(_onVideoTick);
    } catch (_) {}
    try {
      await _vp?.pause();
    } catch (_) {}
    try {
      await _vp?.dispose();
    } catch (_) {}
    _vp = null;
    try {
      await _prevVp?.dispose();
    } catch (_) {}
    _prevVp = null;
    _videoFade = 0;
    _swapping = false;
    _opening = false;
    _openingKey = '';
    _pendingMuxed = const [];
    _syncing = false;
  }

  /// First-frame fade-in: new picture fades 0→1 over the held previous
  /// frame (or from the spinner-held slot), so the switch never pops.
  void _beginFade() {
    try {
      _fadeTimer?.cancel();
    } catch (_) {}
    _fadeTimer = null;
    final off = !widget.state.motionOn;
    if (off) {
      _videoFade = 1.0;
      // Single live decoder even without the fade: drop the held frame
      // now instead of parking a second decoder behind a static picture.
      final prev = _prevVp;
      _prevVp = null;
      if (prev != null) {
        try {
          prev.removeListener(_onVideoTick);
        } catch (_) {}
        unawaited(prev.dispose());
      }
      return;
    }
    _videoFade = 0.0;
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        try {
          setState(() => _videoFade = 1.0);
        } catch (_) {
          _videoFade = 1.0;
        }
      });
    } catch (_) {
      _videoFade = 1.0;
    }
    try {
      final ms = widget.state.motionMs(180) + 120;
      _fadeTimer = Timer(Duration(milliseconds: ms), () {
        if (!mounted) return;
        final prev = _prevVp;
        _prevVp = null;
        if (prev != null) {
          try {
            prev.removeListener(_onVideoTick);
          } catch (_) {}
          try {
            prev.dispose();
          } catch (_) {}
          try {
            if (mounted) setState(() {});
          } catch (_) {}
        }
      });
    } catch (_) {}
  }

  Future<void> _openUrl((String, int) opt,
      {required int initialMs}) async {
    final key = opt.$1;
    // No parallel flights for the same slot+URL: join the in-flight
    // open instead of initializing a second controller (choppy guard).
    if (_opening && _openingKey == key) return;
    // A different URL supersedes: bump the generation so the older
    // flight aborts before swapping.
    if (_opening) _gen++;
    final myGen = ++_gen;
    _opening = true;
    _openingKey = key;
    try {
      _triedUrls.add(key);
    } catch (_) {}
    _url = opt.$1;
    _height = opt.$2;
    _muxed = videoHeightMuxed(_height);
    // Hold-last-frame: only blank when there is no picture to hold.
    // Otherwise the old picture stays with a spinner overlay.
    final holding = _ready && _vp != null;
    if (mounted) {
      if (!holding) {
        setState(() {
          _ready = false;
          _failed = false;
          _videoFade = 0;
        });
      } else if (!_failed) {
        setState(() {
          _failed = false;
          _swapping = true;
        });
      }
    }
    _syncHandle();
    // Build + initialize the replacement OFF-STAGE (never unmount the
    // live controller on toggle — pause/hide instead): the slot keeps
    // showing the held frame until the first new frame is ready.
    VideoPlayerController vp;
    try {
      // Same UA as the working audio path (playback.dart): googlevideo
      // 403s the plugin's default ExoPlayer UA on these URLs.
      vp = VideoPlayerController.networkUrl(Uri.parse(_url),
          httpHeaders: const {
            'User-Agent': 'Cresca/1.0 (Android)',
          });
    } catch (_) {
      await _openFailed(initialMs);
      return;
    }
    try {
      vp.addListener(_onVideoTick);
    } catch (_) {}
    try {
      // Bounded open: an unbounded initialize wedged _opening=true
      // forever (Retry/Next-quality early-return on _opening), freezing
      // the slot on spinner. 8s, then the dead URL is dropped and the
      // next rendition opens at the same frame.
      await vp.initialize().timeout(const Duration(seconds: 8));
    } catch (_) {
      try {
        vp.removeListener(_onVideoTick);
      } catch (_) {}
      try {
        await vp.dispose();
      } catch (_) {}
      if (!mounted || myGen != _gen) {
        _opening = false;
        _openingKey = '';
        return;
      }
      await _openFailed(initialMs);
      return;
    }
    // initialize() can complete with a sourced error (e.g. 500 from
    // an expired/throttled URL) — surface it instead of spinning.
    try {
      if (vp.value.hasError) {
        try {
          vp.removeListener(_onVideoTick);
        } catch (_) {}
        try {
          await vp.dispose();
        } catch (_) {}
        if (!mounted || myGen != _gen) {
          _opening = false;
          _openingKey = '';
          return;
        }
        await _openFailed(initialMs);
        return;
      }
    } catch (_) {}
    if (!mounted || myGen != _gen) {
      // Superseded: dispose off-stage, keep the live picture.
      try {
        vp.removeListener(_onVideoTick);
      } catch (_) {}
      try {
        await vp.dispose();
      } catch (_) {}
      return;
    }
    // Intentional transition: our own engine pause must not echo back
    // through _onAudioState and stall the picture.
    _syncing = true;
    // Stage the replacement muted at the handoff frame first (no
    // double audio while the held picture still sounds).
    try {
      await vp.setVolume(0);
    } catch (_) {}
    int seekMs = initialMs;
    if (seekMs < 0) {
      // Live snapshot at open (not at load start): the audio kept
      // playing under the resolve, so a load-start offset would jump the
      // picture backwards after a slow resolve.
      try {
        seekMs =
            widget.state.controller.player.position.inMilliseconds;
      } catch (_) {
        seekMs = _resumeMs;
      }
      if (seekMs < 0) seekMs = 0;
    }
    try {
      final durMs = vp.value.duration.inMilliseconds;
      final ms = durMs > 600
          ? initialMs.clamp(0, durMs - 500)
          : initialMs.clamp(0, 1 << 30);
      await vp.seekTo(Duration(milliseconds: ms));
      seekMs = ms;
      _lastVideoMs = ms;
      if (!_muxed) {
        // Parked-engine parity: the master clock starts from the same
        // frame the picture shows.
        try {
          await widget.state.controller.player
              .seek(Duration(milliseconds: ms));
          _lastAudioMs = ms;
        } catch (_) {}
      }
    } catch (_) {}
    if (!mounted || myGen != _gen) {
      try {
        vp.removeListener(_onVideoTick);
      } catch (_) {}
      try {
        await vp.dispose();
      } catch (_) {}
      return;
    }
    // Atomic swap: park the held picture, publish the replacement, then
    // fade the first frame in. Never blank between.
    final old = _vp;
    if (old != null) {
      try {
        old.removeListener(_onVideoTick);
      } catch (_) {}
      try {
        await old.pause();
      } catch (_) {}
      // Drop any older held frame; the just-parked one rides underneath.
      final stale = _prevVp;
      _prevVp = old;
      if (stale != null && !identical(stale, old)) {
        try {
          await stale.dispose();
        } catch (_) {}
      }
    }
    _vp = vp;
    try {
      final ar = vp.value.aspectRatio;
      if (ar > 0 && ar.isFinite) _videoAspect = ar;
    } catch (_) {}
    _opening = false;
    _openingKey = '';
    try {
      if (_muxed) {
        // Muxed URL carries its own track: the video element sounds
        // (seeded from the engine level so the user's volume is
        // honored) and the engine parks — one sounding player, no
        // focus fight, no double audio. The engine level itself is
        // never reset (system-volume crew owns it).
        await vp.setVolume(_openVolume);
        try {
          if (widget.state.controller.player.playing) {
            await widget.state.controller.player.pause();
          }
        } catch (_) {}
      } else {
        // Video-only DASH: muted picture, just_audio master clock.
        await vp.setVolume(0);
      }
    } catch (_) {}
    try {
      // Picture rolls first; the sounding engine (re)starts LAST so it
      // holds audio focus. The old order (engine first, picture second)
      // let video_player's focus request duck the engine into silence
      // while the UI volume still read 1.0 — the actual no-audio bug.
      // The engine level is left untouched (no setVolume reset).
      await vp.play();
      if (!_muxed) {
        try {
          await widget.state.controller.player.play();
        } catch (_) {}
      }
    } catch (_) {}
    _lastVideoMs = seekMs;
    _syncing = false;
    if (!mounted || myGen != _gen) return;
    setState(() {
      _ready = true;
      _swapping = false;
    });
    _beginFade();
    _syncHandle();
    _armHide();
    // Late muxed win upgrades a video-only first frame behind at the
    // same position (no spinner reset — the picture keeps rolling).
    List<(String, int)> pend = const [];
    try {
      pend = _pendingMuxed;
      _pendingMuxed = const [];
    } catch (_) {}
    if (pend.isNotEmpty &&
        _openedTier == 'only' &&
        mounted &&
        myGen == _gen) {
      unawaited(_upgradeToMuxed(pend));
    }
  }

  /// First untried rendition (a dead URL is never re-attempted in the
  /// same load — it was evicted from the memo on failure). Null when
  /// every listed rendition already failed. Never throws.
  (String, int)? _nextUntried() {
    try {
      for (final o in _options) {
        if (!_triedUrls.contains(o.$1)) return o;
      }
    } catch (_) {}
    return null;
  }

  /// One failure, one outcome (never advance twice, never double-skip):
  /// the dead URL is evicted everywhere, then the next untried rendition
  /// opens at the same frame; exhausted renditions trigger ONE fresh
  /// re-resolve (memo dropped → network, not memo); only then does the
  /// slot fail — and a working held picture is never blanked for a
  /// failed swap/upgrade. The queue never advances here (audio owns
  /// advance). Never throws.
  Future<void> _openFailed(int posMs) async {
    final myGen = _gen;
    _opening = false;
    _openingKey = '';
    try {
      widget.state.resolver.dropVideoUrl(_playUrl, _url);
    } catch (_) {}
    try {
      final next = _nextUntried();
      if (next != null && mounted && myGen == _gen) {
        await _openUrl(next, initialMs: posMs);
        return;
      }
    } catch (_) {}
    if (!_freshRetried && mounted && myGen == _gen) {
      _freshRetried = true;
      await _reloadFresh(posMs);
      return;
    }
    if (!mounted || myGen != _gen) return;
    if (_ready && _vp != null) {
      try {
        setState(() => _swapping = false);
      } catch (_) {}
      _syncHandle();
      return;
    }
    _fail();
  }

  /// The one fresh re-resolve per load: both tiers in parallel (each
  /// 8s-bounded inside the resolver; tried URLs were evicted so this is
  /// network, not memo). Muxed-first merge; nothing fresh → hold the
  /// working picture or fail. Never throws.
  Future<void> _reloadFresh(int posMs) async {
    final myGen = _gen;
    List<(String, int)> muxed = const [];
    List<(String, int)> only = const [];
    try {
      final both = await Future.wait([
        widget.state.resolver
            .videoMuxedUrls(_playUrl)
            .catchError((_) => const <(String, int)>[]),
        widget.state.resolver
            .videoOnlyUrls(_playUrl)
            .catchError((_) => const <(String, int)>[]),
      ]).timeout(const Duration(seconds: 25));
      muxed = both[0];
      only = both[1];
    } catch (_) {}
    if (!mounted || myGen != _gen) return;
    final freshMuxed = <(String, int)>[
      for (final o in muxed)
        if (!_triedUrls.contains(o.$1)) o,
    ];
    final freshOnly = <(String, int)>[
      for (final o in only)
        if (!_triedUrls.contains(o.$1)) o,
    ];
    if (freshMuxed.isEmpty && freshOnly.isEmpty) {
      if (_ready && _vp != null) {
        try {
          setState(() => _swapping = false);
        } catch (_) {}
        _syncHandle();
        return;
      }
      _fail();
      return;
    }
    _openedTier = freshMuxed.isNotEmpty ? 'muxed' : 'only';
    _options = [...freshMuxed, ...freshOnly].take(6).toList();
    await _openUrl(_pickBest(_options), initialMs: posMs);
  }

  /// Same-position upgrade from a video-only first frame to muxed
  /// (audible): no spinner reset, no failure panel on a failed upgrade —
  /// the rolling picture simply keeps playing. Never throws.
  Future<void> _upgradeToMuxed(List<(String, int)> muxed) async {
    try {
      if (!mounted || _openedTier != 'only' || muxed.isEmpty) return;
      if (_opening) {
        // An open is still in flight: consume when it lands instead of
        // initializing a second controller (single-flight).
        _pendingMuxed = muxed;
        return;
      }
      var posMs = _resumeMs;
      try {
        posMs = _vp?.value.position.inMilliseconds ?? posMs;
      } catch (_) {}
      _options = muxed.take(6).toList();
      _openedTier = 'muxed';
      await _openUrl(_pickBest(_options), initialMs: posMs);
    } catch (_) {}
  }

  void _syncHandle() {
    // Single pass (was two competing active assignments): one notifier
    // write per field so toggles don't fan out redundant rebuilds.
    try {
      widget.handle.active.value = mounted && (_ready || !_failed);
    } catch (_) {}
    try {
      widget.handle.loading.value = !_ready && !_failed;
    } catch (_) {}
    try {
      final p = _vp?.value.isPlaying ?? false;
      if (widget.handle.playing.value != p) {
        widget.handle.playing.value = p;
      }
    } catch (_) {}
  }

  void _onVideoTick() {
    if (!mounted || !_ready || _syncing) return;
    final vp = _vp;
    if (vp == null) return;
    try {
      final v = vp.value;
      try {
        widget.handle.playing.value = v.isPlaying;
      } catch (_) {}
      // Buffering stalls must not pause the soundtrack.
      if (v.isBuffering) return;
      final durMs = v.duration.inMilliseconds;
      final posMs = v.position.inMilliseconds;
      // Video end advances the queue (muxed: the engine is parked, so
      // nothing else would advance; dual: the engine completion drives
      // it, so stay out and avoid a double-advance).
      if (_muxed &&
          !_ended &&
          durMs > 0 &&
          posMs >= durMs - 350 &&
          !v.isPlaying) {
        _ended = true;
        try {
          widget.state.controller.next();
        } catch (_) {}
        return;
      }
      if (durMs > 0 &&
          posMs >= durMs - 350 &&
          !v.isPlaying) {
        try {
          if (widget.state.controller.player.playing) {
            _syncing = true;
            try {
              widget.state.controller.player.pause();
            } catch (_) {}
            _syncing = false;
            if (mounted) setState(() {});
          }
        } catch (_) {
          _syncing = false;
        }
      }
    } catch (_) {
      _syncing = false;
    }
  }

  void _onAudioState(dynamic s) {
    if (!mounted || !_ready || _syncing) return;
    final vp = _vp;
    if (vp == null) return;
    try {
      final playing = widget.state.controller.player.playing;
      final vPlaying = vp.value.isPlaying;
      try {
        widget.handle.playing.value = vPlaying;
      } catch (_) {}
      if (!playing && vPlaying) {
        vp.pause();
        if (mounted) setState(() {});
        _syncHandle();
      } else if (playing && !vPlaying) {
        final durMs = vp.value.duration.inMilliseconds;
        final posMs = vp.value.position.inMilliseconds;
        if (durMs <= 0 || posMs < durMs - 500) {
          // Picture follows the engine; the engine reasserts focus
          // last so a resumed picture cannot duck it again.
          vp.play().then((_) {
            if (!_muxed && mounted) {
              try {
                widget.state.controller.player.play();
              } catch (_) {}
            }
            if (mounted) setState(() {});
            _syncHandle();
          }).catchError((_) {});
        }
      }
    } catch (_) {}
  }

  /// Clock sync, per rendition mode.
  /// Muxed: the video element is the single clock; jumps in the
  /// picture are mirrored into the parked engine so the close handoff
  /// stays exact — and jumps in the engine (sheet seek, repeat-one
  /// rewind) are mirrored into the picture, so the shared sheet
  /// transport scrubs video too. Dual (video-only): audio is the master
  /// clock and the picture chases it, except when the user scrubs the
  /// video bar — then the engine jumps to the picture. The watchdog only
  /// ever pauses (never resumes: auto-resume would blast after a headset
  /// unplug); pressing play re-lights both.
  Future<void> _syncTick() async {
    if (!mounted || !_ready || _syncing) return;
    final vp = _vp;
    if (vp == null) return;
    try {
      // Publish the sounding clock for lyric followers (preview +
      // karaoke): muxed => video frame, dual => engine position.
      // Same try/catch discipline as below — never throws.
      try {
        if (_muxed) {
          widget.handle.videoMs.value =
              vp.value.position.inMilliseconds;
        } else {
          widget.handle.videoMs.value = widget
              .state.controller.player.position.inMilliseconds;
        }
      } catch (_) {}
      final vPlaying = vp.value.isPlaying;
      final aPlaying =
          widget.state.controller.player.playing;
      if (_muxed) {
        try {
          final vMs = vp.value.position.inMilliseconds;
          int aMs = _lastAudioMs;
          try {
            aMs = widget.state.controller.player.position
                .inMilliseconds;
          } catch (_) {}
          final dV = (vMs - _lastVideoMs).abs();
          final dA = (aMs - _lastAudioMs).abs();
          _lastVideoMs = vMs;
          _lastAudioMs = aMs;
          if (vPlaying && dV > 1200 && dA < 1200) {
            _syncing = true;
            try {
              await widget.state.controller.player
                  .seek(Duration(milliseconds: vMs));
              _lastAudioMs = vMs;
            } catch (_) {}
            _syncing = false;
          } else if (dA > 1200 && dV < 1200) {
            // Sheet scrubbed the parked engine (or repeat-one rewound
            // it): the picture jumps to the engine.
            _syncing = true;
            try {
              await vp.seekTo(Duration(milliseconds: aMs));
              _lastVideoMs = aMs;
            } catch (_) {}
            _syncing = false;
          }
        } catch (_) {
          _syncing = false;
        }
        return;
      }
      if (!vPlaying || !aPlaying) {
        if (vPlaying && !aPlaying) {
          // Soundtrack died under a rolling picture (missed pause
          // event): park the picture, never auto-resume audio.
          try {
            await vp.pause();
          } catch (_) {}
          if (mounted) setState(() {});
          _syncHandle();
        }
        try {
          _lastVideoMs = vp.value.position.inMilliseconds;
          _lastAudioMs = widget
              .state.controller.player.position.inMilliseconds;
        } catch (_) {}
        return;
      }
      final vMs = vp.value.position.inMilliseconds;
      final aMs = widget
          .state.controller.player.position.inMilliseconds;
      final dV = (vMs - _lastVideoMs).abs();
      final dA = (aMs - _lastAudioMs).abs();
      _lastVideoMs = vMs;
      _lastAudioMs = aMs;
      final drift = (vMs - aMs).abs();
      if (drift < 700) return;
      _syncing = true;
      try {
        // Video scrubbed (big video jump, steady audio): move audio.
        if (dV > 1200 && dA < 1200) {
          await widget.state.controller.player
              .seek(Duration(milliseconds: vMs));
          _lastAudioMs = vMs;
        } else {
          // Normal drift: picture chases the soundtrack.
          await vp.seekTo(Duration(milliseconds: aMs));
          _lastVideoMs = aMs;
        }
      } catch (_) {}
      _syncing = false;
    } catch (_) {
      _syncing = false;
    }
  }

  /// Shared-transport toggle (the sheet delegates here while video is
  /// active): drives the sounding clock and mirrors into the parked
  /// one, both directions.
  Future<void> _togglePlay() async {
    final vp = _vp;
    if (vp == null || !_ready) return;
    try {
      _syncing = true;
      if (vp.value.isPlaying) {
        try {
          await vp.pause();
        } catch (_) {}
        if (_muxed) {
          // Mirror the paused frame into the parked engine.
          try {
            await widget.state.controller.player.seek(
                vp.value.position);
          } catch (_) {}
        } else {
          try {
            await widget.state.controller.player.pause();
          } catch (_) {}
        }
      } else {
        // Resume order keeps the sounding engine on focus last.
        try {
          await vp.play();
        } catch (_) {}
        if (!_muxed) {
          try {
            await widget.state.controller.player.play();
          } catch (_) {}
        }
      }
    } catch (_) {}
    _syncing = false;
    if (mounted) setState(() {});
    _syncHandle();
    _armHide();
  }

  /// Sheet-seek helper: scrub BOTH clocks to [ms] (the sheet's own
  /// engine seek is idempotent, so every path lands both together
  /// instead of splitting picture from soundtrack).
  Future<void> _seekVideo(int ms) async {
    final vp = _vp;
    if (vp == null || !_ready) return;
    try {
      _syncing = true;
      await vp.seekTo(Duration(milliseconds: ms));
      _lastVideoMs = ms;
      try {
        await widget.state.controller.player
            .seek(Duration(milliseconds: ms));
        _lastAudioMs = ms;
      } catch (_) {}
    } catch (_) {}
    _syncing = false;
    if (mounted) setState(() {});
  }

  Future<void> _switchQuality((String, int) opt) async {
    if (opt.$1 == _url) return;
    // Guarded by _openUrl's single-flight: rapid picker taps join
    // instead of initializing parallel controllers.
    int posMs = 0;
    try {
      posMs = _vp?.value.position.inMilliseconds ?? 0;
    } catch (_) {
      try {
        posMs = widget.state.controller.player.position
            .inMilliseconds;
      } catch (_) {}
    }
    if (posMs <= 0) posMs = _resumeMs;
    await _openUrl(opt, initialMs: posMs);
  }

  void _fail() {
    _opening = false;
    _openingKey = '';
    try {
      if (mounted) {
        setState(() {
          _failed = true;
          _ready = false;
          _swapping = false;
        });
      } else {
        _failed = true;
        _ready = false;
        _swapping = false;
      }
    } catch (_) {
      _failed = true;
      _ready = false;
      _swapping = false;
    }
    _syncHandle();
  }

  /// Retry the same URL (transient network blips). The dead URL is
  /// evicted first so a retry after expiry/throttle re-resolves instead
  /// of re-serving the same dead bytes; the fresh-retry budget resets.
  /// Holds the last frame when there is one; single-flight guarded
  /// inside [_openUrl].
  void _retry() {
    _freshRetry();
  }

  /// Manual fresh cycle (Retry / Next-quality exhausted): the automatic
  /// chain only re-serves memo rows — so evict everything tried and
  /// re-resolve from network. Without this both buttons dead-end
  /// after one full exhaustion. Never throws.
  void _freshRetry() {
    if (!mounted || _opening) return;
    int posMs = _resumeMs;
    try {
      posMs = widget.state.controller.player.position
          .inMilliseconds;
    } catch (_) {}
    try {
      for (final u in List.of(_triedUrls)) {
        widget.state.resolver.dropVideoUrl(_playUrl, u);
      }
    } catch (_) {}
    try {
      _triedUrls.clear();
    } catch (_) {}
    _freshRetried = false;
    final holding = _ready && _vp != null;
    try {
      setState(() {
        _failed = false;
        if (!holding) _ready = false;
        if (holding) _swapping = true;
      });
    } catch (_) {}
    _syncHandle();
    unawaited(_reloadFresh(posMs));
  }

  /// Try the next untried rendition, else report failure. No
  /// wrap-around: re-cycling the list re-attempted the same dead URL
  /// forever while the slot sat on loading.
  void _tryNext() {
    if (_opening) return;
    try {
      final next = _nextUntried();
      if (next == null) {
        // Everything tried: start a genuinely fresh cycle from network
        // instead of failing instantly (the button would dead-end).
        _freshRetry();
        return;
      }
      if (mounted) {
        final holding = _ready && _vp != null;
        setState(() {
          _failed = false;
          if (!holding) _ready = false;
          if (holding) _swapping = true;
        });
      }
      _syncHandle();
      int posMs = _resumeMs;
      try {
        posMs = widget.state.controller.player.position
            .inMilliseconds;
      } catch (_) {}
      unawaited(_openUrl(next, initialMs: posMs));
    } catch (_) {
      _fail();
    }
  }

  /// Audio-only: just notify the owner (toggle off / pop). Position
  /// handoff to the engine happens in dispose, so playback never stops.
  void _audioOnly() {
    try {
      widget.onAudioOnly?.call();
    } catch (_) {}
  }

  /// Exact-fill picture box: covers the slot with no letterbox slivers,
  /// anchored top-center consistently (portrait + landscape).
  Widget _videoBox(VideoPlayerController c) {
    double ar = 16 / 9;
    try {
      final v = c.value.aspectRatio;
      if (v > 0 && v.isFinite) ar = v;
    } catch (_) {}
    return ClipRect(
      child: SizedBox.expand(
        child: FittedBox(
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          child: SizedBox(
            // Layout at the slot width, not a fixed 1280: small phones
            // decoded 1280-wide pixels for a ~380px slot.
            width: _slotW > 0 ? _slotW : 1280,
            height: (_slotW > 0 ? _slotW : 1280) / ar,
            child: VideoPlayer(c),
          ),
        ),
      ),
    );
  }

  /// Slot content: video, error panel, or spinner — inside the
  /// content-sized slot, so surrounding chrome never shifts between
  /// states. The spinner holds the fixed slot space (no layout jump);
  /// the first video frame fades in (no pop); track/quality swaps hold
  /// the old frame underneath with a spinner overlay (no blank).
  /// Error panel keeps Retry / Next quality / Audio only.
  Widget _slotChild() {
    final vp = _vp;
    if (_ready && vp != null) {
      final ms = widget.state.motionMs(180);
      final d = Duration(milliseconds: ms);
      final prev = _prevVp;
      Widget top = _videoBox(vp);
      // First-frame fade-in (no pop).
      top = AnimatedOpacity(
        opacity: _videoFade,
        duration: d,
        curve: Curves.easeOut,
        child: top,
      );
      if (prev != null) {
        // True crossfade: held previous frame underneath, new first
        // frame fades in on top — no blank frame.
        return Stack(
          fit: StackFit.expand,
          children: [
            _videoBox(prev),
            top,
          ],
        );
      }
      if (_swapping) {
        // Background resolve while the old picture holds: overlay a
        // spinner instead of blanking.
        return Stack(
          fit: StackFit.expand,
          children: [
            top,
            Center(
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.45),
                ),
                child: Center(
                  // Base-API spinner (DelayedSpinner lives in an
                  // unlanded design.dart edit; swap back on rebase).
                  child: const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white))),
                ),
              ),
            ],
          );
        }
      return top;
    }
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.videocam_off_outlined,
                  color: Colors.white70, size: 40),
              const SizedBox(height: 12),
              const Text('Video unavailable',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              const Text(
                  'This stream failed to load. The music keeps playing.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FilledButton(
                    onPressed: _retry,
                    child: const Text('Retry'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: _tryNext,
                    style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white),
                    child: const Text('Next quality'),
                  ),
                ],
              ),
              TextButton(
                onPressed: _audioOnly,
                child: const Text('Audio only',
                    style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      );
    }
    return const Center(
      child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
              strokeWidth: 2.5, color: Colors.white)),
    );
  }

  void _pickQuality() {
    final opts = _options.isNotEmpty
        ? _options
        : [(_url, _height)];
    showModalBottomSheet<(String, int)>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GlassSheetSurface(
        motionOn: widget.state.motionOn,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Video quality',
                    style: TextStyle(
                        color: Theme.of(ctx)
                            .colorScheme
                            .onSurface,
                        fontWeight: FontWeight.w700)),
              ),
              for (final o in opts.take(6))
                Semantics(
                  button: true,
                  label: o.$1 == _url
                      ? 'Video quality ${o.$2}p, selected'
                      : 'Video quality ${o.$2}p',
                  excludeSemantics: true,
                  child: ListTile(
                    leading: const Icon(
                        Icons.high_quality_outlined),
                    title: Text('${o.$2}p'),
                    subtitle: Text(videoHeightMuxed(o.$2)
                        ? 'Muxed video+audio'
                        : 'Video + synced audio'),
                    trailing: o.$1 == _url
                        ? const Icon(Icons.check)
                        : null,
                    onTap: () =>
                        Navigator.pop(context, o),
                  ),
                ),
            ],
          ),
        ),
      ),
    ).then((picked) {
      if (picked != null) unawaited(_switchQuality(picked));
    });
  }

  @override
  void dispose() {
    _gen++;
    try {
      _fadeTimer?.cancel();
    } catch (_) {}
    _fadeTimer = null;
    try {
      _hideTimer?.cancel();
    } catch (_) {}
    try {
      _syncTimer?.cancel();
    } catch (_) {}
    try {
      _audioSub?.cancel();
    } catch (_) {}
    try {
      widget.handle.togglePlay = null;
      widget.handle.seekToMs = null;
      widget.handle.active.value = false;
      widget.handle.loading.value = false;
    } catch (_) {}
    try {
      // Audio-only toggle path: hand this position back to the main
      // audio player — playback never stops. With the dual-player model
      // both clocks agree; the video clock wins when the user scrubbed
      // video last, otherwise no seek. dispose can't await, so the
      // handoff runs first and owns the engine seek (unawaited).
      unawaited(_resumeHandoff());
    } catch (_) {}
    try {
      _vp?.removeListener(_onVideoTick);
    } catch (_) {}
    try {
      _vp?.dispose();
    } catch (_) {}
    _vp = null;
    try {
      _prevVp?.dispose();
    } catch (_) {}
    _prevVp = null;
    super.dispose();
  }

  Future<void> _resumeHandoff() async {
    try {
      final vp = _vp;
      int vMs = -1;
      int aMs = -1;
      try {
        vMs = vp?.value.position.inMilliseconds ?? -1;
      } catch (_) {}
      try {
        aMs = widget.state.controller.player.position
            .inMilliseconds;
      } catch (_) {}
      final posMs = (vMs >= 0 && aMs >= 0 && (vMs - aMs).abs() > 500)
          ? vMs
          : (aMs >= 0 ? aMs : (vMs >= 0 ? vMs : _resumeMs));
      bool wasPlaying = _wasPlaying;
      try {
        wasPlaying = wasPlaying ||
            (vp?.value.isPlaying ?? false) ||
            widget.state.controller.player.playing;
      } catch (_) {}
      try {
        await widget.state.controller.player.seek(
            Duration(milliseconds: posMs < 0 ? 0 : posMs));
      } catch (_) {}
      try {
        if (wasPlaying) {
          await widget.state.controller.player.play();
        }
      } catch (_) {}
    } catch (_) {}
  }

  void _toggleChrome() {
    setState(() => _controls = !_controls);
    _armHide();
  }

  void _armHide() {
    try {
      _hideTimer?.cancel();
    } catch (_) {}
    final vp = _vp;
    if (_controls && (vp?.value.isPlaying ?? false)) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _controls = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fullscreen) return _fullscreenStage();
    // Inline: full-bleed width, height sized to content (slot aspect +
    // chips) — no fixed 1.10 box, so no dead band below the picture.
    // The slot itself stays pre-sized (16:9 fallback → stream aspect
    // when known) with a black stage, and spinner ⇄ picture crossfade
    // inside, so art→video never blanks or shifts chrome.
    return LayoutBuilder(
      builder: (_, cons) {
        final w = cons.maxWidth.isFinite
            ? cons.maxWidth
            : MediaQuery.of(context).size.width;
        // Remember slot width for the sharp-picture pick (plain assign,
        // never setState here — no rebuild loop).
        _slotW = w;
        return Container(
          color: Colors.black,
          child: _inlineStage(),
        );
      },
    );
  }

  /// Inline stage: content-sized picture with the control row directly
  /// BELOW it (never overlaid, no bezel gap). No transport here — the
  /// sheet's pinned transport drives the video via [VideoHandle] while
  /// active. No title/quality tag on the picture (the sheet header above
  /// the slot already names the track).
  Widget _inlineStage() {
    final ms = widget.state.motionMs(180);
    final d = Duration(milliseconds: ms);
    // Size the slot to content: stream aspect when known, 16:9 fallback.
    // The transport chips anchor directly below — no empty band.
    final slotAspect =
        _videoAspect > 0 && _videoAspect.isFinite ? _videoAspect : 16 / 9;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AspectRatio(
          aspectRatio: slotAspect,
          child: Container(
            color: Colors.black,
            child: AnimatedSwitcher(
              duration: d,
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeOut,
              // Phase-keyed content: loading ⇄ video ⇄ error crossfade
              // inside the content-sized box (was a single 'slot' key, so
              // picture/error snapped in with no transition).
              child: KeyedSubtree(
                key: ValueKey(_ready
                    ? 'video-$_videoAspect'
                    : (_failed ? 'failed' : 'loading')),
                child: _slotChild(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _chipButton(
              icon: Icons.high_quality_outlined,
              tip: 'Quality',
              onTap: _ready ? _pickQuality : null,
            ),
            const SizedBox(width: 8),
            _chipButton(
              icon: Icons.headphones_outlined,
              tip: 'Audio only',
              onTap: _audioOnly,
            ),
            const SizedBox(width: 8),
            _chipButton(
              icon: Icons.fullscreen_outlined,
              tip: 'Fullscreen',
              onTap: widget.onExpand,
            ),
          ],
        ),
      ],
    );
  }

  Widget _chipButton(
      {required IconData icon,
      required String tip,
      required VoidCallback? onTap}) {
    return Tooltip(
      message: tip,
      child: Semantics(
        button: true,
        label: tip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.black.withValues(alpha: 0.45),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.25),
                  width: 0.5),
            ),
            child: Icon(icon,
                color: Colors.white, size: 19),
          ),
        ),
      ),
    );
  }

  /// Fullscreen stage: true fullscreen picture, chrome overlaid
  /// edge-to-edge (system bars hidden via immersive while expanded).
  Widget _fullscreenStage() {
    final ms = widget.state.motionMs(180);
    final d = Duration(milliseconds: ms);
    final vp = _vp;
    final prev = _prevVp;
    return GestureDetector(
      onTap: _toggleChrome,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: d,
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeOut,
              child: _ready && vp != null
                  ? KeyedSubtree(
                      key: ValueKey('video-$_videoAspect'),
                      child: prev != null
                          ? Stack(
                              fit: StackFit.expand,
                              children: [
                                _videoBox(prev),
                                AnimatedOpacity(
                                  opacity: _videoFade,
                                  duration: d,
                                  curve: Curves.easeOut,
                                  child: _videoBox(vp),
                                ),
                              ],
                            )
                          : AnimatedOpacity(
                              opacity: _videoFade,
                              duration: d,
                              curve: Curves.easeOut,
                              child: _videoBox(vp),
                            ),
                    )
                  : KeyedSubtree(
                      key: const ValueKey('pending'),
                      child: _failed
                          ? _slotChild()
                          : const Center(
                              child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child:
                                      CircularProgressIndicator(
                                          strokeWidth:
                                              2.5,
                                          color:
                                              Colors.white))),
                    ),
            ),
            IgnorePointer(
              ignoring: !_controls,
              child: AnimatedOpacity(
                opacity: _controls && _ready ? 1.0 : 0.0,
                duration: d,
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: d,
                  curve: Curves.easeOut,
                  transform: Matrix4.translationValues(
                      0, _controls ? 0 : 12, 0),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned(
                        top: 12,
                        left: 12,
                        // One-tap labelled Close: pops this route only,
                        // never the player beneath.
                        child: Semantics(
                          button: true,
                          label: 'Close video',
                          excludeSemantics: true,
                          child: IconButton(
                            icon: const Icon(Icons.close,
                                color: Colors.white),
                            tooltip: 'Close video',
                            onPressed: () {
                              try {
                                widget.onCollapse?.call();
                              } catch (_) {}
                            },
                          ),
                        ),
                      ),
                      Positioned(
                        top: 12,
                        right: 12,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              tooltip: 'Audio only',
                              icon: const Icon(
                                  Icons.headphones_outlined,
                                  color: Colors.white),
                              onPressed: _audioOnly,
                            ),
                            IconButton(
                              tooltip: 'Quality',
                              icon: const Icon(
                                  Icons
                                      .high_quality_outlined,
                                  color: Colors.white),
                              onPressed: _ready
                                  ? _pickQuality
                                  : null,
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        bottom: 24,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: IconButton(
                            iconSize: 64,
                            icon: Icon(
                              _ready && (vp?.value.isPlaying ?? false)
                                  ? Icons.pause
                                  : Icons.play_arrow,
                              color: Colors.white,
                            ),
                            tooltip: (vp?.value.isPlaying ?? false)
                                ? 'Pause'
                                : 'Play',
                            onPressed:
                                _ready ? _togglePlay : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
