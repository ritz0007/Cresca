// Radio tab (R2–R3): saved radio cards (150dp, like-heart overlay,
// N songs) + 6 static station gradients. Tap a station for an instant
// music-only mix; tap a card to resume its stored tracks.

import 'package:flutter/material.dart';

import '../app.dart';
import '../design.dart';
import '../radio_store.dart';
import '../widgets/state_widgets.dart';
import '../widgets/track_row.dart';

class RadioScreen extends StatelessWidget {
  const RadioScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state,
      builder: (_, _) {
        final radios = state.library.radios;
        // U6 de-nested: one CustomScrollView (no nested vertical lists).
        // The horizontal lane keeps its fixed height; the stations ride a
        // real SliverGrid. The feed is finite, so the footer is
        // unconditionally terminal — EndFooter still gates on
        // hasMore && !loading for future paged feeds (spinner only while
        // a station/radio load is in flight, "You're all caught up" after).
        return Scaffold(
          appBar: AppBar(title: const Text('Radio')),
          body: CustomScrollView(
            slivers: [
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                      'Your radios plus endless stations. Tap a radio to play it.'),
                ),
              ),
              if (radios.isNotEmpty) ...[
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: StaggerEntrance(
                      child: Text('Your radios',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
                // Lane enters once via the per-card stagger below
                // (capped at 8) — no outer entrance wrapper, so the
                // first cards never pay two opacity/transform pairs.
                SliverToBoxAdapter(
                  child: SizedBox(
                    key: ValueKey('radios-${radios.length}'),
                    height: 210,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16),
                      itemCount: radios.length,
                      // Keep lane items out of the list scope;
                      // the per-row boundary lives in _RadioCard.
                      addRepaintBoundaries: true,
                      itemBuilder: (_, i) => StaggerEntrance(
                        index: i,
                        child: _RadioCard(radio: radios[i]),
                      ),
                    ),
                  ),
                ),
              ],
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: StaggerEntrance(
                    index: 2,
                    child: Text('Stations',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverGrid(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 1.6,
                  ),
                  delegate: SliverChildBuilderDelegate(
                    (_, i) => StaggerEntrance(
                      index: i,
                      child:
                          _StationCard(station: radioStations[i]),
                    ),
                    childCount: radioStations.length,
                  ),
                ),
              ),
              SliverToBoxAdapter(
                // Bottom chrome is app-shell; live measured clearance
                // (estimator fallback) so the footer clears it.
                child: Padding(
                  padding: EdgeInsets.only(
                      bottom:
                          BottomChromeScope.clearanceOf(context)),
                  child: EndFooter(
                    hasMore: false,
                    loading: state.radioLoading,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RadioCard extends StatelessWidget {
  final SavedRadio radio;
  const _RadioCard({required this.radio});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    // RepaintBoundary: art + like-button rows rebuild on likes —
    // keep each card out of the lane's repaint scope.
    //
    // The heart is NOT inside the open-tap subtree: PressScale fires
    // onTapUp for any tap in its child (heart included), so a like
    // used to also open the radio. Art + titles open; the heart only
    // toggles.
    return RepaintBoundary(
      child: Container(
        width: 150,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                PressScale(
                motionOn: state.motionOn,
                onTap: () => state.openRadio(radio),
                child: Container(
                  height: 130,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: Colors.black,
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: radio.thumbUrl.isEmpty
                      ? Container(
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer,
                          child: Center(
                              child: Icon(Icons.music_note,
                                  size: 40,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onPrimaryContainer)),
                        )
                      : TrackArt(track: radio.seed, size: 130),
                ),
                ),
                Positioned(
                  right: 4,
                  top: 4,
                  child: IconButton(
                    tooltip: radio.liked
                        ? 'Remove from favorites'
                        : 'Add to favorites',
                    icon: Icon(
                      radio.liked
                          ? Icons.favorite
                          : Icons.favorite_border,
                      // White reads over real artwork; the
                      // empty-thumb placeholder is the light
                      // primaryContainer, so it needs the
                      // container's own on-color in light mode.
                      // Drop shadow keeps the glyph legible over
                      // light thumbs (shadow paint, not text color).
                      shadows: const [
                        Shadow(
                            color: Colors.black54,
                            blurRadius: 6,
                            offset: Offset(0, 1)),
                      ],
                      color: radio.liked
                          ? scheme.primary
                          : radio.thumbUrl.isEmpty
                              ? scheme.onPrimaryContainer
                              : Colors.white,
                    ),
                    onPressed: () =>
                        state.toggleRadioLike(radio.seed.id),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => state.openRadio(radio),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  AdaptiveText(
                      data: radio.title,
                      background: scheme.surface,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis),
                  AdaptiveText(
                      data: '${radio.tracks.length} songs',
                      background: scheme.surface,
                      secondary: true,
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StationCard extends StatelessWidget {
  final RadioStation station;
  const _StationCard({required this.station});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return RepaintBoundary(
      child: PressScale(
      motionOn: state.motionOn,
      onTap: () => state.startStation(station.query),
      // Station gradients have light stops (e.g. the
      // Romantic/Workout tops), so the label rides a bottom
      // scrim with colors derived from the dark scrim base —
      // legible over any gradient in both modes. The mood icon
      // sits in a theme-derived badge (surfaceContainerHighest bg
      // + primary glyph) so it stays legible in both modes.
      // Single scrim layer; tight 4px label shadow.
      child: Container(
        constraints:
            const BoxConstraints(minWidth: 48, minHeight: 48),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Color(station.top),
                      Color(station.bottom)
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
              ),
              Positioned(
                left: 12,
                top: 12,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _stationIcon(station),
                    color: scheme.primary,
                    size: 24,
                  ),
                ),
              ),
              TextScrim(
                scrim: const [
                  Color(0xB3000000),
                  Color(0x66000000),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.35, 0.8],
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                child: Align(
                  alignment: Alignment.bottomLeft,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: AdaptiveText(
                        data: station.label,
                        background: Colors.black,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            shadows: [
                              Shadow(
                                  color: Colors.black,
                                  blurRadius: 4)
                            ])),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// Music-appropriate Material icon per station kind/mood, matched on
/// label + query so new stations degrade to a music glyph.
IconData _stationIcon(RadioStation station) {
  try {
    final t =
        '${station.label} ${station.query}'.toLowerCase();
    if (t.contains('workout') ||
        t.contains('gym') ||
        t.contains('energy') ||
        t.contains('motivation')) {
      return Icons.fitness_center;
    }
    if (t.contains('party') || t.contains('dance')) {
      return Icons.celebration;
    }
    if (t.contains('lofi') || t.contains('chill')) {
      return Icons.headphones;
    }
    if (t.contains('romantic') ||
        t.contains('love') ||
        t.contains('arijit')) {
      return Icons.favorite;
    }
    if (t.contains('2000') ||
        t.contains('90s') ||
        t.contains('hits') ||
        t.contains('throwback') ||
        t.contains('evergreen')) {
      return Icons.album;
    }
  } catch (_) {}
  return Icons.music_note;
}

