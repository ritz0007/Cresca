// Pure-Dart port of YtTrack + S3 song gates.
// Native refs: YoutubeRepository.kt (YtTrack, isMusicJunk, isArtistLike,
// displayArtist, isShortsUrl, fmtSubs, toTrack gates), InnerTubeApi.kt
// (parseVideoItem gates, sharpThumb, isLiveBadge labels), MainActivity.kt
// (fmtMs, hdThumb).

/// One playable song. JSON schema matches native YtTrack fields so cached
/// payloads stay compatible.
class YtTrack {
  final String id;
  final String title;
  final String artist;
  final String thumbUrl;
  final String watchUrl;
  final String localPath;

  const YtTrack({
    required this.id,
    required this.title,
    required this.artist,
    required this.thumbUrl,
    required this.watchUrl,
    this.localPath = '',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artist': artist,
        'thumbUrl': thumbUrl,
        'watchUrl': watchUrl,
        'localPath': localPath,
      };

  factory YtTrack.fromJson(Map<String, dynamic> j) => YtTrack(
        id: (j['id'] ?? '').toString(),
        title: (j['title'] ?? '').toString(),
        artist: (j['artist'] ?? '').toString(),
        thumbUrl: (j['thumbUrl'] ?? '').toString(),
        watchUrl: (j['watchUrl'] ?? '').toString(),
        localPath: (j['localPath'] ?? '').toString(),
      );

  /// Display artist: label-ish uploaders resolve to the "Artist - Title"
  /// prefix when sane, else "Unknown Artist". Never blank.
  String displayArtist() {
    try {
      final a = artist.trim();
      if (isArtistLike(a)) return a.isEmpty ? 'Unknown Artist' : a;
      final dash = title.indexOf(' - ');
      if (dash >= 2 && dash <= 80) {
        final cand = title.substring(0, dash).trim();
        if (cand.length >= 2 && cand.length <= 60 && isArtistLike(cand)) {
          return cand;
        }
      }
      return 'Unknown Artist';
    } catch (_) {
      return 'Unknown Artist';
    }
  }
}

/// One artist hit: name + art + subscriber label.
class YtArtist {
  final String name;
  final String thumbUrl;
  final String subs;
  const YtArtist({required this.name, required this.thumbUrl, this.subs = ''});
}

/// Songs + music videos ONLY. Drops podcast/TV episodes, trailers, Shorts
/// and other non-music clutter by title/artist shape.
bool isMusicJunk(String title, String artist) {
  try {
    final t = title.toLowerCase();
    final a = artist.toLowerCase().trim();
    if (RegExp(r'\b(ep|episode|eps)\b[\s._:#-]{0,4}\d+').hasMatch(t)) {
      return true;
    }
    if (RegExp(r'\bs\d{1,2}\s?e\d{1,3}\b').hasMatch(t)) return true;
    const badFirst = {
      'episode',
      'episodes',
      'podcast',
      'podcasts',
      'trailer',
      'trailers',
      'teaser',
      'shorts',
    };
    if (badFirst.contains(a)) return true;
    if (t.contains('full episode') || t.contains('episode recap')) return true;
    return false;
  } catch (_) {
    return false;
  }
}

/// True for label-ish uploader names that are never real artists.
bool isArtistLike(String name) {
  try {
    final low = name.trim().toLowerCase();
    if (low.isEmpty) return false;
    if (low == 'youtube' ||
        low == 'song' ||
        low == 'songs' ||
        low == 'video' ||
        low == 'videos' ||
        low == 'episode' ||
        low == 'episodes' ||
        low == 'podcast' ||
        low == 'music' ||
        low == 'unknown artist') {
      return false;
    }
    if (low.contains('official') ||
        low.contains('films') ||
        low.contains('records')) {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

/// True for YouTube Shorts URLs (never songs-in-queue material).
bool isShortsUrl(String url) {
  try {
    return url.contains('/shorts/');
  } catch (_) {
    return false;
  }
}

/// True for reel/shorts watch endpoints (InnerTube reelEndpoint guard).
bool isReelEndpoint(String watchUrl) {
  try {
    final u = watchUrl.toLowerCase();
    return u.contains('reel') || isShortsUrl(watchUrl);
  } catch (_) {
    return false;
  }
}

/// Live/upcoming/premiere badges mark unusable streams.
bool isLiveBadgeLabel(String label) {
  try {
    final l = label.toLowerCase();
    return l.contains('live') ||
        l.contains('upcoming') ||
        l.contains('premiere');
  } catch (_) {
    return false;
  }
}

/// Song duration gate: 30 s – 10 min. Unknown (<=0) is NOT a song
/// (compilations/lives/episodes far more often than songs).
bool isSongDuration(int seconds) => seconds >= 30 && seconds <= 600;

/// Full S3 gate for a candidate row: duration + shorts + live + junk +
/// distinct id handled by caller via [seenIds].
bool passesSongGates({
  required String title,
  required String artist,
  required String watchUrl,
  required int durationSec,
  required bool isLive,
}) {
  if (!isSongDuration(durationSec)) return false;
  if (isLive) return false;
  if (isShortsUrl(watchUrl) || isReelEndpoint(watchUrl)) return false;
  if (isMusicJunk(title, artist)) return false;
  final id = extractVideoId(watchUrl);
  if (id == null) return false;
  return true;
}

/// Extracts the 11-char video id from a youtube watch url, else null.
String? extractVideoId(String url) {
  try {
    final m = RegExp(r'[?&]v=([A-Za-z0-9_-]{11})').firstMatch(url);
    return m?.group(1);
  } catch (_) {
    return null;
  }
}

String fmtSubs(int count) {
  try {
    if (count <= 0) return '';
    if (count >= 1000000000) return '${(count ~/ 100000000) / 10.0}B';
    if (count >= 1000000) return '${(count ~/ 100000) / 10.0}M';
    if (count >= 1000) return '${(count ~/ 100) / 10.0}K';
    return count.toString();
  } catch (_) {
    return '';
  }
}

/// m:ss elapsed helper (MainActivity.fmtMs).
String fmtMs(int ms) {
  if (ms <= 0) return '0:00';
  final s = ms ~/ 1000;
  final m = s ~/ 60;
  final sec = (s % 60).toString().padLeft(2, '0');
  return '$m:$sec';
}

/// HD artwork: maxres for 11-char YouTube ids, else the given thumb.
String hdThumb(YtTrack t) {
  try {
    final id = t.id;
    if (id.length == 11 &&
        RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(id)) {
      return 'https://i.ytimg.com/vi/$id/maxresdefault.jpg';
    }
  } catch (_) {}
  return t.thumbUrl;
}

/// YTM thumbs arrive as =w120-h120: upscale to w544 (same CDN pixels YTM
/// desktop serves). Native: InnerTubeApi.sharpThumb.
String sharpThumb(String url) {
  try {
    if (url.isEmpty) return url;
    final m = RegExp(r'=w\d+-h\d+').firstMatch(url);
    if (m == null) return url;
    return url.replaceFirst(m.group(0)!, '=w544-h544');
  } catch (_) {
    return url;
  }
}

/// Drop duplicate ids (keyed lazy lists crash on dupes), keep first.
List<YtTrack> distinctById(List<YtTrack> tracks) {
  final seen = <String>{};
  final out = <YtTrack>[];
  for (final t in tracks) {
    if (seen.add(t.id)) out.add(t);
  }
  return out;
}
