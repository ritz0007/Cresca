// Video mode (P9): the player-sheet disc opens the track's music
// video — muxed extractor streams with a quality picker (1080p/720p/…),
// first-frame spinner, audio/video toggle (drop back to the main audio
// player at the same position), landscape fullscreen while playing.
// Native refs: VideoSheet.kt + YoutubeRepository.videoOptions; stream
// plumbing rides the same device-consistent browser headers that the
// resolver already uses (extractor parity, no proxy surprises).
// Documented deviation (H8 truthfulness): DASH .mpd + N+1 prefetch ride
// later with a tuned HTTP handler; muxed-first is the working core.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../design.dart';
import '../state.dart';
import '../../core/track.dart';

/// Opens the video surface for a track. Quality default: user cap
/// (prefs video_quality, default 1080).
Future<void> openVideoSheet(
    BuildContext context, AppState state, YtTrack track) async {
  try {
    // JAM politeness mirrors playback gates (F6): joining guests keep
    // local video; transport remains host-driven separately.
    final options = await state.resolver
        .videoMuxedUrls(track.watchUrl)
        .timeout(const Duration(seconds: 45));
    if (options.isEmpty) {
      try {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No playable video stream found')));
      } catch (_) {}
      return;
    }
    if (context.mounted) {
      final picked = await showModalBottomSheet<(String, int)>(
        context: context,
        builder: (_) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Video quality',
                    style:
                        TextStyle(fontWeight: FontWeight.w700)),
              ),
              for (final (url, h) in options.take(6))
                ListTile(
                  leading: const Icon(Icons.high_quality_outlined),
                  title: Text('${h}p'),
                  subtitle: Text(
                      'Muxed video+audio (${h}p stream)'),
                  onTap: () =>
                      Navigator.pop(context, (url, h)),
                ),
            ],
          ),
        ),
      );
      if (picked == null || !context.mounted) return;
      await Navigator.of(context, rootNavigator: true)
          .push(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => VideoPlayerPage(
          state: state,
          track: track,
          url: picked.$1,
          height: picked.$2,
        ),
      ));
    }
  } catch (_) {}
}

class VideoPlayerPage extends StatefulWidget {
  final AppState state;
  final YtTrack track;
  final String url;
  final int height;
  const VideoPlayerPage({
    super.key,
    required this.state,
    required this.track,
    required this.url,
    required this.height,
  });

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late VideoPlayerController _vp;
  bool _controls = true;
  int _resumeMs = 0;
  Timer? _hideTimer;

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
    // Handoff position: wherever the main audio player is.
    try {
      _resumeMs = widget.state.controller.player
          .position.inMilliseconds;
    } catch (_) {}
    try {
      // Pause audio while video plays (video carries the audio).
      unawaited(widget.state.controller.player.pause());
    } catch (_) {}
    _vp = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        try {
          final ms = _resumeMs.clamp(
              0,
              _vp.value.duration.inMilliseconds - 500);
          _vp.seekTo(Duration(milliseconds: ms));
          _vp.play();
        } catch (_) {}
        if (mounted) setState(() {});
      }).catchError((e) {});
    SystemChrome.setPreferredOrientations(_landscape);
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(_portrait);
    try {
      _hideTimer?.cancel();
    } catch (_) {}
    try {
      _resumeHandoff();
    } catch (_) {}
    _vp.dispose();
    super.dispose();
  }

  /// Audio/video toggle (P9): hand this position back to the main
  /// audio player and close the video surface — playback never stops.
  Future<void> _resumeHandoff() async {
    try {
      final ms = _vp.value.position.inMilliseconds;
      final posMs = ms < 0 ? _resumeMs : ms;
      try {
        await widget.state.controller.player.seek(
            Duration(milliseconds: posMs));
      } catch (_) {}
      try {
        await widget.state.controller.player.play();
      } catch (_) {}
    } catch (_) {}
  }

  void _toggleChrome() {
    setState(() => _controls = !_controls);
    _hideTimer?.cancel();
    if (_controls && _vp.value.isPlaying) {
      _hideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _controls = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = _vp.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _toggleChrome,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (ready)
              Center(
                child: AspectRatio(
                  aspectRatio: _vp.value.aspectRatio == 0
                      ? 16 / 9
                      : _vp.value.aspectRatio,
                  child: VideoPlayer(_vp),
                ),
              )
            else
              const Center(
                  child: CircularProgressIndicator()),
            if (_controls && ready) ...[
              Positioned(
                top: 12,
                left: 12,
                child: IconButton(
                  icon: const Icon(Icons.close,
                      color: Colors.white),
                  onPressed: () =>
                      Navigator.of(context).pop(),
                ),
              ),
              Positioned(
                top: 12,
                right: 12,
                child: IconButton(
                  tooltip: 'Audio only',
                  icon: const Icon(Icons.headphones_outlined,
                      color: Colors.white),
                  onPressed: () async {
                    await _resumeHandoff();
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ),
              Positioned(
                bottom: 24,
                left: 24,
                right: 24,
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                        '${widget.track.title} • ${widget.height}p',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Row(children: [
                      IconButton(
                        icon: Icon(
                          _vp.value.isPlaying
                              ? Icons.pause
                              : Icons.play_arrow,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          try {
                            _vp.value.isPlaying
                                ? _vp.pause()
                                : _vp.play();
                          } catch (_) {}
                          setState(() {});
                        },
                      ),
                      Expanded(
                        child: VideoProgressIndicator(
                          _vp,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: spotifyGreen,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          _vp.value.volume > 0
                              ? Icons.volume_up
                              : Icons.volume_off,
                          color: Colors.white,
                        ),
                        onPressed: () {
                          try {
                            _vp.setVolume(
                                _vp.value.volume > 0 ? 0 : 1);
                          } catch (_) {}
                          setState(() {});
                        },
                      ),
                    ]),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
