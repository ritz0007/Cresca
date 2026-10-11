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
import '../podcasts/models.dart';

/// On-device client specs (InnerTune/Metrolist pattern). Versions pinned
/// from InnerTune/yt-dlp; bump only when YouTube 403/400s across clients.
class TubeClient {
  final String name;
  final String version;
  final String apiKey;
  final String userAgent;
  final String? referer;
  final int androidSdkVersion;
  final String osName;
  final String osVersion;
  final String deviceMake;
  final String deviceModel;
  const TubeClient({
    required this.name,
    required this.version,
    required this.apiKey,
    required this.userAgent,
    this.referer,
    this.androidSdkVersion = 34,
    this.osName = '',
    this.osVersion = '',
    this.deviceMake = '',
    this.deviceModel = '',
  });

  static const uaWeb =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const uaAndroid =
      'com.google.android.apps.youtube.music/6.42.55 (Linux; U; Android 14) gzip';

  /// music.youtube.com search/browse — shelves, stable.
  static const webRemix = TubeClient(
    name: 'WEB_REMIX',
    version: '1.20260707.12.00',
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
  /// 2026 note: still answers OK with direct URLs, but YouTube
  /// selectively 403s them at fetch on flagged IPs (GVS poToken
  /// rollout) — visionos is the reliable leg now.
  static const androidVr = TubeClient(
    name: 'ANDROID_VR',
    version: '1.65.10',
    apiKey: 'AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI',
    userAgent:
        'com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip',
    androidSdkVersion: 32,
    osName: 'Android',
    osVersion: '12L',
    deviceMake: 'Oculus',
    deviceModel: 'Quest 3',
  );

  /// iOS — direct signed URLs, no cipher, NO GVS poToken gate.
  /// yt-dlp's primary default player client since 2025.11 (their
  /// BASE_CLIENTS = tv,web,mweb,android,ios). REQUIRE_JS_PLAYER=False
  /// so no n-signature decipher needed. The Apple device fields +
  /// iOS UA travel together or the player 400s. Verified live
  /// 2026-10: OK + probe 206 across videos.
  static const ios = TubeClient(
    name: 'IOS',
    version: '21.26.4',
    apiKey: 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
    userAgent:
        'com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)',
    osName: 'iPhone',
    osVersion: '18.3.2.22D82',
    deviceMake: 'Apple',
    deviceModel: 'iPhone16,2',
  );

  /// Vision Pro — direct signed URLs, no cipher, NO GVS poToken gate.
  /// yt-dlp's primary default client since 2026 (their policy table is
  /// the only client with no poToken requirement + JS-less). Needs the
  /// Apple device fields + desktop-Safari UA exactly as pinned or the
  /// player 400s. Verified live 2026-10: OK + probe 206 across videos,
  /// works via the music.youtube.com host with the session visitor
  /// riding context + X-Goog-Visitor-Id (bot-gate parity).
  static const visionos = TubeClient(
    name: 'VISIONOS',
    version: '1.02',
    apiKey: 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8',
    userAgent:
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15',
    osName: 'visionOS',
    osVersion: '26.5.23O471',
    deviceMake: 'Apple',
    deviceModel: 'RealityDevice17,1',
  );

  /// Fallback for browse/next when music clients fail.
  static const web = TubeClient(
    name: 'WEB',
    version: '2.20260708.00.00',
    apiKey: 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
    userAgent: uaWeb,
  );

  /// Phone client for the NewPipe-equivalent resolve leg: needs a fresh
  /// signatureTimestamp (see fetchSignatureTimestamp) or the player
  /// answers UNPLAYABLE/LOGIN_REQUIRED like the music clients. Version
  /// pinned to yt-dlp's maintained ANDROID spec (2026).
  static const androidPhone = TubeClient(
    name: 'ANDROID',
    version: '21.26.364',
    apiKey: 'AIzaSyAOghZGza2MQSZkY_zfZ370N-PUdXEo8AI',
    userAgent:
        'com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip',
    androidSdkVersion: 30,
    osName: 'Android',
    osVersion: '11',
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
  if (client.osVersion.isNotEmpty) c['osVersion'] = client.osVersion;
  if (client.deviceMake.isNotEmpty) c['deviceMake'] = client.deviceMake;
  if (client.deviceModel.isNotEmpty) {
    c['deviceModel'] = client.deviceModel;
  }
  return {
    'client': c,
    'user': {'lockedSafetyMode': false},
  };
}

/// YTM "Songs" chip filter (ytmusicapi parity): the server returns the
/// Songs shelf only — album/artist/playlist/podcast cards never arrive,
/// so there is less payload to download and nothing non-song to parse.
/// Verified live 2026-10: 200 + song rows + zero two-row cards on song
/// queries. No-match queries fall back to the extractor leg in the
/// repository, so a filtered-empty never strands the user.
const String searchSongsParams = 'EgWKAQIIAWoQEAMQBBAJEAoQEBAQFQ';

Map<String, dynamic> searchBody(String query, String visitorData,
        {bool songsOnly = true}) =>
    {
      'context': contextMap(TubeClient.webRemix, visitorData),
      'query': query,
      if (songsOnly) 'params': searchSongsParams,
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

/// YTM shelf subtitles lead with a content-type badge on official
/// uploads ("Song • AP Dhillon • 3:50"): the badge is never the artist.
/// Skips badges and returns the first real segment (artist channel).
String _artistSeg(List<String> segs) {
  const badges = {
    'song',
    'songs',
    'video',
    'videos',
    'album',
    'albums',
    'playlist',
    'playlists',
    'single',
    'singles',
    'ep',
    'eps',
    'episode',
    'episodes',
    'podcast',
    'podcasts',
    'artist',
    'artists',
    'movie',
    'movies',
    'film',
    'show',
    'shows',
    'trailer',
  };
  for (final s in segs) {
    if (s.isNotEmpty && !badges.contains(s.toLowerCase())) return s;
  }
  return segs.isEmpty ? '' : segs.first;
}

/// Non-song type badges: when the FIRST subtitle segment is one of these,
/// the row is an album/playlist/artist/podcast card — never a song.
/// Song/video/single badges (or a leading artist name) are playable
/// song rows and are kept. The middle segments are free-form (album
/// names like "Album" in "Arijit Singh • Album • 4:22" stay untouched).
const _nonSongBadges = {
  'album',
  'albums',
  'playlist',
  'playlists',
  'artist',
  'artists',
  'podcast',
  'podcasts',
  'episode',
  'episodes',
  'ep',
  'eps',
  'movie',
  'movies',
  'film',
  'show',
  'shows',
  'trailer',
  'trailers',
  'audiobook',
  'audiobooks',
};

/// True when subtitle segments open with a non-song content-type badge.
bool _isNonSongRow(List<String> segs) {
  try {
    if (segs.isEmpty) return false;
    final first = segs.first.toLowerCase();
    if (first == 'song' ||
        first == 'songs' ||
        first == 'single' ||
        first == 'singles' ||
        first == 'video' ||
        first == 'videos') {
      return false;
    }
    return _nonSongBadges.contains(first);
  } catch (_) {
    return false;
  }
}

YtTrack? parseMusicItem(Map<String, dynamic> r,
    {bool requireDuration = false}) {
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
          // Subtitle is "Artist • Album • Duration" (official uploads
          // lead with a type badge: "Song • Artist • 3:50" — skipped).
          // First real segment = artist, trailing M:SS = duration
          // (hour-long comps die here).
          final segs = sub
              .split('•')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList();
          // Songs-only: album/playlist/artist/podcast cards open with a
          // type badge ("Album • Best of • 2024") — dropped at parse time.
          if (_isNonSongRow(segs)) return null;
          final who = _artistSeg(segs);
          if (who.isNotEmpty) {
            artist = who;
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
    // Search is songs-only: song rows always carry a trailing M:SS, so
    // album/playlist/artist/podcast cards without one die here. Shelves
    // and playlist items keep the default (durations optional there).
    if (requireDuration &&
        (durationSec < 30 || durationSec > 600)) {
      return null;
    }
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
    // Search backfill is songs-only: a video row without a known 30s–
    // 10min length is a stream/podcast/gibberish upload, never a song.
    try {
      final len = _runsText(r['lengthText']) ?? '';
      final s = len.isEmpty ? null : parseLengthSec(len);
      if (s == null || s < 30 || s > 600) return null;
    } catch (_) {
      return null;
    }
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
      final segs =
          sub.split('•').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      final first = _artistSeg(segs);
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

/// Single-pass bounded collector for the two playable renderer kinds:
/// one DFS pre-order walk (top results first) banking music rows and
/// plain video rows together, stopping descent once both banks are
/// full. Keeps search parse proportional to the rows actually shown
/// instead of the whole page. Playlist/album/artist/podcast/channel
/// cards are never collected — skipped at parse time, not filtered
/// after the fact.
void _collectSongRenderers(
  dynamic node,
  List<Map<String, dynamic>> music,
  List<Map<String, dynamic>> videos,
  int musicLimit,
  int videoLimit,
) {
  try {
    if (music.length >= musicLimit && videos.length >= videoLimit) return;
    if (node is Map) {
      final m = node.cast<String, dynamic>();
      if (m.containsKey('musicResponsiveListItemRenderer')) {
        final hit = _map(m['musicResponsiveListItemRenderer']);
        if (hit != null && music.length < musicLimit) music.add(hit);
      } else if (m.containsKey('videoRenderer')) {
        final hit = _map(m['videoRenderer']);
        if (hit != null && videos.length < videoLimit) videos.add(hit);
      }
      if (music.length >= musicLimit && videos.length >= videoLimit) {
        return;
      }
      for (final v in m.values) {
        _collectSongRenderers(v, music, videos, musicLimit, videoLimit);
        if (music.length >= musicLimit && videos.length >= videoLimit) {
          return;
        }
      }
    } else if (node is List) {
      for (final e in node) {
        _collectSongRenderers(e, music, videos, musicLimit, videoLimit);
        if (music.length >= musicLimit && videos.length >= videoLimit) {
          return;
        }
      }
    }
  } catch (_) {}
}

/// Search parse: SONGS ONLY. Music song rows first (duration REQUIRED:
/// song rows always carry a trailing M:SS; album/playlist/artist/podcast
/// cards without one die at parse time); plain videoRenderer hits only
/// as a duration-gated backfill (music videos live there).
/// Playlist/album/artist/podcast/channel renderers are never collected —
/// they are skipped at parse time, not filtered after the fact.
/// Single bounded walk with early exit; dedupes ids, caps at max.
List<YtTrack> parseSearch(Map<String, dynamic> root, int max) {
  final out = <YtTrack>[];
  try {
    if (max <= 0) return out;
    final seen = <String>{};
    final found = <Map<String, dynamic>>[];
    final vids = <Map<String, dynamic>>[];
    _collectSongRenderers(root, found, vids, max + 4, max + 4);
    for (final r in found) {
      try {
        final t = parseMusicItem(r, requireDuration: true);
        if (t == null) continue;
        if (seen.add(t.id)) out.add(t);
        if (out.length >= max) break;
      } catch (_) {}
    }
    if (out.length < max) {
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

/// Bare responsive items anywhere in a browse response (community
/// playlist shelves nest items without a shelf wrapper) → tracks.
List<YtTrack> parsePlaylistItems(
    Map<String, dynamic> root, int max) {
  final out = <YtTrack>[];
  try {
    final items = <Map<String, dynamic>>[];
    collectMaps(root, 'musicResponsiveListItemRenderer', items);
    final seen = <String>{};
    for (final r in items) {
      try {
        final t = parseMusicItem(r);
        if (t == null) continue;
        if (seen.add(t.id)) out.add(t);
        if (out.length >= max) break;
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

/// Playlist-card scan (YTM shelf parity): carousel two-row items that
/// point at PLAYLISTS (browseEndpoint VL/PL/RD…), not artists (UC…) or
/// videos. Returns (shelfTitle, cardTitle, browseId) — the caller
/// resolves tracks via playlistTracks. This is how "New releases" /
/// "Trending 20 India" style shelves become playable rails.
List<(String, String, String)> parsePlaylistCards(
    Map<String, dynamic> root,
    {int maxCards = 4}) {
  final out = <(String, String, String)>[];
  try {
    final shelves = <Map<String, dynamic>>[];
    collectMaps(root, 'musicCarouselShelfRenderer', shelves);
    for (final s in shelves) {
      try {
        final shelf = _shelfTitle(s) ?? '';
        if (shelf.isEmpty) continue;
        dynamic contents =
            _map(s['contents'])?['contents'] ?? s['contents'];
        if (contents is! List) continue;
        for (final w in contents) {
          try {
            if (w is! Map) continue;
            final wm = w.cast<String, dynamic>();
            final item = _map(wm['musicTwoRowItemRenderer']) ?? wm;
            if (item['title'] == null ||
                item['navigationEndpoint'] == null) {
              continue;
            }
            final nav =
                _map(_map(item['navigationEndpoint'])?['browseEndpoint']);
            final bid = (nav?['browseId'] ?? '').toString();
            if (bid.isEmpty ||
                bid.startsWith('UC') ||
                bid.startsWith('FE') ||
                bid.startsWith('SP')) {
              continue;
            }
            final card = (_runsText(item['title']) ?? '').trim();
            if (card.isEmpty) continue;
            if (out.any((e) => e.$3 == bid)) continue;
            out.add((shelf, card, bid));
            if (out.length >= maxCards) return out;
          } catch (_) {}
        }
      } catch (_) {}
    }
  } catch (_) {}
  return out;
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

// ---------- podcasts (ADDITIVE MVP slice) ----------
// Episode/show fetch rides the same youtubei host with podcast-shaped
// bodies + parallel parsers. The shared songs-only gates
// (_nonSongBadges, _isNonSongRow, 30–600 s duration checks,
// isMusicJunk) are NEVER widened or called here: episode rows branch on
// their own kind-local rules below.
//
// Live-probe notes (research P0): the Podcasts kiosk browseId and the
// Episodes/Shows search-filter params below are UNVERIFIED against this
// codebase's traffic. Search therefore posts UNFILTERED (no params,
// same as the video leg) and selects episode-shaped rows at parse time;
// show pages post the caller-supplied browseId verbatim.

/// Hypothesized YTM Podcasts kiosk browseId (analogy with FEmusic_home).
/// UNVERIFIED live — callers must tolerate empty shelves (service falls
/// back gracefully) until a probe confirms it.
const String podcastKioskBrowseId = 'FEmusic_podcasts';

/// Episode duration window: 60 s – 5 h. Rows outside a KNOWN duration in
/// this window are clips/junk; rows with NO duration segment are kept
/// (-1 = unknown) since some episode rows carry none.
const int podcastMinSec = 60;
const int podcastMaxSec = 5 * 3600;

/// Unfiltered search body for podcast queries: deliberately NO
/// searchSongsParams (that chip returns the Songs shelf only). Episode
/// selection happens in parsePodcastSearch, never by widening the
/// songs-only path.
Map<String, dynamic> podcastSearchBody(
        String query, String visitorData) =>
    {
      'context': contextMap(TubeClient.webRemix, visitorData),
      'query': query,
    };

/// Browse body for a podcast show page (MPREb_*-style id supplied by
/// the caller — never hardcoded from memory). Same envelope as
/// browseBody under a podcast-named wrapper for call-site clarity.
Map<String, dynamic> podcastShowBody(
        String browseId, String visitorData) =>
    {
      'context': contextMap(TubeClient.webRemix, visitorData),
      'browseId': browseId,
    };

/// Leading content-type badges skipped when resolving the SHOW name
/// from subtitle segments ("Podcast • My Show • 45:12" → "My Show").
/// Local to podcast parsing — the shared _nonSongBadges set is
/// untouched.
const _podcastBadgeSegs = {
  'podcast',
  'podcasts',
  'episode',
  'episodes',
  'ep',
  'eps',
  'show',
  'shows',
  'audiobook',
  'audiobooks',
};

String _podShowTitle(List<String> segs) {
  try {
    for (final s in segs) {
      if (s.isEmpty) continue;
      if (_podcastBadgeSegs.contains(s.toLowerCase())) continue;
      // Trailing duration segments are never the show.
      if (parseLengthSec(s) != null) continue;
      // Date-ish segments are never the show.
      if (_looksLikeDateSeg(s)) continue;
      return s;
    }
    return '';
  } catch (_) {
    return '';
  }
}

bool _looksLikeDateSeg(String s) {
  try {
    final low = s.toLowerCase();
    if (RegExp(r'\b(19|20)\d{2}\b').hasMatch(s)) return true;
    const months = [
      'jan',
      'feb',
      'mar',
      'apr',
      'may',
      'jun',
      'jul',
      'aug',
      'sep',
      'oct',
      'nov',
      'dec'
    ];
    for (final m in months) {
      if (low.contains(m)) return true;
    }
    if (RegExp(
            r'\d+\s+(second|minute|hour|day|week|month|year)s?\s+ago')
        .hasMatch(low)) {
      return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// First date-ish subtitle segment ("Mar 4, 2026", "3 days ago"),
/// else ''. Never throws.
String podPublishLabel(List<String> segs) {
  try {
    for (final s in segs) {
      if (s.isNotEmpty && _looksLikeDateSeg(s)) return s;
    }
    return '';
  } catch (_) {
    return '';
  }
}

List<String> _podSubtitleSegs(Map<String, dynamic> r) {
  try {
    final flex = r['flexColumns'];
    if (flex is List && flex.length > 1) {
      final c1 = _map(
          _map(flex[1])?['musicResponsiveListItemFlexColumnRenderer']);
      final sub = _runsText(c1?['text']) ?? '';
      return sub
          .split('•')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    final sub = _runsText(r['subtitle']) ?? '';
    return sub
        .split('•')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

String _podThumb(Map<String, dynamic> r) {
  try {
    final thumbs = _dig(r, [
      'thumbnail',
      'musicThumbnailRenderer',
      'thumbnail'
    ])?['thumbnails'];
    if (thumbs is List && thumbs.isNotEmpty) {
      return ((_map(thumbs.last))?['url'] ?? '').toString();
    }
    final arr = _map(r['thumbnail'])?['thumbnails'];
    if (arr is List && arr.isNotEmpty) {
      return ((_map(arr.last))?['url'] ?? '').toString();
    }
  } catch (_) {}
  return '';
}

String? _podVideoId(Map<String, dynamic> r) {
  try {
    var videoId = _map(r['playlistItemData'])?['videoId']?.toString();
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
    if (videoId == null || videoId.length != 11) return null;
    return videoId;
  } catch (_) {
    return null;
  }
}

/// Music-channel gate for episode rows: auto-generated Topic
/// channels and VEVO carry songs/music videos, never podcast
/// episodes. Local to podcast parsing — shared gates untouched.
bool _podIsMusicChannel(String s) {
  try {
    final t = s.trim();
    if (t.isEmpty) return false;
    final low = t.toLowerCase();
    if (low.endsWith('- topic') ||
        low.endsWith('\u2013 topic') ||
        low.endsWith('– topic')) {
      return true;
    }
    if (low == 'vevo' ||
        low.endsWith('vevo') ||
        RegExp(r'\bvevo\b').hasMatch(low)) {
      return true;
    }
    return false;
  } catch (_) {
    return false;
  }
}

/// Episode-row parser (musicResponsiveListItemRenderer shape). Branch-on-
/// kind: does NOT call _isNonSongRow / isMusicJunk / song duration
/// gates. Drops only reels, lives, empty titles, and known sub-60 s
/// clips / over-5 h outliers. Unknown durations kept (-1).
PodcastEpisode? parsePodcastEpisodeItem(Map<String, dynamic> r) {
  try {
    if (_isReelNav(r)) return null;
    if (hasLiveBadge(r)) return null;
    final videoId = _podVideoId(r);
    if (videoId == null) return null;
    String title = '';
    try {
      final flex = r['flexColumns'];
      if (flex is List && flex.isNotEmpty) {
        final c0 = _map(
            _map(flex[0])?['musicResponsiveListItemFlexColumnRenderer']);
        title = _runsText(c0?['text']) ?? '';
      }
      title = title.trim();
    } catch (_) {}
    if (title.isEmpty) return null;
    final segs = _podSubtitleSegs(r);
    int durationSec = -1;
    if (segs.isNotEmpty) {
      durationSec = parseLengthSec(segs.last) ?? -1;
    }
    if (durationSec >= 0 &&
        (durationSec < podcastMinSec ||
            durationSec > podcastMaxSec)) {
      return null;
    }
    final show = _podShowTitle(segs);
    if (_podIsMusicChannel(show)) return null;
    final thumb = _podThumb(r);
    return PodcastEpisode(
      id: videoId,
      title: title,
      showTitle: show,
      durationSec: durationSec,
      publishDate: podPublishLabel(segs),
      thumbUrl: sharpThumb(thumb),
      watchUrl: 'https://www.youtube.com/watch?v=$videoId',
    );
  } catch (_) {
    return null;
  }
}

/// Episode-row parser (musicTwoRowItemRenderer carousel shape):
/// title + navigationEndpoint watch id + subtitle segs. Same kind-local
/// gates as parsePodcastEpisodeItem. Thumb best-effort ('').
PodcastEpisode? parsePodcastTwoRowEpisode(Map<String, dynamic> r) {
  try {
    if (_isReelNav(r)) return null;
    if (hasLiveBadge(r)) return null;
    final videoId = _watchId(_map(r['navigationEndpoint']));
    if (videoId == null) return null;
    final title = (_runsText(r['title']) ?? '').trim();
    if (title.isEmpty) return null;
    final segs = _podSubtitleSegs(r);
    int durationSec = -1;
    for (final s in segs) {
      final secs = parseLengthSec(s);
      if (secs != null) {
        durationSec = secs;
        break;
      }
    }
    if (durationSec >= 0 &&
        (durationSec < podcastMinSec ||
            durationSec > podcastMaxSec)) {
      return null;
    }
    final twoRowShow = _podShowTitle(segs);
    if (_podIsMusicChannel(twoRowShow)) return null;
    return PodcastEpisode(
      id: videoId,
      title: title,
      showTitle: _podShowTitle(segs),
      durationSec: durationSec,
      publishDate: podPublishLabel(segs),
      watchUrl: 'https://www.youtube.com/watch?v=$videoId',
    );
  } catch (_) {
    return null;
  }
}

/// Podcast search parse: every musicResponsiveListItemRenderer row is
/// tried as an EPISODE row (parsePodcastEpisodeItem), plus two-row
/// carousel hits. Dedupes ids, caps at max. Never throws.
List<PodcastEpisode> parsePodcastSearch(
    Map<String, dynamic> root, int max) {
  final out = <PodcastEpisode>[];
  try {
    if (max <= 0) return out;
    final seen = <String>{};
    final items = <Map<String, dynamic>>[];
    collectMaps(root, 'musicResponsiveListItemRenderer', items);
    for (final r in items) {
      try {
        final ep = parsePodcastEpisodeItem(r);
        if (ep == null) continue;
        if (seen.add(ep.id)) out.add(ep);
        if (out.length >= max) return out;
      } catch (_) {}
    }
    final twos = <Map<String, dynamic>>[];
    collectMaps(root, 'musicTwoRowItemRenderer', twos);
    for (final r in twos) {
      try {
        final ep = parsePodcastTwoRowEpisode(r);
        if (ep == null) continue;
        if (seen.add(ep.id)) out.add(ep);
        if (out.length >= max) break;
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

/// Podcast shelf parse: title → episode rows (first title wins),
/// per-shelf cap, shelf cap. Parallel to parseShelves; supports list,
/// two-row, and bare shapes. Never throws.
Map<String, List<PodcastEpisode>> parsePodcastShelves(
    Map<String, dynamic> root, int maxShelves, int perShelf) {
  final out = <String, List<PodcastEpisode>>{};
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
        final items = <PodcastEpisode>[];
        final seen = <String>{};
        dynamic contents =
            _map(s['contents'])?['contents'] ?? s['contents'];
        if (contents is List) {
          for (final w in contents) {
            try {
              if (w is! Map) continue;
              final wm = w.cast<String, dynamic>();
              PodcastEpisode? ep;
              if (wm.containsKey(
                  'musicResponsiveListItemRenderer')) {
                ep = parsePodcastEpisodeItem(
                    _map(wm['musicResponsiveListItemRenderer']) ??
                        {});
              } else if (wm
                  .containsKey('musicTwoRowItemRenderer')) {
                ep = parsePodcastTwoRowEpisode(
                    _map(wm['musicTwoRowItemRenderer']) ?? {});
              } else if (wm.containsKey('flexColumns')) {
                ep = parsePodcastEpisodeItem(wm);
              } else if (wm.containsKey('title') &&
                  wm.containsKey('navigationEndpoint')) {
                ep = parsePodcastTwoRowEpisode(wm);
              }
              if (ep == null) continue;
              if (seen.add(ep.id)) items.add(ep);
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
