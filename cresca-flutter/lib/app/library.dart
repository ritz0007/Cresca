// Minimal library stores (liked / recent / playlists) with native
// schemas. Native refs: LikedStore.kt (liked.json), RecentStore.kt
// (recent.json, 300 cap), PlaylistStore.kt (playlists.json array,
// 2000-track / 200-list caps, atomic .tmp+rename writes, dedupe).
// Full library UI (mosaics, covers, Suggested, sync) is Phase 3; this
// file backs the row-menu + restore paths Phase 2 needs.

import 'dart:convert';
import 'dart:io';

import '../core/track.dart';
import 'radio_store.dart'
    show SavedRadio, radioCap, radiosFromJson, radiosToJson;

const int recentCap = 300;
const int playlistTrackCap = 2000;
const int playlistCap = 200;

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

class UserPlaylist {
  final String id;
  String name;
  final List<YtTrack> tracks;
  final int createdAt;
  String coverPath;
  UserPlaylist({
    required this.id,
    required this.name,
    List<YtTrack>? tracks,
    required this.createdAt,
    this.coverPath = '',
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
          coverPath: (m['coverPath'] ?? '').toString(),
        ));
        if (out.length >= playlistCap) break;
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

String playlistsToJson(List<UserPlaylist> lists) => jsonEncode([
      for (final p in lists)
        {
          'id': p.id,
          'name': p.name,
          'tracks': [for (final t in p.tracks) trackRow(t)],
          'createdAt': p.createdAt,
          'coverPath': p.coverPath,
          'spotifyId': '',
        },
    ]);

/// Atomic file write (.tmp + rename) so kills never leave half-JSON.
Future<void> atomicWrite(File f, String text) async {
  try {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text);
    try {
      if (await f.exists()) await f.delete();
    } catch (_) {}
    await tmp.rename(f.path);
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
  final Directory dir;
  List<YtTrack> liked = [];
  List<YtTrack> recent = [];
  List<UserPlaylist> playlists = [];
  List<SavedRadio> radios = [];
  List<LikedArtist> artists = [];

  LibraryStore(this.dir);

  File get _likedFile => File('${dir.path}/liked.json');
  File get _recentFile => File('${dir.path}/recent.json');
  File get _playlistsFile => File('${dir.path}/playlists.json');
  File get _radiosFile => File('${dir.path}/radios.json');
  File get _artistsFile => File('${dir.path}/artists_liked.json');

  Future<void> load() async {
    try {
      liked = trackListFromJson(await readText(_likedFile), cap: 10000);
      recent = trackListFromJson(await readText(_recentFile));
      playlists = playlistsFromJson(await readText(_playlistsFile));
      radios = radiosFromJson(await readText(_radiosFile));
      artists = likedArtistsFromJson(await readText(_artistsFile));
      _sortRadios();
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
      await atomicWrite(_radiosFile, radiosToJson(radios));
    } catch (_) {}
  }

  Future<void> _saveArtists() async {
    try {
      await atomicWrite(
          _artistsFile,
          jsonEncode([
            for (final a in artists.take(500))
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
  Future<void> toggleArtist(String name,
      {String thumbUrl = '', String subs = ''}) async {
    try {
      final low = name.trim().toLowerCase();
      if (low.isEmpty) return;
      if (isArtistFav(name)) {
        artists.removeWhere((a) => a.name.toLowerCase() == low);
      } else {
        artists.insert(
            0, LikedArtist(name: name.trim(), thumbUrl: thumbUrl, subs: subs));
      }
      await _saveArtists();
    } catch (_) {}
  }

  Future<bool> renamePlaylist(String id, String name) async {
    try {
      final idx = playlists.indexWhere((e) => e.id == id);
      final t = name.trim();
      if (idx < 0 || t.isEmpty) return false;
      playlists[idx].name = t.length > 120 ? t.substring(0, 120) : t;
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
      if (idx < 0) return;
      playlists[idx].tracks.removeWhere((t) => t.id == trackId);
      await atomicWrite(_playlistsFile, playlistsToJson(playlists));
    } catch (_) {}
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
      if (isLiked(t.id)) {
        liked.removeWhere((e) => e.id == t.id);
      } else {
        liked.insert(0, t);
      }
      await atomicWrite(_likedFile,
          jsonEncode([for (final e in liked) trackRow(e)]));
    } catch (_) {}
  }

  Future<void> pushRecent(YtTrack t) async {
    try {
      recent.removeWhere((e) => e.id == t.id);
      recent.insert(0, t);
      if (recent.length > recentCap) {
        recent = recent.sublist(0, recentCap);
      }
      await atomicWrite(_recentFile,
          jsonEncode([for (final e in recent) trackRow(e)]));
    } catch (_) {}
  }

  Future<UserPlaylist> createPlaylist(String name) async {
    final p = UserPlaylist(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      name: name.trim().isEmpty ? 'New Playlist' : name.trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
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

  Future<bool> addToPlaylist(String id, YtTrack t) async {
    try {
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
