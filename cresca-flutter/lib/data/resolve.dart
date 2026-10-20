// Stream-URL resolve: InnerTube player race + extractor fallback.
// Native refs: InnerTubeApi.audioUrls/playerUrls/collectAudio,
// YoutubeRepository.audioUrls/audioUrl/dropCachedUrl, C4 (45s cap,
// 403 → drop + ×3 retry → skip; 5h mem + 6h disk).
//
// Fast path rides vendored streamkit (lib/data/streamkit/, reference:
// cresca-streamkit README): full-response player legs (audio + muxed
// video + metadata in one POST), session-visitor bootstrap, first-wins
// parallel race across VISIONOS/VR/MUSIC/REMIX/PHONE, BundleCache memo,
// primeNext prefetch. The VISIONOS leg (yt-dlp's primary client since
// 2026) is the reliable one: direct signed URLs, no cipher, no GVS
// poToken gate — the ANDROID_* legs now answer LOGIN_REQUIRED or serve
// URLs YouTube selectively 403s at fetch on flagged IPs. Legacy
// sequential legs (tubeAudioUrls/audioUrls) stay behavior-identical
// for existing callers; the playback hot path uses bundleFor. Every
// hop timeouts + silent-catches; resolve never throws.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/track.dart';
import 'cache.dart';
import 'innertube.dart';
import 'streamkit/bundle.dart' as sk;

/// Player request body (InnerTubeApi.playerUrls 1:1). The context MUST
/// match the calling client (name/version/key/headers travel together);
/// a mismatched context silently kills that race leg.
Map<String, dynamic> playerBody(
  TubeClient client,
  String videoId,
  String visitorData, {
  String poToken = '',
  int signatureTimestamp = 0,
}) {
  final body = <String, dynamic>{
    'context': contextMap(client, visitorData),
    'videoId': videoId,
    'racyCheckOk': true,
    'contentCheckOk': true,
  };
  if (poToken.isNotEmpty) {
    body['serviceIntegrityDimensions'] = {'poToken': poToken};
  }
  // Phone-leg BotGuard equivalent (NewPipe parity): without a fresh sts
  // the player answers UNPLAYABLE/LOGIN_REQUIRED.
  if (signatureTimestamp > 0) {
    body['playbackContext'] = {
      'contentPlaybackContext': {
        'signatureTimestamp': signatureTimestamp,
      },
    };
  }
  return body;
}

/// Ranked audio URLs from a player response, best-first distinct.
/// Drops non-OK playability, non-audio mimes, and signatureCipher URLs
/// (decipher rides the extractor path, like native).
List<String> parsePlayerUrls(Map<String, dynamic> root) {
  try {
    final status =
        (_asMap(root['playabilityStatus'])?['status'] ?? '').toString();
    if (status.isNotEmpty && status != 'OK') return [];
    final sd = _asMap(root['streamingData']);
    if (sd == null) return [];
    final ranked = <_BrUrl>[];
    for (final key in ['adaptiveFormats', 'formats']) {
      try {
        final arr = sd[key];
        if (arr is List) {
          for (final f in arr) {
            try {
              if (f is Map) {
                final mime = (f['mimeType'] ?? '').toString();
                final url = (f['url'] ?? '').toString();
                if (mime.startsWith('audio/') && url.isNotEmpty) {
                  final br =
                      int.tryParse(f['bitrate'].toString()) ?? 0;
                  ranked.add(_BrUrl(br, url));
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    ranked.sort((a, b) => b.bitrate.compareTo(a.bitrate));
    final seen = <String>{};
    return ranked
        .where((e) => seen.add(e.url))
        .map((e) => e.url)
        .toList();
  } catch (_) {
    return [];
  }
}

class _BrUrl {
  final int bitrate;
  final String url;
  const _BrUrl(this.bitrate, this.url);
}

Map<String, String> modernTubeHeaders() => const {
      'user-agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      'cookie': 'CONSENT=YES+cb',
      'accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
      'accept-language': 'en-US,en;q=0.9',
    };

/// Extractor HTTP with device-consistent browser headers. The bundled
/// default UA (Chrome 96-era) trips bot gating on scrape paths; a
/// current desktop-Chrome profile + consent cookie keeps watch-page +
/// decipher fetches at native parity.
class _ModernTubeClient extends YoutubeHttpClient {
  @override
  Map<String, String> get headers => modernTubeHeaders();
}

Map<String, dynamic>? _asMap(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : null;

/// Resolve budget (C4).
const Duration playerLegTimeout = Duration(seconds: 8);
const Duration resolveCap = Duration(seconds: 45);

/// Memory-hit background refresh threshold: rows older than this trigger
/// one refresh-behind on hit (the fresh URL is still served instantly).
/// Keeps hot rows warm without the per-hit refetch storm a naive
/// stale-while-revalidate would cause (every mem hit racing = radio
/// battery drain). Inside the 5h memory TTL with margin.
const int urlRefreshAfterMs = 4 * 60 * 60 * 1000 + 30 * 60 * 1000;

class StreamResolver {
  final http.Client httpClient;
  final UrlCache urlCache;
  final String Function() cookies;
  final String Function() visitorData;
  final String Function() poToken;
  final bool Function() useInnerTube;

  /// Extractor manifest fetch, injectable for tests (default hits network).
  final Future<List<String>> Function(String videoId)? manifestFetcher;

  /// Session bundle memo: videoId → (meta + muxed video URLs). Audio
  /// URLs stay in [urlCache]; this cache is purely additive (streamkit
  /// BundleCache 1:1 — meta barely changes, 24h mem + 24h disk).
  final sk.BundleCache bundles;

  /// Session visitor bootstrapped from the homepage (cached per
  /// process). A fresh visitorData in context + X-Goog-Visitor-Id
  /// passes the "confirm you're not a bot" gate that otherwise 200s
  /// with LOGIN_REQUIRED on every leg. Reuses the persisted YtSession
  /// value when present (same field the repo session carries); one
  /// homepage fetch (~200ms) otherwise.
  String? _visitorCache;

  Future<String> ensureSessionVisitor() async {
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
              headers: modernTubeHeaders())
          .timeout(const Duration(seconds: 15));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        final m = RegExp(r'"visitorData"\s*:\s*"([^"]+)"')
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

  void dropSessionVisitor() {
    try {
      _visitorCache = null;
    } catch (_) {}
  }

  YoutubeExplode? _yt;
  final Map<String, Future<String?>> _flight = {};

  /// Single-flight for full bundles: concurrent bundleFor(id) joins one
  /// race (no double 6-leg network). Removed on completion; capped.
  final Map<String, Future<sk.StreamBundle?>> _bundleFlight = {};

  /// Negative memo: dead videoIds (total miss) skip race + extractor for
  /// 5m, then retry. Cleared on success. Capped. Never throws.
  final Map<String, int> _bundleDeadAt = {};
  static const int bundleMissTtlMs = 5 * 60 * 1000;
  static const int bundleMissCap = 200;

  bool _bundleSkipped(String videoId, int nowMs) {
    try {
      final at = _bundleDeadAt[videoId];
      if (at == null) return false;
      if (nowMs - at > bundleMissTtlMs) {
        _bundleDeadAt.remove(videoId);
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void _bundleMarkDead(String videoId, int nowMs) {
    try {
      if (videoId.isEmpty) return;
      _bundleDeadAt[videoId] = nowMs;
      while (_bundleDeadAt.length > bundleMissCap) {
        _bundleDeadAt.remove(_bundleDeadAt.keys.first);
      }
    } catch (_) {}
  }

  /// Muxed / video-only URL memo: play watchUrl → ranked (url, height).
  /// Extractor-warmed rows (open + [primeVideoNext] prefetch) so repeat,
  /// next/prev and auto-advance opens skip the seconds-long manifest
  /// decipher. URLs only (strings — bytes ride ExoPlayer's own cache on
  /// play-through). Capped + TTL'd (native 5h URL TTL parity). The bundle
  /// memo stays the second tier (free video URLs + meta from the audio
  /// race). All access guarded; never throws.
  static const int videoMemoCap = 32;
  static const int videoMemoTtlMs = 5 * 60 * 60 * 1000;
  final Map<String, _VideoMemoRow> _videoMemoMuxed = {};
  final Map<String, _VideoMemoRow> _videoMemoOnly = {};

  /// Joins concurrent opens of the same video URL (skip-during-prefetch):
  /// the extractor manifest decipher runs once, latecomers await it.
  /// Entries removed on completion; capped. Never throws.
  final Map<String, Future<List<(String, int)>>> _videoFlight = {};

  /// Per-hop video budget: every tier (extractor manifest, bundle race)
  /// gets 8s; the outer single-flight join gets 20s. A dead track used
  /// to stack 30s + 20s inside a 50s outer, twice (muxed then video-only)
  /// behind an 8s + 8s music-video search — ~100s+ of spinner per track,
  /// so N dead tracks in a row read as an endless loading-skipping storm.
  /// Every hop below honors [videoHopTimeout]; callers bound the join at
  /// [videoOuterTimeout]. Never throws.
  static const Duration videoHopTimeout = Duration(seconds: 8);
  static const Duration videoOuterTimeout = Duration(seconds: 20);

  /// Negative memo for video tiers: watchUrls whose extractor AND bundle
  /// tiers both came back empty skip straight to [] for 5m (zero RTT),
  /// then retry. Cleared on any success. Capped. Never throws. Without
  /// this every repeat visit re-paid the full manifest decipher + race
  /// per dead track (empties were never memoized).
  final Map<String, int> _videoDeadAt = {};
  static const int videoMissTtlMs = 5 * 60 * 1000;
  static const int videoMissCap = 200;

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

  /// Manual-retry escape hatch (Retry / Next-quality buttons): lifts the
  /// 5m negative fast-fail so the next resolve hits network, not memo.
  /// Without this a retry within 5m of a total miss instantly re-fails.
  /// Never throws.
  void clearVideoMiss(String watchUrl) {
    try {
      _videoDeadAt.remove(watchUrl);
    } catch (_) {}
  }

  YoutubeExplode _explode() {
    final yt = _yt;
    if (yt != null) return yt;
    final created = YoutubeExplode(_ModernTubeClient());
    _yt = created;
    return created;
  }

  StreamResolver({
    http.Client? httpClient,
    UrlCache? urlCache,
    sk.BundleCache? bundles,
    String Function()? cookies,
    String Function()? visitorData,
    String Function()? poToken,
    bool Function()? useInnerTube,
    this.manifestFetcher,
  })  : httpClient = httpClient ?? http.Client(),
        urlCache = urlCache ?? UrlCache(),
        bundles = bundles ?? sk.BundleCache(),
        cookies = cookies ?? (() => ''),
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

  /// Session-cached signature timestamp for the phone leg (player-build
  /// scoped; refresh when the phone leg stops returning playable URLs).
  int _sts = 0;

  Future<int> _stsFor(String videoId) async {
    try {
      if (_sts > 0) return _sts;
      final res = await httpClient
          .get(
            Uri.parse(
                'https://www.youtube.com/watch?v=$videoId&app=desktop'),
            headers: sk.scrapeHeaders(),
          )
          .timeout(const Duration(seconds: 12));
      if (res.statusCode < 200 || res.statusCode >= 300) return 0;
      final sts = parseSts(res.body);
      if (sts > 0) _sts = sts;
      return sts;
    } catch (_) {
      return _sts;
    }
  }

  /// Full decoded player response (or null). One call carries
  /// streamingData (audio + muxed video) AND videoDetails (metadata).
  /// Uses the bootstrapped session visitor (bot-gate parity: the
  /// visitor rides both context and X-Goog-Visitor-Id).
  Future<Map<String, dynamic>?> playerJson(
    String videoId,
    TubeClient client, {
    int signatureTimestamp = 0,
  }) async {
    try {
      final visitor = _visitorCache ?? visitorData();
      final res = await httpClient
          .post(
            Uri.parse(tubeUrl(client, 'player',
                host: 'https://music.youtube.com')),
            headers: tubeHeaders(
              client,
              cookies: cookies(),
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

  Future<List<String>> _playerLeg(String videoId, TubeClient client,
      {int signatureTimestamp = 0}) async {
    try {
      final root = await playerJson(videoId, client,
          signatureTimestamp: signatureTimestamp);
      if (root == null) return [];
      return parsePlayerUrls(root);
    } catch (_) {
      return [];
    }
  }

  Future<List<String>> _phoneLeg(String videoId) async {
    try {
      final sts = await _stsFor(videoId);
      if (sts <= 0) return [];
      return await _playerLeg(videoId, TubeClient.androidPhone,
          signatureTimestamp: sts);
    } catch (_) {
      return [];
    }
  }

  /// Ranked audio URLs, best-first. VISIONOS vs VR race first (both
  /// serve direct signed URLs; VISIONOS is the leg YouTube does NOT
  /// poToken-gate at fetch), then MUSIC, WEB_REMIX, then the phone
  /// leg, then extractor manifest in [audioUrls]. The phone leg stays
  /// last: its URLs can 403 at fetch while a non-empty list blocks
  /// extractor fallback — only use when nothing else resolved.
  Future<List<String>> tubeAudioUrls(String videoId) async {
    try {
      final vrFuture = _playerLeg(videoId, TubeClient.androidVr);
      List<String> vis = [];
      try {
        vis = await _playerLeg(videoId, TubeClient.visionos);
      } catch (_) {}
      if (vis.isNotEmpty) return vis; // stragglers ignored.
      try {
        final vr = await vrFuture;
        if (vr.isNotEmpty) return vr;
      } catch (_) {}
      try {
        final music = await _playerLeg(videoId, TubeClient.androidMusic);
        if (music.isNotEmpty) return music;
      } catch (_) {}
      try {
        final remix =
            await _playerLeg(videoId, TubeClient.webRemix);
        if (remix.isNotEmpty) return remix;
      } catch (_) {}
      // Phone leg last: its URLs can 403 at fetch while a non-empty
      // list blocks extractor fallback — only use when nothing else
      // resolved.
      try {
        final phone =
            await _phoneLeg(videoId).timeout(const Duration(seconds: 15));
        if (phone.isNotEmpty) return phone;
      } catch (_) {}
      return const [];
    } catch (_) {
      return const [];
    }
  }

  /// In-flight leg futures of the latest race per videoId (never
  /// throwing; each resolves to (clientName, rankedAudioUrls)). The
  /// race returns its winner at first-audio, but every leg keeps
  /// flying — [extraAudioUrls] harvests the losers' URLs when the
  /// winner's URLs 403 at open (GVS poToken rollout 403s some legs'
  /// URLs at fetch on flagged IPs while other legs play fine).
  /// Bounded to 32 entries; consumed on read.
  final Map<String, List<Future<(String, List<String>)>>> _legFlights =
      {};

  /// First-wins race across IOS / VISIONOS / VR / MUSIC / REMIX / PHONE:
  /// all six POSTs fly in parallel and the first response carrying
  /// playable audio wins (~1 RTT). IOS and VISIONOS lead (no poToken
  /// gate, direct URLs — yt-dlp's primary defaults since 2025.11);
  /// the Android legs answer LOGIN_REQUIRED or serve selectively-403'd
  /// URLs on flagged IPs, so they only win where they genuinely play.
  /// Losers are ignored for the bundle but their URLs stay harvestable
  /// via [extraAudioUrls]. Bounded by [playerLegTimeout]. Seeds fill
  /// metadata gaps when videoDetails is absent (age-restricted
  /// responses that still stream).
  Future<sk.StreamBundle?> raceBundles(
    String videoId, {
    String seedTitle = '',
    String seedArtist = '',
    String seedThumb = '',
  }) async {
    const legs = [
      TubeClient.ios,
      TubeClient.visionos,
      TubeClient.androidVr,
      TubeClient.androidMusic,
      TubeClient.webRemix,
      TubeClient.androidPhone,
    ];
    // Bootstrap the session visitor first (cached after the first
    // call); playerJson picks it up from the cache. Without it every
    // leg 200s LOGIN_REQUIRED under bot-gating.
    await ensureSessionVisitor();
    final win = Completer<sk.StreamBundle?>();
    var pending = legs.length;
    void settle(sk.StreamBundle? b) {
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

    final flights = <Future<(String, List<String>)>>[];
    for (final client in legs) {
      try {
        final f = playerJson(videoId, client);
        flights.add(f.then((root) {
          if (root == null) return (client.name, const <String>[]);
          return (client.name, sk.parseBundleAudio(root));
        }).catchError((_) => (client.name, const <String>[])));
        unawaited(f.then((root) {
          try {
            if (root == null) {
              settle(null);
              return;
            }
            settle(sk.parsePlayerBundle(root, videoId,
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
      _legFlights[videoId] = flights;
      while (_legFlights.length > 32) {
        _legFlights.remove(_legFlights.keys.first);
      }
    } catch (_) {}
    try {
      return await win.future.timeout(playerLegTimeout);
    } catch (_) {
      return null;
    }
  }

  /// Full audio candidate list across EVERY race leg (not just the
  /// winner), merged in leg-priority order with [exclude] dropped.
  /// The legs flew in parallel during the race, so by open-failure
  /// time this is a near-instant merge — no extra round trips. Empty
  /// when no other leg carried audio (or no race ran for [videoId]).
  /// Never throws.
  Future<List<String>> extraAudioUrls(String videoId,
      {List<String> exclude = const []}) async {
    try {
      final flights = _legFlights.remove(videoId);
      if (flights == null || flights.isEmpty) return const [];
      final results = await Future.wait(flights).timeout(
          playerLegTimeout + const Duration(seconds: 2),
          onTimeout: () => const []);
      final seen = <String>{...exclude};
      final out = <String>[];
      for (final r in results) {
        for (final u in r.$2) {
          if (u.isNotEmpty && seen.add(u)) out.add(u);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  /// Full stream bundle for a video id: ranked audio + muxed video +
  /// metadata. Memory first: a fresh [urlCache] row serves instantly
  /// (~microseconds, zero round trips — this is what makes precached
  /// skips instant) with video/meta riding the bundle memo when present
  /// and seeds filling meta gaps; rows past [urlRefreshAfterMs] trigger
  /// ONE background refresh so hot tracks never go cold mid-session.
  /// Dead ids short-circuit via negative memo (5m TTL, zero RTT); on
  /// miss concurrent callers join one resolve (single-flight). On miss
  /// the winner's best audio URL is remembered in [urlCache]
  /// (so [audioUrl] mem-hits) and meta/video in [bundles]. The phone
  /// leg already races up front, so only the extractor manifest
  /// remains as fallback when the race comes back empty — and a
  /// metadata-only gap NEVER blocks stream delivery (the About panel
  /// backfills via DetailsStore.load). Never throws; null only when
  /// nothing resolved at all.
  Future<sk.StreamBundle?> bundleFor(
    String videoId, {
    String seedTitle = '',
    String seedArtist = '',
    String seedThumb = '',
  }) async {
    try {
      if (videoId.length != 11) return null;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_bundleSkipped(videoId, now)) return null;
      try {
        final hit = urlCache.getFresh(
            'https://www.youtube.com/watch?v=$videoId', now);
        if (hit != null && hit.isNotEmpty) {
          try {
            final at =
                urlCache.rows['https://www.youtube.com/watch?v=$videoId']
                        ?.atMs ??
                    now;
            if (now - at > urlRefreshAfterMs) {
              unawaited(_refreshBundle(videoId,
                  seedTitle: seedTitle,
                  seedArtist: seedArtist,
                  seedThumb: seedThumb));
            }
          } catch (_) {}
          final memVideo = bundles.videoFor(videoId, now);
          var meta = bundles.metaFor(videoId, now) ??
              sk.TrackMeta.empty(videoId);
          if (!meta.hasDetails && seedTitle.isNotEmpty) {
            meta = sk.TrackMeta(
              videoId: videoId,
              title: seedTitle,
              artist: seedArtist.isEmpty ? 'Unknown Artist' : seedArtist,
              thumbUrl: seedThumb,
            );
          }
          return sk.StreamBundle(
              videoId: videoId,
              audioUrls: [hit],
              videoUrls: memVideo,
              meta: meta);
        }
      } catch (_) {}
      // Single-flight: one genuine resolve per videoId at a time.
      final existing = _bundleFlight[videoId];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {
          return null;
        }
      }
      final mine = _bundleFresh(videoId,
              seedTitle: seedTitle,
              seedArtist: seedArtist,
              seedThumb: seedThumb)
          .timeout(resolveCap)
          .catchError((_) => null);
      _bundleFlight[videoId] = mine;
      try {
        while (_bundleFlight.length > 32) {
          _bundleFlight.remove(_bundleFlight.keys.first);
        }
      } catch (_) {}
      try {
        return await mine;
      } finally {
        try {
          if (_bundleFlight[videoId] == mine) {
            _bundleFlight.remove(videoId);
          }
        } catch (_) {}
      }
    } catch (_) {
      return null;
    }
  }

  /// Background refresh-behind for near-expiry mem-hit rows: a genuine
  /// re-race (bypasses the memo, so it cannot self-trigger). 20s cap,
  /// silent. Never throws.
  Future<void> _refreshBundle(
    String videoId, {
    String seedTitle = '',
    String seedArtist = '',
    String seedThumb = '',
  }) async {
    try {
      await _bundleFresh(videoId,
              seedTitle: seedTitle,
              seedArtist: seedArtist,
              seedThumb: seedThumb)
          .timeout(const Duration(seconds: 20));
    } catch (_) {}
  }

  /// Genuine network resolve behind [bundleFor]'s memo (race + extractor
  /// fallback). Same contract as the old bundleFor body; never throws.
  Future<sk.StreamBundle?> _bundleFresh(
    String videoId, {
    String seedTitle = '',
    String seedArtist = '',
    String seedThumb = '',
  }) async {
    try {
      if (videoId.length != 11) return null;
      final now = DateTime.now().millisecondsSinceEpoch;
      final watchUrl = 'https://www.youtube.com/watch?v=$videoId';
      sk.StreamBundle? b;
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
      sk.TrackMeta meta = b != null
          ? b.meta
          : (bundles.metaFor(videoId, now) ?? sk.TrackMeta.empty(videoId));
      if (audio.isEmpty) {
        try {
          final ranked = await _manifestUrls(videoId);
          for (final u in ranked) {
            if (u.isNotEmpty && !audio.contains(u)) audio.add(u);
          }
        } catch (_) {}
      }
      if (audio.isEmpty) {
        _bundleMarkDead(videoId, DateTime.now().millisecondsSinceEpoch);
        return null;
      }
      if (!meta.hasDetails && seedTitle.isNotEmpty) {
        meta = sk.TrackMeta(
          videoId: videoId,
          title: seedTitle,
          artist: seedArtist.isEmpty ? 'Unknown Artist' : seedArtist,
          thumbUrl: seedThumb,
        );
      }
      final out = sk.StreamBundle(
          videoId: videoId, audioUrls: audio, videoUrls: video, meta: meta);
      try {
        urlCache.remember(watchUrl, audio.first, now);
        bundles.remember(out, now);
        _bundleDeadAt.remove(videoId);
      } catch (_) {}
      return out;
    } catch (_) {
      return null;
    }
  }

  /// Bounded parallel precache for search hits (search fast path):
  /// resolves the top [max] tracks CONCURRENTLY in one Future.wait
  /// (10s per-track timeout) instead of serially, so tap-to-play mem-
  /// hits even when search returned a full page. Cache-fresh rows are
  /// skipped before any network (instant, zero round trips); metadata
  /// gaps backfill via DetailsStore. [max] bounds the work to the rows
  /// the user can plausibly tap first. Never throws.
  Future<void> primeSearchTop(List<YtTrack> tracks, {int max = 4}) async {
    try {
      if (tracks.isEmpty || max <= 0) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final pending = <YtTrack>[];
      for (final t in tracks.take(max)) {
        try {
          // Instant path: already-resolved rows cost no round trip.
          if (urlCache.getFresh(t.watchUrl, now) != null) continue;
          pending.add(t);
        } catch (_) {
          pending.add(t);
        }
      }
      if (pending.isEmpty) return;
      await Future.wait([
        for (final t in pending)
          audioUrl(t.watchUrl)
              .timeout(const Duration(seconds: 10))
              .catchError((_) => null),
      ]);
    } catch (_) {}
  }

  /// Prefetches bundles for upcoming tracks. Bounded batches of 3; each
  /// bundle self-bounds, so a dead track never stalls the row. Warms
  /// [urlCache] + [bundles] so playback and metadata reads mem-hit.
  /// Warm + negatively-dead rows are skipped before any network (zero
  /// RTT for already-resolved tracks). Never throws.
  Future<void> primeNext(List<YtTrack> tracks) async {
    try {
      if (tracks.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final pending = <YtTrack>[];
      for (final t in tracks) {
        try {
          if (t.id.isEmpty) continue;
          if (_bundleSkipped(t.id, now)) continue;
          if (t.watchUrl.isNotEmpty &&
              urlCache.getFresh(t.watchUrl, now) != null) {
            continue;
          }
          pending.add(t);
        } catch (_) {
          pending.add(t);
        }
      }
      if (pending.isEmpty) return;
      for (var i = 0; i < pending.length; i += 3) {
        try {
          final batch = pending.skip(i).take(3).toList();
          await Future.wait([
            for (final t in batch)
              bundleFor(t.id,
                      seedTitle: t.title,
                      seedArtist: t.artist,
                      seedThumb: t.thumbUrl)
                  .timeout(const Duration(seconds: 20))
                  .catchError((_) => null),
          ]);
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Warms audio URLs for ranked Up Next suggestions (the top [max] of
  /// an already-ranked list): tap-to-play mem-hits instead of spinning.
  /// Thin bounded wrapper over [primeNext] (batches of 3, warm + dead
  /// rows skipped before any network). Same signature family; never
  /// throws.
  Future<void> primeSuggestions(List<YtTrack> ranked, {int max = 3}) async {
    try {
      if (ranked.isEmpty || max <= 0) return;
      await primeNext(ranked.take(max).toList());
    } catch (_) {}
  }

  /// Deciphered extractor manifest audio URLs (native parity
  /// fallback tier). Slow on constrained networks; call only after
  /// race URLs fail at open, at most once per track load.
  /// Same signature family; never throws.
  Future<List<String>> manifestAudioUrls(String videoId) async {
    try {
      if (videoId.length != 11) return const [];
      return await _manifestUrls(videoId);
    } catch (_) {
      return const [];
    }
  }

  Future<List<String>> _manifestUrls(String videoId) async {
    try {
      if (manifestFetcher != null) return await manifestFetcher!(videoId);
      // Watch-page scrape is slow on constrained networks (it carries
      // the n/sig decipher context the URLs need); sized to fit inside
      // the outer resolve cap after the 8s race legs.
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

  /// Ranked muxed (video+audio) URLs, best-first distinct heights —
  /// P9 video mode (VideoSheet quality picker + native videoOptions).
  /// Memo first (extractor-warmed rows from opens + [primeVideoNext]:
  /// microseconds, zero round trips), bundle memo second (free with the
  /// audio race), then extractor manifest and bundle race IN PARALLEL
  /// (each 8s-bounded, extractor winning ties — verified on-device: raw
  /// InnerTube `formats` URLs 500 in ExoPlayer
  /// (`InvalidResponseCodeException: 500`) while the extractor's
  /// deciphered muxed URLs play). Total miss marks the negative memo
  /// (5m fast-fail, respected on every tier + prefetch). Concurrent
  /// opens of one URL join a single fetch (single-flight). Wins memoized
  /// (URL memo + bundle memo, existing meta preserved) so the next open
  /// mem-hits. Same signature; never throws.
  Future<List<(String, int)>> videoMuxedUrls(String watchUrl) async {
    try {
      final vid = extractVideoId(watchUrl);
      if (vid == null) return const [];
      final now = DateTime.now().millisecondsSinceEpoch;
      // Fast-fail known-dead rows (negative memo respected everywhere).
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
        } catch (_) {}
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

  /// Genuine fetch behind [videoMuxedUrls]' memo + single-flight:
  /// extractor manifest and bundle race fly IN PARALLEL (were sequential
  /// 30s + 20s), each 8s-bounded. Extractor wins ties (verified
  /// on-device: its deciphered muxed URLs play where raw InnerTube
  /// `formats` URLs 500). Wins memoized; total miss marks the negative
  /// memo. Never throws.
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
        _rememberBundleVideo(vid, ext);
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

  /// Extractor-manifest leg of [_videoMuxedFresh]: deciphered progressive
  /// muxed URLs, best-first distinct heights. 8s-bounded by the caller.
  /// Never throws.
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

  /// Bundle-race leg of [_videoMuxedFresh]: free muxed URLs from the
  /// audio race. 8s-bounded by the caller. Never throws.
  Future<List<(String, int)>> _muxedFromBundle(String vid) async {
    try {
      final b = await bundleFor(vid);
      if (b != null && b.videoUrls.isNotEmpty) return b.videoUrls;
    } catch (_) {}
    return const [];
  }

  /// Ranked video-ONLY (DASH, no audio track) URLs, best-first
  /// distinct heights — picture-only tier for video mode when no muxed
  /// rendition exists anywhere. The embed pairs these muted pictures
  /// with the synced just_audio soundtrack as master clock (focus-last
  /// ordering, same as the muxed path). Memo first, extractor manifest
  /// (signature-deciphered URLs) second; wins memoized. The bundle
  /// carries no video-only store, so there is no bundle tier. Same
  /// signature; never throws.
  Future<List<(String, int)>> videoOnlyUrls(String watchUrl) async {
    try {
      final vid = extractVideoId(watchUrl);
      if (vid == null) return const [];
      final now = DateTime.now().millisecondsSinceEpoch;
      // Fast-fail known-dead rows (negative memo respected everywhere).
      if (_videoSkipped(watchUrl, now)) return const [];
      final hit = _videoMemoHit(_videoMemoOnly, watchUrl, now);
      if (hit != null) return hit;
      final key = 'only:$watchUrl';
      final existing = _videoFlight[key];
      if (existing != null) {
        try {
          return await existing;
        } catch (_) {}
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

  /// Genuine fetch behind [videoOnlyUrls]' memo + single-flight. Wins
  /// memoized; total miss marks the negative memo (shared with the muxed
  /// tier: a URL dead for both tiers fast-fails everywhere). 8s-bounded.
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
          ..sort((a, b) => b.videoResolution.height.compareTo(
              a.videoResolution.height))) {
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

  /// Evicts one dead video URL from both muxed + video-only memos (call
  /// after an ExoPlayer open failure: expired/throttled URL, 4xx/5xx).
  /// Without this the memo re-served the same dead URL on every retry
  /// while the slot sat on loading. Rows drained to empty are removed
  /// (miss → fresh fetch, not fast-fail). The negative memo is left
  /// alone (it only marks total-empty tiers). Same signature family;
  /// never throws.
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

  /// Fresh memo row, or null (missing / expired / empty). Expired rows
  /// evicted on read (5h URL TTL parity). Never throws.
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

  /// Stores a memo row, evicting oldest-first past [videoMemoCap].
  /// Never throws.
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

  /// Merges extractor-warmed muxed URLs into the bundle memo so later
  /// bundle/video reads mem-hit. Existing meta is preserved (an empty
  /// shell must never clobber resolved details). Never throws.
  void _rememberBundleVideo(String videoId, List<(String, int)> urls) {
    try {
      if (videoId.isEmpty || urls.isEmpty) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      final keep = bundles.metaFor(videoId, now);
      bundles.remember(
          sk.StreamBundle(
              videoId: videoId,
              audioUrls: const [],
              videoUrls: List.of(urls),
              meta: keep ?? sk.TrackMeta.empty(videoId)),
          now);
    } catch (_) {}
  }

  /// Video-mode prefetch: warms the official-video muxed URLs for the
  /// next [max] queue tracks (URL memo + bundle memo) so tapping next /
  /// prev or auto-advance opens instantly with no resolve spinner.
  /// [resolveMusicVideoUrl] maps each queue entry to its official-video
  /// watch URL (repository memo: already 8s-bounded + session-cached).
  /// At most [max] tracks in ONE parallel wave, 8s per hop
  /// (music-video search, muxed fetch, video-only fallback each), rows
  /// already warm skipped before any network. URLs only (no bytes —
  /// ExoPlayer caches bytes on play-through). Silent; never throws.
  Future<void> primeVideoNext(
      List<YtTrack> tracks,
      Future<String> Function(YtTrack track) resolveMusicVideoUrl,
      {int max = 2}) async {
    try {
      if (tracks.isEmpty || max <= 0) return;
      final slice = tracks.take(max).toList();
      if (slice.isEmpty) return;
      await Future.wait([
        for (final t in slice)
          _primeOneVideo(t, resolveMusicVideoUrl)
              .timeout(const Duration(seconds: 20))
              .catchError((_) => null),
      ]);
    } catch (_) {}
  }

  /// Warms one track's official-video muxed (else video-only) URLs.
  /// Never throws.
  Future<void> _primeOneVideo(YtTrack track,
      Future<String> Function(YtTrack track) resolveMusicVideoUrl) async {
    try {
      var playUrl = track.watchUrl;
      if (playUrl.isEmpty) return;
      try {
        final mv = await resolveMusicVideoUrl(track)
            .timeout(const Duration(seconds: 8));
        if (mv.isNotEmpty) playUrl = mv;
      } catch (_) {}
      final vid = extractVideoId(playUrl);
      final now = DateTime.now().millisecondsSinceEpoch;
      try {
        // Known-dead rows stay dead without burning prefetch network.
        if (_videoSkipped(playUrl, now)) return;
        if (_videoMemoHit(_videoMemoMuxed, playUrl, now) != null) return;
        if (_videoMemoHit(_videoMemoOnly, playUrl, now) != null) return;
        if (vid != null && bundles.videoFor(vid, now).isNotEmpty) return;
      } catch (_) {}
      List<(String, int)> opts = const [];
      try {
        opts = await videoMuxedUrls(playUrl)
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        opts = const [];
      }
      if (opts.isNotEmpty) return;
      try {
        await videoOnlyUrls(playUrl)
            .timeout(const Duration(seconds: 8));
      } catch (_) {}
    } catch (_) {}
  }

  /// Ranked audio URLs for a watch URL. Fast path first (remembers best),
  /// extractor fallback, empty on failure.
  Future<List<String>> audioUrls(String watchUrl) async {
    try {
      final vid = extractVideoId(watchUrl);
      if (vid == null) return [];
      if (useInnerTube()) {
        try {
          final fast = await tubeAudioUrls(vid);
          if (fast.isNotEmpty) {
            urlCache.remember(
                watchUrl, fast.first, DateTime.now().millisecondsSinceEpoch);
            return fast;
          }
        } catch (_) {}
      }
      final ranked = await _manifestUrls(vid);
      if (ranked.isNotEmpty) {
        urlCache.remember(
            watchUrl, ranked.first, DateTime.now().millisecondsSinceEpoch);
      }
      return ranked;
    } catch (_) {
      return [];
    }
  }

  /// Full candidate list via [bundleFor]: tube-leg race first, then
  /// deciphered extractor manifest URLs appended (deduped) only when
  /// the race yields none. Playback tries each in order — when every
  /// InnerTube URL 403s at fetch (throttled network), the deciphered
  /// manifest URLs still get their chance instead of the track being
  /// skipped. Same signature; never throws.
  Future<List<String>> audioUrlsAll(String watchUrl) async {
    try {
      final vid = extractVideoId(watchUrl);
      if (vid == null) return [];
      final b = await bundleFor(vid).timeout(resolveCap);
      if (b == null || !b.hasAudio) return [];
      return List.of(b.audioUrls);
    } catch (_) {
      return [];
    }
  }

  /// Best audio URL. 5h mem first (fresh rows serve instantly, zero
  /// RTT); dead ids short-circuit via negative memo; concurrent callers
  /// join one resolve (single-flight); 45s cap; null on failure.
  /// Never throws.
  Future<String?> audioUrl(String watchUrl) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final hit = urlCache.getFresh(watchUrl, now);
      if (hit != null) {
        // Near-expiry refresh-behind: the fresh URL still serves
        // instantly while the row self-heats before it dies.
        try {
          final vid = extractVideoId(watchUrl);
          if (vid != null) {
            final at = urlCache.rows[watchUrl]?.atMs ?? now;
            if (now - at > urlRefreshAfterMs) {
              unawaited(_refreshBundle(vid));
            }
          }
        } catch (_) {}
        return Future.value(hit);
      }
      try {
        final vid = extractVideoId(watchUrl);
        if (vid != null && _bundleSkipped(vid, now)) {
          return Future.value(null);
        }
      } catch (_) {}
      final existing = _flight[watchUrl];
      if (existing != null) return existing;
      final mine =
          audioUrls(watchUrl).timeout(resolveCap).then((l) {
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

  /// Drops a stale cached URL (e.g. after a 403) so the next resolve
  /// refetches. Retry ×3 then skip lives in the queue engine (P12).
  void dropCachedUrl(String watchUrl) => urlCache.drop(watchUrl);

  /// Fast pre-flight: 0-byte Range probe (6 s cap). True on 200/206 —
  /// the URL opens cleanly in ExoPlayer. False (403/timeout) skips the
  /// candidate without paying a full player-open timeout.
  Future<bool> probeUrl(String url) async {
    try {
      final res = await httpClient
          .get(
            Uri.parse(url),
            headers: const {
              'User-Agent': 'Cresca/1.0 (Android)',
              'Range': 'bytes=0-0',
            },
          )
          .timeout(const Duration(seconds: 6));
      return res.statusCode == 200 || res.statusCode == 206;
    } catch (_) {
      return false;
    }
  }

  /// Disk snapshot encode (caller owns file IO; null honors the 30s floor).
  String? encodeUrlSnapshot() {
    try {
      final snap = urlCache.snapshotForDisk(
          DateTime.now().millisecondsSinceEpoch);
      if (snap == null) return null;
      return jsonEncode(snap);
    } catch (_) {
      return null;
    }
  }

  /// Disk snapshot restore. Returns restored row count.
  int restoreUrlSnapshot(String json) {
    try {
      final root = jsonDecode(json);
      if (root is! Map) return 0;
      return urlCache.restoreFromDisk(
          root.cast<String, dynamic>(), DateTime.now().millisecondsSinceEpoch);
    } catch (_) {
      return 0;
    }
  }
  /// Bundle snapshot encode (meta + muxed video URLs, 24h TTL inside;
  /// caller owns file IO, yt_meta.json). Null honors write floors or
  /// when nothing worth persisting.
  String? encodeBundleSnapshot() {
    try {
      final snap = bundles.snapshotForDisk(
          DateTime.now().millisecondsSinceEpoch);
      if (snap == null) return null;
      return jsonEncode(snap);
    } catch (_) {
      return null;
    }
  }

  /// Bundle snapshot restore. Returns restored row count.
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

// ---------- official music video (video-mode YTM parity) ----------
//
// Video mode plays the song's OFFICIAL music video, not the audio
// track's own (often static art-track) stream. The repository searches
// "<title> <artist> official music video" and ranks candidates with
// [scoreMusicVideoCandidate]; these helpers are pure (no network) so
// `flutter test` covers the scoring with zero network.

/// Search query for a track's official video. Label-ish/blank artists
/// degrade to title-only so the query never carries junk.
String musicVideoQuery(YtTrack track) {
  try {
    final t =
        track.title.trim().replaceAll(RegExp(r'\s+'), ' ');
    var a = track.artist.trim().replaceAll(RegExp(r'\s+'), ' ');
    final low = a.toLowerCase();
    if (a.isEmpty ||
        low == 'youtube' ||
        low == 'unknown artist') {
      a = '';
    }
    if (t.isEmpty) return '';
    return a.isEmpty ? '$t official music video' : '$t $a official music video';
  } catch (_) {
    return '';
  }
}

/// Title words that carry song identity. Video-kind words
/// (official/video/music/...) are excluded so overlap measures the
/// SONG title, not the upload kind. Tokens are >= 2 chars.
Set<String> mvTokens(String s) {
  try {
    const stop = {
      'official',
      'video',
      'videos',
      'music',
      'audio',
      'lyric',
      'lyrics',
      'visualizer',
      'visualiser',
      'mv',
      'hq',
      'hd',
      'full',
      'vevo',
    };
    return s
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .where((e) => e.length >= 2 && !stop.contains(e))
        .toSet();
  } catch (_) {
    return const {};
  }
}

/// True when the candidate shares at least one song-title token with
/// the seed (acceptance gate: junk with no title relation never wins).
bool mvSharesTitle(String seedTitle, String candTitle) {
  try {
    final seeds = mvTokens(seedTitle);
    if (seeds.isEmpty) return false;
    final raw = candTitle
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9]+'))
        .toSet();
    return seeds.any(raw.contains);
  } catch (_) {
    return false;
  }
}

/// Ranks one official-video candidate for [seedTitle]/[seedArtist].
/// Weights: title token overlap +2 each (cap +10); 'official video'
/// +6 (bare 'official' +3); 'music video' +2; standalone MV +2;
/// VEVO channel +4 ('official' channel +2); exact artist +5 (token
/// overlap +2); duration within ±15s +4 (±30s +2, >60s −4, only when
/// both durations are known); lyric −8, cover −6 (these uploads are
/// never the official video, and the penalty outweighs short-title
/// token overlap). Never throws.
int scoreMusicVideoCandidate({
  required String seedTitle,
  required String seedArtist,
  required String candTitle,
  required String candArtist,
  int seedDurationSec = -1,
  int candDurationSec = -1,
}) {
  try {
    var s = 0;
    final ct = candTitle.toLowerCase();
    try {
      final seeds = mvTokens(seedTitle);
      final raw =
          ct.split(RegExp(r'[^a-z0-9]+')).toSet();
      var shared = 0;
      for (final w in seeds) {
        if (raw.contains(w)) shared++;
      }
      s += (shared * 2).clamp(0, 10);
    } catch (_) {}
    if (ct.contains('official video') ||
        ct.contains('official music video')) {
      s += 6;
    } else if (ct.contains('official')) {
      s += 3;
    }
    if (ct.contains('music video')) s += 2;
    try {
      if (RegExp(r'(^|[^a-z])mv([^a-z]|$)').hasMatch(ct)) {
        s += 2;
      }
    } catch (_) {}
    try {
      final ca = candArtist.toLowerCase();
      if (ca.contains('vevo')) s += 4;
      if (ca.contains('official')) s += 2;
    } catch (_) {}
    try {
      final sk = artistKeyOf(seedArtist);
      final ck = artistKeyOf(candArtist);
      if (sk.isNotEmpty &&
          sk == ck &&
          sk != 'unknown artist' &&
          sk != 'youtube') {
        s += 5;
      } else {
        final st = artistTokensOf(seedArtist);
        final dt = artistTokensOf(candArtist);
        if (st.isNotEmpty && st.any(dt.contains)) s += 2;
      }
    } catch (_) {}
    try {
      if (seedDurationSec > 0 && candDurationSec > 0) {
        final d = (seedDurationSec - candDurationSec).abs();
        if (d <= 15) {
          s += 4;
        } else if (d <= 30) {
          s += 2;
        } else if (d > 60) {
          s -= 4;
        }
      }
    } catch (_) {}
    if (ct.contains('lyric')) s -= 8;
    if (ct.contains('cover')) s -= 6;
    return s;
  } catch (_) {
    return 0;
  }
}

/// Memoized ranked video URLs (muxed or video-only): (url, height)
/// pairs plus write time. URLs only — bytes ride the native player's
/// own cache on play-through.
class _VideoMemoRow {
  final List<(String, int)> urls;
  final int atMs;
  const _VideoMemoRow(this.urls, this.atMs);
}
