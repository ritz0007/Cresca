// Stream-URL resolve: InnerTube player race + extractor fallback.
// Native refs: InnerTubeApi.audioUrls/playerUrls/collectAudio (race
// ANDROID_MUSIC vs ANDROID_VR 8s, then WEB_REMIX; OK-status gate,
// audio-only direct URLs, bitrate sort), YoutubeRepository.audioUrls/
// audioUrl/dropCachedUrl (fast-first, remember best, single-flight),
// C4 (45s cap, 403 → drop + ×3 retry → skip; 5h mem + 6h disk).
//
// Transport: package:http with player timeouts (6s); extractor fallback
// via youtube_explode_dart manifest (audioOnly, bitrate sort). Every hop
// timeouts + silent-catches; resolve never throws.

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../core/track.dart';
import 'cache.dart';
import 'innertube.dart';

/// Player request body (InnerTubeApi.playerUrls 1:1). The context MUST
/// match the calling client (name/version/key/headers travel together);
/// a mismatched context silently kills that race leg.
Map<String, dynamic> playerBody(
  TubeClient client,
  String videoId,
  String visitorData, {
  String poToken = '',
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

Map<String, dynamic>? _asMap(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : null;

/// Resolve budget (C4).
const Duration playerLegTimeout = Duration(seconds: 8);
const Duration resolveCap = Duration(seconds: 45);

class StreamResolver {
  final http.Client httpClient;
  final UrlCache urlCache;
  final String Function() cookies;
  final String Function() visitorData;
  final String Function() poToken;
  final bool Function() useInnerTube;

  /// Extractor manifest fetch, injectable for tests (default hits network).
  final Future<List<String>> Function(String videoId)? manifestFetcher;

  YoutubeExplode? _yt;
  final Map<String, Future<String?>> _flight = {};

  StreamResolver({
    http.Client? httpClient,
    UrlCache? urlCache,
    String Function()? cookies,
    String Function()? visitorData,
    String Function()? poToken,
    bool Function()? useInnerTube,
    this.manifestFetcher,
  })  : httpClient = httpClient ?? http.Client(),
        urlCache = urlCache ?? UrlCache(),
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

  Future<List<String>> _playerLeg(String videoId, TubeClient client) async {
    try {
      final res = await httpClient
          .post(
            Uri.parse(tubeUrl(client, 'player',
                host: 'https://music.youtube.com')),
            headers: tubeHeaders(
              client,
              cookies: cookies(),
              visitorData: visitorData(),
              poToken: poToken(),
            ),
            body: jsonEncode(playerBody(client, videoId, visitorData(),
                poToken: poToken())),
          )
          .timeout(playerLegTimeout);
      if (res.statusCode < 200 || res.statusCode >= 300) return [];
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) return [];
      return parsePlayerUrls(decoded.cast<String, dynamic>());
    } catch (_) {
      return [];
    }
  }

  /// Ranked audio URLs, best-first. Race: MUSIC vs VR concurrently
  /// (first non-empty wins, 8s cap each), then WEB_REMIX.
  Future<List<String>> tubeAudioUrls(String videoId) async {
    try {
      final vrFuture = _playerLeg(videoId, TubeClient.androidVr);
      List<String> music = [];
      try {
        music = await _playerLeg(videoId, TubeClient.androidMusic);
      } catch (_) {}
      if (music.isNotEmpty) return music; // VR future ignored (cancelled).
      try {
        final vr = await vrFuture;
        if (vr.isNotEmpty) return vr;
      } catch (_) {}
      try {
        return await _playerLeg(videoId, TubeClient.webRemix);
      } catch (_) {
        return [];
      }
    } catch (_) {
      return [];
    }
  }

  Future<List<String>> _manifestUrls(String videoId) async {
    try {
      if (manifestFetcher != null) return await manifestFetcher!(videoId);
      _yt ??= YoutubeExplode();
      // Watch-page scrape is slow on constrained networks (it carries
      // the n/sig decipher context the URLs need); the outer 45s cap
      // still bounds the whole resolve.
      final manifest = await _yt!.videos.streams
          .getManifest(videoId)
          .timeout(const Duration(seconds: 30));
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

  /// Best audio URL. 5h mem first; concurrent callers join one resolve
  /// (single-flight); 45s cap; null on failure.
  Future<String?> audioUrl(String watchUrl) {
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final hit = urlCache.getFresh(watchUrl, now);
      if (hit != null) return Future.value(hit);
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
}
