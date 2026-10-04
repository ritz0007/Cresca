// Karaoke lyrics panel (P7): synced highlight + scale, dots on ≥9 s
// gaps, auto-scroll + 3 s manual hold, tap-to-seek, plain fallback,
// honest empty state. Captions race LRCLIB per track; results memo in
// AppState for the session.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/track.dart';
import '../../data/lyrics.dart';
import '../app.dart';

/// Lyrics section for the player sheet: fetches once per track id.
class LyricsSection extends StatefulWidget {
  final YtTrack track;
  const LyricsSection({super.key, required this.track});

  @override
  State<LyricsSection> createState() => _LyricsSectionState();
}

class _LyricsSectionState extends State<LyricsSection> {
  LyricsState _state = const LyricsLoading();
  http.Client? _http;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant LyricsSection old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id) _load();
  }

  @override
  void dispose() {
    try {
      _http?.close();
    } catch (_) {}
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _state = const LyricsLoading());
    final client = http.Client();
    _http = client;
    try {
      final t = widget.track;
      final capped = fetchCaptions(
        captionJson: () async => null, // InnerTube leg lands with G1 session
        fetchText: (_) async => null,
      );
      final lrc = fetchLrclib(
        client,
        artist: t.displayArtist(),
        title: t.title,
      );
      final first = await Future.wait([capped, lrc]);
      LyricsState res = first[0];
      if (res is LyricsNotFound) res = first[1];
      if (!mounted) return;
      setState(() => _state = res);
      try {
        AppScope.of(context).lyricsMemo[widget.track.id] = res;
      } catch (_) {}
    } catch (_) {
      if (mounted) setState(() => _state = const LyricsNotFound());
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _state;
    if (s is LyricsLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
        child: Column(
          children: [
            _ShimmerLine(width: 220),
            SizedBox(height: 8),
            _ShimmerLine(width: 160),
            SizedBox(height: 8),
            _ShimmerLine(width: 190),
          ],
        ),
      );
    }
    if (s is LyricsSynced) {
      if (s.lines.isEmpty) return const _EmptyLyrics();
      return _KaraokeView(
        key: ValueKey(widget.track.id),
        lines: s.lines,
        track: widget.track,
      );
    }
    if (s is LyricsPlain) {
      return Container(
        height: 300,
        margin: const EdgeInsets.symmetric(horizontal: 24),
        child: SingleChildScrollView(
          child: Text(s.text,
              style: const TextStyle(
                  color: Colors.white70, height: 1.6)),
        ),
      );
    }
    return const _EmptyLyrics();
  }
}

class _ShimmerLine extends StatelessWidget {
  final double width;
  const _ShimmerLine({required this.width});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 14,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(7),
      ),
    );
  }
}

class _EmptyLyrics extends StatelessWidget {
  const _EmptyLyrics();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Text('No lyrics found for this track.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54, fontSize: 12)),
    );
  }
}

/// Synced karaoke list: current line highlighted + scaled, dots where
/// the next line is ≥9 s out, auto-scroll with 3 s manual hold,
/// tap-to-seek.
class _KaraokeView extends StatefulWidget {
  final List<LyricLine> lines;
  final YtTrack track;
  const _KaraokeView(
      {super.key, required this.lines, required this.track});

  @override
  State<_KaraokeView> createState() => _KaraokeViewState();
}

class _KaraokeViewState extends State<_KaraokeView> {
  final ScrollController _scroll = ScrollController();
  final Map<int, GlobalKey> _keys = {};
  DateTime _lastManual = DateTime.fromMillisecondsSinceEpoch(0);
  int _current = -1;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  GlobalKey _keyFor(int i) =>
      _keys.putIfAbsent(i, () => GlobalKey());

  void _maybeScroll(int current) {
    try {
      if (current == _current) return;
      _current = current;
      if (DateTime.now().difference(_lastManual) <
          const Duration(seconds: 3)) {
        return; // 3 s manual hold.
      }
      final k = _keys[current];
      final ctx = k?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(ctx,
          alignment: 0.4,
          duration: const Duration(milliseconds: 280));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        try {
          if (n is ScrollStartNotification &&
              n.dragDetails != null) {
            _lastManual = DateTime.now();
          }
        } catch (_) {}
        return false;
      },
      child: Container(
        height: 300,
        margin: const EdgeInsets.symmetric(horizontal: 8),
        child: StreamBuilder<Duration>(
          stream: state.controller.player.positionStream,
          builder: (_, snap) {
            final pos =
                (snap.data ?? Duration.zero).inMilliseconds;
            var cur = 0;
            for (var i = 0; i < widget.lines.length; i++) {
              if (widget.lines[i].startMs <= pos) {
                cur = i;
              } else {
                break;
              }
            }
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _maybeScroll(cur);
            });
            return ListView.builder(
              controller: _scroll,
              padding: const EdgeInsets.symmetric(vertical: 60),
              itemCount: widget.lines.length * 2 - 1,
              itemBuilder: (_, k) {
                if (k.isOdd) {
                  // Dots on ≥9 s interludes.
                  final a = widget.lines[k ~/ 2];
                  final b = widget.lines[k ~/ 2 + 1];
                  if (b.startMs - a.startMs < 9000) {
                    return const SizedBox(height: 14);
                  }
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 6),
                    child: Text('• • •',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 13,
                            letterSpacing: 4)),
                  );
                }
                final i = k ~/ 2;
                final line = widget.lines[i];
                final active = i == cur;
                return GestureDetector(
                  key: _keyFor(i),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    try {
                      state.controller.player.seek(Duration(
                          milliseconds: line.startMs));
                    } catch (_) {}
                  },
                  child: AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 280),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: active
                          ? Colors.white
                          : Colors.white54,
                      fontSize: active ? 19 : 15,
                      fontWeight: active
                          ? FontWeight.w700
                          : FontWeight.w400,
                      height: 1.7,
                    ),
                    child: Text(line.text),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
