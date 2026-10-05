// JAM room sheet (Phase 4 UI): join form → gradient room card with QR
// (cresca://jam/CODE), code + share, members, guest-allow toggle,
// room queue, leave/end. Deep-link + auto-join (F2/F9). Errors surface
// as text (N5) — never a silent dead tap.

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../jam/protocol.dart';
import '../app.dart';
import '../design.dart';
import '../state.dart';

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
  } catch (_) {}
}

class JamSheet extends StatelessWidget {
  final ScrollController scroll;
  const JamSheet({super.key, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return AnimatedBuilder(
      animation: state.jam,
      builder: (_, _) => GlassSheetSurface(
        child: CustomScrollView(
          controller: scroll,
          slivers: [
            SliverAppBar(
              pinned: true,
              backgroundColor: Colors.transparent,
              automaticallyImplyLeading: false,
              title: const Text('JAM — listen together'),
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
    if (!connected) return _JoinForm(state: state);
    return _RoomCard(state: state, scroll: scroll);
  }
}

class _JoinForm extends StatefulWidget {
  final AppState state;
  const _JoinForm({required this.state});

  @override
  State<_JoinForm> createState() => _JoinFormState();
}

class _JoinFormState extends State<_JoinForm> {
  late final TextEditingController _name;
  late final TextEditingController _code;
  bool _busy = false;

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _name,
          maxLength: 24,
          decoration: const InputDecoration(
              labelText: 'Your name', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _code,
          maxLength: 6,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: 'JAM code',
            hintText: hostRoomFormatHint,
            border: const OutlineInputBorder(),
            suffixIcon: const Icon(Icons.dialpad_outlined),
            errorText: _code.text.isNotEmpty &&
                    !jamValidCode(_code.text)
                ? '6 letters, no 0/O/1/I'
                : null,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          style: spotifyPlayStyle(),
          icon: const Icon(Icons.graphic_eq),
          label: const Text('Start a JAM room'),
          onPressed:
              _busy ? null : () => _go(host: true),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          icon: const Icon(Icons.join_inner_outlined),
          label: const Text('Join with code'),
          onPressed:
              _busy ? null : () => _go(host: false),
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
  const _RoomCard({required this.state, required this.scroll});

  @override
  Widget build(BuildContext context) {
    final jam = state.jam;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(colors: [
              Color(0xFF1DB954),
              Color(0xFF0D5C2B)
            ]),
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
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 12)),
                    Text(jam.code,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 3)),
                    Text(
                        '${jam.membersCount} member'
                        '${jam.membersCount == 1 ? '' : 's'}'
                        ' • ${_stateLine(state)}',
                        style: const TextStyle(
                            color: Colors.white70)),
                  ],
                ),
              ),
              Column(children: [
                IconButton(
                  tooltip: 'Share',
                  icon: const Icon(Icons.share_outlined,
                      color: Colors.white),
                  onPressed: () => _share(context, jam.code),
                ),
                const SizedBox(height: 4),
                Switch(
                  value: jam.guestAllowed,
                  activeThumbColor: Colors.black,
                  onChanged: jam.isHost
                      ? (v) =>
                          state.jamSetGuestAllowed(v)
                      : null,
                ),
                const Text('Guests control',
                    style: TextStyle(
                        color: Colors.white70,
                        fontSize: 10)),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in jam.members)
              Chip(
                avatar: Icon(m.host
                    ? Icons.star
                    : Icons.person_outline,
                    size: 18,
                    color: dark ? Colors.white : Colors.black),
                label: Text(m.name + (m.host ? ' (host)' : '')),
              ),
          ],
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
        for (final t in state.jamQueueView())
          ListTile(
            dense: true,
            title: Text(t.title, maxLines: 1,
                overflow: TextOverflow.ellipsis),
            subtitle: Text(t.displayArtist(), maxLines: 1,
                overflow: TextOverflow.ellipsis),
            leading: const Icon(Icons.music_note_outlined),
          ),
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
      return '';
    }
  }

  Future<void> _share(BuildContext context, String code) async {
    try {
      await SharePlus.instance.share(ShareParams(
        text: 'Join my JAM on Cresca: $code\n'
            'cresca://jam/$code',
      ));
    } catch (_) {}
  }
}
