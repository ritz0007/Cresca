// Player credits destination (U4 split): About-this-song card,
// artist page route + entry, artist header art, videos rail card.
// Extracted verbatim from player_sheet.dart — behavior unchanged.

import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/motion.dart';
import '../../core/track.dart';
import '../../data/details.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'player_sheet.dart';
import 'track_row.dart';


/// About-this-song card (P8): Plays/Likes/Released/Duration + trimmed
/// description. Extractor-backed (P8 native DetailsCard parity).
class DetailsSection extends StatefulWidget {
  final YtTrack track;
  const DetailsSection({super.key, required this.track});

  @override
  State<DetailsSection> createState() => _DetailsSectionState();
}

class _DetailsSectionState extends State<DetailsSection> {
  VideoDetails? _details;

  /// Load generation token (U4): a slow details fetch resolving after
  /// a track change must not paint the previous track's card.
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DetailsSection old) {
    super.didUpdateWidget(old);
    if (old.track.id != widget.track.id) {
      _loadGen++; // invalidate the in-flight fetch for the old track
      _load();
    }
  }

  Future<void> _load() async {
    final gen = _loadGen;
    final store = AppScope.of(context).details;
    try {
      final d = await store.load(widget.track.watchUrl);
      if (!mounted || gen != _loadGen) return;
      setState(() => _details = d);
    } catch (_) {}
  }

  @override
  void dispose() {
    _loadGen++; // invalidate any in-flight fetch
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = _details;
    final rows = <(String, String)>[
      ('Artist', widget.track.displayArtist()),
      if (d != null && d.views >= 0)
        ('Plays', fmtCompact(d.views)),
      if (d != null && d.likes > 0) ('Likes', fmtCompact(d.likes)),
      if (d != null && d.uploadDate.isNotEmpty)
        ('Released', d.uploadDate),
      if (d != null && d.durationSec > 0) ...[
        (
          'Duration',
          '${(d.durationSec ~/ 60)}:${(d.durationSec % 60).toString().padLeft(2, '0')}'
        ),
      ],
      ('Source', 'YouTube'),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('About this song',
                style: TextStyle(
                    color: glassSubtext(true),
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            for (final (k, v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                        width: 84,
                        child: Text(k,
                            style: TextStyle(
                                color: glassSubtext(true),
                                fontSize: 12))),
                    Expanded(
                      child: Text(v,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                              color: glassText(true),
                              fontSize: 12)),
                    ),
                  ],
                ),
              ),
            if (d != null && d.description.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                d.description.trimLeft(),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: glassSubtext(true),
                    fontSize: 12,
                    height: 1.4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> openArtistPage(BuildContext context, YtTrack track) async {
  AppState state;
  try {
    state = AppScope.of(context);
  } catch (_) {
    return;
  }
  final name = track.displayArtist();
  if (name == 'Unknown Artist' || name.trim().isEmpty) return;
  // Thumb resolves best-effort: the page opens even when the channel
  // lookup throws/offlines. Previously the searchArtists await shared
  // one try with the push, so any lookup failure swallowed the whole
  // navigation and the tap looked dead.
  var thumb = track.thumbUrl;
  try {
    final hits = await state.repo.searchArtists(name, max: 1);
    if (hits.isNotEmpty && hits.first.thumbUrl.isNotEmpty) {
      thumb = hits.first.thumbUrl;
    }
  } catch (_) {}
  if (!context.mounted) return;
  try {
    await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => ArtistPage(name: name, thumb: thumb)));
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
  List<YtTrack> videos = [];
  bool loading = true;
  bool _radioBusy = false;

  /// Load generation token (U4): the post-frame fetch resolving after
  /// dispose must never call setState.
  int _loadGen = 0;

  @override
  void initState() {
    super.initState();
    // AppScope is an InheritedWidget: of(context) inside initState throws
    // (dependOnInheritedWidget during init), which the old try/catch
    // turned into an instant empty page. Load post-frame instead.
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _loadGen++; // invalidate the in-flight fetch
    super.dispose();
  }

  /// Tolerant artist match: exact displayArtist equality almost never
  /// holds (topic suffixes, "Artist - Title" splits, label uploaders
  /// resolving to "Unknown Artist"), so the old == filter emptied every
  /// page. Key equality, containment, then token overlap win.
  static bool _matches(String display, String want) {
    try {
      final d = artistKeyOf(display);
      final w = artistKeyOf(want);
      if (d.isEmpty ||
          w.isEmpty ||
          d == 'unknown artist' ||
          w == 'unknown artist') {
        return false;
      }
      if (d == w) return true;
      if (d.contains(w) || w.contains(d)) return true;
      final dt = artistTokensOf(display);
      final wt = artistTokensOf(want);
      return wt.isNotEmpty && wt.any(dt.contains);
    } catch (_) {
      return false;
    }
  }

  /// Two honest legs, fanned out concurrently (each repo-bounded, never
  /// throws): top songs via song search + music videos via video search.
  /// No artist-browse/album/about endpoint exists in the repo
  /// (parseSearch drops album/artist cards by design; searchArtists
  /// carries no subs/bio), so those YTM sections are skipped, never
  /// faked — see build().
  Future<void> _load() async {
    final gen = _loadGen;
    AppState state;
    try {
      state = AppScope.of(context);
    } catch (_) {
      if (mounted && gen == _loadGen) {
        setState(() => loading = false);
      }
      return;
    }
    try {
      final want = widget.name;
      final results = await Future.wait([
        state.repo.searchMusic('$want songs', max: 20),
        state.repo.searchVideos('$want music video', max: 10),
      ]);
      if (!mounted || gen != _loadGen) return;
      final hits = results[0]
          .where((t) => t.id.length == 11 && t.title.trim().isNotEmpty)
          .toList();
      final mine =
          hits.where((t) => _matches(t.displayArtist(), want)).toList();
      // Songs-only rows: same gate the rest of the app plays through.
      List<YtTrack> cleanTop;
      try {
        cleanTop = songsOnlyTracks(mine.isNotEmpty ? mine : hits);
      } catch (_) {
        cleanTop = mine.isNotEmpty ? mine : hits;
      }
      final vids = results[1]
          .where((t) => t.id.length == 11 && t.title.trim().isNotEmpty)
          .toList();
      setState(() {
        // Never blank when upstream returned songs: when the tolerant
        // filter still finds nothing, paint the hits themselves.
        songs = cleanTop.isNotEmpty
            ? cleanTop
            : (mine.isNotEmpty ? mine : hits);
        videos = vids;
        loading = false;
      });
    } catch (_) {
      if (mounted && gen == _loadGen) {
        setState(() => loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final bg = scheme.surface;
    final fav = state.library.liked
        .any((t) => t.displayArtist() == widget.name);
    return Scaffold(
      appBar: AppBar(title: Text(widget.name), actions: [
        SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
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
        ),
      ]),
      body: loading && songs.isEmpty && videos.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : songs.isEmpty && videos.isEmpty
              // Honest empty state (theme-derived colors): the old code
              // rendered a blank ListView here, which read as broken.
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.music_off_outlined,
                            size: 56,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant),
                        const SizedBox(height: 12),
                        Text(
                            'No songs found for ${widget.name}',
                            textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                )
              // YTM artist shape: header art + name + stats line,
              // Shuffle + Radio, ranked Top songs, Videos rail.
              // Skipped with reason (no endpoint, never faked):
              // - subscriber/monthly-listener counts (searchArtists
              //   carries no subs; YtArtist.subs is always ''),
              // - Albums/Singles rails (no artist browse; parseSearch
              //   drops album cards by design; playlistTracks needs VL
              //   ids search never returns),
              // - About/bio (no channel-about/description endpoint).
              : AnimatedSwitcher(
                  duration: Duration(
                      milliseconds: state.motionMs(titleSlideMs)),
                  child: CustomScrollView(
                    key: const ValueKey('artist-body'),
                    slivers: [
                      // Header: big art + name + honest count line.
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(
                              24, 20, 24, 4),
                          child: Column(
                            children: [
                              _ArtistHeaderArt(thumb: widget.thumb),
                              const SizedBox(height: 12),
                              AdaptiveText(
                                data: widget.name,
                                background: bg,
                                align: TextAlign.center,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall
                                    ?.copyWith(
                                        fontWeight:
                                            FontWeight.w700),
                              ),
                              const SizedBox(height: 4),
                              AdaptiveText(
                                data: songs.isEmpty
                                    ? 'Artist'
                                    : 'Artist • ${songs.length} top songs',
                                background: bg,
                                secondary: true,
                                align: TextAlign.center,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium,
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Shuffle (shuffled top songs) + Radio (artist
                      // radio via the existing state API). 48px targets.
                      if (songs.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(
                                24, 16, 24, 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 48,
                                    child: FilledButton.icon(
                                      style:
                                          spotifyPlayStyle(),
                                      icon: const Icon(
                                          Icons.shuffle),
                                      label:
                                          const Text('Shuffle'),
                                      onPressed: () {
                                        final order =
                                            List<int>.generate(
                                                songs.length,
                                                (i) => i)
                                              ..shuffle();
                                        state.actPlay(
                                            [
                                              for (final i
                                                  in order)
                                                songs[i]
                                            ],
                                            0,
                                            origin: 'Artist');
                                      },
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: SizedBox(
                                    height: 48,
                                    child:
                                        OutlinedButton.icon(
                                      icon: _radioBusy
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child:
                                                  CircularProgressIndicator(
                                                      strokeWidth:
                                                          2),
                                            )
                                          : const Icon(Icons
                                              .radio),
                                      label:
                                          const Text('Radio'),
                                      onPressed: _radioBusy
                                          ? null
                                          : () async {
                                              if (mounted) {
                                                setState(() =>
                                                    _radioBusy =
                                                        true);
                                              }
                                              try {
                                                await state
                                                    .startRadio(
                                                        songs.first);
                                              } catch (_) {}
                                              if (mounted) {
                                                setState(() =>
                                                    _radioBusy =
                                                        false);
                                              }
                                            },
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // Top songs: ranked rows, tap-to-play, songs-only.
                      if (songs.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(
                                    24, 20, 24, 4),
                            child: AdaptiveText(
                              data: 'Top songs',
                              background: bg,
                              maxLines: 1,
                              overflow:
                                  TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(
                                      fontWeight:
                                          FontWeight.w700),
                            ),
                          ),
                        ),
                        SliverList.builder(
                          itemCount: songs.length,
                          itemBuilder: (_, i) => Row(
                            crossAxisAlignment:
                                CrossAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 52,
                                child: Center(
                                  child: AdaptiveText(
                                    data: '${i + 1}',
                                    background: bg,
                                    secondary: true,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                            fontWeight:
                                                FontWeight
                                                    .w600),
                                  ),
                                ),
                              ),
                              Expanded(
                                child: TrackRow(
                                    track: songs[i],
                                    contextQueue: songs,
                                    index: i,
                                    origin: 'Artist'),
                              ),
                            ],
                          ),
                        ),
                      ],
                      // Videos rail: cards open in-sheet video mode
                      // (same actPlay + openPlayerSheet(video:true)
                      // pattern as the trending rows).
                      if (videos.isNotEmpty) ...[
                        SliverToBoxAdapter(
                          child: Padding(
                            padding:
                                const EdgeInsets.fromLTRB(
                                    24, 20, 24, 8),
                            child: AdaptiveText(
                              data: 'Videos',
                              background: bg,
                              maxLines: 1,
                              overflow:
                                  TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(
                                      fontWeight:
                                          FontWeight.w700),
                            ),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: 188,
                            child: ListView.builder(
                              scrollDirection:
                                  Axis.horizontal,
                              padding:
                                  const EdgeInsets.symmetric(
                                      horizontal: 24),
                              itemCount: videos.length,
                              itemBuilder: (_, i) {
                                final v = videos[i];
                                return _ArtistVideoCard(
                                    track: v,
                                    queue: videos,
                                    index: i);
                              },
                            ),
                          ),
                        ),
                      ],
                      const SliverToBoxAdapter(
                        child: SizedBox(height: 32),
                      ),
                    ],
                  ),
                ),
    );
  }
}

/// Artist header art: 168px circle, cached channel thumb with a
/// theme-derived fallback (never a broken-image box).
class _ArtistHeaderArt extends StatelessWidget {
  final String thumb;
  const _ArtistHeaderArt({required this.thumb});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 168,
      height: 168,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: scheme.surfaceContainerHighest,
      ),
      child: ClipOval(
        child: thumb.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: sharpThumb(thumb),
                fit: BoxFit.cover,
                width: 168,
                height: 168,
                errorWidget: (_, _, _) => Icon(
                    Icons.person,
                    size: 72,
                    color: scheme.onSurfaceVariant),
              )
            : Icon(Icons.person,
                size: 72, color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// Videos-rail card (160px art + title/artist): tap plays the video
/// queue from here and opens the player sheet with video in the art
/// slot — the in-sheet video entry stays one trivial hop away.
class _ArtistVideoCard extends StatelessWidget {
  final YtTrack track;
  final List<YtTrack> queue;
  final int index;
  const _ArtistVideoCard(
      {required this.track, required this.queue, required this.index});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: track.title,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          try {
            state.actPlay(queue, index, origin: 'Artist videos');
            openPlayerSheet(context, video: true);
          } catch (_) {}
        },
        child: Container(
          width: 160,
          margin: const EdgeInsets.only(right: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: TrackArt(track: track, size: 160),
              ),
              const SizedBox(height: 6),
              AdaptiveText(
                  data: track.title,
                  background: scheme.surface,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              AdaptiveText(
                  data: track.displayArtist(),
                  background: scheme.surface,
                  secondary: true,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
