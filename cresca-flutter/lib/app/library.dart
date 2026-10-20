// Minimal library stores (liked / recent / playlists) with native
// schemas. Native refs: LikedStore.kt (liked.json), RecentStore.kt
// (recent.json, 300 cap), PlaylistStore.kt (playlists.json array,
// 2000-track / 200-list caps, atomic .tmp+rename writes, dedupe).
// Full library UI (mosaics, covers, Suggested, sync) is Phase 3; this
// file backs the row-menu + restore paths Phase 2 needs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/track.dart';
import 'radio_store.dart'
    show SavedRadio, radioCap, radiosFromJson, radiosToJson;

const int recentCap = 300;
const int likedCap = 10000;
const int likedArtistCap = 500;
const int playlistTrackCap = 2000;
const int playlistCap = 200;

/// Play-history (every play since install) cap. The unique recents rail
/// stays at [recentCap]; this table keeps one row PER PLAY (no dedupe)
/// so counts + full history survive. FIFO prune beyond the cap.
const int playHistoryCap = 5000;

Map<String, dynamic> trackRow(YtTrack t) => {
      'id': t.id,
      'title': t.title,
      'artist': t.artist,
      'thumb': t.thumbUrl,
      'watch': t.watchUrl,
    };

YtTrack? trackFromRow(Map<String, dynamic> o) {
  try {
    final id = (o['id'] ?? '').toString();
    if (id.isEmpty) return null;
    return YtTrack(
      id: id,
      title: (o['title'] ?? '').toString(),
      artist: (o['artist'] ?? '').toString(),
      thumbUrl: (o['thumb'] ?? '').toString(),
      watchUrl: (o['watch'] ?? '').toString(),
    );
  } catch (_) {
    return null;
  }
}

List<YtTrack> trackListFromJson(String raw, {int cap = recentCap}) {
  final out = <YtTrack>[];
  try {
    if (raw.trim().isEmpty) return out;
    final arr = jsonDecode(raw);
    if (arr is! List) return out;
    final seen = <String>{};
    for (final e in arr) {
      try {
        if (out.length >= cap) break;
        if (e is! Map) continue;
        final t = trackFromRow(e.cast<String, dynamic>());
        if (t == null || !seen.add(t.id)) continue;
        out.add(t);
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// One play-history row. Mirrors the SQLite schema below (field names
/// match the `play_history` columns) so a future sqflite migration is a
/// straight port with no data-shape change:
///
/// ```sql
/// CREATE TABLE IF NOT EXISTS play_history(
///   id INTEGER PRIMARY KEY AUTOINCREMENT,
///   track_id TEXT NOT NULL,
///   title TEXT NOT NULL DEFAULT '',
///   artist TEXT NOT NULL DEFAULT '',
///   thumb TEXT NOT NULL DEFAULT '',
///   watch_url TEXT NOT NULL DEFAULT '',
///   played_at INTEGER NOT NULL,
///   origin TEXT NOT NULL DEFAULT '');
/// CREATE INDEX IF NOT EXISTS idx_play_history_played_at
///   ON play_history(played_at DESC);
/// CREATE INDEX IF NOT EXISTS idx_play_history_track_id
///   ON play_history(track_id);
/// ```
///
/// NOTE: `sqflite` is not currently a dependency (pubspec has no sqlite
/// package and this task forbids touching anything but library.dart +
/// downloads.dart), so the table is backed by `play_history.json`
/// (atomic .tmp+rename writes, same crash discipline as the other
/// stores) with the identical semantics: append-only, most-recent-first,
/// FIFO prune beyond [playHistoryCap], in-memory played_at index. If
/// sqflite is ever added, replace [PlayHistoryStore] internals with the
/// DDL above; the public API stays unchanged.
class PlayHistoryEntry {
  final String trackId;
  final String title;
  final String artist;
  final String thumb;
  final String watchUrl;
  final int playedAt;
  final String origin;
  const PlayHistoryEntry({
    required this.trackId,
    this.title = '',
    this.artist = '',
    this.thumb = '',
    this.watchUrl = '',
    required this.playedAt,
    this.origin = '',
  });

  Map<String, dynamic> toRow() => {
        'track_id': trackId,
        'title': title,
        'artist': artist,
        'thumb': thumb,
        'watch_url': watchUrl,
        'played_at': playedAt,
        'origin': origin,
      };

  YtTrack toTrack() => YtTrack(
        id: trackId,
        title: title,
        artist: artist,
        thumbUrl: thumb,
        watchUrl: watchUrl,
      );
}

PlayHistoryEntry? playHistoryEntryFromRow(Map<String, dynamic> o) {
  try {
    final id = (o['track_id'] ?? o['id'] ?? '').toString();
    if (id.isEmpty) return null;
    var playedAt = 0;
    try {
      final v = o['played_at'];
      if (v is int) {
        playedAt = v;
      } else {
        playedAt = int.tryParse(v.toString()) ?? 0;
      }
    } catch (_) {
      playedAt = 0;
    }
    if (playedAt <= 0) return null;
    return PlayHistoryEntry(
      trackId: id,
      title: (o['title'] ?? '').toString(),
      artist: (o['artist'] ?? '').toString(),
      thumb: (o['thumb'] ?? '').toString(),
      watchUrl: (o['watch_url'] ?? o['watch'] ?? '').toString(),
      playedAt: playedAt,
      origin: (o['origin'] ?? '').toString(),
    );
  } catch (_) {
    return null;
  }
}

/// Append-only play log: one row PER PLAY, most-recent-first, FIFO prune
/// beyond [playHistoryCap]. Lazily opened (never on the boot hot path),
/// never throws; callers awaiting [logPlay]/[history] trigger the single
/// coalesced load.
class PlayHistoryStore {
  final Directory dir;
  final List<PlayHistoryEntry> _entries = [];
  bool _loaded = false;
  Future<void>? _loading;
  bool _saveInFlight = false;
  bool _saveQueued = false;

  PlayHistoryStore(this.dir);

  File get _file => File('${dir.path}/play_history.json');

  /// In-memory entry count (0 before first load). Never throws.
  int get cachedCount {
    try {
      return _entries.length;
    } catch (_) {
      return 0;
    }
  }

  Future<void> ensureLoaded() async {
    try {
      if (_loaded) return;
      final pending = _loading;
      if (pending != null) {
        await pending;
        return;
      }
      _loading = _load();
      await _loading;
    } catch (_) {
    } finally {
      try {
        _loading = null;
      } catch (_) {}
    }
  }

  Future<void> _load() async {
    try {
      final raw = await readText(_file);
      final parsed = <PlayHistoryEntry>[];
      try {
        if (raw.trim().isNotEmpty) {
          final arr = jsonDecode(raw);
          if (arr is List) {
            for (final e in arr) {
              try {
                if (e is! Map) continue;
                final row =
                    playHistoryEntryFromRow(e.cast<String, dynamic>());
                if (row == null) continue;
                parsed.add(row);
                if (parsed.length >= playHistoryCap) break;
              } catch (_) {}
            }
          } else if (parsed.isEmpty && raw.trim().length > 2) {
            await backupCorrupt(_file, raw);
          }
        }
      } catch (_) {
        await backupCorrupt(_file, raw);
      }
      parsed.sort((a, b) => b.playedAt.compareTo(a.playedAt));
      _entries
        ..clear()
        ..addAll(parsed.take(playHistoryCap));
      _loaded = true;
    } catch (_) {
      try {
        _loaded = true;
      } catch (_) {}
    }
  }

  Future<void> _persist() async {
    try {
      if (_saveInFlight) {
        _saveQueued = true;
        return;
      }
      _saveInFlight = true;
      try {
        while (true) {
          _saveQueued = false;
          List<Map<String, dynamic>> rows;
          try {
            rows = [
              for (final e in _entries.take(playHistoryCap)) e.toRow(),
            ];
          } catch (_) {
            rows = const [];
          }
          try {
            await atomicWrite(_file, jsonEncode(rows));
          } catch (_) {}
          if (!_saveQueued) break;
        }
      } finally {
        try {
          _saveInFlight = false;
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Logs one play (blank ids ignored). Awaits only the one-time lazy
  /// load; the disk write is coalesced in the background so rapid
  /// successive plays stay instant. Never throws.
  Future<void> logPlay(YtTrack track, {String origin = ''}) async {
    try {
      if (track.id.isEmpty) return;
      await ensureLoaded();
      final now = DateTime.now().millisecondsSinceEpoch;
      try {
        _entries.insert(
            0,
            PlayHistoryEntry(
              trackId: track.id,
              title: track.title,
              artist: track.artist,
              thumb: track.thumbUrl,
              watchUrl: track.watchUrl,
              playedAt: now,
              origin: origin,
            ));
        if (_entries.length > playHistoryCap) {
          _entries.removeRange(playHistoryCap, _entries.length);
        }
      } catch (_) {}
      // Fire-and-forget: callers (pushRecent) stay instant; concurrent
      // plays coalesce into one write via _saveQueued.
      unawaited(_persist());
    } catch (_) {}
  }

  /// Plays most-recent-first. Never throws; empty before first load.
  Future<List<YtTrack>> history({int limit = 100, int offset = 0}) async {
    try {
      await ensureLoaded();
      final lim = limit.clamp(1, 500);
      final off = offset < 0 ? 0 : offset;
      if (off >= _entries.length) return const [];
      final end = (off + lim).clamp(0, _entries.length);
      return [
        for (var i = off; i < end; i++) _entries[i].toTrack(),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Raw rows most-recent-first (with played_at/origin metadata).
  Future<List<PlayHistoryEntry>> historyEntries(
      {int limit = 100, int offset = 0}) async {
    try {
      await ensureLoaded();
      final lim = limit.clamp(1, 500);
      final off = offset < 0 ? 0 : offset;
      if (off >= _entries.length) return const [];
      final end = (off + lim).clamp(0, _entries.length);
      return _entries.sublist(off, end).toList();
    } catch (_) {
      return const [];
    }
  }

  Future<int> historyCount() async {
    try {
      await ensureLoaded();
      return _entries.length;
    } catch (_) {
      return 0;
    }
  }

  Future<int> playCount(String id) async {
    try {
      if (id.isEmpty) return 0;
      await ensureLoaded();
      var n = 0;
      for (final e in _entries) {
        if (e.trackId == id) n++;
      }
      return n;
    } catch (_) {
      return 0;
    }
  }

  /// Most recent played_at millis for [id], or null when never played.
  Future<int?> lastPlayed(String id) async {
    try {
      if (id.isEmpty) return null;
      await ensureLoaded();
      for (final e in _entries) {
        if (e.trackId == id) return e.playedAt;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<void> clearHistory() async {
    try {
      _entries.clear();
      await _persist();
    } catch (_) {}
  }
}

class UserPlaylist {
  final String id;
  String name;
  final List<YtTrack> tracks;
  final int createdAt;
  String coverPath;
  String spotifyId;
  UserPlaylist({
    required this.id,
    required this.name,
    List<YtTrack>? tracks,
    required this.createdAt,
    this.coverPath = '',
    this.spotifyId = '',
  }) : tracks = tracks ?? [];
}

List<UserPlaylist> playlistsFromJson(String raw) {
  final out = <UserPlaylist>[];
  try {
    if (raw.trim().isEmpty) return out;
    final arr = jsonDecode(raw);
    if (arr is! List) return out;
    final seen = <String>{};
    for (final e in arr) {
      try {
        if (e is! Map) continue;
        final m = e.cast<String, dynamic>();
        final id = (m['id'] ?? '').toString().trim();
        if (id.isEmpty || !seen.add(id)) continue;
        final name = (m['name'] ?? '').toString().trim();
        if (name.isEmpty) continue;
        final tracks = <YtTrack>[];
        final seenT = <String>{};
        final tarr = m['tracks'];
        if (tarr is List) {
          for (final te in tarr) {
            try {
              if (tracks.length >= playlistTrackCap) break;
              if (te is! Map) continue;
              final t = trackFromRow(te.cast<String, dynamic>());
              if (t == null || !seenT.add(t.id)) continue;
              tracks.add(t);
            } catch (_) {}
          }
        }
        out.add(UserPlaylist(
          id: id,
          name: name.length > 120 ? name.substring(0, 120) : name,
          tracks: tracks,
          createdAt: int.tryParse(m['createdAt'].toString()) ?? 0,
          // Native key is "cover"; older Flutter builds wrote
          // "coverPath". Accept both so custom covers survive reload.
          coverPath: (m['coverPath'] ?? m['cover'] ?? '').toString(),
          // Rename-safe Spotify sync link (native Playlist.spotifyId).
          // Older Flutter builds dropped this on load; keep it so a
          // future sync can match the mirrored playlist.
          spotifyId: (m['spotifyId'] ?? '').toString(),
        ));
        if (out.length >= playlistCap) break;
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

String playlistsToJson(List<UserPlaylist> lists) {
  // Native schema: "cover" + "spotifyId" written only when non-blank,
  // blank ids/names and duplicate tracks skipped, caps enforced.
  // "coverPath" is written alongside "cover" for back-compat with
  // older Flutter builds that only read "coverPath".
  final arr = <Map<String, dynamic>>[];
  for (final p in lists.take(playlistCap)) {
    try {
      if (p.id.trim().isEmpty || p.name.trim().isEmpty) continue;
      final seen = <String>{};
      final tarr = <Map<String, dynamic>>[];
      for (final t in p.tracks) {
        try {
          if (t.id.isEmpty || !seen.add(t.id)) continue;
          if (tarr.length >= playlistTrackCap) break;
          tarr.add(trackRow(t));
        } catch (_) {}
      }
      final o = <String, dynamic>{
        'id': p.id,
        'name': p.name.length > 120 ? p.name.substring(0, 120) : p.name,
        'tracks': tarr,
        'createdAt': p.createdAt,
      };
      if (p.coverPath.trim().isNotEmpty) {
        o['cover'] = p.coverPath;
        o['coverPath'] = p.coverPath;
      }
      if (p.spotifyId.trim().isNotEmpty) o['spotifyId'] = p.spotifyId;
      arr.add(o);
    } catch (_) {}
  }
  return jsonEncode(arr);
}

/// Atomic file write (.tmp + rename) so kills never leave half-JSON.
/// Keeps one .bak of the previous good file (native PlaylistStore
/// parity) and falls back to a direct write when the rename fails.
Future<void> atomicWrite(File f, String text) async {
  try {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text);
    try {
      // Keep one backup for crash recovery.
      try {
        final bak = File('${f.path}.bak');
        try {
          await bak.delete();
        } catch (_) {}
        if (await f.exists()) {
          await f.copy(bak.path);
        }
      } catch (_) {}
      if (!await _renameOver(tmp, f)) {
        await tmp.rename(f.path);
      }
    } catch (_) {
      try {
        await f.writeAsString(text);
      } catch (_) {}
    }
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  } catch (_) {}
}

/// Renames [src] onto [dst], deleting [dst] first on platforms where
/// rename-over-existing fails (Windows). Returns true on success.
Future<bool> _renameOver(File src, File dst) async {
  try {
    try {
      if (await dst.exists()) await dst.delete();
    } catch (_) {}
    await src.rename(dst.path);
    return true;
  } catch (_) {
    return false;
  }
}

/// Backs up a corrupt JSON file once (native PlaylistStore parity: the
/// raw text survives next to the reset file instead of being silently
/// lost). Never throws.
Future<void> backupCorrupt(File f, String raw) async {
  try {
    if (raw.trim().isEmpty) return;
    final bak =
        File('${f.path}.corrupt.${DateTime.now().millisecondsSinceEpoch}');
    await bak.writeAsString(raw.length > 200 * 1024
        ? raw.substring(0, 200 * 1024)
        : raw);
  } catch (_) {}
}

Future<String> readText(File f) async {
  try {
    if (!await f.exists()) return '';
    return await f.readAsString();
  } catch (_) {
    return '';
  }
}

class LikedArtist {
  final String name;
  final String thumbUrl;
  final String subs;
  const LikedArtist({required this.name, this.thumbUrl = '', this.subs = ''});
}

List<LikedArtist> likedArtistsFromJson(String raw, {int cap = 500}) {
  final out = <LikedArtist>[];
  try {
    if (raw.trim().isEmpty) return out;
    final arr = jsonDecode(raw);
    if (arr is! List) return out;
    final seen = <String>{};
    for (final e in arr) {
      try {
        if (e is! Map) continue;
        final m = e.cast<String, dynamic>();
        final name = (m['name'] ?? '').toString().trim();
        if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
        out.add(LikedArtist(
          name: name,
          thumbUrl: (m['thumb'] ?? '').toString(),
          subs: (m['subs'] ?? '').toString(),
        ));
        if (out.length >= cap) break;
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// File-backed library: liked + recent (300) + playlists + radios +
/// favorite artists. All IO silent, atomic writes, native schemas.
class LibraryStore {
  static int _plistSeq = 0;
  final Directory dir;
  List<YtTrack> liked = [];
  List<YtTrack> recent = [];
  List<UserPlaylist> playlists = [];
  List<SavedRadio> radios = [];
  List<LikedArtist> artists = [];

  LibraryStore(this.dir) : playHistory = PlayHistoryStore(dir);

  /// Append-only log of EVERY play since install (no dedupe, FIFO prune
  /// beyond [playHistoryCap]). Lazily opened: [load] never blocks boot
  /// on it — first [logPlay]/[history] (or a background preload) opens
  /// it. `recent.json` stays the fast unique rail + fallback.
  final PlayHistoryStore playHistory;

  File get _likedFile => File('${dir.path}/liked.json');
  File get _recentFile => File('${dir.path}/recent.json');
  File get _playlistsFile => File('${dir.path}/playlists.json');
  File get _radiosFile => File('${dir.path}/radios.json');
  File get _artistsFile => File('${dir.path}/artists_liked.json');

  Future<void> load() async {
    try {
      final rawLiked = await readText(_likedFile);
      liked = trackListFromJson(rawLiked, cap: likedCap);
      await _backupIfCorrupt(_likedFile, rawLiked, liked.isNotEmpty);

      final rawRecent = await readText(_recentFile);
      recent = trackListFromJson(rawRecent);
      await _backupIfCorrupt(_recentFile, rawRecent, recent.isNotEmpty);
      final rawPlaylists = await readText(_playlistsFile);
      playlists = playlistsFromJson(rawPlaylists);
      try {
        // Corrupt file that parses to empty while raw was non-trivial:
        // back it up once so user data isn't silently lost (native
        // PlaylistStore.list parity).
        final t = rawPlaylists.trim();
        if (playlists.isEmpty && t.length > 2 && t != '[]') {
          await backupCorrupt(_playlistsFile, rawPlaylists);
        }
      } catch (_) {}
      final rawRadios = await readText(_radiosFile);
      radios = radiosFromJson(rawRadios);
      await _backupIfCorrupt(_radiosFile, rawRadios, radios.isNotEmpty);
      final rawArtists = await readText(_artistsFile);
      artists = likedArtistsFromJson(rawArtists);
      await _backupIfCorrupt(
          _artistsFile, rawArtists, artists.isNotEmpty);
      _sortRadios();
      // History open stays off the boot hot path: warm it in the
      // background without blocking callers of load().
      try {
        unawaited(playHistory.ensureLoaded());
      } catch (_) {}
    } catch (_) {}
  }

  /// Backs up [file] once when [raw] is non-trivial but parsed to empty
  /// (crash-torn write). [nonEmpty] is whether parsing produced rows.
  /// Never throws.
  Future<void> _backupIfCorrupt(
      File file, String raw, bool nonEmpty) async {
    try {
      final t = raw.trim();
      if (!nonEmpty && t.length > 2 && t != '[]' && t != '{}') {
        await backupCorrupt(file, raw);
      }
    } catch (_) {}
  }

  void _sortRadios() {
    try {
      radios.sort((a, b) {
        if (a.liked != b.liked) return a.liked ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    } catch (_) {}
  }

  Future<void> _saveRadios() async {
    try {
      // Cap enforced on write too (upsert caps in memory; without this a
      // hand-grown list would persist unbounded).
      await atomicWrite(
          _radiosFile, radiosToJson(radios.take(radioCap).toList()));
    } catch (_) {}
  }

  Future<void> _saveArtists() async {
    try {
      await atomicWrite(
          _artistsFile,
          jsonEncode([
            for (final a in artists.take(likedArtistCap))
              if (a.name.isNotEmpty)
                {
                  'name': a.name.length > 120
                      ? a.name.substring(0, 120)
                      : a.name,
                  'thumb': a.thumbUrl,
                  'subs': a.subs,
                },
          ]));
    } catch (_) {}
  }

  /// Insert or refresh a radio card (liked flag survives refreshes).
  Future<void> upsertRadio(SavedRadio radio) async {
    try {
      if (radio.seed.id.isEmpty) return;
      final idx = radios.indexWhere((e) => e.seed.id == radio.seed.id);
      final keepLiked = idx >= 0 ? radios[idx].liked : radio.liked;
      final merged = radio.copyWith(
        id: idx >= 0 ? radios[idx].id : radio.id,
        liked: keepLiked,
        createdAt:
            idx >= 0 ? radios[idx].createdAt : radio.createdAt,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
      radios = [
        merged,
        for (final r in radios)
          if (r.seed.id != radio.seed.id) r,
      ];
      if (radios.length > radioCap) {
        radios = radios.sublist(0, radioCap);
      }
      _sortRadios();
      await _saveRadios();
    } catch (_) {}
  }

  /// Toggles the radio heart. Returns the new liked state.
  Future<bool> toggleRadioLike(String seedId) async {
    try {
      if (seedId.isEmpty) return false;
      final idx = radios.indexWhere((e) => e.seed.id == seedId);
      if (idx < 0) return false;
      final next = !radios[idx].liked;
      radios[idx] = radios[idx].copyWith(
          liked: next,
          updatedAt: DateTime.now().millisecondsSinceEpoch);
      _sortRadios();
      await _saveRadios();
      return next;
    } catch (_) {
      return false;
    }
  }

  Future<void> deleteRadio(String seedId) async {
    try {
      if (seedId.isEmpty) return;
      radios = radios.where((e) => e.seed.id != seedId).toList();
      await _saveRadios();
    } catch (_) {}
  }

  bool isArtistFav(String name) {
    try {
      final low = name.trim().toLowerCase();
      return artists.any((a) => a.name.toLowerCase() == low);
    } catch (_) {
      return false;
    }
  }

  /// Favorite-artist toggle (name-keyed, art refreshes on re-like).
  /// Names truncate to 120 chars and the list is capped in memory as
  /// well as on disk (native take(500) parity).
  Future<void> toggleArtist(String name,
      {String thumbUrl = '', String subs = ''}) async {
    try {
      final low = name.trim().toLowerCase();
      if (low.isEmpty) return;
      if (isArtistFav(name)) {
        artists.removeWhere((a) => a.name.toLowerCase() == low);
      } else {
        var clean = name.trim();
        if (clean.length > 120) clean = clean.substring(0, 120);
        artists.insert(
            0, LikedArtist(name: clean, thumbUrl: thumbUrl, subs: subs));
        if (artists.length > likedArtistCap) {
          artists = artists.sublist(0, likedArtistCap);
        }
      }
      await _saveArtists();
    } catch (_) {}
  }

  Future<bool> renamePlaylist(String id, String name) async {
    try {
      final idx = playlists.indexWhere((e) => e.id == id);
      final t = name.trim();
      if (idx < 0 || t.isEmpty) return false;
      final clean = t.length > 120 ? t.substring(0, 120) : t;
      if (playlists[idx].name == clean) return false;
      playlists[idx].name = clean;
      await atomicWrite(_playlistsFile, playlistsToJson(playlists));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> deletePlaylist(String id) async {
    try {
      playlists = playlists.where((e) => e.id != id).toList();
      await atomicWrite(_playlistsFile, playlistsToJson(playlists));
    } catch (_) {}
  }

  Future<void> removeFromPlaylist(String id, String trackId) async {
    try {
      final idx = playlists.indexWhere((e) => e.id == id);
      if (idx < 0 || trackId.isEmpty) return;
      // Single occurrence only: swipe-delete of one dupe row must not
      // wipe its twins (index-based removeTrackAt for exact rows).
      final at = playlists[idx].tracks.indexWhere((t) => t.id == trackId);
      if (at < 0) return;
      playlists[idx].tracks.removeAt(at);
      await atomicWrite(_playlistsFile, playlistsToJson(playlists));
    } catch (_) {}
  }

  /// Removes the single row at [index] (swipe-delete path, dupe-safe).
  /// Returns false when the playlist or index is unknown.
  Future<bool> removeTrackAt(String id, int index) async {
    try {
      final idx = playlists.indexWhere((e) => e.id == id);
      if (idx < 0) return false;
      final tracks = playlists[idx].tracks;
      if (index < 0 || index >= tracks.length) return false;
      tracks.removeAt(index);
      await atomicWrite(_playlistsFile, playlistsToJson(playlists));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Persists the current in-memory order (Undo re-insert path: the
  /// move is in-memory only until this write lands, or a kill loses
  /// it). Never throws.
  Future<void> persistPlaylists() async {
    try {
      await atomicWrite(_playlistsFile, playlistsToJson(playlists));
    } catch (_) {}
  }

  /// Restores a previously deleted playlist at [index] (Undo path for
  /// playlist deletes). No-op when an entry with the same id exists or
  /// the snapshot is blank. Returns true when restored.
  Future<bool> restorePlaylist(UserPlaylist snapshot, {int index = 0}) async {
    try {
      if (snapshot.id.isEmpty || snapshot.name.trim().isEmpty) {
        return false;
      }
      if (playlists.any((e) => e.id == snapshot.id)) return false;
      final at = index.clamp(0, playlists.length);
      playlists.insert(at, snapshot);
      if (playlists.length > playlistCap) {
        playlists = playlists.sublist(0, playlistCap);
      }
      await atomicWrite(_playlistsFile, playlistsToJson(playlists));
      return true;
    } catch (_) {
      return false;
    }
  }

  bool isLiked(String id) {
    try {
      return liked.any((t) => t.id == id);
    } catch (_) {
      return false;
    }
  }

  Future<void> toggleLike(YtTrack t) async {
    try {
      if (t.id.isEmpty) return;
      if (isLiked(t.id)) {
        liked.removeWhere((e) => e.id == t.id);
      } else {
        liked.insert(0, t);
        // Cap enforced on write too (load caps at likedCap; without
        // this the in-memory list grows without bound).
        if (liked.length > likedCap) {
          liked = liked.sublist(0, likedCap);
        }
      }
      await atomicWrite(_likedFile,
          jsonEncode([for (final e in liked.take(likedCap)) trackRow(e)]));
    } catch (_) {}
  }

  /// Unique recents rail (deduped, [recentCap] cap, `recent.json` stays
  /// the fast list + fallback) AND the full play log: every call also
  /// appends one row to [playHistory] (no dedupe there), so no caller
  /// changes are needed to capture every play since install.
  Future<void> pushRecent(YtTrack t, {String origin = ''}) async {
    try {
      if (t.id.isEmpty) return;
      recent.removeWhere((e) => e.id == t.id);
      recent.insert(0, t);
      if (recent.length > recentCap) {
        recent = recent.sublist(0, recentCap);
      }
      await atomicWrite(_recentFile,
          jsonEncode([for (final e in recent.take(recentCap)) trackRow(e)]));
    } catch (_) {}
    try {
      await logPlay(t, origin: origin);
    } catch (_) {}
  }

  /// Logs one play to the append-only history (no dedupe, FIFO prune
  /// beyond [playHistoryCap]). Called from [pushRecent]; safe to call
  /// directly. Never throws.
  Future<void> logPlay(YtTrack t, {String origin = ''}) async {
    try {
      await playHistory.logPlay(t, origin: origin);
    } catch (_) {}
  }

  /// Full play history most-recent-first ([PlayHistoryStore.history]).
  Future<List<YtTrack>> history({int limit = 100, int offset = 0}) {
    try {
      return playHistory.history(limit: limit, offset: offset);
    } catch (_) {
      return Future.value(const <YtTrack>[]);
    }
  }

  /// Full history rows most-recent-first (with played_at/origin).
  Future<List<PlayHistoryEntry>> historyEntries(
      {int limit = 100, int offset = 0}) {
    try {
      return playHistory.historyEntries(limit: limit, offset: offset);
    } catch (_) {
      return Future.value(const <PlayHistoryEntry>[]);
    }
  }

  /// Total logged plays since install.
  Future<int> historyCount() {
    try {
      return playHistory.historyCount();
    } catch (_) {
      return Future.value(0);
    }
  }

  /// Play count for one track id.
  Future<int> playCount(String id) {
    try {
      return playHistory.playCount(id);
    } catch (_) {
      return Future.value(0);
    }
  }

  /// Most recent played_at millis for one track id, or null when never
  /// played.
  Future<int?> lastPlayed(String id) {
    try {
      return playHistory.lastPlayed(id);
    } catch (_) {
      return Future.value(null);
    }
  }

  Future<UserPlaylist> createPlaylist(String name) async {
    final clean = name.trim().isEmpty
        ? 'New Playlist'
        : (name.trim().length > 120
            ? name.trim().substring(0, 120)
            : name.trim());
    final now = DateTime.now().millisecondsSinceEpoch;
    // Millis-only ids collide on double-tap creates; suffix with a
    // per-process counter like native's pl_<now>_<uuid8> shape.
    final p = UserPlaylist(
      id: 'pl_${now}_${_plistSeq++ % 100000}',
      name: clean,
      createdAt: now,
    );
    try {
      playlists.insert(0, p);
      if (playlists.length > playlistCap) {
        playlists = playlists.sublist(0, playlistCap);
      }
      await atomicWrite(_playlistsFile, playlistsToJson(playlists));
    } catch (_) {}
    return p;
  }

  /// Adds a track (dedupe + cap). Idempotent: re-adding an existing
  /// song returns true without duplicating (Flutter contract per
  /// home_test; native returns false here — same no-growth outcome).
  /// Returns false only when the list is full or ids are
  /// blank/missing.
  Future<bool> addToPlaylist(String id, YtTrack t) async {
    try {
      if (id.isEmpty || t.id.isEmpty) return false;
      final p = playlists.where((e) => e.id == id).firstOrNull;
      if (p == null || p.tracks.length >= playlistTrackCap) return false;
      if (p.tracks.any((e) => e.id == t.id)) return true;
      p.tracks.add(t);
      await atomicWrite(_playlistsFile, playlistsToJson(playlists));
      return true;
    } catch (_) {
      return false;
    }
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    try {
      return first;
    } catch (_) {
      return null;
    }
  }
}
