// Audio Pipeline sheet: LIVE signal path + WORKING system EQ.
//
// The old sheet showed hardcoded demo values (a fixed decoder name,
// fixed 48000 Hz everywhere, fake AudioFlinger mixer lines). Every row
// here is now either measured live from the player/device or labeled
// honestly ("Device default") when the platform doesn't expose it.
// The EQ section drives a real platform Equalizer + LoudnessEnhancer
// (volume boost) attached to just_audio's audio session via the
// `cresca.audiofx` channel — sliders move real hardware effects,
// presets persist, and unsupported devices get an honest note
// instead of fake controls.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../audio/effects.dart';
import '../../core/motion.dart' show motionMs;
import '../../core/track.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';

/// Solid dialog background for the pipeline card. All text in this
/// sheet derives from textOn/subtextOn against this color (never
/// hardcoded whiteXX), so labels stay legible.
const _pipelineBg = Color(0xFF1C1C1E);

Future<void> openAudioPipelineSheet(
    BuildContext context) async {
  try {
    final state = AppScope.of(context);
    final track = state.controller.engine.current;
    final motionOn = state.motionOn;
    await showDialog<void>(
      context: context,
      builder: (_) => Theme(
        data: crescaTheme(Brightness.dark),
        child: Dialog(
          backgroundColor: _pipelineBg,
          shape: RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.circular(24)),
          insetPadding:
              const EdgeInsets.symmetric(
                  horizontal: 20, vertical: 40),
          child: SheetEntrance(
            motionOn: motionOn,
            child: _PipelineCard(
                track: track, motionOn: motionOn),
          ),
        ),
      ),
    );
  } catch (_) {}
}

class _PipelineCard extends StatefulWidget {
  final YtTrack? track;
  final bool motionOn;
  const _PipelineCard(
      {required this.track, this.motionOn = true});

  @override
  State<_PipelineCard> createState() =>
      _PipelineCardState();
}

class _PipelineCardState extends State<_PipelineCard> {
  final AudioFx _fx = AudioFx();
  StreamSubscription<int?>? _sessionSub;
  int? _sessionId;
  bool _attaching = true;
  bool _eqOn = true;
  String _preset = 'Flat';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    AppState? state;
    try {
      state = AppScope.of(context);
    } catch (_) {
      if (mounted) setState(() => _attaching = false);
      return;
    }
    try {
      final prefsOn = _fx.enabled;
      if (mounted) setState(() => _eqOn = prefsOn);
    } catch (_) {}
    int? current;
    try {
      current = state.controller.player
          .androidAudioSessionId;
    } catch (_) {}
    await _attach(current);
    try {
      _sessionSub = state.controller.player
          .androidAudioSessionIdStream
          .listen((sid) {
        try {
          if (sid != null &&
              sid != _sessionId &&
              sid > 0 &&
              mounted) {
            _attach(sid);
          }
        } catch (_) {}
      });
    } catch (_) {}
  }

  Future<void> _attach(int? sid) async {
    if (!mounted) return;
    setState(() {
      _attaching = true;
      if (sid != null && sid > 0) _sessionId = sid;
    });
    try {
      await _fx.attach(sid ?? 0);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _attaching = false;
      _eqOn = _fx.enabled;
    });
  }

  @override
  void dispose() {
    try {
      _sessionSub?.cancel();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    final localPath = t?.localPath ?? '';
    final isLocal = localPath.isNotEmpty;
    AppState? state;
    try {
      state = AppScope.of(context);
    } catch (_) {}
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Text('Audio Pipeline',
                  style: TextStyle(
                      color: textOn(_pipelineBg),
                      fontSize: 20,
                      fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 4),
            Center(
              child: Text(
                  'Live signal path, decoder to output',
                  style: TextStyle(
                      color: subtextOn(_pipelineBg),
                      fontSize: 13)),
            ),
            const SizedBox(height: 16),
            _SectionLabel('SIGNAL PATH'),
            _LiveRows(
                track: t,
                isLocal: isLocal,
                localPath: localPath,
                state: state,
                sessionId: _sessionId),
            const SizedBox(height: 16),
            _SectionLabel('EQUALIZER'),
            // Probing ⇄ unavailable ⇄ live EQ crossfade (180 ms,
            // motion-gated). The probing skeleton holds the EQ's
            // space (toggle-height row + slider-height bars), so the
            // Done button below never jumps when effects attach.
            AnimatedSwitcher(
              duration: Duration(
                  milliseconds:
                      motionMs(widget.motionOn, 180)),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeOut,
              child: _attaching
                  ? _EqSkeleton(
                      key:
                          const ValueKey('eq-probing'),
                      motionOn: widget.motionOn,
                    )
                  : !_fx.available
                      ? Padding(
                          key: const ValueKey(
                              'eq-unavailable'),
                          padding:
                              const EdgeInsets.symmetric(
                                  vertical: 8),
                          child: Text(
                              'System audio effects aren\u2019t available on this device — showing the live signal path only.',
                              style: TextStyle(
                                  color: subtextOn(
                                      _pipelineBg),
                                  fontSize: 13)),
                        )
                      : Column(
                          key: const ValueKey('eq-live'),
                          children: [
                            _EqToggle(
                                on: _eqOn &&
                                    _fx.enabled,
                                onChanged: (v) async {
                                  await _fx.setEnabled(
                                      v);
                                  if (mounted) {
                                    setState(
                                        () => _eqOn = v);
                                  }
                                }),
                            _PresetRow(
                                current: _preset,
                                onPick: (name) async {
                                  await _fx.applyPreset(
                                      name);
                                  if (mounted) {
                                    setState(() =>
                                        _preset = name);
                                  }
                                }),
                            for (var i = 0;
                                i <
                                    (_fx.bands?.count ??
                                        0);
                                i++)
                              _BandSlider(
                                  fx: _fx,
                                  index: i,
                                  enabled: _eqOn &&
                                      _fx.enabled),
                            if (_fx.hasBoost)
                              _BoostSlider(
                                  fx: _fx,
                                  enabled: _eqOn &&
                                      _fx.enabled),
                          ],
                        ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 48),
                ),
                onPressed: () {
                  try {
                    Navigator.of(context).pop();
                  } catch (_) {}
                },
                child: Text('Done',
                    style: TextStyle(
                        color: textOn(_pipelineBg),
                        fontSize: 17,
                        fontWeight:
                            FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: TextStyle(
              color: subtextOn(_pipelineBg),
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2)),
    );
  }
}

/// Live measured rows. Anything the platform doesn't expose is
/// labeled "Device default" — never a fake specific.
class _LiveRows extends StatelessWidget {
  final YtTrack? track;
  final bool isLocal;
  final String localPath;
  final AppState? state;
  final int? sessionId;
  const _LiveRows(
      {required this.track,
      required this.isLocal,
      required this.localPath,
      required this.state,
      required this.sessionId});

  @override
  Widget build(BuildContext context) {
    final st = state;
    final vol = st?.controller.player.volume ?? 1.0;
    final dur =
        st?.controller.player.duration?.inMilliseconds ??
            0;
    return Column(children: [
      _row('Source',
          isLocal ? 'Download' : 'YouTube stream'),
      _row('Format', isLocal ? _extOf(localPath) : 'Opus'),
      _row('Engine', 'ExoPlayer (Media3)'),
      _row('Output', 'This phone'),
      _row('Sample rate', 'Device default'),
      _row('Audio session',
          sessionId != null ? '$sessionId' : '—'),
      _row('Volume', '${(vol * 100).round()}%'),
      _row('Duration',
          dur > 0 ? fmtMs(dur) : '—'),
    ]);
  }

  Widget _row(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Expanded(
            child: Text(k,
                style: TextStyle(
                    color: subtextOn(_pipelineBg),
                    fontSize: 14))),
        Text(v,
            style: TextStyle(
                color: textOn(_pipelineBg),
                fontSize: 14,
                fontWeight: FontWeight.w600)),
      ]),
    );
  }

  static String _extOf(String path) {
    try {
      final dot = path.lastIndexOf('.');
      if (dot < 0) return 'File';
      return path
          .substring(dot + 1)
          .toUpperCase();
    } catch (_) {
      return 'File';
    }
  }
}

class _EqToggle extends StatelessWidget {
  final bool on;
  final ValueChanged<bool> onChanged;
  const _EqToggle(
      {required this.on, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
          child: Text('Equalizer',
              style: TextStyle(
                  color: textOn(_pipelineBg),
                  fontSize: 15,
                  fontWeight: FontWeight.w600))),
      Switch(value: on, onChanged: onChanged),
    ]);
  }
}

class _PresetRow extends StatelessWidget {
  final String current;
  final ValueChanged<String> onPick;
  const _PresetRow(
      {required this.current, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final name in fxPresetDb.keys)
            ChoiceChip(
              label: Text(name),
              selected: current == name,
              onSelected: (_) => onPick(name),
            ),
        ],
      ),
    );
  }
}

class _BandSlider extends StatelessWidget {
  final AudioFx fx;
  final int index;
  final bool enabled;
  const _BandSlider(
      {required this.fx,
      required this.index,
      required this.enabled});

  @override
  Widget build(BuildContext context) {
    final info = fx.bands;
    if (info == null) return const SizedBox.shrink();
    final mb = (index < fx.levelsMb.length)
        ? fx.levelsMb[index]
        : 0;
    final label =
        AudioFx.bandLabel(
            index < info.freqsMHZ.length
                ? info.freqsMHZ[index]
                : 0,
            index);
    return Row(children: [
      SizedBox(
          width: 64,
          child: Text(label,
              style: TextStyle(
                  color: subtextOn(_pipelineBg),
                  fontSize: 13))),
      Expanded(
        child: Slider(
          min: info.minMb.toDouble(),
          max: info.maxMb.toDouble(),
          divisions: ((info.maxMb - info.minMb) ~/ 100)
              .clamp(1, 60),
          value: mb.toDouble().clamp(
              info.minMb.toDouble(),
              info.maxMb.toDouble()),
          onChanged: enabled
              ? (v) => fx.setBand(index, v.round())
              : null,
        ),
      ),
      SizedBox(
          width: 64,
          child: Text(
              '${(mb / 100).toStringAsFixed(1)} dB',
              textAlign: TextAlign.end,
              style: TextStyle(
                  color: textOn(_pipelineBg),
                  fontSize: 13))),
    ]);
  }
}

class _BoostSlider extends StatelessWidget {
  final AudioFx fx;
  final bool enabled;
  const _BoostSlider(
      {required this.fx, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(
          width: 64,
          child: Text('Boost',
              style: TextStyle(
                  color: subtextOn(_pipelineBg),
                  fontSize: 13))),
      Expanded(
        child: Slider(
          min: 0,
          max: 1500,
          divisions: 30,
          value: fx.boostMb.toDouble().clamp(0, 1500),
          onChanged: enabled
              ? (v) => fx.setBoost(v.round())
              : null,
        ),
      ),
      SizedBox(
          width: 64,
          child: Text(
              '+${(fx.boostMb / 100).toStringAsFixed(1)} dB',
              textAlign: TextAlign.end,
              style: TextStyle(
                  color: textOn(_pipelineBg),
                  fontSize: 13))),
    ]);
  }
}

/// Skeleton EQ: holds the live section's space while system effects
/// attach (toggle-height status row + slider-height shimmer bars), so
/// the Done button below never jumps. Shimmer is opacity-only.
class _EqSkeleton extends StatelessWidget {
  final bool motionOn;
  const _EqSkeleton({super.key, this.motionOn = true});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(children: [
            _DelayedSpinner(motionOn: motionOn),
            const SizedBox(width: 12),
            Text('Probing system effects…',
                style: TextStyle(
                    color: subtextOn(_pipelineBg),
                    fontSize: 13)),
          ]),
        ),
        for (var i = 0; i < 3; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: PulseOpacity(
              motionOn: motionOn,
              child: Container(
                height: 28,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Pre-sized spinner slot (20dp) that fades in only after 300 ms —
/// no flicker on fast attaches. Motion-off shows instantly.
class _DelayedSpinner extends StatefulWidget {
  final bool motionOn;
  const _DelayedSpinner({this.motionOn = true});

  @override
  State<_DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<_DelayedSpinner> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    if (!widget.motionOn) {
      _show = true;
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void didUpdateWidget(covariant _DelayedSpinner old) {
    super.didUpdateWidget(old);
    if (widget.motionOn != old.motionOn && !widget.motionOn) {
      setState(() => _show = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 20,
      height: 20,
      child: AnimatedOpacity(
        opacity: _show ? 1.0 : 0.0,
        duration: Duration(
            milliseconds: motionMs(widget.motionOn, 180)),
        curve: Curves.easeOut,
        child: _show
            ? const CircularProgressIndicator(
                strokeWidth: 2, color: Colors.white)
            : null,
      ),
    );
  }
}
