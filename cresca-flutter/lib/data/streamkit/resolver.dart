// Vendored from cresca-streamkit (streaming-logic reference: see its README). Only relative imports rewritten to package:cresca_app/...; do not edit logic here, fix upstream.
// Fast no-login resolve: first-wins player race + extractor fallback.
//
// Hot path for one track:
//   1. memory cache hit -> return in microseconds (stale served instantly,
//      refreshed in background);
//   2. VISIONOS / MUSIC / VR / REMIX player POSTs race in parallel;
//      the first response with playable audio wins (~1 RTT, not 3
//      sequential legs). VISIONOS leads (no poToken gate). That single
//      response ALSO yields muxed video URLs + full metadata,
//      so video mode and the About panel cost zero extra requests;
//   3. phone leg (sts-scoped), then the extractor manifest appended as
//      fallback when every InnerTube URL 403s at fetch.
//
// Budgets: race bounded by [playerLegTimeout] (8s), whole resolve by
// [resolveCap] (45s). Nothing here throws: failures surface as null/[].

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import 'package:cresca_app/core/track.dart' show extractVideoId;
import 'package:cresca_app/data/cache.dart' show UrlCache, urlMemTtlMs;
import 'package:cresca_app/data/innertube.dart'
    show TubeClient, parseSts, tubeHeaders, tubeUrl;
import 'package:cresca_app/data/resolve.dart' show playerBody;
import 'package:cresca_app/data/streamkit/bundle.dart';

/// Per-leg player timeout (also bounds the whole parallel race).
const Duration playerLegTimeout = Duration(seconds: 8);

/// Outer resolve budget.
const Duration resolveCap = Duration(seconds: 45);

/// Memory-hit background refresh threshold: rows older than this trigger
/// one refresh-behind on hit (fresh URL still served instantly). Keeps
/// hot rows warm without the per-hit refetch storm a naive
/// stale-while-revalidate would cause (every mem hit racing = radio
/// battery drain). Inside the 5h memory TTL with margin.
const int urlRefreshAfterMs = 4 * 60 * 60 * 1000 + 30 * 60 * 1000;

/// Battery-kind next-2 prefetch window (native primeNext [current, +1, +2]
/// byte warming; URL warming here, bytes ride the player cache).
const int prefetchWindow = 2;

/// Resolve retry budget (native retriesLeft = 3 per track).
const int resolveMaxAttempts = 3;

class _ScrapeClient extends YoutubeHttpClient {
  @override
  Map<String, String> get headers => scrapeHeaders();
}

class FastResolver {
  final http.Client httpClient;
  final UrlCache urlCache;
  final BundleCache bundles;
  final String Function() visitorData;
  final String Function() poToken;
  final bool Function() useInnerTube;

  /// Extractor manifest fetch, injectable for tests (default hits network).
  final Future<List<String>> Function(String videoId)? manifestFetcher;

  YoutubeExplode? _yt;
  final Map<String, Future<String?>> _flight = {};

  /// Single-flight for full bundles: concurrent bundleFor(id) joins one
  /// race (no double 6-leg network). Entries removed on completion.
  final Map<String, Future<StreamBundle?>> _bundleFlight = {};

  /// Video URL memo: play watchUrl → ranked (url, height), extractor-
  /// warmed so repeat/next/prev/auto-advance opens skip the manifest
  /// decipher. URLs only (bytes ride the player cache). Capped + TTL'd
  /// (5h URL TTL parity). Joins concurrent opens of one URL
  /// (single-flight). Negative memo: watchUrls dead on every tier skip
  /// straight to [] for 5m (zero RTT). All guarded; never throws.
  static const int videoMemoCap = 32;
  static const int videoMemoTtlMs = 5 * 60 * 60 * 1000;
  static const int videoMissTtlMs = 5 * 60 * 1000;
  static const int videoMissCap = 200;

  /// Per-hop video budget (each tier) + outer single-flight join bound.
  static const Duration videoHopTimeout = Duration(seconds: 8);
  static const Duration videoOuterTimeout = Duration(seconds: 20);

  final Map<String, _VideoMemoRow> _videoMemoMuxed = {};
  final Map<String, _VideoMemoRow> _videoMemoOnly = {};
  final Map<String, Future<List<(String, int)>>> _videoFlight = {};
  final Map<String, int> _videoDeadAt = {};

  bool _videoSkipped(String watchUrl, int nowMs) {
    try {
      final at = _videoDeadAt[watchUrl];
      if (at == null) return false;
      if (nowMs - at > videoMissTtlMs) {
        _videoDeadAt.remove(watchUrl);
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _videoMarkDead(String watchUrl, int nowMs) {
    try {
      if (watchUrl.isEmpty) return;
      _videoDeadAt[watchUrl] = nowMs;
      while (_videoDeadAt.length > videoMissCap) {
        _videoDeadAt.remove(_videoDeadAt.keys.first);
      }
    } catch (_) {}
  }

  void _videoClearDead(String watchUrl) {
    try {
      _videoDeadAt.remove(watchUrl);
    } catch (_) {}
  }

  List<(String, int)>? _videoMemoHit(
      Map<String, _VideoMemoRow> memo, String watchUrl, int nowMs) {
    try {
      final hit = memo[watchUrl];
      if (hit == null) return null;
      if (nowMs - hit.atMs > videoMemoTtlMs) {
        memo.remove(watchUrl);
        return null;
      }
      if (hit.urls.isEmpty) return null;
      return List.of(hit.urls);
    } catch (_) {
      return null;
    }
  }

  void _videoMemoStore(Map<String, _VideoMemoRow> memo, String watchUrl,
      List<(String, int)> urls, int nowMs) {
    try {
      if (urls.isEmpty) return;
      memo[watchUrl] = _VideoMemoRow(List.of(urls), nowMs);
      while (memo.length > videoMemoCap) {
        memo.remove(memo.keys.first);
      }
    } catch (_) {}
  }

  /// Evicts one dead video URL from both memos (rows drained to empty
  /// are removed → miss → fresh fetch). Never throws.
  void dropVideoUrl(String watchUrl, String url) {
    try {
      if (url.isEmpty) return;
      for (final memo in [_videoMemoMuxed, _videoMemoOnly]) {
        try {
          final row = memo[watchUrl];
          if (row == null) continue;
          final kept = row.urls.where((e) => e.$1 != url).toList();
          if (kept.isEmpty) {
            memo.remove(watchUrl);
          } else if (kept.length != row.urls.length) {
            memo[watchUrl] = _VideoMemoRow(kept, row.atMs);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Negative memo: dead videoIds skip the race + extractor fallback for
  /// 5m (short TTL — retried after expiry). Cleared on success.
  final BundleMisses misses = BundleMisses();

  YoutubeExplode _explode() {
    final yt = _yt;
    if (yt != null) return yt;
    final created = YoutubeExplode(_ScrapeClient());
    _yt = created;
    return created;
  }

  /// Session visitor bootstrapped from the homepage (cached per process).
  /// A fresh visitorData in context + X-Goog-Visitor-Id passes the
  /// "confirm you're not a bot" gate that otherwise 200s with
  /// LOGIN_REQUIRED on every leg. Homepage fetch ~200ms, once.
  String? _visitorCache;

  Future<String> ensureSession() async {
    try {
      final hit = _visitorCache;
      if (hit != null) return hit;
      final provided = visitorData();
      if (provided.isNotEmpty) {
        _visitorCache = provided;
        return provided;
      }
      final res = await httpClient
          .get(Uri.parse('https://www.youtube.com/'),
              headers: scrapeHeaders())
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final m =
            RegExp(r'"visitorData"\s*:\s*"([^"]+)"')
                .firstMatch(res.body);
        final v = m?.group(1) ?? '';
        if (v.isNotEmpty) {
          _visitorCache = v;
          return v;
        }
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  void dropSession() {
    try {
      _visitorCache = null;
    } catch (_) {}
  }

  FastResolver({
    http.Client? httpClient,
    UrlCache? urlCache,
    BundleCache? bundles,
    String Function()? visitorData,
    String Function()? poToken,
    bool Function()? useInnerTube,
    this.manifestFetcher,
  })  : httpClient = httpClient ?? http.Client(),
        urlCache = urlCache ?? UrlCache(),
        bundles = bundles ?? BundleCache(),
        visitorData = visitorData ?? (() => ''),
        poToken = poToken ?? (() => ''),
        useInnerTube = useInnerTube ?? (() => true);

  void dispose() {
    try {
      _yt?.close();
    } catch (_) {}
    _yt = null;
    try {
      httpClient.close();
    } catch (_) {}
  }

  // ---------- player legs ----------

  /// Full decoded player response (or null). One call carries
  /// streamingData (audio + muxed video) AND videoDetails (metadata).
  /// Uses the session visitor when bootstrapped (bot-gate parity).
  Future<Map<String, dynamic>?> playerJson(
    String videoId,
    TubeClient client, {
    int signatureTimestamp = 0,
  }) async {
    try {
      final visitor = _visitorCache ?? visitorData();
      final res = await httpClient
          .post(
            Uri.parse(tubeUrl(client, 'player')),
            headers: tubeHeaders(
              client,
              visitorData: visitor,
              poToken: poToken(),
            ),
            body: jsonEncode(playerBody(client, videoId, visitor,
                poToken: poToken(),
                signatureTimestamp: signatureTimestamp)),
          )
          .timeout(playerLegTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return null;
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return null;
      return decoded.cast<String, dynamic>();
    } catch (_) {
      return null;
    }
  }

  /// Session-cached signature timestamp for the phone leg. The watch
  /// page 429s under load, so the hot path never depends on sts: the
  /// phone leg races WITHOUT sts (proven OK with session visitor) and
  /// this stays only as a best-effort fallback helper.
  int _sts = 0;

  Future<int> stsFor(String videoId) async {
    try {
      if (_sts > 0) return _sts;
      final res = await httpClient
          .get(
            Uri.parse('https://www.youtube.com/watch?v=$videoId&app=desktop'),
            headers: scrapeHeaders(),
          )
          .timeout(const Duration(seconds: 8));
      if (res.statusCode < 200 || res.statusCode >= 300) return 0;
      final sts = parseSts(res.body);
      if (sts > 0) _sts = sts;
      return sts;
    } catch (_) {
      return _sts;
    }
  }

  /// First-wins race across IOS / VISIONOS / PHONE / MUSIC / VR / REMIX:
  /// all six POSTs fly in parallel and the first response carrying
  /// playable audio wins (~1 RTT). IOS and VISIONOS lead: no poToken
  /// gate, direct signed URLs (yt-dlp's primary defaults since 2025.11).
  /// The phone leg is IN the race (not a fallback): with a session
  /// visitor it answers OK where MUSIC/VR 200 LOGIN_REQUIRED. Losers
  /// are ignored. Bounded by [playerLegTimeout].
  Future<StreamBundle?> raceBundles(
    String videoId, {
    String seedTitle = '',
    String seedArtist = '',
    String seedThumb = '',
  }) async {
    const legs = [
      TubeClient.ios,
      TubeClient.visionos,
      TubeClient.androidPhone,
      TubeClient.androidMusic,
      TubeClient.androidVr,
      TubeClient.webRemix,
    ];
    // Bootstrap the session visitor first (cached after the first call;
    // playerJson picks it up from the cache). Without it every leg 200s
    // LOGIN_REQUIRED under bot-gating.
    await ensureSession();
    final win = Completer<StreamBundle?>();
    var pending = legs.length;
    void settle(StreamBundle? b) {
      if (win.isCompleted) return;
      if (b != null && b.hasAudio) {
        try {
          win.complete(b);
        } catch (_) {}
        return;
      }
      pending--;
      if (pending <= 0) {
        try {
          win.complete(null);
        } catch (_) {}
      }
    }

    for (final client in legs) {
      try {
        unawaited(playerJson(videoId, client).then((root) {
          try {
            if (root == null) {
              settle(null);
              return;
            }
            settle(parsePlayerBundle(root, videoId,
                seedTitle: seedTitle,
                seedArtist: seedArtist,
                seedThumb: seedThumb));
          } catch (_) {
            settle(null);
          }
        }).catchError((_) => settle(null)));
      } catch (_) {
        settle(null);
      }
    }
    try {
      return await win.future.timeout(playerLegTimeout);
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _manifestUrls(String videoId) async {
    try {
      if (manifestFetcher != null) return await manifestFetcher!(videoId);
      final manifest = await _explode()
          .videos
          .streams
          .getManifest(videoId)
          .timeout(const Duration(seconds: 35));
      final sorted = manifest.audioOnly.toList()
        ..sort((a, b) =>
            b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond));
      final seen = <String>{};
      return sorted
          .map((s) => s.url.toString())
          .where((u) => u.isNotEmpty && seen.add(u))
          .toList();
    } catch (_) {
      return [];
    }
  }

  // ---------- public fast path ----------

  /// Full stream bundle for a video id: ranked audio + muxed video +
  /// metadata. Memo first: a fresh [urlCache] row serves instantly
  /// (~microseconds, zero round trips) with video/meta riding [bundles]
  /// when present; rows past [urlRefreshAfterMs] trigger ONE background
  /// refresh so hot tracks never go cold. On miss concurrent callers join
  /// one resolve (single-flight); dead ids short-circuit via negative
  /// memo (5m TTL). The phone leg already races up front, so only the
  /// extractor manifest remains as fallback when the race comes back
  /// empty — and a metadata-only gap NEVER blocks stream delivery.
  /// Never throws; null only when nothing resolved at all.
  Future<StreamBundle?> bundleFor(
    String videoId, {
    String seedTitle = '',
    String seedArtist = '',
    String seedThumb = '',
  }) {
    try {
      if (videoId.length != 11) return Future.value(null);
      final now = DateTime.now().millisecondsSinceEpoch;
      if (misses.shouldSkip(videoId, now)) return Future.value(null);
      // Memo fast path: zero round trips for precached / repeat tracks.
      try {
        final watchUrl = 'https://www.youtube.com/watch?v=$videoId';
        final hit = urlCache.getFresh(watchUrl, now);
        if (hit != null && hit.isNotEmpty) {
          try {
            final at = urlCache.rows[watchUrl]?.atMs ?? now;
            if (now - at > urlRefreshAfterMs) {
              unawaited(_refresh(videoId));
            }
          } catch (_) {}
          final memVideo = bundles.videoFor(videoId, now);
          var meta = bundles.metaFor(videoId, now) ?? TrackMeta.empty(videoId);
          if (!meta.hasDetails && seedTitle.isNotEmpty) {
            meta = TrackMeta(
              videoId: videoId,
              title: seedTitle,
              artist: seedArtist.isEmpty ? 'Unknown Artist' : seedArtist,
              thumbUrl: seedThumb,
            );
          }
          return Future.value(StreamBundle(
              videoId: videoId,
              audioUrls: [hit],
              videoUrls: memVideo,
              meta: meta));
        }
      } catch (_) {}
      final existing = _bundleFlight[videoId];
      if (existing != null) return existing;
      final mine = _bundleFresh(videoId,
              seedTitle: seedTitle,
              seedArtist: seedArtist,
              seedThumb: seedThumb)
          .timeout(resolveCap)
          .catchError((_) => null);
      _bundleFlight[videoId] = mine;
      mine.whenComplete(() {
        try {
          if (_bundleFlight[videoId] == mine) {
            _bundleFlight.remove(videoId);
          }
        } catch (_) {}
      });
      return mine;
    } catch (_) {
      return Future.value(null);
    }
  }

  /// Genuine network resolve behind [bundleFor]'s memo + single-flight.
  /// Marks the negative memo on total miss, clears it on success.
  /// Never throws.
  Future<StreamBundle?> _bundleFresh(
    String videoId, {
    String seedTitle = '',
    String seedArtist = '',
    String seedThumb = '',
  }) async {
    try {
      if (videoId.length != 11) return null;
      final now = DateTime.now().millisecondsSinceEpoch;
      final watchUrl = 'https://www.youtube.com/watch?v=$videoId';
      StreamBundle? b;
      if (useInnerTube()) {
        try {
          b = await raceBundles(videoId,
              seedTitle: seedTitle,
              seedArtist: seedArtist,
              seedThumb: seedThumb);
        } catch (_) {
          b = null;
        }
      }
      List<String> audio =
          (b != null && b.hasAudio) ? List.of(b.audioUrls) : <String>[];
      final List<(String, int)> video =
          b != null ? List.of(b.videoUrls) : <(String, int)>[];
      TrackMeta meta = b != null
          ? b.meta
          : (bundles.metaFor(videoId, now) ?? TrackMeta.empty(videoId));
      // Extractor fallback runs ONLY when audio is missing. A metadata-only
      // gap (race won audio but carried no videoDetails) must NOT block
      // stream delivery behind a seconds-long extractor call: the player
      // paints the seed row and the About panel backfills via
      // DetailsStore.load. This keeps cold resolves at ~1 RTT.
      if (audio.isEmpty) {
        try {
          final ranked = await _manifestUrls(videoId);
          for (final u in ranked) {
            if (u.isNotEmpty && !audio.contains(u)) audio.add(u);
          }
        } catch (_) {}
      }
      if (audio.isEmpty) {
        try {
          misses.markDead(videoId, DateTime.now().millisecondsSinceEpoch);
        } catch (_) {}
        return null;
      }
      if (!meta.hasDetails && seedTitle.isNotEmpty) {
        meta = TrackMeta(
          videoId: videoId,
          title: seedTitle,
          artist: seedArtist.isEmpty ? 'Unknown Artist' : seedArtist,
          thumbUrl: seedThumb,
        );
      }
      final out = StreamBundle(
          videoId: videoId, audioUrls: audio, videoUrls: video, meta: meta);
      try {
        urlCache.remember(watchUrl, audio.first, now);
        bundles.remember(out, now);
        misses.clear(videoId);
      } catch (_) {}
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Best audio URL for a watch URL. Memory first (fresh rows served
  /// instantly; rows past [urlRefreshAfterMs] trigger ONE background
  /// refresh so hot tracks never go cold mid-session); dead ids
  /// short-circuit via negative memo; concurrent callers join one
  /// resolve (single-flight); 45s cap; null on failure. Never throws.
  Future<String?> audioUrl(String watchUrl) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final hit = urlCache.getFresh(watchUrl, now);
      final vid = extractVideoId(watchUrl);
      if (hit != null) {
        // Near-expiry refresh-behind only: a fresh hit costs zero
        // network (battery-kind); the row self-heats before it dies.
        if (vid != null) {
          try {
            final at = urlCache.rows[watchUrl]?.atMs ?? now;
            if (now - at > urlRefreshAfterMs) unawaited(_refresh(vid));
          } catch (_) {}
        }
        return Future.value(hit);
      }
      // Negative: a recently-dead track resolves null with zero RTT.
      try {
        if (vid != null && misses.shouldSkip(vid, now)) {
          return Future.value(null);
        }
      } catch (_) {}
      final existing = _flight[watchUrl];
      if (existing != null) return existing;
      final mine = _resolveAudio(watchUrl, vid).timeout(resolveCap).then(
          (l) {
        try {
          return l.isEmpty ? null : l.first;
        } catch (_) {
          return null;
        }
      }).catchError((_) => null);
      _flight[watchUrl] = mine;
      mine.whenComplete(() {
        try {
          if (_flight[watchUrl] == mine) _flight.remove(watchUrl);
        } catch (_) {}
      });
      return mine;
    } catch (_) {
      return Future.value(null);
    }
  }

  Future<void> _refresh(String videoId) async {
    try {
      await bundleFor(videoId).timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  Future<List<String>> _resolveAudio(String watchUrl, String? vid) async {
    try {
      if (vid == null) return [];
      final b = await bundleFor(vid);
      return b == null ? [] : b.audioUrls;
    } catch (_) {
      return [];
    }
  }

  /// Ranked muxed (video+audio) URLs, best-first distinct heights.
  /// Extractor-first (free-ish, signature-deciphered); bundle second —
  /// the two legs fly IN PARALLEL (were sequential 30s + 20s), each 8s-
  /// bounded, extractor winning ties (verified on-device: raw InnerTube
  /// `formats` URLs 500 in ExoPlayer while the extractor's deciphered
  /// muxed URLs play). Memo first (microseconds, zero round trips),
  /// negative memo on total miss (5m fast-fail), single-flight joins
  /// concurrent opens. Video-only DASH rides [videoOnlyUrls], never
  /// here. Same signature; never throws.
  Future<List<(String, int)>> videoUrls(String watchUrl) async {
    try {
      final vid = extractVideoId(watchUrl);
      if (vid == null) return const [];
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_videoSkipped(watchUrl, now)) return const [];
      final hit = _videoMemoHit(_videoMemoMuxed, watchUrl, now);
      if (hit != null) return hit;
      try {
        final bv = bundles.videoFor(vid, now);
        if (bv.isNotEmpty) {
          _videoMemoStore(_videoMemoMuxed, watchUrl, bv, now);
          _videoClearDead(watchUrl);
          return List.of(bv);
        }
      } catch (_) {}
      final existing = _videoFlight[watchUrl];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {
          return const [];
        }
      }
      final mine = _videoMuxedFresh(watchUrl, vid, now)
          .timeout(videoOuterTimeout)
          .catchError((_) => const <(String, int)>[]);
      _videoFlight[watchUrl] = mine;
      try {
        while (_videoFlight.length > videoMemoCap) {
          _videoFlight.remove(_videoFlight.keys.first);
        }
      } catch (_) {}
      try {
        return await mine;
      } finally {
        try {
          if (_videoFlight[watchUrl] == mine) {
            _videoFlight.remove(watchUrl);
          }
        } catch (_) {}
      }
    } catch (_) {
      return const [];
    }
  }

  /// Genuine fetch behind [videoUrls]' memo + single-flight: extractor
  /// manifest and bundle race in parallel, each [videoHopTimeout]-
  /// bounded. Wins memoized; total miss marks the negative memo. Never
  /// throws.
  Future<List<(String, int)>> _videoMuxedFresh(
      String watchUrl, String vid, int nowMs) async {
    try {
      final extFuture = _muxedFromManifest(vid)
          .timeout(videoHopTimeout)
          .catchError((_) => const <(String, int)>[]);
      final bunFuture = _muxedFromBundle(vid)
          .timeout(videoHopTimeout)
          .catchError((_) => const <(String, int)>[]);
      List<(String, int)> ext = const [];
      List<(String, int)> bun = const [];
      try {
        final both = await Future.wait([extFuture, bunFuture]);
        ext = both[0];
        bun = both[1];
      } catch (_) {}
      if (ext.isNotEmpty) {
        _videoMemoStore(_videoMemoMuxed, watchUrl, ext, nowMs);
        _videoClearDead(watchUrl);
        return ext;
      }
      if (bun.isNotEmpty) {
        _videoMemoStore(_videoMemoMuxed, watchUrl, bun, nowMs);
        _videoClearDead(watchUrl);
        return bun;
      }
      _videoMarkDead(watchUrl, DateTime.now().millisecondsSinceEpoch);
      return const [];
    } catch (_) {
      return const [];
    }
  }

  Future<List<(String, int)>> _muxedFromManifest(String vid) async {
    try {
      final manifest = await _explode().videos.streams.getManifest(vid);
      final out = <(String, int)>[];
      final seen = <int>{};
      for (final s in manifest.muxed.toList()
        ..sort((a, b) => b.videoResolution.height
            .compareTo(a.videoResolution.height))) {
        final h = s.videoResolution.height;
        if (h <= 0 || !seen.add(h)) continue;
        try {
          final u = s.url.toString();
          if (u.isEmpty) continue;
          out.add((u, h));
        } catch (_) {}
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<List<(String, int)>> _muxedFromBundle(String vid) async {
    try {
      final b = await bundleFor(vid);
      if (b != null && b.videoUrls.isNotEmpty) return b.videoUrls;
    } catch (_) {}
    return const [];
  }

  /// Ranked video-ONLY (DASH, no audio track) URLs, best-first distinct
  /// heights. Picture-only tier for video mode when no muxed rendition
  /// exists anywhere (muted picture + synced just_audio master clock).
  /// Memo first, extractor manifest second (8s-bounded); wins memoized,
  /// total miss marks the negative memo. Single-flight joins concurrent
  /// opens; the bundle carries no video-only store. Same signature;
  /// never throws.
  Future<List<(String, int)>> videoOnlyUrls(String watchUrl) async {
    try {
      final vid = extractVideoId(watchUrl);
      if (vid == null) return const [];
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_videoSkipped(watchUrl, now)) return const [];
      final hit = _videoMemoHit(_videoMemoOnly, watchUrl, now);
      if (hit != null) return hit;
      final key = 'only:$watchUrl';
      final existing = _videoFlight[key];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {
          return const [];
        }
      }
      final mine = _videoOnlyFresh(watchUrl, vid, now)
          .timeout(videoOuterTimeout)
          .catchError((_) => const <(String, int)>[]);
      _videoFlight[key] = mine;
      try {
        while (_videoFlight.length > videoMemoCap) {
          _videoFlight.remove(_videoFlight.keys.first);
        }
      } catch (_) {}
      try {
        return await mine;
      } finally {
        try {
          if (_videoFlight[key] == mine) _videoFlight.remove(key);
        } catch (_) {}
      }
    } catch (_) {
      return const [];
    }
  }

  /// Genuine fetch behind [videoOnlyUrls]' memo + single-flight.
  /// 8s-bounded; wins memoized; total miss marks the negative memo.
  /// Never throws.
  Future<List<(String, int)>> _videoOnlyFresh(
      String watchUrl, String vid, int nowMs) async {
    try {
      List<(String, int)> out = const [];
      try {
        final manifest = await _explode()
            .videos
            .streams
            .getManifest(vid)
            .timeout(videoHopTimeout);
        final rows = <(String, int)>[];
        final seen = <int>{};
        for (final s in manifest.videoOnly.toList()
          ..sort((a, b) => b.videoResolution.height
              .compareTo(a.videoResolution.height))) {
          final h = s.videoResolution.height;
          if (h <= 0 || !seen.add(h)) continue;
          try {
            final u = s.url.toString();
            if (u.isEmpty) continue;
            rows.add((u, h));
          } catch (_) {}
        }
        out = rows;
      } catch (_) {
        out = const [];
      }
      if (out.isNotEmpty) {
        _videoMemoStore(_videoMemoOnly, watchUrl, out, nowMs);
        _videoClearDead(watchUrl);
      } else {
        _videoMarkDead(watchUrl, DateTime.now().millisecondsSinceEpoch);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Prefetches bundles for upcoming tracks. Bounded batches of 3; each
  /// bundle self-bounds, so a dead track never stalls the row. Warms
  /// [urlCache] + [bundles] so playback and metadata reads mem-hit.
  /// [max] caps the work (battery-kind: callers pass the 2-ahead window).
  /// Cache-warm + negatively-dead rows are skipped before any network
  /// (zero RTT for already-resolved tracks). Never throws.
  Future<void> primeNext(
    List<({String id, String title, String artist, String thumb})> tracks, {
    int max = 8,
  }) async {
    try {
      if (tracks.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final pending = <({String id, String title, String artist, String thumb})>[];
      for (final t in tracks.take(max <= 0 ? tracks.length : max)) {
        try {
          if (t.id.length != 11) continue;
          if (misses.shouldSkip(t.id, now)) continue;
          final w = 'https://www.youtube.com/watch?v=${t.id}';
          if (urlCache.getFresh(w, now) != null) continue;
          pending.add(t);
        } catch (_) {
          pending.add(t);
        }
      }
      if (pending.isEmpty) return;
      final slice = pending;
      if (slice.isEmpty) return;
      for (var i = 0; i < slice.length; i += 3) {
        try {
          final batch = slice.skip(i).take(3).toList();
          await Future.wait([
            for (final t in batch)
              bundleFor(t.id,
                      seedTitle: t.title,
                      seedArtist: t.artist,
                      seedThumb: t.thumb)
                  .timeout(const Duration(seconds: 20))
                  .catchError((_) => null),
          ]);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Battery-kind next-2 prefetch: warms exactly the 2-ahead gapless
  /// window in ONE parallel wave (20s cap each). Called on every track
  /// load + auto-advance so skips mem-hit. Warm/dead rows skipped before
  /// any network. Never throws.
  Future<void> prefetchNext2(
    List<({String id, String title, String artist, String thumb})> upcoming,
  ) async {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final slice = <({String id, String title, String artist, String thumb})>[];
      for (final t in upcoming.take(prefetchWindow)) {
        try {
          if (t.id.length != 11) continue;
          if (misses.shouldSkip(t.id, now)) continue;
          final w = 'https://www.youtube.com/watch?v=${t.id}';
          if (urlCache.getFresh(w, now) != null) continue;
          slice.add(t);
        } catch (_) {
          slice.add(t);
        }
      }
      if (slice.isEmpty) return;
      await Future.wait([
        for (final t in slice)
          bundleFor(t.id,
                  seedTitle: t.title,
                  seedArtist: t.artist,
                  seedThumb: t.thumb)
              .timeout(const Duration(seconds: 20))
              .catchError((_) => null),
      ]);
    } catch (_) {}
  }

  /// [bundleFor] with exponential-backoff retries ([resolveMaxAttempts]
  /// total tries, 400ms << attempt). Covers transient race timeouts on
  /// flaky networks; permanent misses return null fast (no sleep after
  /// the last attempt). Never throws.
  Future<StreamBundle?> bundleForWithBackoff(
    String videoId, {
    String seedTitle = '',
    String seedArtist = '',
    String seedThumb = '',
    int maxAttempts = resolveMaxAttempts,
  }) async {
    try {
      final tries = maxAttempts < 1 ? 1 : (maxAttempts > 5 ? 5 : maxAttempts);
      for (var attempt = 0; attempt < tries; attempt++) {
        try {
          final b = await bundleFor(videoId,
              seedTitle: seedTitle,
              seedArtist: seedArtist,
              seedThumb: seedThumb);
          if (b != null && b.hasAudio) return b;
        } catch (_) {}
        if (attempt + 1 < tries) {
          try {
            await Future<void>.delayed(
                Duration(milliseconds: 400 << attempt));
          } catch (_) {}
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Eagerly drops expired memory rows (get-time eviction otherwise
  /// leaves them until read). Returns the evicted count. Never throws.
  int pruneUrlCache([int? nowMs]) {
    var n = 0;
    try {
      final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      final dead = <String>[];
      for (final e in urlCache.rows.entries) {
        if (now - e.value.atMs > urlMemTtlMs) dead.add(e.key);
      }
      for (final k in dead) {
        urlCache.drop(k);
        n++;
      }
    } catch (_) {}
    return n;
  }

  /// Drops a stale cached URL (e.g. after a 403) so the next resolve
  /// refetches. Callers retry x3, then skip the track.
  void dropCachedUrl(String watchUrl) => urlCache.drop(watchUrl);

  /// Disk snapshot encodes (caller owns file IO).
  String? encodeUrlSnapshot() {
    try {
      final snap =
          urlCache.snapshotForDisk(DateTime.now().millisecondsSinceEpoch);
      if (snap == null) return null;
      return jsonEncode(snap);
    } catch (_) {
      return null;
    }
  }

  int restoreUrlSnapshot(String json) {
    try {
      final root = jsonDecode(json);
      if (root is! Map) return 0;
      return urlCache.restoreFromDisk(root.cast<String, dynamic>(),
          DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      return 0;
    }
  }

  String? encodeBundleSnapshot() {
    try {
      final snap =
          bundles.snapshotForDisk(DateTime.now().millisecondsSinceEpoch);
      if (snap == null) return null;
      return jsonEncode(snap);
    } catch (_) {
      return null;
    }
  }

  int restoreBundleSnapshot(String json) {
    try {
      final root = jsonDecode(json);
      if (root is! Map) return 0;
      return bundles.restoreFromDisk(root.cast<String, dynamic>(),
          DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      return 0;
    }
  }
}

/// Memoized ranked video URLs (muxed or video-only): (url, height) pairs
/// plus write time. URLs only — bytes ride the player cache.
class _VideoMemoRow {
  final List<(String, int)> urls;
  final int atMs;
  const _VideoMemoRow(this.urls, this.atMs);
}
