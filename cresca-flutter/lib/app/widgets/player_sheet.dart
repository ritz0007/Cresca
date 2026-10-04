// Full player sheet (P1–P6, audio path): full-bleed artwork + blurred
// backdrop + idle breathe (no FFT — documented deviation), rolling lyric
// ticker stub, title/artist + artist-tap, glowing seek bar (tap + drag,
// knob swell), transport (shuffle OFF→ON→SMART, repeat OFF→ALL→ONE),
// error line + buffering spinner, actions row (Video/Audio, Like,
// Download, Queue, JAM placeholder, More). Karaoke/credits/video are
// Phase 3 (P7–P9 show honest stubs, never fake content).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/discovery.dart';
import '../../core/queue.dart';
import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'queue_sheet.dart';
import 'track_menu.dart';
import 'track_row.dart';

Future<void> openPlayerSheet(BuildContext context) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.94,
        minChildSize: 0.5,
        maxChildSize: 0.94,
        builder: (_, scroll) => PlayerSheet(scroll: scroll),
      ),
    );
  } catch (_) {}
}

class PlayerSheet extends StatefulWidget {
  final ScrollController scroll;
  const PlayerSheet({super.key, required this.scroll});

  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet> {
  double? _dragPos;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final track = state.controller.engine.current;
        if (track == null) {
          return const Center(child: Text('Nothing playing'));
        }
        return Stack(
          children: [
            // Artwork mesh wash (Apple-Music/BitChord backdrop).
            const Positioned.fill(
              child: MeshBackdrop(),
            ),
            CustomScrollView(
              controller: widget.scroll,
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      const SizedBox(height: 8),
                      Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                              color: Colors.white54,
                              borderRadius: BorderRadius.circular(2))),
                      const SizedBox(height: 16),
                      // Full-bleed artwork: idle breathe × pause shrink.
                      _ArtCard(track: track),
                      const SizedBox(height: 8),
                      // Rolling ticker on art (P2; lyrics ride it in P3).
                      _Ticker(text: '${track.title} • ${track.displayArtist()}'),
                      const SizedBox(height: 8),
                      // Title/artist with shadow; artist tap → artist page.
                      Text(track.title,
                          textAlign: TextAlign.center,
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(
                                  color: Colors.white,
                                  shadows: const [
                                Shadow(blurRadius: 8)
                              ])),
                      GestureDetector(
                        onTap: () => openArtistPage(context, track),
                        child: Text(track.displayArtist(),
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                    color: Colors.white70,
                                    shadows: const [
                                      Shadow(blurRadius: 8)
                                    ])),
                      ),
                      const SizedBox(height: 8),
                      _SeekBar(
                        state: state,
                        dragPos: _dragPos,
                        onDrag: (v) =>
                            setState(() => _dragPos = v),
                        onSeek: (ms) {
                          try {
                            state.controller.player.seek(
                                Duration(milliseconds: ms.toInt()));
                          } catch (_) {}
                          setState(() => _dragPos = null);
                        },
                      ),
                      _Transport(state: state),
                      _VolumeRow(state: state),
                      if (state.controller.errorLine != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24),
                          child: Text(state.controller.errorLine!,
                              style: TextStyle(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .error)),
                        ),
                      _ActionsRow(state: state, track: track),
                      const SizedBox(height: 8),
                      _Phase3Stubs(track: track),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _ArtCard extends StatefulWidget {
  final YtTrack track;
  const _ArtCard({required this.track});

  @override
  State<_ArtCard> createState() => _ArtCardState();
}

class _ArtCardState extends State<_ArtCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breathe;

  @override
  void initState() {
    super.initState();
    // Idle-sine breathe 1.2% (P1 adaptation: no FFT API in Flutter).
    _breathe = AnimationController(
        vsync: this, duration: const Duration(seconds: 4))
      ..repeat();
  }

  @override
  void dispose() {
    _breathe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final track = widget.track;
    final art = track.thumbUrl.replaceAll('hqdefault', 'maxresdefault');
    return StreamBuilder<bool>(
      stream:
          AppScope.of(context).controller.player.playingStream,
      initialData:
          AppScope.of(context).controller.player.playing,
      builder: (_, snap) {
        final playing = snap.data ?? true;
        return AnimatedScale(
          // Apple-Music pause shrink (1.0 → 0.92).
          scale: playing ? 1.0 : 0.92,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutBack,
          child: AnimatedBuilder(
            animation: _breathe,
            builder: (_, child) {
              final s = 1.0 +
                  0.012 *
                      (0.5 +
                          0.5 *
                              math.sin(_breathe.value *
                                  2 *
                                  math.pi));
              return Transform.scale(scale: s, child: child);
            },
            child: Container(
              width: 320,
              height: 320,
              margin:
                  const EdgeInsets.symmetric(horizontal: 24),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                boxShadow: const [
                  BoxShadow(
                      blurRadius: 24, color: Colors.black45)
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: TrackArt(
                    track: YtTrack(
                        id: track.id,
                        title: track.title,
                        artist: track.artist,
                        thumbUrl: art,
                        watchUrl: track.watchUrl),
                    size: 320),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Rolling ticker (P2): constant pan while sounding.
class _Ticker extends StatefulWidget {
  final String text;
  const _Ticker({required this.text});

  @override
  State<_Ticker> createState() => _TickerState();
}

class _TickerState extends State<_Ticker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(seconds: 12))
      ..repeat();
  }

  @override
  void didUpdateWidget(covariant _Ticker old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _c.reset();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 22,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => FractionallySizedBox(
          alignment: Alignment(-1 + 2 * _c.value, 0),
          widthFactor: 1.6,
          child: Text(widget.text,
              maxLines: 1,
              overflow: TextOverflow.visible,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)),
        ),
      ),
    );
  }
}

/// Glowing seek bar: tap + drag scrub, knob swell, time labels (P4).
class _SeekBar extends StatelessWidget {
  final AppState state;
  final double? dragPos;
  final ValueChanged<double> onDrag;
  final ValueChanged<double> onSeek;
  const _SeekBar(
      {required this.state,
      required this.dragPos,
      required this.onDrag,
      required this.onSeek});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration>(
      stream: state.controller.player.positionStream,
      builder: (_, posSnap) {
        final pos =
            (posSnap.data ?? Duration.zero).inMilliseconds.toDouble();
        final total = (state.controller.player.duration ?? Duration.zero)
            .inMilliseconds
            .toDouble();
        final value = dragPos ??
            (total <= 0 ? 0.0 : pos.clamp(0.0, total));
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Column(
            children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  // Hairline capsule (7dp, 12dp while dragging),
                  // played white / unplayed faint (BitChord shape).
                  trackHeight: 7,
                  trackShape:
                      const RoundedRectSliderTrackShape(),
                  thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius:
                          dragPos != null ? 12 : 7),
                  overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 18),
                  activeTrackColor:
                      Colors.white.withValues(alpha: 0.92),
                  inactiveTrackColor:
                      Colors.white.withValues(alpha: 0.26),
                  thumbColor: Colors.white,
                ),
                child: Slider(
                  value: total <= 0 ? 0.0 : value.clamp(0.0, total),
                  max: total <= 0 ? 1.0 : total,
                  onChanged: onDrag,
                  onChangeEnd: onSeek,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    Text(fmtMs(value.toInt()),
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12)),
                    Text(fmtMs(total.toInt()),
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12)),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Transport (P5): shuffle OFF→ON→SMART, prev/play/next, repeat
/// OFF→ALL→ONE; error line + buffering spinner.
class _Transport extends StatelessWidget {
  final AppState state;
  const _Transport({required this.state});

  @override
  Widget build(BuildContext context) {
    final engine = state.controller.engine;
    return StreamBuilder<PlayerState>(
      stream: state.controller.player.playerStateStream,
      builder: (_, snap) {
        final playing = snap.data?.playing ??
            state.controller.player.playing;
        final loading = snap.data?.processingState ==
                ProcessingState.loading ||
            snap.data?.processingState == ProcessingState.buffering ||
            state.controller.resolving;
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            IconButton(
              icon: Icon(
                  engine.shuffleMode == shuffleOff
                      ? Icons.shuffle_outlined
                      : engine.shuffleMode == shuffleSmart
                          ? Icons.shuffle_on_outlined
                          : Icons.shuffle,
                  color: Colors.white),
              tooltip: engine.shuffleMode == shuffleSmart
                  ? 'Smart shuffle'
                  : 'Shuffle',
              onPressed: () {
                try {
                  final m = engine.cycleShuffle();
                  if (m == shuffleSmart) {
                    final liked = state.library.liked
                        .map((e) => e.displayArtist())
                        .toSet();
                    final recent = state.library.recent
                        .map((e) => e.displayArtist())
                        .toList();
                    engine.applyOrder(smartOrderFor(
                      items: engine.snapshot(),
                      currentIndex: engine.currentIndex,
                      likedArtists: liked,
                      recentArtists: recent,
                    ));
                  }
                  state.controller.saveSessionNow();
                } catch (_) {}
              },
            ),
            IconButton(
              iconSize: 53,
              icon: const Icon(Icons.skip_previous, color: Colors.white),
              tooltip: 'Previous',
              onPressed: () => state.controller.previous(),
            ),
            loading
                ? const SizedBox(
                    width: 92,
                    height: 92,
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 3),
                    ),
                  )
                : IconButton.filled(
                    iconSize: 74,
                    style: IconButton.styleFrom(
                        backgroundColor:
                            Theme.of(context).colorScheme.primary,
                        foregroundColor: Theme.of(context)
                            .colorScheme
                            .onPrimary,
                        padding:
                            const EdgeInsets.all(9)),
                    icon: Icon(
                        playing ? Icons.pause : Icons.play_arrow),
                    tooltip: playing ? 'Pause' : 'Play',
                    onPressed: () =>
                        state.controller.togglePlay(),
                  ),
            IconButton(
              iconSize: 53,
              icon: const Icon(Icons.skip_next, color: Colors.white),
              tooltip: 'Next',
              onPressed: () => state.controller.next(),
            ),
            IconButton(
              icon: Icon(
                  engine.repeatMode == repeatOff
                      ? Icons.repeat_outlined
                      : engine.repeatMode == repeatAll
                          ? Icons.repeat
                          : Icons.repeat_one,
                  color: Colors.white),
              tooltip: 'Repeat',
              onPressed: () {
                try {
                  engine.cycleRepeat();
                  state.controller.saveSessionNow();
                } catch (_) {}
              },
            ),
          ],
        );
      },
    );
  }
}

/// Volume row (Apple-Music shape): 20dp speakers + slider.
/// Drives the player volume directly.
class _VolumeRow extends StatelessWidget {
  final AppState state;
  const _VolumeRow({required this.state});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: state.controller.player.volumeStream,
      initialData: state.controller.player.volume,
      builder: (_, snap) {
        final v = (snap.data ?? 1.0).clamp(0.0, 1.0);
        return Padding(
          padding:
              const EdgeInsets.fromLTRB(32, 0, 32, 4),
          child: Row(
            children: [
              const Icon(Icons.volume_down_outlined,
                  size: 20, color: Colors.white54),
              const SizedBox(width: 10),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 6,
                    thumbShape:
                        const RoundSliderThumbShape(
                            enabledThumbRadius: 7),
                    overlayShape:
                        const RoundSliderOverlayShape(
                            overlayRadius: 14),
                    activeTrackColor: Colors.white70,
                    inactiveTrackColor: Colors.white24,
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    value: v,
                    onChanged: (nv) {
                      try {
                        state.controller.player
                            .setVolume(nv);
                      } catch (_) {}
                    },
                  ),
                ),
              ),
              const SizedBox(width: 10),
              const Icon(Icons.volume_up_outlined,
                  size: 20, color: Colors.white54),
            ],
          ),
        );
      },
    );
  }
}

/// Actions row (P6): Video/Audio toggle, Like, Download, Queue, JAM
/// (dot when active — placeholder toast until Phase 4), 3-dot More.
class _ActionsRow extends StatelessWidget {
  final AppState state;
  final YtTrack track;
  const _ActionsRow({required this.state, required this.track});

  @override
  Widget build(BuildContext context) {
    final liked = state.library.isLiked(track.id);
    Widget disc({
      required String tip,
      required IconData icon,
      required VoidCallback onTap,
      bool filled = false,
    }) {
      return Tooltip(
        message: tip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: filled
                  ? Colors.white.withValues(alpha: 0.34)
                  : Colors.white.withValues(alpha: 0.18),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.35),
                  width: 0.5),
            ),
            child: Icon(icon, size: 19, color: Colors.white),
          ),
        ),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        disc(
          tip: 'Video',
          icon: Icons.ondemand_video_outlined,
          onTap: () => _toast(context,
              'Video mode arrives in Phase 3 — audio for now'),
        ),
        disc(
          tip: liked ? 'Unlike' : 'Like',
          icon: liked ? Icons.favorite : Icons.favorite_border,
          filled: liked,
          onTap: () => state.actToggleLike(track),
        ),
        disc(
          tip: 'Download',
          icon: Icons.download_outlined,
          onTap: () => _toast(context, state.downloadStub),
        ),
        disc(
          tip: 'Queue',
          icon: Icons.queue_music_outlined,
          onTap: () => openQueueSheet(context),
        ),
        disc(
          tip: 'JAM',
          icon: Icons.group_outlined,
          onTap: () => _toast(
              context, 'JAM listen-together arrives in Phase 4'),
        ),
        disc(
          tip: 'More',
          icon: Icons.more_vert,
          onTap: () => showTrackMenu(
              context, state, track, state.controller.engine.snapshot()),
        ),
      ],
    );
  }
}

/// Honest stubs for Phase-3 surfaces: never fake content (H8).
class _Phase3Stubs extends StatelessWidget {
  final YtTrack track;
  const _Phase3Stubs({required this.track});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Text('Lyrics, credits and video arrive in Phase 3.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }
}

Future<void> openArtistPage(BuildContext context, YtTrack track) async {
  try {
    final state = AppScope.of(context);
    final name = track.displayArtist();
    if (name == 'Unknown Artist') return;
    final hits = await state.repo.searchArtists(name, max: 1);
    if (!context.mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ArtistPage(
            name: name,
            thumb: hits.isNotEmpty ? hits.first.thumbUrl : track.thumbUrl)));
  } catch (_) {}
}

/// Artist page (P15): hero + top songs + Play/Shuffle + fav-heart.
class ArtistPage extends StatefulWidget {
  final String name;
  final String thumb;
  const ArtistPage({super.key, required this.name, required this.thumb});

  @override
  State<ArtistPage> createState() => _ArtistPageState();
}

class _ArtistPageState extends State<ArtistPage> {
  List<YtTrack> songs = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final state = AppScope.of(context);
      final hits =
          await state.repo.searchMusic('${widget.name} songs', max: 20);
      if (!mounted) return;
      setState(() {
        songs = hits
            .where((t) =>
                t.displayArtist().toLowerCase() ==
                widget.name.toLowerCase())
            .toList();
        loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final fav = state.library.liked
        .any((t) => t.displayArtist() == widget.name);
    return Scaffold(
      appBar: AppBar(title: Text(widget.name), actions: [
        IconButton(
          icon: Icon(fav ? Icons.favorite : Icons.favorite_border),
          tooltip: fav ? 'Unfavorite artist' : 'Favorite artist',
          onPressed: () async {
            try {
              await state.library.toggleArtist(widget.name,
                  thumbUrl: widget.thumb);
              if (mounted) setState(() {});
            } catch (_) {}
          },
        ),
      ]),
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                if (songs.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.play_arrow),
                            label: const Text('Play'),
                            onPressed: () =>
                                state.actPlay(songs, 0),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.shuffle),
                            label: const Text('Shuffle'),
                            onPressed: () {
                              final order = List<int>.generate(
                                  songs.length, (i) => i)
                                ..shuffle();
                              state.actPlay(
                                  [for (final i in order) songs[i]], 0);
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                for (var i = 0; i < songs.length; i++)
                  TrackRow(
                      track: songs[i],
                      contextQueue: songs,
                      index: i),
              ],
            ),
    );
  }
}

void _toast(BuildContext context, String message) {
  try {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  } catch (_) {}
}
