// Network repository: search/browse/related/autoplay with S3 gates.
// Native ref: YoutubeRepository.kt (method-by-method fallbacks),
// innertube/InnerTubeApi.kt (fast path), NewPipeExtractor paths replaced
// by youtube_explode_dart (mapping table in RESTRUCTURE.md section 2).
//
// Rules (RESTRUCTURE.md): every network call has a timeout + fallback +
// silent catch. Fast path first (InnerTube WEB_REMIX), extractor fallback,
// empty list on failure — never throws.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/discovery.dart';
import '../core/track.dart';
import 'cache.dart';
import 'innertube.dart';

/// Login session + engine knobs (backed by flutter_secure_storage /
/// shared_preferences in the app layer; fakes in tests).
class RepoSession {
  String cookies = '';
  String visitorData = '';
  String poToken = '';
  bool useInnerTube = true;
}

/// Timeouts: connect 10s, read/write 12s (C3); player path 4/6/6s (C4).
const Duration browseTimeout = Duration(seconds: 12);
const Duration suggestTimeout = Duration(seconds: 8);

class YoutubeRepository {
  final http.Client _http;
  final RepoSession session;
  final Directory? cacheDir;
  YoutubeExplode? _yt;

  YoutubeRepository({
    http.Client? httpClient,
    RepoSession? session,
    this.cacheDir,
  })  : _http = httpClient ?? http.Client(),
        session = session ?? RepoSession();

  YoutubeExplode get _explode => _yt ??= YoutubeExplode();

  void dispose() {
    try {
      _yt?.close();
    } catch (_) {}
    _yt = null;
    try {
      _http.close();
    } catch (_) {}
  }

  Future<Map<String, dynamic>?> _post(
    String endpoint,
    Map<String, dynamic> body, {
    String host = 'https://music.youtube.com',
    Duration timeout = browseTimeout,
  }) async {
    try {
      final client = TubeClient.webRemix;
      final res = await _http
          .post(
            Uri.parse(tubeUrl(client, endpoint, host: host)),
            headers: tubeHeaders(
              client,
              cookies: session.cookies,
              visitorData: session.visitorData,
              poToken: session.poToken,
            ),
            body: jsonEncode(body),
          )
          .timeout(timeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (_) {
      return null;
    }
  }

  // ---------- search ----------

  /// YTM song search (fast path) → extractor video search fallback.
  /// Distinct ids, capped at max, S3-gated by the parsers.
  Future<List<YtTrack>> searchMusic(String query, {int max = 15}) async {
    try {
      if (query.trim().isEmpty) return [];
      if (session.useInnerTube) {
        try {
          final json = await _post(
            'search',
            searchBody(query, session.visitorData),
          );
          if (json != null) {
            final fast = parseSearch(json, max);
            if (fast.isNotEmpty) return distinctById(fast).take(max).toList();
          }
        } catch (_) {}
      }
      return await searchVideos(query, max: max);
    } catch (_) {
      return [];
    }
  }

  Future<List<YtTrack>> search(String query, {int max = 15}) =>
      searchMusic(query, max: max);

  /// Plain video search via the extractor (music videos live here).
  Future<List<YtTrack>> searchVideos(String query, {int max = 20}) async {
    try {
      if (query.trim().isEmpty) return [];
      final list = await _explode.search
          .search(query, filter: TypeFilters.video)
          .timeout(browseTimeout);
      final out = <YtTrack>[];
      final seen = <String>{};
      for (final v in list) {
        try {
          final t = _trackFromVideo(v);
          if (t == null || !seen.add(t.id)) continue;
          out.add(t);
          if (out.length >= max) break;
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Artist channel hits with art (distinct names).
  Future<List<YtArtist>> searchArtists(String query, {int max = 8}) async {
    try {
      if (query.trim().isEmpty) return [];
      final list = await _explode.search
          .searchContent(query, filter: TypeFilters.channel)
          .timeout(browseTimeout);
      final out = <YtArtist>[];
      final seen = <String>{};
      for (final r in list) {
        try {
          if (r is! SearchChannel) continue;
          final name = r.name.trim();
          if (name.isEmpty || !seen.add(name.toLowerCase())) continue;
          String thumb = '';
          try {
            if (r.thumbnails.isNotEmpty) {
              thumb = r.thumbnails.last.url.toString();
            }
          } catch (_) {}
          out.add(YtArtist(name: name, thumbUrl: thumb, subs: ''));
          if (out.length >= max) break;
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Suggestions via the fast engine only (<180ms target, S2).
  Future<List<String>> suggestions(String input) async {
    try {
      if (!session.useInnerTube || input.trim().length < 2) return [];
      final json = await _post(
        'music/get_search_suggestions',
        suggestionBody(input, session.visitorData),
        timeout: suggestTimeout,
      );
      if (json == null) return [];
      return parseSuggestions(json);
    } catch (_) {
      return [];
    }
  }

  // ---------- browse / charts ----------

  /// One-call home shelves (FEmusic_home). Empty on failure.
  Future<Map<String, List<YtTrack>>> homeShelves({
    int maxShelves = 8,
    int perShelf = 12,
  }) async {
    try {
      if (!session.useInnerTube) return {};
      final json = await _post(
        'browse',
        browseBody('FEmusic_home', session.visitorData),
      );
      if (json == null) return {};
      return parseShelves(json, maxShelves, perShelf);
    } catch (_) {
      return {};
    }
  }

  Future<Map<String, List<YtTrack>>> _chartShelves(
      {int maxShelves = 8, int perShelf = 25}) async {
    try {
      if (!session.useInnerTube) return {};
      final json = await _post(
        'browse',
        browseBody('FEmusic_charts', session.visitorData),
      );
      if (json == null) return {};
      return parseShelves(json, maxShelves, perShelf);
    } catch (_) {
      return {};
    }
  }

  /// Top charts flattened, distinct. Falls back to trending songs.
  Future<List<YtTrack>> chartTopVideos({int max = 100}) async {
    try {
      final shelves = await _chartShelves();
      final out =
          shelves.values.expand((e) => e).toList();
      final flat = distinctById(out).take(max).toList();
      if (flat.isNotEmpty) return flat;
    } catch (_) {}
    try {
      return await trendingMusic(max: max > 25 ? 25 : max);
    } catch (_) {
      return [];
    }
  }

  /// Trending music videos: prefer a "video" shelf, else first shelf.
  /// Falls back to resolving chart songs to official videos.
  Future<List<YtTrack>> trendingVideoTracks({int max = 10}) async {
    try {
      final shelves = await _chartShelves(maxShelves: 5, perShelf: max);
      final entries = shelves.entries.toList()
        ..sort((a, b) {
          final av = a.key.toLowerCase().contains('video') ? 1 : 0;
          final bv = b.key.toLowerCase().contains('video') ? 1 : 0;
          return bv.compareTo(av);
        });
      final ranked = entries.expand((e) => e.value).toList();
      final out = distinctById(ranked).take(max).toList();
      if (out.isNotEmpty) return out;
    } catch (_) {}
    try {
      final songs = await trendingMusic(max: 6);
      final out = <YtTrack>[];
      final seen = <String>{};
      for (final s in songs) {
        if (out.length >= max) break;
        try {
          final v = await resolveMusicVideo(s);
          if (v == null || !seen.add(v.id)) continue;
          out.add(v);
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Trending songs: charts shelves → extractor trending fallback is
  /// covered by a popular-music search (kiosk has no explode twin).
  Future<List<YtTrack>> trendingMusic({int max = 15}) async {
    try {
      final shelves =
          await _chartShelves(maxShelves: 3, perShelf: max);
      final flat = distinctById(
              shelves.values.expand((e) => e).toList())
          .take(max)
          .toList();
      if (flat.isNotEmpty) return flat;
    } catch (_) {}
    try {
      return await searchMusic('top hindi songs', max: max);
    } catch (_) {
      return [];
    }
  }

  // ---------- releases / playlists / related / autoplay ----------

  /// New releases: per-artist song searches, round-robin interleaved.
  /// (Channel-feed accuracy rides the InnerTube browse path next slice.)
  Future<List<YtTrack>> newReleases(List<String> artists,
      {int max = 12}) async {
    try {
      final seeds = artists
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && e.toLowerCase() != 'youtube')
          .toSet()
          .take(3)
          .toList();
      if (seeds.isEmpty) {
        return await searchMusic('new hindi songs 2026', max: max);
      }
      final perArtist = <List<YtTrack>>[];
      for (final a in seeds) {
        try {
          perArtist.add(await searchMusic('$a songs', max: 5));
        } catch (_) {
          perArtist.add([]);
        }
      }
      final out = interleaveRoundRobin(perArtist, max: max);
      if (out.isNotEmpty) return out;
      return await searchMusic('new hindi songs 2026', max: max);
    } catch (_) {
      return [];
    }
  }

  /// Curated playlist rail via youtubei browse (VL id). Same song gates.
  Future<List<YtTrack>> playlistTracks(String playlistId,
      {int max = 25}) async {
    try {
      if (playlistId.isEmpty) return [];
      final id =
          playlistId.startsWith('VL') ? playlistId : 'VL$playlistId';
      final json = await _post('browse', browseBody(id, session.visitorData));
      if (json == null) return [];
      final shelves = parseShelves(json, 4, max);
      return distinctById(shelves.values.expand((e) => e).toList())
          .take(max)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// Related graph: RDAMVM radio → plain next column → extractor related.
  Future<List<YtTrack>> relatedTracks(String watchUrl,
      {int max = 12}) async {
    try {
      final id = extractVideoId(watchUrl);
      if (id == null) return [];
      if (session.useInnerTube) {
        try {
          final radio = await _post(
            'next',
            nextBody(id, session.visitorData,
                playlistId: 'RDAMVM$id'),
          );
          if (radio != null) {
            final tracks = parseRadioPanels(radio, id, max);
            if (tracks.length >= max ~/ 2) return tracks.take(max).toList();
            final plain = await _post(
              'next',
              nextBody(id, session.visitorData),
            );
            if (plain != null) {
              final filler = parseRadioPanels(plain, id, max + tracks.length);
              final seen = tracks.map((e) => e.id).toSet();
              for (final t in filler) {
                if (seen.add(t.id)) tracks.add(t);
                if (tracks.length >= max) break;
              }
            }
            if (tracks.isNotEmpty) {
              return distinctById(tracks).take(max).toList();
            }
          }
        } catch (_) {}
      }
      return await _explodeRelated(id, max: max);
    } catch (_) {
      return [];
    }
  }

  Future<List<YtTrack>> _explodeRelated(String id, {int max = 12}) async {
    try {
      final video = await _explode.videos.get(id).timeout(browseTimeout);
      final rel = await _explode.videos
          .getRelatedVideos(video)
          .timeout(browseTimeout);
      if (rel == null) return [];
      final out = <YtTrack>[];
      final seen = <String>{};
      for (final v in rel) {
        try {
          final t = _trackFromVideo(v);
          if (t == null || !seen.add(t.id)) continue;
          out.add(t);
          if (out.length >= max) break;
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Endless autoplay queue fill: related graph + ONE artist-radio filler,
  /// same hard rules (seed/same-name out, max 2/artist), mood-ranked.
  Future<List<YtTrack>> autoplayFor(YtTrack seed, {int max = 20}) async {
    try {
      final rel = await relatedTracks(seed.watchUrl, max: max + 10);
      List<YtTrack> filler = [];
      final low = seed.artist.toLowerCase().trim();
      final labelish = low.isEmpty ||
          const {
            'youtube',
            'song',
            'songs',
            'episode',
            'episodes',
            'podcast'
          }.contains(low) ||
          low.contains('music') ||
          low.contains('official') ||
          low.contains('films') ||
          low.contains('records');
      if (!labelish) {
        try {
          filler = await searchMusic('${seed.artist} songs', max: 10);
        } catch (_) {}
      }
      return buildAutoplay(seed, rel, filler, max: max);
    } catch (_) {
      return [];
    }
  }

  /// Music→video switch for video mode (Phase 3 hook): seed already looks
  /// like a video → itself; else best distinct official-video hit.
  Future<YtTrack?> resolveMusicVideo(YtTrack seed, {int max = 10}) async {
    try {
      if (seed.title.isEmpty) return null;
      final low = seed.title.toLowerCase();
      if (low.contains('official video') ||
          low.contains('music video') ||
          low.contains('official mv') ||
          RegExp(r'\bmv\b').hasMatch(low)) {
        return seed;
      }
      final pool = <YtTrack>[];
      final seen = <String>{};
      for (final q in [
        '${seed.title} ${seed.artist} official music video',
        '${seed.title} ${seed.artist} music video',
      ]) {
        try {
          for (final h in await searchMusic(q, max: max)) {
            if (seen.add(h.id)) pool.add(h);
          }
          if (pool.any((t) => _videoScore(seed, t) >= 10)) break;
        } catch (_) {}
      }
      final ranked = pool.where((t) => t.id != seed.id).toList()
        ..sort((a, b) =>
            _videoScore(seed, b).compareTo(_videoScore(seed, a)));
      for (final t in ranked) {
        if (_videoScore(seed, t) > 0) return t;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  int _videoScore(YtTrack seed, YtTrack cand) {
    try {
      var s = 0;
      final st = seed.title.toLowerCase();
      final ct = cand.title.toLowerCase();
      for (final w in st.split(RegExp(r'\s+')).where((e) => e.length > 3)) {
        if (ct.contains(w)) s += 2;
      }
      if (ct.contains('official')) s += 3;
      if (ct.contains('music video') || ct.contains('mv')) s += 2;
      if (cand.artist.toLowerCase() == seed.artist.toLowerCase()) s += 2;
      return s;
    } catch (_) {
      return 0;
    }
  }

  // ---------- disk snapshots (instant-first UI, S1/H8) ----------

  Future<void> saveSnapshot(String key, List<YtTrack> tracks) async {
    try {
      final dir = cacheDir;
      if (dir == null) return;
      final f = File('${dir.path}/${songCacheFile(key)}');
      await f.writeAsString(jsonEncode(
          songListToJson(tracks, DateTime.now().millisecondsSinceEpoch)));
    } catch (_) {}
  }

  Future<List<YtTrack>?> loadSnapshot(String key, int ttlMs) async {
    try {
      final dir = cacheDir;
      if (dir == null) return null;
      final f = File('${dir.path}/${songCacheFile(key)}');
      if (!await f.exists()) return null;
      final root = jsonDecode(await f.readAsString());
      if (root is! Map) return null;
      return songListFromJson(root.cast<String, dynamic>(), ttlMs);
    } catch (_) {
      return null;
    }
  }

  // ---------- extractor mapping (S3 gates, shared with pagers) ----------

  /// Extractor Video → track, or null. Same gates as every other source
  /// (duration 30s–10min, lives, junk, distinct handled by caller).
  YtTrack? _trackFromVideo(Video v) {
    try {
      final id = v.id.value;
      if (id.length != 11) return null;
      try {
        if (v.isLive) return null;
      } catch (_) {}
      final secs = v.duration?.inSeconds ?? 0;
      if (secs < 30 || secs > 600) return null;
      final title = v.title;
      final artist = v.author.trim().isEmpty ? 'YouTube' : v.author.trim();
      if (isMusicJunk(title, artist)) return null;
      String thumb = '';
      try {
        thumb = sharpThumb(v.thumbnails.highResUrl);
      } catch (_) {}
      return YtTrack(
        id: id,
        title: title,
        artist: artist,
        thumbUrl: thumb,
        watchUrl: 'https://www.youtube.com/watch?v=$id',
      );
    } catch (_) {
      return null;
    }
  }
}
