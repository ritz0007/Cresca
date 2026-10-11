// Audio output sheet (reference parity): "Audio output" title,
// "This phone / Playing here" device card with check, volume slider
// card driving the player volume, "Audio Pipeline" card opening the
// live signal-path modal. Device switching isn't implemented — the
// sheet honestly reports the only output (no fake picker).

import 'dart:async';

import 'package:flutter/material.dart';

import '../../audio/system_volume.dart';
import '../app.dart';
import '../design.dart';
import 'audio_pipeline_sheet.dart';
import 'jam_sheet.dart';

Future<void> openAudioOutputSheet(BuildContext context) async {
  try {
    bool motionOn = true;
    try {
      motionOn = AppScope.of(context).motionOn;
    } catch (_) {}
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetCtx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.85,
        builder: (_, scroll) => Theme(
          data: crescaTheme(Brightness.dark),
          child: GlassSheetSurface(
            motionOn: motionOn,
            child: _AudioOutputSheet(scroll: scroll),
          ),
        ),
      ),
    );
  } catch (_) {}
}

class _AudioOutputSheet extends StatelessWidget {
  final ScrollController scroll;
  const _AudioOutputSheet({required this.scroll});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final on = state.motionOn;
    // Sheet forces the dark glass theme, so Theme.of here is always
    // dark — glassText/glassSubtext resolve to the AA-verified pair
    // (white / spotifySubtext) instead of hardcoded whiteXX values.
    final dark =
        Theme.of(context).brightness == Brightness.dark;
    // Cards stagger in (fade + 12 px slide, 40 ms steps, one-shot).
    // 120Hz polish: each card keeps its own boundary so the stagger
    // never repaints the static glass behind it.
    Widget stagger(Widget c, int i) => RepaintBoundary(
          child: FadeSlide(
          motionOn: on,
          delay:
              Duration(milliseconds: on ? 40 * i : 0),
          child: c,
          ),
        );
    return CustomScrollView(
      controller: scroll,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding:
                const EdgeInsets.fromLTRB(20, 10, 20, 24),
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.start,
              children: [
                // Drag handle: decoration-only fill over the dark
                // glass (AA-verified glassSubtext at 50%).
                Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: glassSubtext(dark)
                              .withValues(alpha: 0.5),
                          borderRadius:
                              BorderRadius.circular(
                                  2))),
                ),
                const SizedBox(height: 14),
                Text('Audio output',
                    style: TextStyle(
                        color: glassText(dark),
                        fontSize: 21,
                        fontWeight: FontWeight.w800)),
                const SizedBox(height: 14),
                // Device card (only output).
                stagger(
                  Container(
                    padding:
                        const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white
                        .withValues(alpha: 0.10),
                    borderRadius:
                        BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white
                              .withValues(alpha: 0.14),
                        ),
                        child: const Icon(
                            Icons
                                .smartphone_outlined,
                            color: Colors.white,
                            size: 24),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment:
                              CrossAxisAlignment.start,
                          children: [
                            Text('This phone',
                                style: TextStyle(
                                    color:
                                        glassText(dark),
                                    fontSize: 16,
                                    fontWeight:
                                        FontWeight.w700)),
                            Text('Playing here',
                                style: TextStyle(
                                    color: glassSubtext(
                                        dark),
                                    fontSize: 13)),
                          ],
                        ),
                      ),
                      const Icon(Icons.check,
                          color: Colors.white,
                          size: 22),
                    ],
                  ),
                  ),
                  0,
                ),
                const SizedBox(height: 10),
                // Volume card (system STREAM_MUSIC volume; same
                // slider/icons/layout, StreamBuilder on watch()).
                stagger(
                  _VolumeCard(dark: dark, motionOn: on),
                  1,
                ),
                const SizedBox(height: 10),
                // JAM entry (the ONLY JAM entry point: the player
                // output pill no longer carries a JAM segment).
                stagger(
                  PressScale(
                    motionOn: on,
                    onTap: () =>
                        openJamSheet(context),
                    child: Container(
                      padding:
                          const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white
                            .withValues(alpha: 0.10),
                        borderRadius:
                            BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(
                              Icons
                                  .people_outline,
                              color:
                                  glassSubtext(dark),
                              size: 24),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                Text('JAM',
                                    style: TextStyle(
                                        color: glassText(
                                            dark),
                                        fontSize: 16,
                                        fontWeight:
                                            FontWeight
                                                .w700)),
                                Text(
                                    'Listen together',
                                    style: TextStyle(
                                        color: glassSubtext(
                                            dark),
                                        fontSize: 13)),
                              ],
                            ),
                          ),
                          Icon(
                              Icons.chevron_right,
                              color: glassSubtext(dark),
                              size: 24),
                        ],
                      ),
                    ),
                  ),
                  2,
                ),
                const SizedBox(height: 10),
                // Audio pipeline card (press-scale tap feedback).
                stagger(
                  PressScale(
                    motionOn: on,
                    onTap: () =>
                        openAudioPipelineSheet(context),
                    child: Container(
                      padding:
                          const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white
                            .withValues(alpha: 0.10),
                        borderRadius:
                            BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Icon(
                              Icons
                                  .graphic_eq_outlined,
                              color:
                                  glassSubtext(dark),
                              size: 24),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment
                                      .start,
                              children: [
                                Text('Audio Pipeline',
                                    style: TextStyle(
                                        color: glassText(
                                            dark),
                                        fontSize: 16,
                                        fontWeight:
                                            FontWeight
                                                .w700)),
                                Text(
                                    '16-bit PCM · 48 kHz',
                                    style: TextStyle(
                                        color: glassSubtext(
                                            dark),
                                        fontSize: 13)),
                              ],
                            ),
                          ),
                          Icon(
                              Icons.chevron_right,
                              color: glassSubtext(dark),
                              size: 24),
                        ],
                      ),
                    ),
                  ),
                  3,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// System-volume card (same slider/icons/layout as before): the stream
/// emits the current level first, then hardware-button changes; drags
/// call setLevel. The audio-engine level is never reset here.
class _VolumeCard extends StatefulWidget {
  final bool dark;
  final bool motionOn;
  const _VolumeCard({required this.dark, this.motionOn = true});

  @override
  State<_VolumeCard> createState() => _VolumeCardState();
}

class _VolumeCardState extends State<_VolumeCard> {
  late final Stream<double> _stream = _sysVolume();

  static Stream<double> _sysVolume() async* {
    try {
      yield await SystemVolume.level();
    } catch (_) {
      yield 1.0;
    }
    yield* SystemVolume.watch();
  }

  @override
  Widget build(BuildContext context) {
    final dark = widget.dark;
    return Container(
      padding:
          const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white
            .withValues(alpha: 0.10),
        borderRadius:
            BorderRadius.circular(16),
      ),
      child: StreamBuilder<double>(
        stream: _stream,
        builder: (_, snap) {
          // Same widgets pre/post data (never a skeleton swap), so
          // the card never shifts size: while the system level loads,
          // the slider sits dimmed under an opacity-only shimmer,
          // then fades to full — no thumb jump from a 1.0 seed.
          final v = snap.data;
          final ready = v != null;
          final level = (v ?? 1.0).clamp(0.0, 1.0);
          return PulseOpacity(
            motionOn: widget.motionOn,
            pulsing: !ready,
            child: Opacity(
              opacity: ready ? 1.0 : 0.6,
              child: Row(
            children: [
              Icon(
                  Icons
                      .volume_up_outlined,
                  color: glassText(dark),
                  size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(
                          context)
                      .copyWith(
                    trackHeight: 4,
                    thumbShape:
                        const RoundSliderThumbShape(
                            enabledThumbRadius:
                                7),
                    overlayShape:
                        const RoundSliderOverlayShape(
                            overlayRadius:
                                14),
                    activeTrackColor:
                        Colors.white,
                    inactiveTrackColor: Colors
                        .white
                        .withValues(
                            alpha: 0.28),
                    thumbColor:
                        Colors.white,
                  ),
                  child: Slider(
                    value: level,
                    label:
                        'Volume ${(level * 100).round()}%',
                    onChanged: ready
                        ? (nv) {
                            try {
                              SystemVolume.setLevel(
                                  nv);
                            } catch (_) {}
                          }
                        : null,
                  ),
                ),
              ),
            ],
          ),
            ),
          );
        },
      ),
    );
  }
}
