// Radio tab (R2–R3): saved radio cards (150dp, like-heart overlay,
// N songs) + 6 static station gradients. Tap a station for an instant
// music-only mix; tap a card to resume its stored tracks.

import 'package:flutter/material.dart';

import '../app.dart';
import '../radio_store.dart';
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
        return Scaffold(
          appBar: AppBar(title: const Text('Radio')),
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 210),
                  children: [
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                          'Your radios plus endless stations. Tap a radio to play it.'),
                    ),
                    if (radios.isNotEmpty) ...[
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Text('Your radios',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold)),
                      ),
                      SizedBox(
                        height: 190,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16),
                          itemCount: radios.length,
                          itemBuilder: (_, i) =>
                              _RadioCard(radio: radios[i]),
                        ),
                      ),
                    ],
                    if (state.radioLoading)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(
                            child: CircularProgressIndicator()),
                      ),
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text('Stations',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                    ),
                    GridView.builder(
                      shrinkWrap: true,
                      physics:
                          const NeverScrollableScrollPhysics(),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1.6,
                      ),
                      itemCount: radioStations.length,
                      itemBuilder: (_, i) =>
                          _StationCard(station: radioStations[i]),
                    ),
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

class _RadioCard extends StatelessWidget {
  final SavedRadio radio;
  const _RadioCard({required this.radio});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return GestureDetector(
      onTap: () => state.openRadio(radio),
      child: Container(
        width: 150,
        margin: const EdgeInsets.only(right: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                Container(
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
                          child: const Center(
                              child: Icon(Icons.radio,
                                  size: 40)),
                        )
                      : TrackArt(track: radio.seed, size: 130),
                ),
                Positioned(
                  right: 4,
                  top: 4,
                  child: IconButton(
                    icon: Icon(
                      radio.liked
                          ? Icons.favorite
                          : Icons.favorite_border,
                      color: radio.liked
                          ? const Color(0xFF1DB954)
                          : Colors.white,
                    ),
                    onPressed: () =>
                        state.toggleRadioLike(radio.seed.id),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(radio.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            Text('${radio.tracks.length} songs',
                style: Theme.of(context).textTheme.bodySmall),
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
    return GestureDetector(
      onTap: () => state.startStation(station.query),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [
              Color(station.top),
              Color(station.bottom)
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: const EdgeInsets.all(12),
        alignment: Alignment.bottomLeft,
        child: Text(station.label,
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16)),
      ),
    );
  }
}

