// Player overflow row (U4): the five overflow actions as icon + text
// labels — Shuffle / Repeat / Like / Download / Video, in that order.
// Previously icon-only (video toggle) or hidden (track menu) — now
// discoverable. The callbacks mirror track_menu.dart's actions; the
// row is the phase's single deliberate visual change, everything else
// stays pixel-identical. Active state is a tint (spotifyGreen), never
// a size change; each action is Expanded + maxLines:1 so 200% text
// ellipsizes instead of overflowing.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/discovery.dart';
import '../../core/queue.dart';
import '../../core/track.dart';
import '../design.dart' hide PressScale;
import '../state.dart';
import 'player_header.dart';
import 'player_transport.dart';

/// Overflow order contract (Shuffle / Repeat / Like / Download /
/// Video) — pinned by test/player_menu_test.dart.
const playerMenuLabels = [
  'Shuffle',
  'Repeat',
  'Like',
  'Download',
  'Video',
];

/// Labelled overflow actions. Stateful so the active tints refresh
/// even when the engine toggles without notifying AppState listeners.
class PlayerMenu extends StatefulWidget {
  final AppState state;
  final YtTrack track;
  final bool videoActive;
  final VoidCallback onToggleVideo;
  const PlayerMenu(
      {super.key,
      required this.state,
      required this.track,
      this.videoActive = false,
      required this.onToggleVideo});

  @override
  State<PlayerMenu> createState() => _PlayerMenuState();
}

class _PlayerMenuState extends State<PlayerMenu> {
  void _menuToast(String message) {
    try {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (_) {}
  }

  // Mirrors track_menu.dart's shuffle action (cycle + smart reorder +
  // session save + toast).
  Future<void> _toggleShuffle() async {
    try {
      final engine = widget.state.controller.engine;
      final m = engine.cycleShuffle();
      if (m == shuffleSmart) {
        final liked = widget.state.library.liked
            .map((e) => e.displayArtist())
            .toSet();
        final recent = widget.state.library.recent
            .map((e) => e.displayArtist())
            .toList();
        engine.applyOrder(smartOrderFor(
          items: engine.snapshot(),
          currentIndex: engine.currentIndex,
          likedArtists: liked,
          recentArtists: recent,
        ));
      }
      widget.state.controller.saveSessionNow();
      if (mounted) {
        _menuToast(
            'Shuffle: ${m == shuffleOff ? 'off' : m == shuffleSmart ? 'smart' : 'on'}');
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  // Mirrors track_menu.dart's repeat action.
  Future<void> _toggleRepeat() async {
    try {
      final engine = widget.state.controller.engine;
      engine.cycleRepeat();
      widget.state.controller.saveSessionNow();
      if (mounted) {
        _menuToast(
            'Repeat: ${engine.repeatMode == repeatOff ? 'off' : engine.repeatMode == repeatAll ? 'all' : 'one'}');
      }
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _toggleLike() async {
    try {
      await widget.state.actToggleLike(widget.track);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Future<void> _download() async {
    try {
      final msg = await widget.state.actDownload(widget.track);
      if (mounted) _menuToast(msg);
    } catch (_) {}
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final track = widget.track;
    bool shuffleOn = false;
    int repeatMode = repeatOff;
    bool liked = false;
    bool downloaded = false;
    try {
      shuffleOn = state.controller.engine.shuffleMode != shuffleOff;
    } catch (_) {}
    try {
      repeatMode = state.controller.engine.repeatMode;
    } catch (_) {}
    try {
      liked = state.library.isLiked(track.id);
    } catch (_) {}
    try {
      downloaded = state.downloads.isDownloaded(track.id);
    } catch (_) {}
    Widget action({
      required IconData icon,
      required String label,
      required VoidCallback onTap,
      bool active = false,
    }) {
      final color = active
          ? spotifyGreen
          : Colors.white.withValues(alpha: 0.85);
      return PressScale(
        child: Semantics(
          button: true,
          label: label,
          selected: active,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: color, size: 24),
                  const SizedBox(height: 2),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: color,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.2)),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      container: true,
      label: 'Playback actions',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: playerGutter),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Expanded(
                child: action(
                    icon: Icons.shuffle,
                    label: playerMenuLabels[0],
                    onTap: _toggleShuffle,
                    active: shuffleOn)),
            Expanded(
                child: action(
                    icon: repeatMode == repeatOne
                        ? Icons.repeat_one
                        : Icons.repeat,
                    label: playerMenuLabels[1],
                    onTap: _toggleRepeat,
                    active: repeatMode != repeatOff)),
            Expanded(
                child: action(
                    icon:
                        liked ? Icons.favorite : Icons.favorite_outline,
                    label: playerMenuLabels[2],
                    onTap: _toggleLike,
                    active: liked)),
            Expanded(
                child: action(
                    icon: downloaded
                        ? Icons.download_done
                        : Icons.download_outlined,
                    label: playerMenuLabels[3],
                    onTap: _download,
                    active: downloaded)),
            Expanded(
                child: action(
                    icon: widget.videoActive
                        ? Icons.videocam
                        : Icons.videocam_outlined,
                    label: playerMenuLabels[4],
                    onTap: () {
                      try {
                        widget.onToggleVideo();
                      } catch (_) {}
                      if (mounted) setState(() {});
                    },
                    active: widget.videoActive)),
          ],
        ),
      ),
    );
  }
}
