// JAM room sheet (Phase 4 UI): join form → gradient room card with QR
// (cresca://jam/CODE), code + share, members, guest-allow toggle,
// room queue, leave/end. Deep-link + auto-join (F2/F9). Errors surface
// as text (N5) — never a silent dead tap.

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/motion.dart' show motionMs;
import '../../jam/protocol.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';
import 'cresca_toast.dart';

Future<void> openJamSheet(BuildContext context) async {
  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.82,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scroll) => JamSheet(scroll: scroll),
      ),
    );
  } catch (e, st) {
    await logUserFailure(context, 'open JAM failed', e, st);
    await showCrescaToast(context, 'Could not open JAM — Retry');
  }
}

class JamSheet extends StatelessWidget {
  final ScrollController scroll;
  const JamSheet({super.key, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    // Pinned header needs an opaque backing: the sheet glass is
    // translucent at the top, so scrolled rows would ghost through
    // the title. surfaceContainer at 0.94 reads as the same
    // material fading to opaque (no solid-fill chrome elsewhere).
    final headerBg = Theme.of(context)
        .colorScheme
        .surfaceContainer
        .withValues(alpha: 0.94);
    final dark =
        Theme.of(context).brightness == Brightness.dark;
    return AnimatedBuilder(
      animation: state.jam,
      builder: (_, _) => GlassSheetSurface(
        motionOn: state.motionOn,
        child: CustomScrollView(
          controller: scroll,
          slivers: [
            SliverToBoxAdapter(
              child: Center(
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Theme.of(context)
                        .colorScheme
                        .onSurfaceVariant
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            SliverAppBar(
              pinned: true,
              backgroundColor: headerBg,
              automaticallyImplyLeading: false,
              title: Text('Listen together',
                  style:
                      TextStyle(color: glassText(dark))),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                child: _Body(state: state, scroll: scroll),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final AppState state;
  final ScrollController scroll;
  const _Body({required this.state, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final jam = state.jam;
    final connected = jam.connected;
    // Section switch: join ⇄ room crossfades + slides (180 ms,
    // transform/opacity only).
    final ms = state.motionMs(180);
    final d = Duration(milliseconds: ms);
    return AnimatedSwitcher(
      duration: d,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeOut,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween(
            begin: const Offset(0, 0.06),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: connected
          ? _RoomCard(
              key: const ValueKey('room'),
              state: state,
              scroll: scroll)
          : _JoinForm(
              key: const ValueKey('join'), state: state),
    );
  }
}

class _JoinForm extends StatefulWidget {
  final AppState state;
  const _JoinForm({super.key, required this.state});

  @override
  State<_JoinForm> createState() => _JoinFormState();
}

class _JoinFormState extends State<_JoinForm> {
  late final TextEditingController _name;
  late final TextEditingController _code;
  bool _busy = false;
  bool _showJoin = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(
        text: widget.state.jamName.isNotEmpty
            ? widget.state.jamName
            : 'Guest-${1000 + (DateTime.now().millisecondsSinceEpoch % 9000)}');
    _code = TextEditingController(
        text: widget.state.jam.pendingCode); // deep-link prefill (F2)
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _go({required bool host}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.state.jamSetName(_name.text.trim());
      if (host) {
        await widget.state.jamCreate();
      } else {
        await widget.state.jamJoin(_code.text.trim());
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final jam = widget.state.jam;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final canCreate =
        !_busy && _name.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        // Reference header: centered title + subtitle. Title carries an
        // explicit glassText color (never an ambient const style) so it
        // stays legible on the translucent sheet in both modes.
        Text('Start a party',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: glassText(dark),
                fontSize: 28,
                fontWeight: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(
            'Because music sounds better together. Invite friends to listen and add songs in real time, wherever they are.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurfaceVariant,
                fontSize: 14,
                height: 1.4)),
        const SizedBox(height: 20),
        TextField(
          controller: _name,
          maxLength: 24,
          onChanged: (_) {
            try {
              setState(() {});
            } catch (_) {
              // silent: rebuild nudge only, next keystroke rebuilds
            }
          },
          decoration: const InputDecoration(
              labelText: 'Your name',
              border: OutlineInputBorder()),
        ),
        const SizedBox(height: 8),
        FilledButton(
          style: spotifyPlayStyle(),
          onPressed:
              canCreate ? () => _go(host: true) : null,
          child: _busy
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _DelayedSpinner(size: 20, strokeWidth: 2),
                    SizedBox(width: 10),
                    Text('Creating…',
                        style: TextStyle(
                            fontWeight: FontWeight.w700)),
                  ],
                )
              : const Text('Create a party',
                  style: TextStyle(
                      fontWeight: FontWeight.w700)),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(
                  () => _showJoin = !_showJoin),
          child: const Text('Join existing'),
        ),
        if (_showJoin)
          FadeSlide(
            key: const ValueKey('join-fields'),
            motionOn: widget.state.motionOn,
            child: Column(
              crossAxisAlignment:
                  CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 4),
                TextField(
                  controller: _code,
                  maxLength: 6,
                  textCapitalization:
                      TextCapitalization.characters,
                  decoration: InputDecoration(
                    labelText: 'JAM code',
                    hintText: hostRoomFormatHint,
                    border:
                        const OutlineInputBorder(),
                    suffixIcon: const Icon(
                        Icons.dialpad_outlined),
                    errorText:
                        _code.text.isNotEmpty &&
                                !jamValidCode(
                                    _code.text)
                            ? '6 letters, no 0/O/1/I'
                            : null,
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(
                      Icons.join_inner_outlined),
                  label:
                      const Text('Join with code'),
                  onPressed: _busy
                      ? null
                      : () => _go(host: false),
                ),
              ],
            ),
          ),
        const SizedBox(height: 8),
        if (jam.pendingCode.isNotEmpty && !_busy)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Deep link ready — tap Join to enter '
                '${jam.pendingCode}',
                style: Theme.of(context).textTheme.bodySmall),
          ),
        if (jam.statusLine.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(jam.statusLine,
                style: Theme.of(context).textTheme.bodySmall),
          ),
      ],
    );
  }
}

const String hostRoomFormatHint = '6 letters';

class _RoomCard extends StatelessWidget {
  final AppState state;
  final ScrollController scroll;
  const _RoomCard(
      {super.key, required this.state, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final jam = state.jam;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // Room card stays neutral glass: green is reserved for actions
    // (Create/Join buttons), so the card uses the adaptive surface
    // ramp with matching legible text in both modes.
    final cardTop =
        dark ? const Color(0xFF333336) : Colors.white;
    final cardBottom = dark
        ? const Color(0xFF1C1C1E)
        : const Color(0xFFE9E9EC);
    // Room text verified against the card's mid-gradient tone: textOn
    // picks the higher-contrast black/white, subtextOn the legible
    // secondary (falling back to primary below 4.5:1) — no hardcoded
    // white70/black54 that would wash out in either mode.
    final cardBg =
        Color.lerp(cardTop, cardBottom, 0.5) ?? cardTop;
    final onCard = textOn(cardBg);
    final subCard = subtextOn(cardBg);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: LinearGradient(colors: [
              cardTop,
              cardBottom,
            ]),
            border: Border.all(
              color: dark
                  ? Colors.white.withValues(alpha: 0.14)
                  : Colors.black.withValues(alpha: 0.10),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: QrImageView(
                  data: 'cresca://jam/${jam.code}',
                  size: 96,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(jam.isHost ? 'You are the host'
                        : 'Guest of the room',
                        style: TextStyle(
                            color: subCard,
                            fontSize: 12)),
                    Text(jam.code,
                        style: TextStyle(
                            color: onCard,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 3)),
                    Text(
                        '${jam.membersCount} member'
                        '${jam.membersCount == 1 ? '' : 's'}'
                        ' • ${_stateLine(state)}',
                        style: TextStyle(
                            color: subCard)),
                  ],
                ),
              ),
              Column(children: [
                IconButton(
                  tooltip: 'Share',
                  icon: Icon(Icons.share_outlined,
                      color: onCard),
                  onPressed: () => _share(context, jam.code),
                ),
                const SizedBox(height: 4),
                // Toggle track tints smoothly (AnimatedContainer,
                // transform/opacity-class property animation).
                AnimatedContainer(
                  duration: Duration(
                      milliseconds:
                          state.motionMs(180)),
                  curve: Curves.easeOut,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: jam.guestAllowed
                        ? Theme.of(context)
                            .colorScheme
                            .primary
                            .withValues(alpha: 0.30)
                        : Colors.black
                            .withValues(alpha: 0.25),
                    borderRadius:
                        BorderRadius.circular(16),
                  ),
                  child: Switch(
                    value: jam.guestAllowed,
                    activeThumbColor: dark
                        ? Colors.white
                        : Colors.black,
                    onChanged: jam.isHost
                        ? (v) =>
                            state.jamSetGuestAllowed(v)
                        : null,
                  ),
                ),
                Text('Guests control',
                    style: TextStyle(
                        color: subCard,
                        fontSize: 10)),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 10),
        // Members empty ⇄ chips crossfade (180 ms, motion-gated) so
        // the first join never pops the layout.
        AnimatedSwitcher(
          duration: Duration(
              milliseconds: motionMs(state.motionOn, 180)),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeOut,
          child: jam.members.isEmpty
              ? Padding(
                  key: const ValueKey('jam-no-members'),
                  padding:
                      const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                      'No members yet — share the code to invite.',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall),
                )
              : Wrap(
                  key: const ValueKey('jam-members'),
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in jam.members)
                      RepaintBoundary(
                        child: Chip(
                          avatar: Icon(
                              m.host
                                  ? Icons.star
                                  : Icons.person_outline,
                              size: 18,
                              color: glassText(dark)),
                          label: Text(m.name +
                              (m.host ? ' (host)' : '')),
                        ),
                      ),
                  ],
                ),
        ),
        if (jam.statusLine.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(jam.statusLine,
                style: Theme.of(context).textTheme.bodySmall),
          ),
        const SizedBox(height: 8),
        Text('Queue',
            style: Theme.of(context).textTheme.titleSmall),
        Builder(builder: (context) {
          final q = state.jamQueueView();
          // Queue empty ⇄ rows crossfade (180 ms, motion-gated).
          return AnimatedSwitcher(
            duration: Duration(
                milliseconds:
                    motionMs(state.motionOn, 180)),
            switchInCurve: Curves.easeOut,
            switchOutCurve: Curves.easeOut,
            child: q.isEmpty
                ? Padding(
                    key: const ValueKey('jam-q-empty'),
                    padding:
                        const EdgeInsets.symmetric(
                            vertical: 8),
                    child: Text(
                        'Queue is empty — guests can add songs.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall),
                  )
                : Column(
                    key: const ValueKey('jam-q-list'),
                    children: [
                      for (final t in q)
                        RepaintBoundary(
                          child: ListTile(
                            dense: true,
                            contentPadding:
                                EdgeInsets.zero,
                            title: Text(t.title,
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis),
                            subtitle: Text(
                                t.displayArtist(),
                                maxLines: 1,
                                overflow:
                                    TextOverflow.ellipsis),
                            leading: const Icon(Icons
                                .music_note_outlined),
                          ),
                        ),
                    ],
                  ),
          );
        }),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.logout_outlined),
              label: const Text('Leave'),
              onPressed: () => state.jamLeave(),
            ),
          ),
          const SizedBox(width: 8),
          if (jam.isHost)
            Expanded(
              child: FilledButton.tonalIcon(
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('End room'),
                onPressed: () => state.jamEnd(),
              ),
            ),
        ]),
      ],
    );
  }

  String _stateLine(AppState state) {
    try {
      final n = state.jam.now;
      if (n == null) return 'waiting for the host…';
      return '${n.playing ? 'Playing' : 'Paused'} · ${n.track.title}';
    } catch (_) {
      // silent: status-line probe, empty line hides the row
      return '';
    }
  }

  Future<void> _share(BuildContext context, String code) async {
    try {
      await SharePlus.instance.share(ShareParams(
        text: 'Join my JAM on Cresca: $code\n'
            'cresca://jam/$code',
      ));
    } catch (e, st) {
      await logUserFailure(context, 'share JAM invite failed', e, st);
      if (context.mounted) {
        await showCrescaToast(
            context, "Couldn't share invite — try again");
      }
    }
  }
}

/// Spinner that reserves its slot from frame one (no size jump) and
/// fades in only after 300 ms (no flicker on fast loads). Motion-off
/// shows it immediately (1 ms via [motionMs]).
class _DelayedSpinner extends StatefulWidget {
  final double size;
  final double strokeWidth;
  const _DelayedSpinner({this.size = 20, this.strokeWidth = 2});

  @override
  State<_DelayedSpinner> createState() => _DelayedSpinnerState();
}

class _DelayedSpinnerState extends State<_DelayedSpinner> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    // Motion flag reads post-frame: dependOnInheritedWidget is illegal
    // in initState, so the delay starts once the scope is readable.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      bool on = true;
      try {
        on = AppScope.of(context).motionOn;
      } catch (_) {
        // silent: motion probe, animation default (on) is safe
      }
      if (!on) {
        setState(() => _show = true);
        return;
      }
      Future<void>.delayed(
          const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _show = true);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    bool on = true;
    try {
      on = AppScope.of(context).motionOn;
    } catch (_) {
      // silent: motion probe, animation default (on) is safe
    }
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedOpacity(
        opacity: _show ? 1.0 : 0.0,
        duration:
            Duration(milliseconds: motionMs(on, 180)),
        curve: Curves.easeOut,
        child: _show
            ? CircularProgressIndicator(
                strokeWidth: widget.strokeWidth)
            : null,
      ),
    );
  }
}
