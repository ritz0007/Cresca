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
import '../core/search_failures.dart';
import '../core/track.dart';
import 'cache.dart';
import 'innertube.dart';
import 'resolve.dart';

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

/// Taste fetch bounds: each related pull caps at 8s, a whole Top Picks
/// assembly at 25s. Slow seeds degrade to an empty contribution, never a
/// stalled homescreen — compute stays off the hot path via the async
/// rankers in discovery.dart.
const Duration tasteFetchTimeout = Duration(seconds: 8);
const Duration tasteOverallTimeout = Duration(seconds: 25);

/// Official-video search cap: each tier (InnerTube, extractor) gets 8s;
/// the embed additionally bounds the whole resolve at 8s, so a dead
/// search never stalls the spinner slot.
const Duration mvSearchTimeout = Duration(seconds: 8);

/// Top Picks assembly: at most this many recent seeds × this many related
/// each, pooled to [topPicksPoolCap] (10 × 4 → 36; 20 shown, room to rotate).
const int topPicksSeedCap = 10;
const int topPicksPerSeed = 4;
const int topPicksPoolCap = 36;

/// Taste profile snapshot file (affinities persist across restarts).
const String tasteSnapshotFile = 'taste.json';

/// Recommendation-blend memo: per-seed merged server-signal pools live
/// 30m (server expands the pool; local taste re-ranks fresh every call,
/// so a stale pool never means stale ranking). Capped; single-flight;
/// empties negative-cache briefly. All guarded, never throws.
const int recoBlendTtlMs = 30 * 60 * 1000;
const int recoBlendCap = 20;

/// Merged server-signal pool for one seed: tracks + multi-source
/// agreement (id -> sources-1) feeding the quadratic co-occurrence term.
class RecoBlend {
  final List<YtTrack> pool;
  final Map<String, double> coOcc;
  const RecoBlend(this.pool, this.coOcc);
  const RecoBlend.empty() : pool = const [], coOcc = const {};
}

/// Blend memo row: merged pool + agreement + write time.
class _BlendRow {
  final List<YtTrack> pool;
  final Map<String, double> coOcc;
  final int atMs;
  _BlendRow(List<YtTrack> p, Map<String, double> c, this.atMs)
      : pool = List<YtTrack>.of(p),
        coOcc = Map<String, double>.of(c);
}

class YoutubeRepository {
  final http.Client _http;
  final RepoSession session;
  final Directory? cacheDir;
  YoutubeExplode? _yt;

  // ---------- snapshot / memo layer (T4/T5 + NEG) ----------
  //
  // Budgets (full matrix in lib/data/cache.dart): mem 50 keys x 100
  // tracks (home 12h / search 30m / trending 7d TTLs, same as disk);
  // disk yt_<key>.json v2 {v,savedAt,items} each <~200KB. Rules:
  // mem-hit serves instantly (zero disk IO, zero RTT); stale mem serves
  // once while disk refreshes behind (SWR); identical concurrent loads
  // join one disk read (single-flight); empty saves record a short
  // negative instead of a disk write (no re-hit churn). All guarded,
  // never throws.
  final Map<String, _SnapRow> _memSnaps = {};
  final Map<String, Future<List<YtTrack>?>> _snapFlight = {};
  final Map<String, int> _snapEmptyAt = {};

  // Search/home network memo (repeat visits = zero RTT for fresh data):
  // query -> rows. Search 30m, home/browse 12h, single-flight, 5m
  // negative on empty. Background refresh-behind keeps hot rows warm.
  final Map<String, _SnapRow> _queryMemo = {};
  final Map<String, Future<List<YtTrack>>> _queryFlight = {};
  final Map<String, Future<Map<String, List<YtTrack>>>> _homeFlight = {};
  // U6: keys whose last search fetch failed at transport (never cached,
  // cleared by the next successful fetch). searchNow consults this so
  // offline reads as error, never as empty.
  final SearchFailureLedger searchFailures = SearchFailureLedger();
  static const int _queryMemoCap = 50;
  static const int _homeMemoCap = 8;

  // Recommendation-blend memo (server signals per seed): merged pool +
  // multi-source agreement, 30m TTL, single-flight, brief negative on
  // empty. Same guarded patterns as the search/home memos above; the
  // pool only EXPANDS candidates — ranking stays local (taste re-ranks
  // every call), so staleness can never strand the queue.
  final Map<String, _BlendRow> _blendMemo = {};
  final Map<String, Future<RecoBlend>> _blendFlight = {};
  final Map<String, Future<List<YtTrack>>> _artistFlight = {};
  final Map<String, Future<List<YtTrack>>> _moodFlight = {};

  void _memoStore(Map<String, _SnapRow> memo, String key,
      List<YtTrack> tracks, int nowMs, int cap) {
    try {
      if (key.isEmpty) return;
      final capped = tracks.length > songMemCapTracks
          ? tracks.sublist(0, songMemCapTracks)
          : List<YtTrack>.of(tracks);
      memo[key] = _SnapRow(capped, nowMs);
      while (memo.length > cap) {
        memo.remove(memo.keys.first);
      }
    } catch (_) {}
  }

  List<YtTrack>? _memoFresh(
      Map<String, _SnapRow> memo, String key, int ttlMs, int nowMs) {
    try {
      final hit = memo[key];
      if (hit == null || hit.tracks.isEmpty) return null;
      if (nowMs - hit.atMs > ttlMs) return null;
      return List<YtTrack>.of(hit.tracks);
    } catch (_) {
      return null;
    }
  }

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

  /// Logout wipe: drops every in-memory memo (search/home/blend/snaps/
  /// music-video) so no session-bound rows survive. Never throws.
  void clearSessionMemos() {
    try {
      _memSnaps.clear();
      _queryMemo.clear();
      _homeMapMemo.clear();
      _blendMemo.clear();
      _mvMemo.clear();
      _mvAt.clear();
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
  /// Memoized: repeat queries inside [searchCacheTtlMs] serve instantly
  /// (zero RTT) with a refresh-behind so hot rows never go cold; empty
  /// results negative-cache 5m; concurrent identical queries join one
  /// fetch (single-flight). Same signature; never throws.
  Future<List<YtTrack>> searchMusic(String query, {int max = 15}) async {
    try {
      final q = query.trim();
      if (q.isEmpty) return [];
      final now = DateTime.now().millisecondsSinceEpoch;
      final key = 'q:${q.toLowerCase()}|$max';
      try {
        final hit = _memoFresh(_queryMemo, key, searchCacheTtlMs, now);
        if (hit != null) {
          // Refresh-behind: stay instant, revalidate for next visit.
          try {
            final at = _queryMemo[key]?.atMs ?? now;
            if (now - at > searchCacheTtlMs ~/ 2) {
              unawaited(_searchMusicFresh(q, max: max).then((fresh) {
                try {
                  if (fresh.isNotEmpty) {
                    _memoStore(
                        _queryMemo, key, fresh, DateTime.now().millisecondsSinceEpoch, _queryMemoCap);
                  }
                } catch (_) {}
              }).catchError((_) {}));
            }
          } catch (_) {}
          return hit;
        }
        // Negative: recently-empty query fails fast, zero RTT.
        final neg = _snapEmptyAt['search:$key'];
        if (neg != null && now - neg <= negativeTtlMs) return [];
      } catch (_) {}
      final existing = _queryFlight[key];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {
          return [];
        }
      }
      final mine = _searchMusicFresh(q, max: max);
      _queryFlight[key] = mine;
      try {
        while (_queryFlight.length > _queryMemoCap) {
          _queryFlight.remove(_queryFlight.keys.first);
        }
      } catch (_) {}
      List<YtTrack> out;
      // Transport failures are recorded, never cached: Retry re-fetches,
      // so a recovered network paints instead of serving the failure
      // again (U6: offline reads as error, never as empty).
      var transportFailed = false;
      try {
        out = await mine;
      } catch (_) {
        out = [];
        transportFailed = true;
      } finally {
        try {
          if (_queryFlight[key] == mine) _queryFlight.remove(key);
        } catch (_) {}
      }
      try {
        if (transportFailed) {
          searchFailures.noteFailure(key);
        } else {
          searchFailures.noteSuccess(key);
          if (out.isNotEmpty) {
            _memoStore(_queryMemo, key, out,
                DateTime.now().millisecondsSinceEpoch, _queryMemoCap);
          } else {
            _snapEmptyAt['search:$key'] =
                DateTime.now().millisecondsSinceEpoch;
            while (_snapEmptyAt.length > negativeCap) {
              _snapEmptyAt.remove(_snapEmptyAt.keys.first);
            }
          }
        }
      } catch (_) {}
      return out;
    } catch (_) {
      return [];
    }
  }

  /// True when the last fetch for [query] failed at transport (U6: the
  /// search screen raises Retry instead of empty). Genuine empties clear
  /// the mark, so "No results" still shows when the fetch succeeded.
  /// Never throws.
  bool searchFailed(String query, {int max = 15}) {
    try {
      final q = query.trim();
      if (q.isEmpty) return false;
      return searchFailures.failed('q:${q.toLowerCase()}|$max');
    } catch (_) {
      return false;
    }
  }

  /// Genuine network fetch behind [searchMusic]'s memo. Same contract as
  /// the old searchMusic body; never throws.
  Future<List<YtTrack>> _searchMusicFresh(String query, {int max = 15}) async {
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

  /// Endless pager for See All (H11). Caller drains via loadMore().
  SearchPager searchPager(String query, {int pageSize = 20}) =>
      SearchPager(_explode, query, pageSize: pageSize);

  /// Logged-in library pull (liked songs + history) for taste seeds.
  /// Authed browse; empty when logged out or on any failure. Caller
  /// persists + feeds recommendation seeds — never merges into local
  /// liked/recent.
  Future<(List<YtTrack>, List<YtTrack>)> ytLibrary({int max = 50}) async {
    try {
      if (session.cookies.isEmpty) return (<YtTrack>[], <YtTrack>[]);
      Future<List<YtTrack>> pull(String browseId) async {
        try {
          final json = await _post(
            'browse',
            browseBody(browseId, session.visitorData),
          );
          if (json == null) return [];
          return parseShelves(json, 4, 25)
              .values
              .expand((e) => e)
              .toList();
        } catch (_) {
          return [];
        }
      }

      final liked =
          distinctById(await pull('FEmusic_liked')).take(max).toList();
      final history =
          distinctById(await pull('FEmusic_history')).take(max).toList();
      return (liked, history);
    } catch (_) {
      return (<YtTrack>[], <YtTrack>[]);
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
  /// Memoized 12h ([homeCacheTtlMs]): repeat home visits serve instantly
  /// (zero RTT) with refresh-behind past half-TTL; concurrent callers
  /// join one browse (single-flight). Same signature; never throws.
  Future<Map<String, List<YtTrack>>> homeShelves({
    int maxShelves = 8,
    int perShelf = 12,
  }) async {
    try {
      if (!session.useInnerTube) return {};
      final now = DateTime.now().millisecondsSinceEpoch;
      final key = 'home:$maxShelves|$perShelf';
      try {
        final mhit = _homeMapMemo[key];
        if (mhit != null && now - mhit.atMs <= homeCacheTtlMs) {
          try {
            if (now - mhit.atMs > homeCacheTtlMs ~/ 2) {
              unawaited(_homeShelvesFresh(
                      maxShelves: maxShelves, perShelf: perShelf)
                  .then((fresh) {
                try {
                  if (fresh.isNotEmpty) {
                    _homeMapMemo[key] = _HomeMapRow(
                        fresh, DateTime.now().millisecondsSinceEpoch);
                    while (_homeMapMemo.length > _homeMemoCap) {
                      _homeMapMemo.remove(_homeMapMemo.keys.first);
                    }
                  }
                } catch (_) {}
              }).catchError((_) {}));
            }
          } catch (_) {}
          return {
            for (final e in mhit.shelves.entries)
              e.key: List<YtTrack>.of(e.value),
          };
        }
      } catch (_) {}
      final existing = _homeFlight[key];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {
          return {};
        }
      }
      final mine =
          _homeShelvesFresh(maxShelves: maxShelves, perShelf: perShelf);
      _homeFlight[key] = mine;
      try {
        while (_homeFlight.length > _homeMemoCap) {
          _homeFlight.remove(_homeFlight.keys.first);
        }
      } catch (_) {}
      Map<String, List<YtTrack>> out;
      try {
        out = await mine;
      } catch (_) {
        out = {};
      } finally {
        try {
          if (_homeFlight[key] == mine) _homeFlight.remove(key);
        } catch (_) {}
      }
      try {
        if (out.isNotEmpty) {
          _homeMapMemo[key] =
              _HomeMapRow(out, DateTime.now().millisecondsSinceEpoch);
          while (_homeMapMemo.length > _homeMemoCap) {
            _homeMapMemo.remove(_homeMapMemo.keys.first);
          }
        }
      } catch (_) {}
      return out;
    } catch (_) {
      return {};
    }
  }

  final Map<String, _HomeMapRow> _homeMapMemo = {};

  /// Genuine network fetch behind [homeShelves]' memo. Same contract as
  /// the old homeShelves body; never throws.
  Future<Map<String, List<YtTrack>>> _homeShelvesFresh({
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

  /// Playlist cards from YTM kiosks (home + charts): (shelf, card,
  /// browseId) for playable playlist shelves ("Trending 20 India",
  /// "New releases" style). Caller resolves via playlistTracks.
  Future<List<(String, String, String)>> browsePlaylistCards(
      {int maxCards = 4}) async {
    final out = <(String, String, String)>[];
    try {
      if (!session.useInnerTube) return out;
      for (final kiosk in ['FEmusic_home', 'FEmusic_charts']) {
        try {
          final json = await _post(
            'browse',
            browseBody(kiosk, session.visitorData),
          );
          if (json == null) continue;
          for (final c in parsePlaylistCards(json,
              maxCards: maxCards - out.length)) {
            if (out.any((e) => e.$3 == c.$3)) continue;
            out.add(c);
            if (out.length >= maxCards) return out;
          }
        } catch (_) {}
      }
    } catch (_) {}
    return out;
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
      for (var i = 0; i < songs.length && out.length < max; i += 3) {
        try {
          final batch = await Future.wait([
            for (final s in songs.skip(i).take(3))
              resolveMusicVideoTrack(s).catchError((_) => null),
          ]);
          for (final v in batch) {
            if (out.length >= max) break;
            try {
              if (v == null || !seen.add(v.id)) continue;
              out.add(v);
            } catch (_) {}
          }
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
      final perArtist = await Future.wait([
        for (final a in seeds)
          searchMusic('$a songs', max: 5).catchError((_) => <YtTrack>[]),
      ]);
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
      final out =
          distinctById(shelves.values.expand((e) => e).toList());
      if (out.isNotEmpty) return out.take(max).toList();
      // Community/playlist shelves nest bare responsive items without
      // a shelf wrapper (VLPL responses) — collect them directly.
      return distinctById(parsePlaylistItems(json, max))
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

  /// Artist-radio leg: the artist's top songs as their own scored source
  /// (multi-source agreement counts — a track in both the related mix
  /// AND artist radio is evidence). Label-ish/blank artists return []
  /// (no singer to build radio from). Memoized per artist (30m),
  /// single-flight, [fetchTimeout]-bounded, never throws.
  Future<List<YtTrack>> artistRadioFor(
    String artist, {
    int max = 10,
    Duration fetchTimeout = tasteFetchTimeout,
  }) async {
    try {
      final a = artist.trim();
      if (a.isEmpty || max <= 0) return [];
      final low = a.toLowerCase();
      if (const {
            'youtube',
            'song',
            'songs',
            'episode',
            'episodes',
            'podcast',
            'unknown artist',
          }.contains(low) ||
          low.contains('music') ||
          low.contains('official') ||
          low.contains('films') ||
          low.contains('records')) {
        return [];
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final key = 'artist:$low|$max';
      try {
        final hit = _memoFresh(_queryMemo, 'radio:$key', recoBlendTtlMs, now);
        if (hit != null) return hit;
        final neg = _snapEmptyAt['radio:$key'];
        if (neg != null && now - neg <= negativeTtlMs) return [];
      } catch (_) {}
      final existing = _artistFlight[key];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {
          return [];
        }
      }
      final mine = searchMusic('$a songs', max: max)
          .timeout(fetchTimeout, onTimeout: () => <YtTrack>[]);
      _artistFlight[key] = mine;
      List<YtTrack> out;
      try {
        out = await mine;
      } catch (_) {
        out = [];
      } finally {
        try {
          if (_artistFlight[key] == mine) _artistFlight.remove(key);
        } catch (_) {}
      }
      try {
        if (out.isNotEmpty) {
          _memoStore(_queryMemo, 'radio:$key', out,
              DateTime.now().millisecondsSinceEpoch, _queryMemoCap);
        } else {
          _snapEmptyAt['radio:$key'] =
              DateTime.now().millisecondsSinceEpoch;
          while (_snapEmptyAt.length > negativeCap) {
            _snapEmptyAt.remove(_snapEmptyAt.keys.first);
          }
        }
      } catch (_) {}
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Genre/mood seed leg: [vibeQueries] searches (mood-first, NOT singer
  /// radio — same energy/genre/era/language), ≤2 queries × [perQuery]
  /// hits. Memoized per seed (30m), single-flight, [fetchTimeout]-
  /// bounded, never throws.
  Future<List<YtTrack>> moodSeedsFor(
    YtTrack seed, {
    int max = 12,
    int perQuery = 6,
    Duration fetchTimeout = tasteFetchTimeout,
  }) async {
    try {
      if (seed.id.isEmpty || max <= 0) return [];
      final now = DateTime.now().millisecondsSinceEpoch;
      final key = 'mood:${seed.id}|$max';
      try {
        final hit = _memoFresh(_queryMemo, key, recoBlendTtlMs, now);
        if (hit != null) return hit;
        final neg = _snapEmptyAt[key];
        if (neg != null && now - neg <= negativeTtlMs) return [];
      } catch (_) {}
      final existing = _moodFlight[key];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {
          return [];
        }
      }
      List<String> queries = const [];
      try {
        queries = vibeQueries(seed);
      } catch (_) {
        queries = const [];
      }
      if (queries.isEmpty) return [];
      final mine = _moodSeedsFresh(seed, queries.take(2).toList(),
          max: max, perQuery: perQuery, fetchTimeout: fetchTimeout);
      _moodFlight[key] = mine;
      List<YtTrack> out;
      try {
        out = await mine;
      } catch (_) {
        out = [];
      } finally {
        try {
          if (_moodFlight[key] == mine) _moodFlight.remove(key);
        } catch (_) {}
      }
      try {
        if (out.isNotEmpty) {
          _memoStore(_queryMemo, key, out,
              DateTime.now().millisecondsSinceEpoch, _queryMemoCap);
        } else {
          _snapEmptyAt[key] = DateTime.now().millisecondsSinceEpoch;
          while (_snapEmptyAt.length > negativeCap) {
            _snapEmptyAt.remove(_snapEmptyAt.keys.first);
          }
        }
      } catch (_) {}
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Genuine fetch behind [moodSeedsFor]'s memo: the vibe queries fly
  /// concurrently (≤2), each [fetchTimeout]-bounded. Never throws.
  Future<List<YtTrack>> _moodSeedsFresh(
    YtTrack seed,
    List<String> queries, {
    int max = 12,
    int perQuery = 6,
    Duration fetchTimeout = tasteFetchTimeout,
  }) async {
    try {
      if (queries.isEmpty) return [];
      final results = await Future.wait([
        for (final q in queries)
          searchMusic(q, max: perQuery)
              .timeout(fetchTimeout, onTimeout: () => <YtTrack>[]),
      ]);
      final out = <YtTrack>[];
      final seen = <String>{seed.id};
      for (final hits in results) {
        for (final h in hits) {
          if (out.length >= max) break;
          if (h.id.isEmpty || !seen.add(h.id)) continue;
          out.add(h);
        }
        if (out.length >= max) break;
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Merged server-signal pool for one seed: song-radio mix (RDAMVM) +
  /// watch-next column + artist radio + mood seeds, fanned out
  /// CONCURRENTLY (≤3 network legs), each [fetchTimeout]-bounded. Tracks
  /// appearing under 2+ sources earn agreement weight (sources − 1) for
  /// the quadratic co-occurrence term — YouTube's graph corroborating
  /// itself. Memoized per seed (30m) + single-flight; the pool only
  /// expands candidates (local taste re-ranks), so staleness is safe.
  /// Never throws; empty blend on any failure.
  Future<RecoBlend> serverBlendFor(
    YtTrack seed, {
    int max = 30,
    Duration fetchTimeout = tasteFetchTimeout,
  }) async {
    try {
      if (seed.id.isEmpty || max <= 0) return const RecoBlend.empty();
      final now = DateTime.now().millisecondsSinceEpoch;
      try {
        final hit = _blendMemo['${seed.id}|$max'];
        if (hit != null && now - hit.atMs <= recoBlendTtlMs) {
          return RecoBlend(List.of(hit.pool), Map.of(hit.coOcc));
        }
      } catch (_) {}
      final key = '${seed.id}|$max';
      final existing = _blendFlight[key];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {
          return const RecoBlend.empty();
        }
      }
      final mine = _serverBlendFresh(seed,
          max: max, fetchTimeout: fetchTimeout);
      _blendFlight[key] = mine;
      try {
        while (_blendFlight.length > recoBlendCap) {
          _blendFlight.remove(_blendFlight.keys.first);
        }
      } catch (_) {}
      RecoBlend out;
      try {
        out = await mine;
      } catch (_) {
        out = const RecoBlend.empty();
      } finally {
        try {
          if (_blendFlight[key] == mine) _blendFlight.remove(key);
        } catch (_) {}
      }
      try {
        if (out.pool.isNotEmpty) {
          _blendMemo[key] =
              _BlendRow(out.pool, out.coOcc, DateTime.now().millisecondsSinceEpoch);
          while (_blendMemo.length > recoBlendCap) {
            _blendMemo.remove(_blendMemo.keys.first);
          }
        }
      } catch (_) {}
      return out;
    } catch (_) {
      return const RecoBlend.empty();
    }
  }

  /// Genuine fetch behind [serverBlendFor]'s memo + single-flight: three
  /// legs fly in one Future.wait (related mix, artist radio, mood
  /// seeds), each self-bounded, merged deduped with source-agreement
  /// counts. Never throws.
  Future<RecoBlend> _serverBlendFresh(
    YtTrack seed, {
    int max = 30,
    Duration fetchTimeout = tasteFetchTimeout,
  }) async {
    try {
      final results = await Future.wait([
        relatedTracks(seed.watchUrl, max: max)
            .timeout(fetchTimeout, onTimeout: () => <YtTrack>[]),
        artistRadioFor(seed.artist, max: 10, fetchTimeout: fetchTimeout),
        moodSeedsFor(seed, max: 12, fetchTimeout: fetchTimeout),
      ]);
      final pool = <YtTrack>[];
      final seen = <String>{};
      final sources = <String, int>{};
      for (final list in results) {
        final ids = <String>{};
        for (final t in list) {
          try {
            if (t.id.isEmpty || t.id == seed.id) continue;
            ids.add(t.id);
            if (seen.add(t.id)) pool.add(t);
          } catch (_) {}
        }
        for (final id in ids) {
          sources[id] = (sources[id] ?? 0) + 1;
        }
      }
      final coOcc = <String, double>{
        for (final e in sources.entries)
          if (e.value > 1) e.key: (e.value - 1).toDouble(),
      };
      return RecoBlend(pool.take(max).toList(), coOcc);
    } catch (_) {
      return const RecoBlend.empty();
    }
  }

  /// Endless autoplay queue fill: server-signal blend (song-radio mix +
  /// artist radio + mood seeds, ≤3 concurrent fetches) re-ranked by local
  /// taste, same hard rules (seed/same-name out, max 2/artist).
  ///
  /// Taste mode: pass [taste] (built via buildTasteProfile or loaded with
  /// loadTaste) plus [queueIds] to dedupe against the visible queue and
  /// [skipIds] to penalize skips — ranking then uses affinity +
  /// co-occurrence instead of the legacy vibe order. [sessionContext]
  /// (live tail) steers the moment; [skipArtists] buries skipped singers;
  /// [serverBlend]=false restores the legacy related+filler path; every
  /// fetch is timeout-bounded ([fetchTimeout]); ranking runs off the hot
  /// path.
  Future<List<YtTrack>> autoplayFor(
    YtTrack seed, {
    int max = 20,
    TasteProfile? taste,
    Set<String> queueIds = const {},
    Set<String> skipIds = const {},
    Set<String> likedIds = const {},
    Set<String> recentIds = const {},
    List<YtTrack> sessionContext = const [],
    Set<String> skipArtists = const {},
    bool serverBlend = true,
    bool moodArc = true,
    int? rotationSalt,
    Duration fetchTimeout = tasteFetchTimeout,
  }) async {
    try {
      var graph = <YtTrack>[];
      var coOcc = const <String, double>{};
      if (serverBlend && seed.id.isNotEmpty) {
        // Server signals (YouTube's own graph corroborating itself) +
        // local taste re-rank: the blend expands the pool, taste picks
        // the winners. Whole blend [fetchTimeout]-bounded; thin blends
        // fall through to the filler tier, never stall.
        try {
          final blend = await serverBlendFor(seed,
                  max: max + 10, fetchTimeout: fetchTimeout)
              .timeout(fetchTimeout, onTimeout: () => const RecoBlend.empty());
          graph = List.of(blend.pool);
          coOcc = blend.coOcc;
        } catch (_) {
          graph = <YtTrack>[];
          coOcc = const <String, double>{};
        }
      }
      List<YtTrack> filler = [];
      if (graph.length < max ~/ 2) {
        if (!serverBlend) {
          // Legacy graph tier (blend off): related mix, bounded.
          try {
            graph = await relatedTracks(seed.watchUrl, max: max + 10)
                .timeout(fetchTimeout, onTimeout: () => <YtTrack>[]);
          } catch (_) {
            graph = <YtTrack>[];
          }
        }
        // ONE artist-radio filler when the graph is thin (already
        // caller-filtered for labelish artists).
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
            filler = await searchMusic('${seed.artist} songs', max: 10)
                .timeout(fetchTimeout, onTimeout: () => <YtTrack>[]);
          } catch (_) {}
        }
      }
      // Pure scoring yields off the hot path; never throws.
      return await Future(() => buildAutoplay(
            seed,
            graph,
            filler,
            max: max,
            taste: taste,
            skipIds: skipIds,
            excludeIds: queueIds,
            likedIds: likedIds,
            recentIds: recentIds,
            coOccurrence: coOcc,
            sessionContext: sessionContext,
            skipArtists: skipArtists,
            moodArc: moodArc,
            rotationSalt: rotationSalt,
          )).catchError((_) => <YtTrack>[]);
    } catch (_) {
      return [];
    }
  }

  /// Queue Up Next for [seed]: autoplay fill deduped against the visible
  /// queue ([queueIds]) and skip-penalized. Thin alias over [autoplayFor]
  /// so queue call sites read intent, not plumbing.
  Future<List<YtTrack>> upNextFor(
    YtTrack seed, {
    int max = 20,
    TasteProfile? taste,
    Set<String> queueIds = const {},
    Set<String> skipIds = const {},
    Set<String> likedIds = const {},
    Set<String> recentIds = const {},
    List<YtTrack> sessionContext = const [],
    Set<String> skipArtists = const {},
    bool serverBlend = true,
    bool moodArc = true,
    int? rotationSalt,
  }) =>
      autoplayFor(
        seed,
        max: max,
        taste: taste,
        queueIds: queueIds,
        skipIds: skipIds,
        likedIds: likedIds,
        recentIds: recentIds,
        sessionContext: sessionContext,
        skipArtists: skipArtists,
        serverBlend: serverBlend,
        moodArc: moodArc,
        rotationSalt: rotationSalt,
      );

  /// Endless-queue refill for the CURRENT sounding track: call when
  /// engine.needsRefill() fires (≤2 remaining, for ANY played song).
  /// Tiers, all bounded (battery-kind, ≤3 concurrent network legs, each
  /// [fetchTimeout]-bounded, whole blend [fetchTimeout]-bounded, never
  /// throws):
  /// 1. server-signal blend ([serverBlendFor]: song-radio mix + artist
  ///    radio + mood-query seeds with source-agreement weights).
  /// 2. legacy related graph when the blend is off ([serverBlend]=false).
  /// 3. mood-query searches (vibeQueries — mood-first, NOT artist radio;
  ///    ≤2 queries × 6 hits) when the graph is still thin (< max~/2).
  /// 4. offline [libraryFallback] scored by mood fit (pure, zero net).
  /// Ranks via buildAutoplay (seed/same-name out, ≤2/artist, mood-fit +
  /// affinity + session moment + skip penalties, mood-arc walk), dedupes
  /// [queueIds], hard-drops [skipIds]. Works from a single song (seed
  /// only needs a watchUrl).
  Future<List<YtTrack>> endlessRefillFor(
    YtTrack seed, {
    int max = 20,
    TasteProfile? taste,
    Set<String> queueIds = const {},
    Set<String> skipIds = const {},
    Set<String> likedIds = const {},
    Set<String> recentIds = const {},
    List<YtTrack> sessionContext = const [],
    Set<String> skipArtists = const {},
    bool serverBlend = true,
    bool moodArc = true,
    int? rotationSalt,
    List<YtTrack> libraryFallback = const [],
    Duration fetchTimeout = tasteFetchTimeout,
  }) async {
    try {
      if (seed.id.isEmpty || max <= 0) return [];
      var graph = <YtTrack>[];
      var coOcc = const <String, double>{};
      if (serverBlend) {
        try {
          final blend = await serverBlendFor(seed,
                  max: max + 10, fetchTimeout: fetchTimeout)
              .timeout(fetchTimeout, onTimeout: () => const RecoBlend.empty());
          graph = List.of(blend.pool);
          coOcc = blend.coOcc;
        } catch (_) {
          graph = <YtTrack>[];
          coOcc = const <String, double>{};
        }
      } else {
        try {
          graph = await relatedTracks(seed.watchUrl, max: max + 10)
              .timeout(fetchTimeout, onTimeout: () => <YtTrack>[]);
        } catch (_) {
          graph = <YtTrack>[];
        }
      }
      // Mood-query tier (NOT artist radio): same energy/genre/era/
      // language via vibeQueries when the graph is thin. The memoized
      // leg makes repeats zero-RTT (blend already ran it); raw searches
      // stay fetchTimeout-capped; failures degrade silently.
      try {
        if (graph.length < max ~/ 2) {
          final seenGraph = <String>{for (final t in graph) t.id};
          try {
            final memo = await moodSeedsFor(seed, max: 12)
                .timeout(fetchTimeout, onTimeout: () => <YtTrack>[]);
            for (final h in memo) {
              if (graph.length >= max + 10) break;
              if (seenGraph.add(h.id)) graph.add(h);
            }
          } catch (_) {}
          if (graph.length < max ~/ 2) {
            List<String> queries = const [];
            try {
              queries = vibeQueries(seed);
            } catch (_) {
              queries = const [];
            }
            for (final q in queries.take(2)) {
              if (graph.length >= max + 10) break;
              try {
                final hits = await searchMusic(q, max: 6)
                    .timeout(fetchTimeout, onTimeout: () => <YtTrack>[]);
                for (final h in hits) {
                  if (graph.length >= max + 10) break;
                  if (seenGraph.add(h.id)) graph.add(h);
                }
              } catch (_) {}
            }
          }
        }
      } catch (_) {}
      // Offline library tier: mood-scored locally, zero network.
      final libFill = <YtTrack>[];
      try {
        if (graph.length < max ~/ 2 && libraryFallback.isNotEmpty) {
          final exclude = <String>{
            seed.id,
            ...queueIds,
            for (final t in graph) t.id,
          };
          final scored = <(double, YtTrack)>[];
          for (final c in libraryFallback) {
            try {
              if (c.id.isEmpty || exclude.contains(c.id)) continue;
              if (skipIds.contains(c.id)) continue;
              if (isSameName(c, seed)) continue;
              scored.add((moodFitScore(seed, c), c));
            } catch (_) {}
          }
          scored.sort((a, b) => b.$1.compareTo(a.$1));
          final perArtist = <String, int>{};
          for (final e in scored) {
            if (libFill.length >= max) break;
            try {
              final key = e.$2.artist.toLowerCase();
              final n = (perArtist[key] ?? 0) + 1;
              if (n > 2) continue;
              perArtist[key] = n;
              libFill.add(e.$2);
            } catch (_) {}
          }
        }
      } catch (_) {}
      final merged = distinctById([...graph, ...libFill]);
      if (merged.isEmpty) return [];
      // Pure scoring yields off the hot path; never throws.
      return await Future(() => buildAutoplay(
            seed,
            merged,
            const [],
            max: max,
            taste: taste,
            skipIds: skipIds,
            excludeIds: queueIds,
            likedIds: likedIds,
            recentIds: recentIds,
            coOccurrence: coOcc,
            sessionContext: sessionContext,
            skipArtists: skipArtists,
            moodArc: moodArc,
            rotationSalt: rotationSalt,
          )).catchError((_) => <YtTrack>[]);
    } catch (_) {
      return [];
    }
  }

  /// Taste-matched Top Picks from recent plays: the last [maxSeeds] seeds
  /// contribute [perSeed] related tracks each (concurrent batches of 3 —
  /// bounded fan-out, each leg [fetchTimeout]-bounded, whole assembly by
  /// [overallTimeout] — native topVibe shape), then [rankTopPicksAsync]
  /// scores the pool by recency-weighted affinity + superlinear
  /// co-occurrence (tracks surfacing under several seeds win),
  /// with dedupe, skip penalties, diversity caps, mood-arc walk and
  /// freshness rotation. [sessionContext] (live tail) steers the moment;
  /// [skipArtists] buries skipped singers. Returns [] when taste is too
  /// thin (< 2 usable seeds); the caller falls back to home tracks.
  /// Never throws.
  Future<List<YtTrack>> topPicksFor(
    List<YtTrack> recent, {
    List<YtTrack>? liked,
    TasteProfile? taste,
    Set<String> skipIds = const {},
    Set<String> shownIds = const {},
    Set<String> skipArtists = const {},
    List<YtTrack> sessionContext = const [],
    bool moodArc = true,
    int max = tasteTopPicksDefault,
    int perSeed = topPicksPerSeed,
    int maxSeeds = topPicksSeedCap,
    int poolCap = topPicksPoolCap,
    int maxPerArtist = tasteTopPicksPerArtist,
    int? rotationSalt,
    Duration fetchTimeout = tasteFetchTimeout,
    Duration overallTimeout = tasteOverallTimeout,
  }) async {
    try {
      return await _topPicks(
        recent,
        liked: liked,
        taste: taste,
        skipIds: skipIds,
        shownIds: shownIds,
        skipArtists: skipArtists,
        sessionContext: sessionContext,
        moodArc: moodArc,
        max: max,
        perSeed: perSeed,
        maxSeeds: maxSeeds,
        poolCap: poolCap,
        maxPerArtist: maxPerArtist,
        rotationSalt: rotationSalt,
        fetchTimeout: fetchTimeout,
      ).timeout(overallTimeout, onTimeout: () => <YtTrack>[]);
    } catch (_) {
      return [];
    }
  }

  Future<List<YtTrack>> _topPicks(
    List<YtTrack> recent, {
    List<YtTrack>? liked,
    TasteProfile? taste,
    Set<String> skipIds = const {},
    Set<String> shownIds = const {},
    Set<String> skipArtists = const {},
    List<YtTrack> sessionContext = const [],
    bool moodArc = true,
    int max = tasteTopPicksDefault,
    int perSeed = topPicksPerSeed,
    int maxSeeds = topPicksSeedCap,
    int poolCap = topPicksPoolCap,
    int maxPerArtist = tasteTopPicksPerArtist,
    int? rotationSalt,
    Duration fetchTimeout = tasteFetchTimeout,
  }) async {
    try {
      final allSeeds = recent
          .where((t) => t.watchUrl.trim().isNotEmpty)
          .toList();
      if (allSeeds.length < 2) return [];
      // Rotate the seed window by salt: every refresh / reopen / revisit
      // pulls related from DIFFERENT recents, so the pool gains
      // genuinely new (still taste-relevant) songs instead of re-ranking
      // the same seeds' pool forever.
      var seeds = allSeeds.take(maxSeeds).toList();
      try {
        final salt = rotationSalt ?? 0;
        if (salt != 0 && allSeeds.length > maxSeeds) {
          final start = salt % allSeeds.length;
          seeds = [
            for (var i = 0; i < maxSeeds; i++)
              allSeeds[(start + i) % allSeeds.length]
          ];
        }
      } catch (_) {}
      final profile = taste ??
          buildTasteProfile(recent: recent, liked: liked ?? const []);
      if (profile.isEmpty) return [];
      final seedIds = seeds.map((e) => e.id).toSet();
      final pool = <YtTrack>[];
      final poolHits = <String, int>{};
      final seenPool = <String>{};
      // Bounded fan-out: batches of 3 concurrent related pulls (were
      // sequential 10 × 8s). Same poolCap/co-occurrence contract, a third
      // of the wall-clock on warm taste.
      for (var i = 0; i < seeds.length; i += 3) {
        try {
          final batch = seeds.skip(i).take(3).toList();
          final results = await Future.wait([
            for (final s in batch)
              relatedTracks(s.watchUrl, max: perSeed + 2)
                  .timeout(fetchTimeout, onTimeout: () => <YtTrack>[]),
          ]);
          for (final rel in results) {
            for (final r in rel.take(perSeed)) {
              if (seedIds.contains(r.id)) continue;
              poolHits[r.id] = (poolHits[r.id] ?? 0) + 1;
              if (seenPool.add(r.id)) pool.add(r);
            }
          }
        } catch (_) {}
        if (pool.length >= poolCap) break;
      }
      if (pool.isEmpty) return [];
      final coOccurrence = <String, double>{
        for (final e in poolHits.entries)
          if (e.value > 1) e.key: (e.value - 1).toDouble(),
      };
      final likedIds = <String>{for (final t in liked ?? const []) t.id};
      return await rankTopPicksAsync(
        pool,
        taste: profile,
        excludeIds: seedIds,
        likedIds: likedIds,
        recentIds: seedIds,
        skipIds: skipIds.isNotEmpty
            ? skipIds
            : profile.skipCounts.keys.toSet(),
        shownIds: shownIds,
        coOccurrence: coOccurrence,
        sessionContext: sessionContext,
        skipArtists: skipArtists,
        moodArc: moodArc,
        max: max,
        maxPerArtist: maxPerArtist,
        rotationSalt:
            rotationSalt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000,
      ).timeout(fetchTimeout, onTimeout: () => <YtTrack>[]);
    } catch (_) {
      return [];
    }
  }

  /// Persist affinities across restarts (taste.json next to the song
  /// snapshots). Silent, atomic, never throws.
  Future<void> saveTaste(TasteProfile taste) async {
    try {
      final dir = cacheDir;
      if (dir == null) return;
      final raw = taste.encode();
      if (raw.isEmpty) return;
      final f = File('${dir.path}/$tasteSnapshotFile');
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(raw);
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
      await tmp.rename(f.path);
    } catch (_) {}
  }

  /// Load persisted affinities (with background global decay so stale
  /// taste fades). Empty profile when absent/corrupt — never throws.
  Future<TasteProfile> loadTaste() async {
    try {
      final dir = cacheDir;
      if (dir == null) return const TasteProfile();
      final f = File('${dir.path}/$tasteSnapshotFile');
      if (!await f.exists()) return const TasteProfile();
      final raw = await f.readAsString();
      return TasteProfile.decode(raw).decayed();
    } catch (_) {
      return const TasteProfile();
    }
  }

  /// Music→video switch for video mode (YTM parity): the official music
  /// video's watch URL for [seed], or '' when none resolves (the embed
  /// falls back to the track's own stream as before). Seed already
  /// looking like a video resolves to itself with no network.
  /// Memoized per track id (memory map, cap ~100, failures included so
  /// a dead search never re-stalls the slot). Every hop 8s-bounded +
  /// silent; never throws.
  Future<String> resolveMusicVideo(YtTrack seed,
      {int seedDurationSec = -1, int max = 10}) async {
    try {
      final t = await resolveMusicVideoTrack(seed,
          seedDurationSec: seedDurationSec, max: max);
      return t?.watchUrl ?? '';
    } catch (_) {
      return '';
    }
  }

  /// Track-object twin of [resolveMusicVideo] (trending rail needs the
  /// video row, not just its URL). Same memo, same scoring, same caps.
  /// InnerTube + extractor tiers fly IN PARALLEL (were sequential 8s +
  /// 8s), each 8s-bounded; the best acceptable candidate across both
  /// tiers wins (ties → InnerTube, matching the old strong-hit order).
  /// Concurrent callers join one resolve (single-flight). Same
  /// signature; never throws.
  Future<YtTrack?> resolveMusicVideoTrack(YtTrack seed,
      {int seedDurationSec = -1, int max = 10}) async {
    try {
      if (seed.id.isEmpty || seed.title.trim().isEmpty) return null;
      try {
        if (_mvMemo.containsKey(seed.id)) {
          final at = _mvAt[seed.id] ?? 0;
          final age = DateTime.now().millisecondsSinceEpoch - at;
          final ttl =
              _mvMemo[seed.id] == null ? _mvNegTtlMs : homeCacheTtlMs;
          if (age <= ttl) return _mvMemo[seed.id];
          _mvMemo.remove(seed.id);
          _mvAt.remove(seed.id);
        }
      } catch (_) {}
      final flightKey = '${seed.id}|$max';
      final existing = _mvFlight[flightKey];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {
          return null;
        }
      }
      final mine = _resolveMusicVideoFresh(seed,
          seedDurationSec: seedDurationSec, max: max);
      _mvFlight[flightKey] = mine;
      try {
        while (_mvFlight.length > 50) {
          _mvFlight.remove(_mvFlight.keys.first);
        }
      } catch (_) {}
      YtTrack? out;
      try {
        out = await mine;
      } catch (_) {
        out = null;
      } finally {
        try {
          if (_mvFlight[flightKey] == mine) {
            _mvFlight.remove(flightKey);
          }
        } catch (_) {}
      }
      try {
        _mvMemo[seed.id] = out;
        _mvAt[seed.id] = DateTime.now().millisecondsSinceEpoch;
        while (_mvMemo.length > 100) {
          final oldest = _mvMemo.keys.first;
          _mvMemo.remove(oldest);
          _mvAt.remove(oldest);
        }
      } catch (_) {}
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Genuine network resolve behind [resolveMusicVideoTrack]'s memo +
  /// single-flight. Both search tiers fly in parallel, each
  /// [mvSearchTimeout]-bounded + silent. Never throws.
  Future<YtTrack?> _resolveMusicVideoFresh(YtTrack seed,
      {int seedDurationSec = -1, int max = 10}) async {
    try {
      // Already a video upload: itself, no search.
      final low = seed.title.toLowerCase();
      if (low.contains('official video') ||
          low.contains('music video') ||
          low.contains('official mv') ||
          RegExp(r'(^|[^a-z])mv([^a-z]|$)').hasMatch(low)) {
        return seed;
      }
      final query = musicVideoQuery(seed);
      if (query.isEmpty) return null;
      // Tier 1: InnerTube, UNFILTERED — videos wanted, so the songs-only
      // params must NOT apply here (they would hide the video rows).
      // Tier 2: extractor video search — carries true durations + channel
      // names, so duration (±15s) and VEVO scoring apply in full.
      // Parallel: worst ~8s either way instead of 8s + 8s stacked.
      List<(YtTrack, int)> scored = const [];
      try {
        final both = await Future.wait([
          _mvInnerTube(seed, query, seedDurationSec, max)
              .timeout(mvSearchTimeout)
              .catchError((_) => const <(YtTrack, int)>[]),
          _mvExtractor(seed, query, seedDurationSec)
              .timeout(mvSearchTimeout)
              .catchError((_) => const <(YtTrack, int)>[]),
        ]);
        // InnerTube listed first: ties keep the old strong-hit order.
        scored = [...both[0], ...both[1]];
      } catch (_) {
        scored = const [];
      }
      YtTrack? best;
      var bestScore = 0;
      for (final e in scored) {
        try {
          if (_mvAcceptable(seed, e.$1, e.$2) &&
              (best == null || e.$2 > bestScore)) {
            best = e.$1;
            bestScore = e.$2;
          }
        } catch (_) {}
      }
      return best;
    } catch (_) {
      return null;
    }
  }

  /// InnerTube tier of the official-video search: scored candidates,
  /// unsorted (caller picks the best acceptable). Never throws.
  Future<List<(YtTrack, int)>> _mvInnerTube(
      YtTrack seed, String query, int seedDurationSec, int max) async {
    final out = <(YtTrack, int)>[];
    try {
      if (!session.useInnerTube) return out;
      final json = await _post(
        'search',
        searchBody(query, session.visitorData, songsOnly: false),
        timeout: mvSearchTimeout,
      );
      if (json == null) return out;
      for (final t in parseSearch(json, max)) {
        try {
          if (t.id == seed.id) continue;
          final sc = scoreMusicVideoCandidate(
            seedTitle: seed.title,
            seedArtist: seed.artist,
            candTitle: t.title,
            candArtist: t.artist,
            seedDurationSec: seedDurationSec,
          );
          if (_mvAcceptable(seed, t, sc)) out.add((t, sc));
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  /// Extractor tier of the official-video search: scored candidates,
  /// unsorted (caller picks the best acceptable). Never throws.
  Future<List<(YtTrack, int)>> _mvExtractor(
      YtTrack seed, String query, int seedDurationSec) async {
    final out = <(YtTrack, int)>[];
    try {
      final list = await _explode.search
          .search(query, filter: TypeFilters.video)
          .timeout(mvSearchTimeout);
      final seen = <String>{};
      for (final v in list) {
        try {
          final id = v.id.value;
          if (id.length != 11 || id == seed.id || !seen.add(id)) {
            continue;
          }
          final dur = v.duration?.inSeconds ?? -1;
          final t = _trackFromVideo(v);
          if (t == null) continue;
          final sc = scoreMusicVideoCandidate(
            seedTitle: seed.title,
            seedArtist: seed.artist,
            candTitle: t.title,
            candArtist: t.artist,
            seedDurationSec: seedDurationSec,
            candDurationSec: dur,
          );
          if (_mvAcceptable(seed, t, sc)) out.add((t, sc));
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  /// Session memo: seed track id → resolved official video (null = none;
  /// fall back to the seed's own stream). Capped ~100 entries. Positive
  /// hits live 12h ([homeCacheTtlMs]); misses (null) negative-cache 30m
  /// so a dead search retries instead of never resolving. Timestamps in
  /// [_mvAt]; all guarded, never throws.
  final Map<String, YtTrack?> _mvMemo = {};
  final Map<String, int> _mvAt = {};
  static const int _mvNegTtlMs = 30 * 60 * 1000;

  /// Single-flight for official-video resolves: concurrent callers (slot
  /// open + prefetch wave + trending rail) join one search instead of
  /// firing duplicate InnerTube + scrape tiers. Removed on completion;
  /// capped. Never throws.
  final Map<String, Future<YtTrack?>> _mvFlight = {};

  /// Acceptance gate: positive score AND a real relation to the seed
  /// (shared title token or same artist). The seed's own id never wins
  /// (fallback covers it).
  bool _mvAcceptable(YtTrack seed, YtTrack cand, int score) {
    try {
      if (cand.id == seed.id || score <= 0) return false;
      if (mvSharesTitle(seed.title, cand.title)) return true;
      try {
        final sk = artistKeyOf(seed.artist);
        if (sk.isNotEmpty &&
            sk != 'unknown artist' &&
            sk == artistKeyOf(cand.artist)) {
          return true;
        }
      } catch (_) {}
      return false;
    } catch (_) {
      return false;
    }
  }

  // ---------- disk snapshots (instant-first UI, S1/H8) ----------

  Future<void> saveSnapshot(String key, List<YtTrack> tracks) async {
    try {
      if (key.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (tracks.isEmpty) {
        // Negative: don't write an empty file (loads as null natively);
        // remember the miss briefly so repeat visits skip disk IO.
        try {
          _snapEmptyAt[key] = now;
          while (_snapEmptyAt.length > negativeCap) {
            _snapEmptyAt.remove(_snapEmptyAt.keys.first);
          }
          _memSnaps.remove(key);
        } catch (_) {}
        return;
      }
      try {
        _snapEmptyAt.remove(key);
      } catch (_) {}
      _memoStore(_memSnaps, key, tracks, now, songMemCapKeys);
      final dir = cacheDir;
      if (dir == null) return;
      final f = File('${dir.path}/${songCacheFile(key)}');
      // Atomic tmp+rename (v2 schema via songListToJson); 12s cap so a
      // wedged fs never stalls the UI thread caller.
      await f
          .writeAsString(jsonEncode(songListToJson(tracks, now)))
          .timeout(const Duration(seconds: 12));
    } catch (_) {}
  }

  Future<List<YtTrack>?> loadSnapshot(String key, int ttlMs) async {
    try {
      if (key.isEmpty) return null;
      final now = DateTime.now().millisecondsSinceEpoch;
      // T4 mem-hit: zero disk IO, zero RTT for fresh data.
      try {
        final hit = _memoFresh(_memSnaps, key, ttlMs, now);
        if (hit != null) return hit;
      } catch (_) {}
      final existing = _snapFlight[key];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {
          return null;
        }
      }
      final mine = _loadSnapshotDisk(key, ttlMs);
      _snapFlight[key] = mine;
      try {
        while (_snapFlight.length > songMemCapKeys) {
          _snapFlight.remove(_snapFlight.keys.first);
        }
      } catch (_) {}
      List<YtTrack>? out;
      try {
        out = await mine;
      } catch (_) {
        out = null;
      } finally {
        try {
          if (_snapFlight[key] == mine) _snapFlight.remove(key);
        } catch (_) {}
      }
      if (out != null) return out;
      // SWR: disk missed/stale but mem still holds rows — serve stale
      // instantly (caller refreshes behind via its network wave).
      try {
        final stale = _memSnaps[key];
        if (stale != null && stale.tracks.isNotEmpty) {
          return List<YtTrack>.of(stale.tracks);
        }
      } catch (_) {}
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Disk read behind [loadSnapshot]'s memo + single-flight. Warms the
  /// mem tier on hit (v1 + v2 snapshots migrate on read, never crash).
  /// Null on miss/stale/corrupt. Never throws.
  Future<List<YtTrack>?> _loadSnapshotDisk(String key, int ttlMs) async {
    try {
      final dir = cacheDir;
      if (dir == null) return null;
      final f = File('${dir.path}/${songCacheFile(key)}');
      if (!await f.exists().timeout(const Duration(seconds: 5))) {
        return null;
      }
      final raw =
          await f.readAsString().timeout(const Duration(seconds: 5));
      final root = jsonDecode(raw);
      if (root is! Map) return null;
      final out = songListFromJson(root.cast<String, dynamic>(), ttlMs);
      if (out != null) {
        try {
          _memoStore(_memSnaps, key, out,
              DateTime.now().millisecondsSinceEpoch, songMemCapKeys);
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  // ---------- extractor mapping (S3 gates, shared with pagers) ----------

  /// Extractor Video → track, or null. Same gates as every other source
  /// (duration 30s–10min, lives, junk, distinct handled by caller).
  YtTrack? _trackFromVideo(Video v) => trackFromExplodeVideo(v);
}

/// Extractor Video → track, or null (shared with [SearchPager]).
YtTrack? trackFromExplodeVideo(Video v) {
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

/// Memory snapshot row (T4): tracks + write time. TTL applied by the
/// reader (home 12h / search 30m / trending 7d). URLs only — bytes ride
/// the native player cache.
class _SnapRow {
  final List<YtTrack> tracks;
  final int atMs;
  _SnapRow(List<YtTrack> t, this.atMs) : tracks = List<YtTrack>.of(t);
}

/// Home-shelves memo row (map shape preserved: shelf -> tracks).
class _HomeMapRow {
  final Map<String, List<YtTrack>> shelves;
  final int atMs;
  _HomeMapRow(Map<String, List<YtTrack>> s, this.atMs)
      : shelves = {
          for (final e in s.entries) e.key: List<YtTrack>.of(e.value),
        };
}

/// Endless search pager for See All full pages (H11): keeps the query +
/// continuation, appends page after page. Seen-set + exhausted flag
/// mirror the native SearchPager.
class SearchPager {
  final YoutubeExplode _yt;
  final String query;
  final int pageSize;
  final Set<String> seen = {};
  bool exhausted = false;
  VideoSearchList? _page;
  bool _started = false;

  SearchPager(this._yt, this.query, {this.pageSize = 20});

  Future<List<YtTrack>> loadMore() async {
    try {
      if (exhausted) return [];
      VideoSearchList? list = _page;
      if (!_started) {
        list = await _yt.search
            .search(query, filter: TypeFilters.video)
            .timeout(browseTimeout);
        _started = true;
      } else {
        try {
          final prev = _page;
          if (prev == null) {
            exhausted = true;
            return [];
          }
          list = await prev.nextPage().timeout(browseTimeout);
        } catch (_) {
          list = null;
        }
        if (list == null) {
          exhausted = true;
          return [];
        }
      }
      _page = list;
      final current = list;
      if (current.isEmpty) {
        exhausted = true;
        return [];
      }
      final out = <YtTrack>[];
      for (final v in list) {
        try {
          final t = trackFromExplodeVideo(v);
          if (t == null || !seen.add(t.id)) continue;
          out.add(t);
          if (out.length >= pageSize) break;
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}
