// Karaoke lyrics panel (P7): synced highlight + scale, dots on ≥9 s
// gaps, auto-scroll with explicit Resume pill on manual hold,
// tap-to-seek (tap-vs-drag gated), plain fallback,
// honest empty state. Captions race LRCLIB per track; results memo in
// AppState for the session. InnerTube leg: WEB_REMIX player response
// (serviceIntegrityDimensions ignored logs get timedtext too), then
// NewPipe subtitles fallback, then LRCLIB.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../core/motion.dart';
import '../../core/track.dart';
import '../../data/lyrics.dart';
import '../../data/translate.dart';
import '../app.dart';
import '../design.dart';

/// Opaque stand-in for the black88 toast/panel surface, for contrast
/// math ([textOn]/[subtextOn] need an opaque background color).
const _panelBg = Color(0xFF141414);

/// Lyrics section for the player sheet: fetches once per track id.
class LyricsSection extends StatefulWidget {
  final YtTrack track;

  /// Publishes synced lines for the art-mode preview row (BitChord:
  /// current line under the title). Plain/absent → empty list.
  final ValueChanged<List<LyricLine>>? onLines;

  /// Publishes the DISPLAY lines (post language/romanization
  /// selection) so the collapsed preview shows the same language as
  /// the expanded karaoke. Fires post-frame on identity change only.
  final ValueChanged<List<LyricLine>>? onDisplay;

  /// Sounding-clock override (ms): when set, karaoke follows this
  /// instead of the engine positionStream. The sheet passes the video
  /// handle's clock in video mode (the parked engine freezes, so the
  /// engine stream would freeze the highlight too).
  final ValueListenable<int>? clockMs;

  /// Hidden publisher: runs the fetch + publishes lines without
  /// painting anything (art mode keeps a zero-size instance alive
  /// so the preview stays live).
  final bool hide;
  const LyricsSection(
      {super.key,
      required this.track,
      this.onLines,
      this.onDisplay,
      this.clockMs,
      this.hide = false});

  @override
  State<LyricsSection> createState() => _LyricsSectionState();
}

class _LyricsSectionState extends State<LyricsSection> {
  LyricsState _state = const LyricsLoading();
  http.Client? _http;
  YoutubeExplode? _explode;
  // Generation token: every _load bumps it; stale flights bail instead
  // of painting the old track's lyrics over the new one (skip-fast).
  int _gen = 0;

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
    // Invalidate any in-flight fetch so it can't paint after dispose.
    _gen++;
    try {
      _http?.close();
    } catch (_) {}
    try {
      _explode?.close();
    } catch (_) {}
    super.dispose();
  }

  /// Caption download with the same device-consistent headers as the
  /// player POST (native passes cookies + browser UA on timedtext GETs;
  /// consent keeps the consentless flow from 302 meta-stomping).
  Future<String?> _captionText(http.Client client, String url) async {
    try {
      final res = await client
          .get(Uri.parse(url), headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        'Referer': 'https://music.youtube.com/',
      }).timeout(const Duration(seconds: 9));
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      return res.body;
    } catch (_) {
      return null;
    }
  }

  /// InnerTube leg (LyricsRepository.fetchCaptions 1:1): WEB_REMIX
  /// player → captionTracks parse + rank → first 3 timedtext downloads.
  Future<LyricsState> _captionLeg(http.Client client, String videoId) =>
      fetchCaptions(
        captionJson: () async {
          try {
            final res = await client
                .post(
                  Uri.parse(
                      'https://music.youtube.com/youtubei/v1/player'
                      '?key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30'
                      '&prettyPrint=false'),
                  headers: const {
                    'Content-Type': 'application/json',
                    'User-Agent':
                        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                            '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
                    'Origin': 'https://music.youtube.com',
                    'Referer': 'https://music.youtube.com/',
                  },
                  body: '{"context":{"client":{"clientName":"WEB_REMIX",'
                      '"clientVersion":"1.20260218.01.00","hl":"en","gl":"US"}},'
                      '"videoId":"$videoId","racyCheckOk":true,'
                      '"contentCheckOk":true}',
                )
                .timeout(const Duration(seconds: 9));
            if (res.statusCode < 200 || res.statusCode >= 300) return null;
            final decoded = jsonDecode(res.body);
            return decoded is Map
                ? decoded.cast<String, dynamic>()
                : null;
          } catch (_) {
            return null;
          }
        },
        fetchText: (url) => _captionText(client, url),
      );

  /// NewPipe leg (YoutubeRepository.captionLines parity): manual tracks
  /// first, en/hi preferred, VTT re-encoded by the extractor.
  Future<LyricsState> _newpipeLeg(
      http.Client client, YoutubeExplode yt, String videoId) async {
    try {
      final manifest = await yt.videos.closedCaptions
          .getManifest(videoId)
          .timeout(const Duration(seconds: 12));
      final tracks = manifest.tracks.toList()
        ..sort((a, b) {
          final ma = !a.isAutoGenerated ? 1 : 0;
          final mb = !b.isAutoGenerated ? 1 : 0;
          if (ma != mb) return mb.compareTo(ma);
          final la = a.language.code.toLowerCase();
          final lb = b.language.code.toLowerCase();
          final ra = la.startsWith('en') || la.startsWith('hi') ? 1 : 0;
          final rb = lb.startsWith('en') || lb.startsWith('hi') ? 1 : 0;
          return rb.compareTo(ra);
        });
      for (final t in tracks.take(3)) {
        try {
          final res = await client
              .get(t.url)
              .timeout(const Duration(seconds: 9));
          if (res.statusCode < 200 || res.statusCode >= 300) continue;
          final lines = parseCaptions(res.body);
          if (lines.length >= 3) {
            return LyricsSynced(lines, LyricSource.youtubeCaptions);
          }
        } catch (_) {}
      }
      return const LyricsNotFound();
    } catch (_) {
      return const LyricsNotFound();
    }
  }

  Future<void> _load([bool force = false]) async {
    // Bump first: switching tracks (even to an episode or a memoized
    // track) invalidates any in-flight fetch for the previous track.
    final myGen = ++_gen;
    // Episodes carry no lyrics: skip the whole fetch cascade (which
    // would burn network + show a spinner for nothing).
    try {
      if (AppScope.of(context).isEpisodeTrack(widget.track.id)) {
        if (mounted) setState(() => _state = const LyricsNotFound());
        return;
      }
    } catch (_) {}
    setState(() => _state = const LyricsLoading());
    widget.onLines?.call(const []);
    if (!force) {
      final memo =
          AppScope.of(context).lyricsMemo[widget.track.id];
      if (memo != null) {
        setState(() => _state = memo);
        _publish(memo);
        return;
      }
    }
    // Drop the previous fetch's transport first: rapid skips leaked one
    // http.Client + YoutubeExplode per track.
    try {
      _http?.close();
    } catch (_) {}
    _http = null;
    try {
      _explode?.close();
    } catch (_) {}
    _explode = null;
    final client = http.Client();
    _http = client;
    final yt = _explode = YoutubeExplode();
    try {
      final videoId =
          extractVideoId(widget.track.watchUrl) ?? widget.track.id;
      // All three legs fly in parallel; priority still decides
      // (captions > NewPipe tracks > LRCLIB), so a fast miss never
      // beats a slower hit.
      final legs = await Future.wait([
        _captionLeg(client, videoId)
            .catchError((_) => const LyricsNotFound()),
        _newpipeLeg(client, yt, videoId),
        fetchLrclib(
          client,
          artist: widget.track.displayArtist(),
          title: widget.track.title,
        ).catchError((_) => const LyricsNotFound()),
      ]);
      LyricsState res = const LyricsNotFound();
      for (final leg in legs) {
        if (leg is! LyricsNotFound) {
          res = leg;
          break;
        }
      }
      // Skip-fast guard: a superseded load must not paint the old
      // track's lyrics over the new one.
      if (!mounted || myGen != _gen) return;
      setState(() => _state = res);
      _publish(res);
      try {
        AppScope.of(context).lyricsMemo[widget.track.id] = res;
      } catch (_) {}
    } catch (_) {
      if (mounted && myGen == _gen) {
        setState(() => _state = const LyricsNotFound());
      }
    }
  }

  void _publish(LyricsState s) {
    try {
      if (s is LyricsSynced) {
        widget.onLines?.call(s.lines);
      } else {
        widget.onLines?.call(const []);
      }
    } catch (_) {}
  }

  /// "Change" retry (attribution row): clears BOTH memos for this track
  /// — the session map in AppState AND the 128-entry LRU inside
  /// lyrics.dart — then re-runs the full pipeline and toasts which
  /// provider served. Root cause of the dead button: [_load] short-
  /// circuits on the session memo, so a plain re-call returns the
  /// identical state with zero feedback (perceived as "does nothing");
  /// the LRU would additionally pin the same LRCLIB-era result even
  /// past the session map. 48px target kept in [_Attribution].
  Future<void> _retry() async {
    LyricSource before = LyricSource.none;
    try {
      final s = _state;
      if (s is LyricsSynced) before = s.source;
      if (s is LyricsPlain) before = s.source;
    } catch (_) {}
    try {
      AppScope.of(context).lyricsMemo.remove(widget.track.id);
    } catch (_) {}
    try {
      clearLyricsMemo();
    } catch (_) {}
    await _load(true);
    if (!mounted) return;
    final s = _state;
    if (s is LyricsSynced) {
      _LyricTools.toast(
          context,
          s.source == before
              ? 'Already showing the best match (${lyricSourceName(s.source)})'
                  ')'
              : 'Lyrics via ${lyricSourceName(s.source)}');
    } else if (s is LyricsPlain) {
      _LyricTools.toast(
          context, 'Plain lyrics via ${lyricSourceName(s.source)}');
    } else {
      _LyricTools.toast(context, 'No other lyrics found');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hide) return const SizedBox.shrink();
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
      return _SyncedBody(
        key: ValueKey('lyrbody-${widget.track.id}'),
        lines: s.lines,
        source: s.source,
        track: widget.track,
        onRetry: _retry,
        onDisplay: widget.onDisplay,
        clockMs: widget.clockMs,
      );
    }
    if (s is LyricsPlain) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Attribution(source: s.source, onRetry: _retry),
          Container(
            height: 300,
            margin: const EdgeInsets.symmetric(horizontal: 24),
            child: SingleChildScrollView(
              child: Text(s.text,
                  style: TextStyle(
                      color: subtextOn(_panelBg), height: 1.6)),
            ),
          ),
        ],
      );
    }
    return const _EmptyLyrics();
  }
}

/// Synced-lyrics body: owns the display mode (original / English
/// translation / Hinglish romanized sing-along) so the tools row can
/// swap what [_KaraokeView] paints. Timings never change — display
/// lines reuse the original startMs, so highlight dots, roll,
/// auto-scroll and tap-to-seek behave identically in every mode.
enum _LyricMode { original, english, hinglish }

class _SyncedBody extends StatefulWidget {
  final List<LyricLine> lines;
  final LyricSource source;
  final YtTrack track;
  final VoidCallback onRetry;
  final ValueChanged<List<LyricLine>>? onDisplay;
  final ValueListenable<int>? clockMs;
  const _SyncedBody(
      {super.key,
      required this.lines,
      required this.source,
      required this.track,
      required this.onRetry,
      this.onDisplay,
      this.clockMs});

  @override
  State<_SyncedBody> createState() => _SyncedBodyState();
}

class _SyncedBodyState extends State<_SyncedBody> {
  _LyricMode _mode = _LyricMode.original;
  List<String>? _english;
  bool _busy = false;

  /// Per-track timing offset (ms, ±500 steps). Loaded from
  /// SharedPreferences once, live in [lyricOffsetMs] memo after that.
  int _offsetMs = 0;

  /// Display-line caches per mode. Rebuilt ONLY when the underlying
  /// data changes (mode switch / translation arrival / refetch), so the
  /// same list instance flows to [_KaraokeView] across rebuilds and
  /// line identity, scroll offset and the active highlight survive
  /// language switches. Timings are never baked in — the original
  /// startMs is preserved and the offset applies on top at render.
  List<LyricLine>? _englishLines;
  List<LyricLine>? _hinglishLines;

  /// Last display list handed to [onDisplay] (identity-guarded so the
  /// collapsed preview isn't spammed on every rebuild).
  List<LyricLine>? _published;

  @override
  void initState() {
    super.initState();
    _loadOffset();
  }

  @override
  void didUpdateWidget(covariant _SyncedBody old) {
    super.didUpdateWidget(old);
    // Refetch (Change retry) hands a NEW list object for the same track:
    // per-mode caches built from the old lines are stale, so drop them
    // and fall back to Original (translations re-fetch on demand).
    // Same-object rebuilds (parent setState) keep everything.
    if (!identical(old.lines, widget.lines)) {
      _english = null;
      _englishLines = null;
      _hinglishLines = null;
      _mode = _LyricMode.original;
    }
    if (old.track.id != widget.track.id) _loadOffset();
  }

  Future<void> _loadOffset() async {
    var v = 0;
    try {
      v = lyricOffsetMs(widget.track.id);
    } catch (_) {}
    try {
      final saved = AppScope.of(context)
          .prefs
          ?.getInt(lyricOffsetPrefKey(widget.track.id));
      if (saved != null) v = setLyricOffsetMs(widget.track.id, saved);
    } catch (_) {}
    if (!mounted) return;
    if (v != _offsetMs) setState(() => _offsetMs = v);
  }

  Future<void> _setOffset(int ms) async {
    final v = setLyricOffsetMs(widget.track.id, ms);
    if (mounted) setState(() => _offsetMs = v);
    try {
      await AppScope.of(context)
          .prefs
          ?.setInt(lyricOffsetPrefKey(widget.track.id), v);
    } catch (_) {}
  }

  /// Rebuilds display lines from [alt] text, keeping the original
  /// startMs (karaoke identity). ALWAYS returns a same-length list:
  /// missing/extra translated lines fall back per-line to the
  /// original, so a length-divergent translation can never silently
  /// show originals under a foreign-language pill (or vice versa).
  List<LyricLine> _remap(List<String>? alt) {
    try {
      final base = widget.lines;
      return [
        for (var i = 0; i < base.length; i++)
          LyricLine(
              base[i].startMs,
              alt != null &&
                      i < alt.length &&
                      alt[i].trim().isNotEmpty
                  ? alt[i]
                  : base[i].text),
      ];
    } catch (_) {
      return widget.lines;
    }
  }

  List<String>? get _roman {
    try {
      return romanizeLines(widget.lines.map((e) => e.text).toList());
    } catch (_) {
      return null;
    }
  }

  List<LyricLine> _display() {
    try {
      if (_mode == _LyricMode.english && _englishLines != null) {
        return _englishLines!;
      }
      if (_mode == _LyricMode.hinglish && _hinglishLines != null) {
        return _hinglishLines!;
      }
      return widget.lines;
    } catch (_) {
      return widget.lines;
    }
  }

  bool get _hasNonLatin {
    try {
      return widget.lines.any((l) => needsTranslation(l.text));
    } catch (_) {
      return false;
    }
  }

  bool get _hasIndic {
    try {
      return widget.lines.any((l) => needsRomanization(l.text));
    } catch (_) {
      return false;
    }
  }

  Future<void> _select(_LyricMode m) async {
    if (_busy) return;
    if (m == _LyricMode.original) {
      if (mounted) setState(() => _mode = m);
      return;
    }
    if (m == _LyricMode.hinglish) {
      if (!_hasIndic) {
        _LyricTools.toast(
            context, 'These lyrics already use Latin characters');
        return;
      }
      // Romanize once and cache: every later build reuses the same
      // list instance (identity + scroll preserved). A null romanizer
      // keeps Original selected instead of showing original text
      // under a Hinglish pill (mode/text mismatch).
      final roman = _roman;
      if (roman == null) {
        _LyricTools.toast(
            context, 'Hinglish unavailable for these lyrics');
        return;
      }
      try {
        _hinglishLines ??= _remap(roman);
      } catch (_) {}
      if (mounted) setState(() => _mode = m);
      return;
    }
    // English translation leg: memoized keyless endpoint, per-line
    // fallback to the original (offline = original lines).
    if (!_hasNonLatin) {
      _LyricTools.toast(
          context, 'These lyrics already use Latin characters');
      return;
    }
    if (_english != null && _english!.length == widget.lines.length) {
      if (mounted) setState(() => _mode = m);
      return;
    }
    if (mounted) setState(() => _busy = true);
    try {
      final out = await translateLines(
          widget.lines.map((e) => e.text).toList());
      if (!mounted) return;
      var same = true;
      try {
        for (var i = 0; i < out.length && i < widget.lines.length; i++) {
          if (out[i] != widget.lines[i].text) {
            same = false;
            break;
          }
        }
      } catch (_) {}
      if (same) {
        _LyricTools.toast(
            context, 'Translation unavailable offline');
        setState(() {
          _busy = false;
          _mode = _LyricMode.original;
        });
        return;
      }
      setState(() {
        _busy = false;
        _english = out;
        _englishLines = _remap(out);
        _mode = m;
      });
    } catch (_) {
      if (!mounted) return;
      _LyricTools.toast(
          context, 'Translation unavailable offline');
      setState(() {
        _busy = false;
        _mode = _LyricMode.original;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final disp = _display();
    // Publish display lines for the collapsed preview (same language
    // as karaoke): post-frame + identity-guarded, never during build.
    try {
      if (!identical(_published, disp)) {
        _published = disp;
        final cb = widget.onDisplay;
        if (cb != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            try {
              cb(disp);
            } catch (_) {}
          });
        }
      }
    } catch (_) {}
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Stable key across Original/English/Hinglish: the SAME
        // _KaraokeView state (scroll controller, startMs-keyed item
        // keys, active index) survives language switches, so position
        // and highlight never reset.
        _KaraokeView(
          key: ValueKey('karaoke-${widget.track.id}'),
          lines: disp,
          track: widget.track,
          offsetMs: _offsetMs,
          clockMs: widget.clockMs,
        ),
        _LyricTools(
          lines: widget.lines,
          mode: _mode,
          busy: _busy,
          onSelect: _select,
          trackId: widget.track.id,
          offsetMs: _offsetMs,
          onOffset: _setOffset,
        ),
        _Attribution(source: widget.source, onRetry: widget.onRetry),
      ],
    );
  }
}

/// Language tools row: original (globe) left, English translation +
/// Hinglish sing-along (romanized narration text) right, plus a 3-dot
/// tools menu hosting the timing offset stepper. Every target is
/// 48×48; selection-pill fades collapse to 1 ms when motion is off.
/// Offline/failed translation falls back to the original lines.
class _LyricTools extends StatelessWidget {
  final List<LyricLine> lines;
  final _LyricMode mode;
  final bool busy;
  final ValueChanged<_LyricMode> onSelect;
  final String trackId;
  final int offsetMs;
  final ValueChanged<int> onOffset;
  const _LyricTools(
      {required this.lines,
      required this.mode,
      required this.busy,
      required this.onSelect,
      required this.trackId,
      required this.offsetMs,
      required this.onOffset});

  static void toast(BuildContext context, String msg) {
    try {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.black.withValues(alpha: 0.88),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        content: Semantics(liveRegion: true, child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Color(0xFFFA243C),
              ),
              child: Icon(Icons.graphic_eq,
                  color: textOn(crescaRed), size: 15),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(msg,
                  style: TextStyle(
                      color: textOn(_panelBg), fontSize: 13)),
            ),
          ],
        )),
      ));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final pillMs = state.motionMs(180);
    Widget tool({
      required IconData icon,
      required String tip,
      required bool selected,
      required VoidCallback? onTap,
      Widget? child,
    }) {
      return AnimatedContainer(
        duration: Duration(milliseconds: pillMs),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context)
                  .colorScheme
                  .primary
                  .withValues(alpha: 0.22)
              : const Color(0x00000000),
          borderRadius: BorderRadius.circular(12),
        ),
        child: IconButton(
          style: IconButton.styleFrom(
            minimumSize: const Size(48, 48),
            tapTargetSize: MaterialTapTargetSize.padded,
            padding: EdgeInsets.zero,
          ),
          icon: child ??
              Icon(icon,
                  color: selected
                      ? textOn(_panelBg)
                      : subtextOn(_panelBg),
                  size: 22),
          tooltip: tip,
          onPressed: onTap,
        ),
      );
    }

    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      child: Row(
        children: [
          tool(
            icon: Icons.language_outlined,
            tip: 'Original language',
            selected: mode == _LyricMode.original,
            onTap: busy ? null : () => onSelect(_LyricMode.original),
          ),
          const Spacer(),
          tool(
            icon: Icons.record_voice_over_outlined,
            tip: 'Hinglish sing-along',
            selected: mode == _LyricMode.hinglish,
            onTap: busy ? null : () => onSelect(_LyricMode.hinglish),
          ),
          const SizedBox(width: 4),
          tool(
            icon: Icons.translate_outlined,
            tip: 'Translate to English',
            selected: mode == _LyricMode.english,
            onTap: busy ? null : () => onSelect(_LyricMode.english),
            child: busy
                ? SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: subtextOn(_panelBg),
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 4),
          // 3-dot tools menu: timing offset (-/+ 0.5 s steps, persisted
          // per track). 48×48 like every other tool.
          tool(
            icon: Icons.more_horiz,
            tip:
                'Lyric options (timing ${formatLyricOffset(offsetMs)})',
            selected: offsetMs != 0,
            onTap: () => _openOffsetSheet(context),
          ),
        ],
      ),
    );
  }

  /// Timing offset sheet: -/+ [lyricOffsetStepMs] steps with the live
  /// value, plus reset. Shifts every line's effective timing in the
  /// karaoke (highlight, roll, auto-scroll, tap-to-seek all read the
  /// offset on top) and persists per track. Transform/opacity motion
  /// only; opaque surface so textOn math holds.
  void _openOffsetSheet(BuildContext context) {
    var v = offsetMs;
    late final int pillMs;
    try {
      pillMs = AppScope.of(context).motionMs(180);
    } catch (_) {
      pillMs = 180;
    }
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          Widget stepBtn({
            required IconData icon,
            required String tip,
            required int delta,
          }) {
            return Semantics(
              button: true,
              label: tip,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  try {
                    v = (v + delta).clamp(
                        -lyricOffsetMaxMs, lyricOffsetMaxMs);
                    onOffset(v);
                    setSheet(() {});
                  } catch (_) {}
                },
                child: AnimatedContainer(
                  duration: Duration(milliseconds: pillMs),
                  curve: Curves.easeOut,
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.14),
                    border: Border.all(
                        color:
                            Colors.white.withValues(alpha: 0.25),
                        width: 0.5),
                  ),
                  child: Icon(icon,
                      color: textOn(_panelBg), size: 22),
                ),
              ),
            );
          }

          return Container(
            decoration: const BoxDecoration(
              color: Color(0xFF1B1B1B),
              borderRadius:
                  BorderRadius.vertical(top: Radius.circular(20)),
            ),
            padding:
                const EdgeInsets.fromLTRB(20, 12, 20, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.white54,
                        borderRadius:
                            BorderRadius.circular(2))),
                const SizedBox(height: 12),
                Text('Lyric timing',
                    style: TextStyle(
                        color: textOn(_panelBg),
                        fontSize: 16,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text('Shift all lines to match the music',
                    style: TextStyle(
                        color: subtextOn(_panelBg),
                        fontSize: 12)),
                const SizedBox(height: 14),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    stepBtn(
                        icon: Icons.remove,
                        tip: 'Shift lyrics earlier by 0.5 seconds',
                        delta: -lyricOffsetStepMs),
                    SizedBox(
                      width: 84,
                      child: Text(formatLyricOffset(v),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: textOn(_panelBg),
                              fontSize: 20,
                              fontWeight: FontWeight.w800)),
                    ),
                    stepBtn(
                        icon: Icons.add,
                        tip: 'Shift lyrics later by 0.5 seconds',
                        delta: lyricOffsetStepMs),
                  ],
                ),
                const SizedBox(height: 8),
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(48, 48),
                    tapTargetSize:
                        MaterialTapTargetSize.padded,
                  ),
                  onPressed: v == 0
                      ? null
                      : () {
                          try {
                            v = 0;
                            onOffset(0);
                            setSheet(() {});
                          } catch (_) {}
                        },
                  child: Text('Reset',
                      style: TextStyle(
                          color: v == 0
                              ? subtextOn(_panelBg)
                              : textOn(_panelBg),
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// Provider attribution row (BitChord/YTM parity): "Lyrics by X" +
/// retry (re-runs the pipeline — next provider may hit).
class _Attribution extends StatelessWidget {
  final LyricSource source;
  final VoidCallback onRetry;
  const _Attribution({required this.source, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final name = lyricSourceName(source);
    if (name.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Text('Lyrics by $name',
                style: TextStyle(
                    color: subtextOn(_panelBg)
                        .withValues(alpha: 0.8),
                    fontSize: 12,
                    letterSpacing: 0.2)),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              tapTargetSize: MaterialTapTargetSize.padded,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            onPressed: onRetry,
            child: Text('Change',
                style: TextStyle(
                    color: textOn(_panelBg),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    decoration: TextDecoration.underline)),
          ),
        ],
      ),
    );
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
    return Padding(
      padding:
          const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Text('No lyrics found for this track.',
          textAlign: TextAlign.center,
          style: TextStyle(color: subtextOn(_panelBg), fontSize: 12)),
    );
  }
}

/// Synced karaoke list: current line highlighted + scaled, dots where
/// the next line is ≥9 s out, auto-scroll that yields to the finger with
/// an explicit Resume pill (no silent timer yank),
/// tap-to-seek (tap-vs-drag gated). Item identity is startMs-keyed (not index-keyed), so a
/// language swap over the same timings reuses the same elements and
/// the scroll offset + active highlight never reset. [offsetMs] shifts
/// every line's effective timing live (highlight, roll, auto-scroll
/// and tap-to-seek all read it on top); raw startMs gaps (dots) are
/// offset-invariant.
class _KaraokeView extends StatefulWidget {
  final List<LyricLine> lines;
  final YtTrack track;
  final int offsetMs;
  final ValueListenable<int>? clockMs;
  const _KaraokeView(
      {super.key,
      required this.lines,
      required this.track,
      this.offsetMs = 0,
      this.clockMs});

  @override
  State<_KaraokeView> createState() => _KaraokeViewState();
}

class _KaraokeViewState extends State<_KaraokeView> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _keys = {};
  DateTime _lastManual = DateTime.fromMillisecondsSinceEpoch(0);
  // Explicit manual-hold state: the finger beats auto-scroll until the
  // user taps Resume (no silent auto-resume timer — timers that yank
  // the lines back are the bug). Reset on track change below.
  bool _userScrolling = false;
  // Tap-vs-drag gate: a seek needs tapUp within 300 ms and <8 dp of
  // movement. Screen-reader activation carries no touch data and
  // always passes the gate.
  DateTime? _downAt;
  Offset? _downPos;
  DateTime? _upAt;
  Offset? _upPos;
  int _current = -1;
  int _rollMs = lyricRollMs;
  int _resumeMs = 220;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _KaraokeView old) {
    super.didUpdateWidget(old);
    // New track (same widget element, e.g. hidden publisher reuse):
    // the finger-hold belongs to the old song — auto-scroll resumes.
    if (old.track.id != widget.track.id) {
      _userScrolling = false;
      _lastManual = DateTime.fromMillisecondsSinceEpoch(0);
    }
    // Language / offset swaps keep the same startMs sequence: element
    // identity, pixel offset and the active index all survive — never
    // jump or reset. Only prune keys for lines that genuinely left.
    try {
      final live = <String>{};
      final counts = <int, int>{};
      for (final l in widget.lines) {
        final n = counts[l.startMs] ?? 0;
        counts[l.startMs] = n + 1;
        live.add('lyr-${l.startMs}-$n');
      }
      _keys.removeWhere((k, _) => !live.contains(k));
    } catch (_) {}
  }

  String _stemFor(int i) {
    try {
      final l = widget.lines[i];
      // Occurrence suffix keeps duplicate timestamps unique; the
      // startMs stem keeps identity across Original/English/Hinglish.
      var occ = 0;
      for (var k = 0; k < i; k++) {
        if (widget.lines[k].startMs == l.startMs) occ++;
      }
      return 'lyr-${l.startMs}-$occ';
    } catch (_) {
      return 'lyr-idx-$i';
    }
  }

  GlobalKey _keyFor(int i) {
    try {
      return _keys.putIfAbsent(_stemFor(i), () => GlobalKey());
    } catch (_) {
      return _keys.putIfAbsent('lyr-idx-$i', () => GlobalKey());
    }
  }

  void _maybeScroll(int current) {
    try {
      if (current == _current) return;
      _current = current;
      // Finger always wins: while the user holds the scroll, the
      // position stream keeps flowing and we simply skip the scroll.
      // Resume is explicit (the pill) — never a silent timer yank.
      // The 3 s hold below stays as a backstop for programmatic
      // scrolls that never raised the touch flag.
      if (_userScrolling) return;
      if (DateTime.now().difference(_lastManual) <
          const Duration(seconds: manualHoldSec)) {
        return;
      }
      final k = _keys[_stemFor(current)];
      final ctx = k?.currentContext;
      if (ctx == null) return;
      // Smooth auto-scroll (easeInOut, lyric-roll spec; 1ms when
      // motion is off via the cached kill-switch-aware duration).
      Scrollable.ensureVisible(ctx,
          alignment: 0.4,
          duration: Duration(milliseconds: _rollMs),
          curve: Curves.easeInOut);
    } catch (_) {}
  }

  /// Explicit resume: glide back to the current line (220 ms,
  /// motion-aware) and hand auto-scroll the wheel again.
  void _resume() {
    try {
      if (!_userScrolling) return;
      setState(() => _userScrolling = false);
      final k = _keys[_stemFor(_current)];
      final ctx = k?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(ctx,
          alignment: 0.4,
          duration: Duration(milliseconds: _resumeMs),
          curve: Curves.easeInOut);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        try {
          if (n is ScrollStartNotification &&
              n.dragDetails != null) {
            // Touch scroll (not a programmatic ensureVisible): the
            // finger takes over until Resume is tapped.
            _lastManual = DateTime.now();
            if (!_userScrolling && mounted) {
              setState(() => _userScrolling = true);
            }
          }
        } catch (_) {}
        return false;
      },
      child: Container(
        height: 300,
        margin: const EdgeInsets.symmetric(horizontal: 12),
        child: Stack(
          children: [
            _clock(),
            // Explicit Resume pill: bottom-center Glass chip. Tells
            // the user auto-scroll will hand back on tap — the old
            // silent 3 s hold yanked the lines with no warning.
            if (_userScrolling)
              Positioned(
                bottom: 12,
                left: 0,
                right: 0,
                child: Center(
                  child: Semantics(
                    button: true,
                    label: 'Resume',
                    excludeSemantics: true,
                    child: PressScale(
                      motionOn:
                          AppScope.of(context).motionOn,
                      onTap: _resume,
                      child: Glass(
                        radius: 999,
                        padding:
                            const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 10),
                        child: Text('Resume',
                            style: TextStyle(
                                color:
                                    textOn(_panelBg),
                                fontSize: 13,
                                fontWeight:
                                    FontWeight.w600,
                                height: 1.2)),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Position source: the video sounding clock in video mode (the
  /// parked engine freezes), else the engine position stream.
  Widget _clock() {
    final c = widget.clockMs;
    if (c != null) {
      return ValueListenableBuilder<int>(
        valueListenable: c,
        builder: (_, ms, _) => _list(ms),
      );
    }
    final state = AppScope.of(context);
    // Throttle: position ticks rebuild the whole karaoke list; 4 Hz is
    // plenty for highlight + autoscroll and skips the in-between frames.
    return StreamBuilder<Duration>(
      stream: state.controller.player.positionStream.distinct((a, b) =>
          (a.inMilliseconds ~/ 250) == (b.inMilliseconds ~/ 250)),
      builder: (_, snap) => _list(
          (snap.data ?? Duration.zero).inMilliseconds),
    );
  }

  Widget _list(int pos) {
    final state = AppScope.of(context);
            // Cache the kill-switch-aware roll duration for the
            // post-frame auto-scroll (avoids context reads off-build).
            try {
              _rollMs = state.motionMs(lyricRollMs);
              _resumeMs = state.motionMs(220);
            } catch (_) {}
            var cur = 0;
            final off = widget.offsetMs;
            for (var i = 0; i < widget.lines.length; i++) {
              if (effectiveLyricMs(widget.lines[i].startMs, off) <=
                  pos) {
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
                    return const SizedBox(height: 12);
                  }
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: 8),
                    child: Text('• • •',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: subtextOn(_panelBg)
                                .withValues(alpha: 0.7),
                            fontSize: 12,
                            letterSpacing: 5,
                            height: 1.0)),
                  );
                }
                final i = k ~/ 2;
                final line = widget.lines[i];
                final active = i == cur;
                // Respect large text: scale hero type modestly.
                double scaler = 1.0;
                try {
                  scaler = MediaQuery.textScalerOf(context)
                      .scale(1.0)
                      .clamp(1.0, 1.3);
                } catch (_) {}
                return GestureDetector(
                  key: _keyFor(i),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (d) {
                    _downAt = DateTime.now();
                    _downPos = d.globalPosition;
                  },
                  onTapUp: (d) {
                    _upAt = DateTime.now();
                    _upPos = d.globalPosition;
                  },
                  onTap: () {
                    try {
                      // Finger wins: while the user holds the scroll,
                      // taps never seek (tap Resume first).
                      if (_userScrolling) return;
                      final downAt = _downAt;
                      final downPos = _downPos;
                      final upAt = _upAt;
                      final upPos = _upPos;
                      _downAt = null;
                      _downPos = null;
                      _upAt = null;
                      _upPos = null;
                      // Tap, not drag: up within 300 ms and <8 dp of
                      // movement. Screen-reader activation carries no
                      // touch data and always passes.
                      if (downAt != null &&
                          upAt != null &&
                          downPos != null &&
                          upPos != null) {
                        if (upAt.difference(downAt) >
                            const Duration(
                                milliseconds: 300)) {
                          return;
                        }
                        if ((upPos - downPos).distance >
                            8) {
                          return;
                        }
                      }
                      // Offset applies on top: seek lands on the
                      // shifted (heard) moment, timings preserved.
                      state.controller.player.seek(Duration(
                          milliseconds: effectiveLyricMs(
                              line.startMs,
                              widget.offsetMs)));
                    } catch (_) {}
                  },
                  // Karaoke highlight crossfade (AnimatedContainer,
                  // 280ms) + active-line roll (AnimatedSwitcher with
                  // SlideTransition per lyricRollMs). Transform/opacity
                  // only; no blur anywhere.
                  child: Semantics(
                    button: true,
                    label: active
                        ? 'Current lyric line: ${line.text}'
                        : 'Lyric line, tap to seek: ${line.text}',
                    child: AnimatedContainer(
                      duration: Duration(
                          milliseconds:
                              state.motionMs(lyricRollMs)),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        gradient: active
                            ? LinearGradient(
                                begin: Alignment.centerLeft,
                                end: Alignment.centerRight,
                                colors: [
                                  Theme.of(context)
                                      .colorScheme
                                      .primary
                                      .withValues(alpha: 0.20),
                                  Colors.white.withValues(
                                      alpha: 0.05),
                                ],
                              )
                            : null,
                        color: active
                            ? Colors.white
                                .withValues(alpha: 0.05)
                            : const Color(0x00000000),
                        borderRadius:
                            BorderRadius.circular(12),
                      ),
                      child: AnimatedSwitcher(
                        duration: Duration(
                            milliseconds:
                                state.motionMs(lyricRollMs)),
                        // Default layout stacks children centered;
                        // pin them left so lyric lines stay put.
                        layoutBuilder: (current, previous) =>
                            Stack(
                          alignment:
                              Alignment.centerLeft,
                          children: [
                            ...previous,
                            ?current,
                          ],
                        ),
                        transitionBuilder:
                            (child, anim) {
                          final curved = CurvedAnimation(
                              parent: anim,
                              curve: Curves.easeOut);
                          return FadeTransition(
                            opacity: curved,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin:
                                    const Offset(0, 0.25),
                                end: Offset.zero,
                              ).animate(curved),
                              child: child,
                            ),
                          );
                        },
                        child: AnimatedDefaultTextStyle(
                          key: ValueKey(
                              'lyr-$i-$active'),
                          duration: Duration(
                              milliseconds: state
                                  .motionMs(lyricRollMs)),
                          // Refined hero type: left-aligned, calm step
                          // between idle and active (timings untouched).
                          textAlign: TextAlign.left,
                          style: TextStyle(
                            color: active
                                ? textOn(_panelBg)
                                : subtextOn(_panelBg)
                                    .withValues(alpha: 0.75),
                            fontSize:
                                (active ? 28 : 19) *
                                    scaler,
                            fontWeight: active
                                ? FontWeight.w700
                                : FontWeight.w400,
                            letterSpacing:
                                active ? -0.3 : 0.0,
                            height: active ? 1.4 : 1.5,
                          ),
                          child: Text(line.text),
                        ),
                      ),
                    ),
                  ),
                );
              },
            );
  }
}
