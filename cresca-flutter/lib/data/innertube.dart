// Pure-Dart InnerTube youtubei/v1 client specs + response parsers.
// Native refs: innertube/InnerTubeClient.kt (client specs 1:1),
// InnerTubeAuth.kt (SAPISIDHASH + origin headers),
// InnerTubeApi.kt (context/search/b suggestions/browse shapes,
// parseMusicItem/parseVideoItem/parseTwoRowItem/parseSearch/
// parseSuggestions/parseShelves, S3 gates).
//
// HTTP transport lives in repository.dart; this file builds request
// bodies/headers and parses response maps, so `flutter test` covers the
// protocol with canned fixtures and zero network.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../core/track.dart';

/// On-device client specs (InnerTune/Metrolist pattern). Versions pinned
/// from InnerTune; bump only when YouTube 403/400s across clients.
class TubeClient {
  final String name;
  final String version;
  final String apiKey;
  final String userAgent;
  final String? referer;
  final int androidSdkVersion;
  final String osName;
  const TubeClient({
    required this.name,
    required this.version,
    required this.apiKey,
    required this.userAgent,
    this.referer,
    this.androidSdkVersion = 34,
    this.osName = '',
  });

  static const uaWeb =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const uaAndroid =
      'com.google.android.apps.youtube.music/6.42.55 (Linux; U; Android 14) gzip';

  /// music.youtube.com search/browse — shelves, stable.
  static const webRemix = TubeClient(
    name: 'WEB_REMIX',
    version: '1.20260218.01.00',
    apiKey: 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
    userAgent: uaWeb,
    referer: 'https://music.youtube.com/',
  );

  /// Player — direct audio URLs, minimal cipher.
  static const androidMusic = TubeClient(
    name: 'ANDROID_MUSIC',
    version: '6.42.55',
    apiKey: 'AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI',
    userAgent: uaAndroid,
  );

  /// Oculus — direct signed URLs, no cipher (~200ms fast path).
  static const androidVr = TubeClient(
    name: 'ANDROID_VR',
    version: '1.57.21',
    apiKey: 'AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI',
    userAgent: uaAndroid,
  );

  /// Fallback for browse/next when music clients fail.
  static const web = TubeClient(
    name: 'WEB',
    version: '2.20260218.01.00',
    apiKey: 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
    userAgent: uaWeb,
  );

  /// Phone client for the NewPipe-equivalent resolve leg: needs a fresh
  /// signatureTimestamp (see fetchSignatureTimestamp) or the player
  /// answers UNPLAYABLE/LOGIN_REQUIRED like the music clients.
  static const androidPhone = TubeClient(
    name: 'ANDROID',
    version: '20.10.38',
    apiKey: 'AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI',
    userAgent:
        'com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip',
    androidSdkVersion: 30,
    osName: 'Android',
  );
}

String tubeUrl(TubeClient client, String endpoint,
        {String host = 'https://music.youtube.com'}) =>
    '$host/youtubei/v1/$endpoint?key=${client.apiKey}&prettyPrint=false';

Map<String, dynamic> contextMap(TubeClient client, String visitorData) {
  final c = <String, dynamic>{
    'clientName': client.name,
    'clientVersion': client.version,
    'hl': 'en',
    'gl': 'US',
  };
  if (visitorData.isNotEmpty) c['visitorData'] = visitorData;
  if (client.name.startsWith('ANDROID')) {
    c['androidSdkVersion'] = client.androidSdkVersion;
  }
  if (client.osName.isNotEmpty) c['osName'] = client.osName;
  return {
    'client': c,
    'user': {'lockedSafetyMode': false},
  };
}

Map<String, dynamic> searchBody(
        String query, String visitorData) =>
    {
      'context': contextMap(TubeClient.webRemix, visitorData),
      'query': query,
    };

Map<String, dynamic> suggestionBody(
        String input, String visitorData) =>
    {
      'context': contextMap(TubeClient.webRemix, visitorData),
      'input': input,
    };

Map<String, dynamic> browseBody(
        String browseId, String visitorData) =>
    {
      'context': contextMap(TubeClient.webRemix, visitorData),
      'browseId': browseId,
    };

Map<String, dynamic> nextBody(String videoId, String visitorData,
    {String? playlistId}) {
  final body = <String, dynamic>{
    'context': contextMap(TubeClient.webRemix, visitorData),
    'videoId': videoId,
  };
  if (playlistId != null) body['playlistId'] = playlistId;
  return body;
}

/// SAPISIDHASH for authed calls (InnerTune pattern). Required when
/// cookies carry a login session, else authed player 403s.
String? sapisidHash(String cookies, [int? nowSec]) {
  try {
    final now = nowSec ??
        DateTime.now().millisecondsSinceEpoch ~/ 1000;
    String? sapisid;
    for (final part in cookies.split(';')) {
      final p = part.trim();
      if (p.startsWith('SAPISID=')) {
        sapisid = p.substring('SAPISID='.length).trim();
        break;
      }
    }
    if (sapisid == null || sapisid.isEmpty) return null;
    final input = '$now $sapisid https://music.youtube.com';
    final digest = sha1.convert(utf8.encode(input)).toString();
    return '${now}_$digest';
  } catch (_) {
    return null;
  }
}

/// Origin/auth headers for a youtubei POST (InnerTubeAuth 1:1).
Map<String, String> tubeHeaders(
  TubeClient client, {
  String cookies = '',
  String visitorData = '',
  String poToken = '',
}) {
  final h = <String, String>{
    'Content-Type': 'application/json',
    'X-Goog-Api-Format-Version': '1',
    'X-YouTube-Client-Name': client.name,
    'X-YouTube-Client-Version': client.version,
    'User-Agent': client.userAgent,
    'Origin': 'https://music.youtube.com',
    'X-Origin': 'https://music.youtube.com',
  };
  try {
    if (client.referer != null) h['Referer'] = client.referer!;
    if (visitorData.isNotEmpty) h['X-Goog-Visitor-Id'] = visitorData;
    if (cookies.isNotEmpty) {
      h['Cookie'] = cookies;
      final auth = sapisidHash(cookies);
      if (auth != null) h['Authorization'] = 'SAPISIDHASH $auth';
    }
    if (poToken.isNotEmpty) h['X-Goog-EOM-Visitor-Id'] = poToken;
  } catch (_) {}
  return h;
}

// ---------- response parsing (all best-effort, null/empty on failure) ----------

String? _runsText(dynamic textObj) {
  try {
    if (textObj is! Map) return null;
    final runs = textObj['runs'];
    if (runs is List) {
      final sb = StringBuffer();
      for (final r in runs) {
        if (r is Map) sb.write((r['text'] ?? '').toString());
      }
      final s = sb.toString();
      return s.isNotEmpty ? s : null;
    }
    final simple = (textObj['simpleText'] ?? '').toString();
    return simple.isNotEmpty ? simple : null;
  } catch (_) {
    return null;
  }
}

Map<String, dynamic>? _map(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : null;

/// Walks nested string-keyed maps; null on any miss/shape break.
Map<String, dynamic>? _dig(Map<String, dynamic> root, List<String> keys) {
  try {
    Map<String, dynamic> cur = root;
    for (var i = 0; i < keys.length; i++) {
      final next = _map(cur[keys[i]]);
      if (next == null) return null;
      if (i == keys.length - 1) return next;
      cur = next;
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// "12:34" / "1:02:03" → seconds. Null when no duration segment (lives).
int? parseLengthSec(String len) {
  try {
    final m = RegExp(r'^(?:(\d+):)?([0-5]?\d):([0-5]\d)$')
        .firstMatch(len.trim());
    if (m == null) return null;
    return (int.tryParse(m.group(1) ?? '') ?? 0) * 3600 +
        (int.tryParse(m.group(2) ?? '') ?? 0) * 60 +
        (int.tryParse(m.group(3) ?? '') ?? 0);
  } catch (_) {
    return null;
  }
}

/// True when badges mark a live/upcoming/premiere stream.
bool hasLiveBadge(Map<String, dynamic> r) {
  try {
    final badges = r['badges'];
    if (badges is! List) return false;
    for (final b in badges) {
      final badge = _dig(_map(b) ?? {}, ['metadataBadgeRenderer']);
      final l = ((badge?['label'] ?? '').toString()).toLowerCase();
      if (l.contains('live') ||
          l.contains('upcoming') ||
          l.contains('premiere')) {
        return true;
      }
    }
    return false;
  } catch (_) {
    return false;
  }
}

bool _isReelNav(Map<String, dynamic> r) {
  try {
    final nav = _map(r['navigationEndpoint']);
    return nav != null &&
        (nav.containsKey('reelEndpoint') ||
            nav.containsKey('reelWatchEndpoint'));
  } catch (_) {
    return false;
  }
}

String? _watchId(Map<String, dynamic>? nav) {
  try {
    final id = _map(nav?['watchEndpoint'])?['videoId']?.toString() ?? '';
    return id.length == 11 ? id : null;
  } catch (_) {
    return null;
  }
}

YtTrack? parseMusicItem(Map<String, dynamic> r) {
  try {
    if (_isReelNav(r)) return null;
    String? videoId;
    try {
      videoId = _map(r['playlistItemData'])?['videoId']?.toString();
      if (videoId == null || videoId.isEmpty) {
        videoId = _dig(r, [
          'overlay',
          'musicItemThumbnailOverlayRenderer',
          'content',
          'musicPlayButtonRenderer',
          'playNavigationEndpoint',
          'watchEndpoint',
        ])?['videoId']
            ?.toString();
      }
      if (videoId == null || videoId.isEmpty) {
        videoId = _watchId(_map(r['navigationEndpoint']));
      }
    } catch (_) {}
    if (videoId == null || videoId.length != 11) return null;

    String title = '';
    String artist = 'YouTube';
    int durationSec = -1;
    try {
      final flex = r['flexColumns'];
      if (flex is List && flex.isNotEmpty) {
        final c0 = _map(_map(flex[0])?['musicResponsiveListItemFlexColumnRenderer']);
        title = _runsText(c0?['text']) ?? '';
        if (flex.length > 1) {
          final c1 = _map(
              _map(flex[1])?['musicResponsiveListItemFlexColumnRenderer']);
          final sub = _runsText(c1?['text']) ?? '';
          // Subtitle is "Artist • Album • Duration": first = artist,
          // trailing M:SS = duration (hour-long comps die here).
          final segs = sub
              .split('•')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
          if (segs.isNotEmpty && segs.first.isNotEmpty) {
            artist = segs.first;
          }
          if (segs.isNotEmpty) {
            durationSec = parseLengthSec(segs.last) ?? -1;
          }
        }
      }
    } catch (_) {}
    if (title.isEmpty) return null;
    // Lives have no usable duration segment; badges say LIVE.
    if (durationSec < 0 && hasLiveBadge(r)) return null;
    // Known duration must be a song: 30s-10min.
    if (durationSec >= 0 &&
        (durationSec < 30 || durationSec > 600)) {
      return null;
    }
    if (isMusicJunk(title, artist)) return null;

    String thumb = '';
    try {
      final thumbs = _dig(r, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail'])?['thumbnails'];
      if (thumbs is List && thumbs.isNotEmpty) {
        thumb = ((_map(thumbs.last))?['url'] ?? '').toString();
      }
    } catch (_) {}
    return YtTrack(
      id: videoId,
      title: title,
      artist: artist,
      thumbUrl: sharpThumb(thumb),
      watchUrl: 'https://www.youtube.com/watch?v=$videoId',
    );
  } catch (_) {
    return null;
  }
}

YtTrack? parseVideoItem(Map<String, dynamic> r) {
  try {
    final videoId = (r['videoId'] ?? '').toString();
    if (videoId.length != 11) return null;
    if (hasLiveBadge(r)) return null;
    if (_isReelNav(r)) return null;
    // lengthText "12:34": songs only, 30s-10min.
    try {
      final len = _runsText(r['lengthText']) ?? '';
      if (len.isNotEmpty) {
        final s = parseLengthSec(len);
        if (s != null && (s < 30 || s > 600)) return null;
      }
    } catch (_) {}
    final title = _runsText(r['title']) ?? '';
    if (title.isEmpty) return null;
    String artist = 'YouTube';
    try {
      artist = _runsText(r['ownerText']) ??
          _runsText(r['shortBylineText']) ??
          'YouTube';
    } catch (_) {}
    if (isMusicJunk(title, artist)) return null;
    String thumb = '';
    try {
      final arr = _map(r['thumbnail'])?['thumbnails'];
      if (arr is List && arr.isNotEmpty) {
        thumb = ((_map(arr.last))?['url'] ?? '').toString();
      }
    } catch (_) {}
    return YtTrack(
      id: videoId,
      title: title,
      artist: artist,
      thumbUrl: sharpThumb(thumb),
      watchUrl: 'https://www.youtube.com/watch?v=$videoId',
    );
  } catch (_) {
    return null;
  }
}

YtTrack? parseTwoRowItem(Map<String, dynamic> r) {
  try {
    if (hasLiveBadge(r)) return null;
    if (_isReelNav(r)) return null;
    final videoId = _watchId(_map(r['navigationEndpoint']));
    if (videoId == null) return null;
    final title = _runsText(r['title']) ?? '';
    if (title.isEmpty) return null;
    String artist = 'YouTube';
    try {
      final sub = _runsText(r['subtitle']) ?? '';
      final first = sub.split('•').first.trim();
      if (first.isNotEmpty) artist = first;
    } catch (_) {}
    if (isMusicJunk(title, artist)) return null;
    return YtTrack(
      id: videoId,
      title: title,
      artist: artist,
      thumbUrl: '',
      watchUrl: 'https://www.youtube.com/watch?v=$videoId',
    );
  } catch (_) {
    return null;
  }
}

void collectMaps(dynamic node, String key, List<Map<String, dynamic>> acc) {
  try {
    if (node is Map) {
      final m = node.cast<String, dynamic>();
      if (m.containsKey(key)) {
        final hit = _map(m[key]);
        if (hit != null) acc.add(hit);
      }
      for (final v in m.values) {
        collectMaps(v, key, acc);
      }
    } else if (node is List) {
      for (final e in node) {
        collectMaps(e, key, acc);
      }
    }
  } catch (_) {}
}

/// Search parse: music items first, plain videoRenderer fallback.
/// Dedupes ids, caps at max.
List<YtTrack> parseSearch(Map<String, dynamic> root, int max) {
  final out = <YtTrack>[];
  try {
    final found = <Map<String, dynamic>>[];
    collectMaps(root, 'musicResponsiveListItemRenderer', found);
    final seen = <String>{};
    for (final r in found) {
      try {
        final t = parseMusicItem(r);
        if (t == null) continue;
        if (seen.add(t.id)) out.add(t);
        if (out.length >= max) break;
      } catch (_) {}
    }
    if (out.length < max) {
      final vids = <Map<String, dynamic>>[];
      collectMaps(root, 'videoRenderer', vids);
      for (final r in vids) {
        try {
          final t = parseVideoItem(r);
          if (t == null) continue;
          if (seen.add(t.id)) out.add(t);
          if (out.length >= max) break;
        } catch (_) {}
      }
    }
  } catch (_) {}
  return out;
}

/// Suggestions parse: up to 8, case-insensitive dedupe.
List<String> parseSuggestions(Map<String, dynamic> root) {
  final out = <String>[];
  try {
    final arr = _map(root['contents'])?['searchSuggestionsSectionContents'];
    if (arr is! List) return out;
    for (final e in arr) {
      try {
        final runs = _map(_map(_map(e)?['searchSuggestionRenderer'])?['suggestion'])?['runs'];
        if (runs is! List || runs.isEmpty) continue;
        final sb = StringBuffer();
        for (final r in runs) {
          if (r is Map) sb.write((r['text'] ?? '').toString());
        }
        final text = sb.toString();
        if (text.isNotEmpty &&
            !out.any((s) => s.toLowerCase() == text.toLowerCase())) {
          out.add(text);
        }
        if (out.length >= 8) break;
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// Ordered radio/watch-next panels → tracks (junk-gated).
/// next → contents.twoColumnWatchNextResults.playlist.playlist.contents[]
/// each with playlistPanelVideoRenderer (videoId/title/shortByline).
/// Seed itself + reel endpoints + junk + off-gate durations dropped.
List<YtTrack> parseRadioPanels(
    Map<String, dynamic> root, String seedId, int max) {
  final out = <YtTrack>[];
  try {
    final panels = <Map<String, dynamic>>[];
    collectMaps(root, 'playlistPanelVideoRenderer', panels);
    final seen = <String>{};
    for (final p in panels) {
      try {
        final vid = (p['videoId'] ?? '').toString();
        if (vid.length != 11 || vid == seedId) continue;
        if (_isReelNav(p)) continue;
        final title = _runsText(p['title']) ?? '';
        if (title.isEmpty) continue;
        final artist =
            (_runsText(p['shortBylineText']) ?? '').trim();
        final byline = artist.isEmpty ? 'YouTube' : artist;
        if (isMusicJunk(title, byline)) continue;
        // Panel lengthText "4:12" gates hour-long mixes/junk.
        try {
          final len = _runsText(p['lengthText']) ?? '';
          if (len.isNotEmpty) {
            final s = parseLengthSec(len);
            if (s != null && (s < 30 || s > 600)) continue;
          }
        } catch (_) {}
        String thumb = '';
        try {
          final arr = _map(p['thumbnail'])?['thumbnails'];
          if (arr is List && arr.isNotEmpty) {
            thumb = ((_map(arr.last))?['url'] ?? '').toString();
          }
        } catch (_) {}
        final t = YtTrack(
          id: vid,
          title: title,
          artist: byline,
          thumbUrl: sharpThumb(thumb),
          watchUrl: 'https://www.youtube.com/watch?v=$vid',
        );
        if (seen.add(t.id)) out.add(t);
        if (out.length >= max) break;
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// Signature timestamp for the phone resolve leg, scraped from a watch
/// page (`"STS":20725`). Player-build scoped: cache per session, refresh
/// when the phone leg stops returning OK.
int parseSts(String html) {
  try {
    final m =
        RegExp(r'"STS":(\d+)').firstMatch(html);
    if (m == null) return 0;
    return int.tryParse(m.group(1) ?? '') ?? 0;
  } catch (_) {
    return 0;
  }
}

String? _shelfTitle(Map<String, dynamic> s) {
  try {
    final h = _map(s['header']);
    final t1 = _runsText(_map(_map(h)?['musicCarouselShelfBasicHeaderRenderer'])?['title']);
    if (t1 != null && t1.isNotEmpty) return t1;
    final t2 = _runsText(_map(_map(h)?['musicShelfHeaderRenderer'])?['title']);
    if (t2 != null && t2.isNotEmpty) return t2;
    final t3 = _runsText(_map(_map(h)?['title']));
    if (t3 != null && t3.isNotEmpty) return t3;
    final t4 = (_map(h)?['title'] ?? '').toString();
    if (t4.isNotEmpty) return t4;
    return _runsText(s['title']);
  } catch (_) {
    return null;
  }
}

/// Shelf parse: title → tracks (first title wins), per-shelf cap,
/// shelf cap. Supports list/twoRow/bare shapes.
Map<String, List<YtTrack>> parseShelves(
    Map<String, dynamic> root, int maxShelves, int perShelf) {
  final out = <String, List<YtTrack>>{};
  try {
    final shelves = <Map<String, dynamic>>[];
    collectMaps(root, 'musicCarouselShelfRenderer', shelves);
    collectMaps(root, 'musicShelfRenderer', shelves);
    for (final s in shelves) {
      try {
        final title = _shelfTitle(s);
        if (title == null || title.isEmpty || out.containsKey(title)) {
          continue;
        }
        final items = <YtTrack>[];
        final seen = <String>{};
        dynamic contents = _map(s['contents'])?['contents'] ?? s['contents'];
        if (contents is List) {
          for (final w in contents) {
            try {
              if (w is! Map) continue;
              final wm = w.cast<String, dynamic>();
              YtTrack? t;
              if (wm.containsKey('musicResponsiveListItemRenderer')) {
                t = parseMusicItem(
                    _map(wm['musicResponsiveListItemRenderer']) ?? {});
              } else if (wm.containsKey('musicTwoRowItemRenderer')) {
                t = parseTwoRowItem(
                    _map(wm['musicTwoRowItemRenderer']) ?? {});
              } else if (wm.containsKey('flexColumns')) {
                t = parseMusicItem(wm);
              } else if (wm.containsKey('title') &&
                  wm.containsKey('navigationEndpoint')) {
                t = parseTwoRowItem(wm);
              }
              if (t == null) continue;
              if (seen.add(t.id)) items.add(t);
              if (items.length >= perShelf) break;
            } catch (_) {}
          }
        }
        if (items.isNotEmpty) {
          out[title] = items;
          if (out.length >= maxShelves) break;
        }
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}
