// Search tab (S1–S4): debounced (250ms) music-only search, instant
// cached results first, suggestions (fast engine only) + artist row
// (real channels, track-derived fallback), song rows + overflow menu.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/track.dart';
import '../app.dart';
import '../state.dart';
import '../widgets/mini_player.dart';
import '../widgets/track_row.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;
  List<YtTrack> _rows = [];
  List<YtTrack> _cachedFirst = [];
  List<String> _suggestions = [];
  List<YtArtist> _artists = [];
  bool _loading = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    AppScope.of(context).onSearchFocusRequest = () {
      try {
        FocusScope.of(context).requestFocus(_focus);
      } catch (_) {}
    };
  }

  @override
  void dispose() {
    try {
      AppScope.of(context).onSearchFocusRequest = null;
    } catch (_) {}
    _debounce?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String value, AppState state) {
    try {
      _debounce?.cancel();
      // Instant cached results first (S1).
      state.searchCached(value).then((c) {
        if (!mounted || value != _text.text) return;
        setState(() => _cachedFirst = c ?? []);
      }).catchError((_) {});
      // Suggestions on every keystroke (fast engine only, S2).
      state.suggestions(value).then((s) {
        if (!mounted || value != _text.text) return;
        setState(() => _suggestions = s);
      }).catchError((_) {});
      // Debounced (250ms) music-only search.
      _debounce = Timer(const Duration(milliseconds: 250), () {
        _run(value, state);
      });
    } catch (_) {}
  }

  Future<void> _run(String value, AppState state) async {
    try {
      final q = value.trim();
      if (q.isEmpty) {
        if (mounted) {
          setState(() {
            _rows = [];
            _artists = [];
            _loading = false;
            _query = '';
          });
        }
        return;
      }
      if (mounted) {
        setState(() {
          _loading = true;
          _query = q;
        });
      }
      final hits = await state.searchNow(q);
      if (!mounted || _text.text.trim() != q) return;
      final artists = await state.artistsFor(q, hits);
      if (!mounted) return;
      setState(() {
        _rows = hits;
        _artists = artists;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final shown = _rows.isEmpty ? _cachedFirst : _rows;
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _text,
          focusNode: _focus,
          decoration: InputDecoration(
            hintText: 'Search songs, artists',
            border: InputBorder.none,
            suffixIcon: _loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2)),
                  )
                : (_text.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _text.clear();
                          _run('', state);
                        },
                      )),
          ),
          onChanged: (v) => _onChanged(v, state),
          onSubmitted: (v) => _run(v, state),
        ),
      ),
      body: Column(
        children: [
          if (_suggestions.isNotEmpty)
            SizedBox(
              height: 40,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _suggestions.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    label: Text(_suggestions[i]),
                    onPressed: () {
                      _text.text = _suggestions[i];
                      _run(_suggestions[i], state);
                    },
                  ),
                ),
              ),
            ),
          if (_artists.isNotEmpty)
            SizedBox(
              height: 84,
              child: ListView.builder(
                scrollDirection: Axis.horizontal,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12),
                itemCount: _artists.length,
                itemBuilder: (_, i) {
                  final a = _artists[i];
                  return GestureDetector(
                    onTap: () {
                      _text.text = a.name;
                      _run('${a.name} songs', state);
                    },
                    child: Container(
                      width: 72,
                      margin: const EdgeInsets.only(right: 8),
                      child: Column(
                        children: [
                          CircleAvatar(
                            radius: 24,
                            backgroundImage: a.thumbUrl.isEmpty
                                ? null
                                : NetworkImage(a.thumbUrl),
                            child: a.thumbUrl.isEmpty
                                ? const Icon(Icons.person)
                                : null,
                          ),
                          Text(a.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          Expanded(
            child: shown.isEmpty && !_loading
                ? Center(
                    child: Text(_query.isEmpty
                        ? 'Search for songs and artists'
                        : 'No results — try another query'))
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (_, i) => TrackRow(
                        track: shown[i],
                        contextQueue: shown,
                        index: i),
                  ),
          ),
          const MiniPlayer(),
        ],
      ),
    );
  }
}
