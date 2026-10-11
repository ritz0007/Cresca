// Vendored from cresca-streamkit (streaming-logic reference: see its README). Only relative imports rewritten to package:cresca_app/...; do not edit logic here, fix upstream.
// Fast stream bundle: ONE InnerTube player response carries everything
// a track needs — ranked audio URLs + muxed video URLs + full metadata.
// The naive path throws videoDetails away and pays extra round trips
// (extractor manifest, extractor video page) for data the player call
// already returned for free.
//
// All parse functions are pure (no network) so `dart test` covers the
// protocol with canned fixtures. Every function is total: it returns an
// empty value instead of throwing.

/// Metadata for one track. Likes are NOT in player responses (-1 =
/// unknown); the About panel backfills them via the extractor only when
/// the user opens it.
class TrackMeta {
  final String videoId;
  final String title;
  final String artist;
  final String thumbUrl;
  final int durationSec;
  final int viewCount;
  final int likeCount;
  final String uploadDate;
  final String description;

  const TrackMeta({
    required this.videoId,
    this.title = '',
    this.artist = '',
    this.thumbUrl = '',
    this.durationSec = -1,
    this.viewCount = -1,
    this.likeCount = -1,
    this.uploadDate = '',
    this.description = '',
  });

  /// Empty shell: callers always get a non-null meta, even when the
  /// player response carried no videoDetails.
  factory TrackMeta.empty(String videoId) => TrackMeta(videoId: videoId);

  bool get hasDetails =>
      title.isNotEmpty || description.isNotEmpty || viewCount >= 0;

  Map<String, dynamic> toJson() => {
        'v': videoId,
        't': title,
        'a': artist,
        'thumb': thumbUrl,
        'd': durationSec,
        'views': viewCount,
        'likes': likeCount,
        'up': uploadDate,
        'desc': description,
      };

  factory TrackMeta.fromJson(Map<String, dynamic> j) {
    try {
      return TrackMeta(
        videoId: (j['v'] ?? '').toString(),
        title: (j['t'] ?? '').toString(),
        artist: (j['a'] ?? '').toString(),
        thumbUrl: (j['thumb'] ?? '').toString(),
        durationSec: _asInt(j['d']),
        viewCount: _asInt(j['views']),
        likeCount: _asInt(j['likes']),
        uploadDate: (j['up'] ?? '').toString(),
        description: (j['desc'] ?? '').toString(),
      );
    } catch (_) {
      return TrackMeta.empty('');
    }
  }
}

/// Ranked audio URLs (best-first) + muxed video URLs ((url, height),
/// best-first distinct heights) + metadata, all from one player call.
class StreamBundle {
  final String videoId;
  final List<String> audioUrls;
  final List<(String, int)> videoUrls;
  final TrackMeta meta;

  const StreamBundle({
    required this.videoId,
    this.audioUrls = const [],
    this.videoUrls = const [],
    required this.meta,
  });

  bool get hasAudio => audioUrls.isNotEmpty;
  String get bestAudio => audioUrls.isEmpty ? '' : audioUrls.first;
}

/// Playability gate shared by every player-response parse.
bool playerOk(Map<String, dynamic> root) {
  try {
    final status = (_map(root['playabilityStatus'])?['status'] ?? '')
        .toString()
        .toUpperCase();
    return status == 'OK';
  } catch (_) {
    return false;
  }
}

Map<String, dynamic>? _map(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : null;

int _asInt(dynamic v, [int fallback = -1]) {
  try {
    if (v == null) return fallback;
    if (v is int) return v;
    return int.tryParse(v.toString()) ?? fallback;
  } catch (_) {
    return fallback;
  }
}

/// YTM thumbs arrive as =w120-h120: upscale to w544 (same CDN pixels YTM
/// desktop serves).
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

/// HD artwork: maxres for 11-char YouTube ids, else the given thumb.
String hdThumb(String videoId, String fallback) {
  try {
    if (videoId.length == 11 &&
        RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(videoId)) {
      return 'https://i.ytimg.com/vi/$videoId/maxresdefault.jpg';
    }
  } catch (_) {}
  return fallback;
}

/// Ranked audio URLs from a player response, best-first distinct.
/// Drops non-OK playability, non-audio mimes, and signatureCipher URLs
/// (URLs without a direct `url` field need deciphering, which rides the
/// extractor fallback path).
List<String> parseBundleAudio(Map<String, dynamic> root) {
  try {
    if (!playerOk(root)) return [];
    final sd = _map(root['streamingData']);
    if (sd == null) return [];
    final ranked = <_Scored>[];
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
                  ranked.add(_Scored(_asInt(f['bitrate'], 0), url, 0));
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
    ranked.sort((a, b) => b.score.compareTo(a.score));
    final seen = <String>{};
    return ranked.where((e) => seen.add(e.url)).map((e) => e.url).toList();
  } catch (_) {
    return [];
  }
}

/// Ranked muxed (video+audio progressive) URLs from a player response:
/// (url, height), best-first, distinct heights. Free with the audio
/// resolve — no extractor manifest needed for video mode.
///
/// ONLY `formats` is read: those entries are progressive muxed
/// (video+audio in one URL). `adaptiveFormats` video entries are DASH
/// video-ONLY (zero audio track no matter the volume) — ranking them
/// here by height promoted silent 1080p+ URLs above the audible muxed
/// ones (progressive tops out at ~720p). Video-only lives in
/// [parseBundleVideoOnly], never here.
List<(String, int)> parseBundleVideo(Map<String, dynamic> root) {
  try {
    if (!playerOk(root)) return [];
    final sd = _map(root['streamingData']);
    if (sd == null) return [];
    final ranked = <_Scored>[];
    try {
      final arr = sd['formats'];
      if (arr is List) {
        for (final f in arr) {
          try {
            if (f is Map) {
              final mime = (f['mimeType'] ?? '').toString();
              final url = (f['url'] ?? '').toString();
              if (!mime.startsWith('video/') || url.isEmpty) continue;
              final h = _asInt(f['height'], 0);
              if (h <= 0) continue;
              ranked.add(_Scored(h, url, _asInt(f['bitrate'], 0)));
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    ranked.sort((a, b) {
      final h = b.score.compareTo(a.score);
      return h != 0 ? h : b.tiebreak.compareTo(a.tiebreak);
    });
    final seenH = <int>{};
    final out = <(String, int)>[];
    for (final e in ranked) {
      if (seenH.add(e.score)) out.add((e.url, e.score));
    }
    return out;
  } catch (_) {
    return [];
  }
}

/// Ranked video-ONLY (DASH, no audio track) URLs from a player
/// response: (url, height), best-first, distinct heights. Picture-only
/// fallback for video mode when no muxed rendition exists anywhere —
/// the sheet pairs these muted pictures with the synced just_audio
/// soundtrack as master clock. Never mixed into [parseBundleVideo].
List<(String, int)> parseBundleVideoOnly(Map<String, dynamic> root) {
  try {
    if (!playerOk(root)) return [];
    final sd = _map(root['streamingData']);
    if (sd == null) return [];
    final ranked = <_Scored>[];
    try {
      final arr = sd['adaptiveFormats'];
      if (arr is List) {
        for (final f in arr) {
          try {
            if (f is Map) {
              final mime = (f['mimeType'] ?? '').toString();
              final url = (f['url'] ?? '').toString();
              if (!mime.startsWith('video/') || url.isEmpty) continue;
              final h = _asInt(f['height'], 0);
              if (h <= 0) continue;
              ranked.add(_Scored(h, url, _asInt(f['bitrate'], 0)));
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    ranked.sort((a, b) {
      final h = b.score.compareTo(a.score);
      return h != 0 ? h : b.tiebreak.compareTo(a.tiebreak);
    });
    final seenH = <int>{};
    final out = <(String, int)>[];
    for (final e in ranked) {
      if (seenH.add(e.score)) out.add((e.url, e.score));
    }
    return out;
  } catch (_) {
    return [];
  }
}

/// Metadata from a player response's videoDetails (free with resolve).
/// [seedTitle]/[seedArtist]/[seedThumb] fill gaps when videoDetails is
/// absent (e.g. age-restricted responses that still stream).
TrackMeta parseBundleMeta(
  Map<String, dynamic> root,
  String videoId, {
  String seedTitle = '',
  String seedArtist = '',
  String seedThumb = '',
}) {
  try {
    final vd = _map(root['videoDetails']);
    if (vd == null) {
      if (seedTitle.isEmpty) return TrackMeta.empty(videoId);
      return TrackMeta(
        videoId: videoId,
        title: seedTitle,
        artist: seedArtist.isEmpty ? 'Unknown Artist' : seedArtist,
        thumbUrl: seedThumb,
      );
    }
    String thumb = '';
    try {
      final arr = _map(vd['thumbnail'])?['thumbnails'];
      if (arr is List && arr.isNotEmpty) {
        thumb = ((_map(arr.last))?['url'] ?? '').toString();
      }
    } catch (_) {}
    try {
      thumb = sharpThumb(thumb);
    } catch (_) {}
    if (thumb.isEmpty) thumb = seedThumb;
    var title = (vd['title'] ?? '').toString();
    if (title.isEmpty) title = seedTitle;
    var artist = (vd['author'] ?? '').toString();
    if (artist.isEmpty || artist == 'YouTube') artist = seedArtist;
    if (artist.isEmpty) artist = 'Unknown Artist';
    return TrackMeta(
      videoId: videoId,
      title: title,
      artist: artist,
      thumbUrl: thumb,
      durationSec: _asInt(vd['lengthSeconds']),
      viewCount: _asInt(vd['viewCount']),
      likeCount: -1, // player responses never carry likes.
      uploadDate: (vd['uploadDate'] ?? '').toString(),
      description: (vd['shortDescription'] ?? '').toString(),
    );
  } catch (_) {
    if (seedTitle.isEmpty) return TrackMeta.empty(videoId);
    return TrackMeta(
      videoId: videoId,
      title: seedTitle,
      artist: seedArtist.isEmpty ? 'Unknown Artist' : seedArtist,
      thumbUrl: seedThumb,
    );
  }
}

/// Full bundle from one player response. Never throws; the bundle is
/// simply empty (hasAudio == false, blank meta) on any failure.
StreamBundle parsePlayerBundle(
  Map<String, dynamic> root,
  String videoId, {
  String seedTitle = '',
  String seedArtist = '',
  String seedThumb = '',
}) {
  try {
    if (root.isEmpty) {
      return StreamBundle(
        videoId: videoId,
        meta: TrackMeta.empty(videoId),
      );
    }
    return StreamBundle(
      videoId: videoId,
      audioUrls: parseBundleAudio(root),
      videoUrls: parseBundleVideo(root),
      meta: parseBundleMeta(root, videoId,
          seedTitle: seedTitle, seedArtist: seedArtist, seedThumb: seedThumb),
    );
  } catch (_) {
    return StreamBundle(
      videoId: videoId,
      meta: TrackMeta.empty(videoId),
    );
  }
}

class _Scored {
  final int score;
  final String url;
  final int tiebreak;
  const _Scored(this.score, this.url, this.tiebreak);
}

// ---------- caches ----------
//
// Tier table (budgets — see lib/data/cache.dart for the full matrix):
// T1 stream-URL mem: 5h TTL, 6h disk, <=1 write/30s, cap 500 rows.
// T3 bundle memo (this file): meta + muxed video URLs only (audio rides
//    T1 UrlCache); 24h mem + 24h disk snapshot {v,savedAt,items}, cap 200
//    rows, detail-less rows never persist, never crash on old snapshots.
// NEG bundle misses: 5m negative memo (see BundleMisses) — dead videoIds
//    skip the 6-leg race + extractor fallback until TTL expires.

/// Snapshot schema version for bundle disk payloads. v1 = no 'v' key.
/// Readers migrate v1 + best-effort future v; writers emit v2.
const int bundleSnapshotVersion = 2;

/// Bundle memory cap (rows). Audio URLs excluded — each row is small
/// (meta + few video URLs), 200 rows ≈ tens of KB.
const int bundleMemCap = 200;

/// Negative-cache TTL for bundle misses (dead videoIds). Short: a dead
/// track retries after 5m instead of stalling every visit.
const int bundleMissTtlMs = 5 * 60 * 1000;

/// Memory entry + SWR helper: true when the row is stale-but-servable
/// (past TTL, inside grace) — serve instantly + refresh behind.
bool bundleStaleForServe(int atMs, int ttlMs, int nowMs,
    {int graceMs = 30 * 60 * 1000}) {
  try {
    final age = nowMs - atMs;
    return age > ttlMs && age <= ttlMs + graceMs;
  } catch (_) {
    return false;
  }
}

/// Short-TTL negative memo for bundle misses (videoId -> fail time).
/// Stops re-racing dead tracks on every visit. Capped. Never throws.
class BundleMisses {
  final Map<String, int> deadAtMs = {};
  static const int cap = 200;

  bool shouldSkip(String videoId, int nowMs, {int? ttlMs}) {
    try {
      final at = deadAtMs[videoId];
      if (at == null) return false;
      if (nowMs - at > (ttlMs ?? bundleMissTtlMs)) {
        deadAtMs.remove(videoId);
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void markDead(String videoId, int nowMs) {
    try {
      if (videoId.isEmpty) return;
      deadAtMs[videoId] = nowMs;
      while (deadAtMs.length > cap) {
        deadAtMs.remove(deadAtMs.keys.first);
      }
    } catch (_) {}
  }

  void clear(String videoId) {
    try {
      deadAtMs.remove(videoId);
    } catch (_) {}
  }
}

/// Stream-URL memory entry.
class UrlRow {
  final String url;
  final int atMs;
  const UrlRow(this.url, this.atMs);
}

/// Stream-URL cache: 5h memory fronted by a 6h disk snapshot.
/// Schema: {savedAt, items: {watchUrl: {u, t}}}.
class UrlCache {
  static const int memTtlMs = 5 * 60 * 60 * 1000;
  static const int diskTtlMs = 6 * 60 * 60 * 1000;
  static const int diskWriteFloorMs = 30 * 1000;

  /// Memory budget: 500 rows max (each ~100B → ~50KB). Oldest-inserted
  /// evicted past cap so a long session never grows unbounded.
  static const int memCap = 500;

  final Map<String, UrlRow> rows = {};
  int lastDiskSaveMs = 0;

  String? getFresh(String watchUrl, int nowMs) {
    try {
      final hit = rows[watchUrl];
      if (hit == null) return null;
      if (nowMs - hit.atMs > memTtlMs) {
        rows.remove(watchUrl);
        return null;
      }
      return hit.url;
    } catch (_) {
      return null;
    }
  }

  void remember(String watchUrl, String url, int nowMs) {
    try {
      rows[watchUrl] = UrlRow(url, nowMs);
      while (rows.length > memCap) {
        rows.remove(rows.keys.first);
      }
    } catch (_) {}
  }

  void drop(String watchUrl) {
    try {
      rows.remove(watchUrl);
    } catch (_) {}
  }

  /// Snapshot for disk. Skips already-stale rows at write time. Returns
  /// null when inside the <=1-write/30s floor (caller skips IO).
  /// Schema v2: {v: 2, savedAt, items}. Never throws.
  Map<String, dynamic>? snapshotForDisk(int nowMs) {
    try {
      if (nowMs - lastDiskSaveMs < diskWriteFloorMs) return null;
      lastDiskSaveMs = nowMs;
      final items = <String, dynamic>{};
      for (final e in rows.entries) {
        if (nowMs - e.value.atMs > diskTtlMs) continue;
        items[e.key] = {'u': e.value.url, 't': e.value.atMs};
      }
      return {'v': bundleSnapshotVersion, 'savedAt': nowMs, 'items': items};
    } catch (_) {
      return null;
    }
  }

  /// Restore from a disk snapshot. Stale/blank rows dropped, existing
  /// memory rows win. Accepts v1 (no 'v') + v2+ (migrate on read, never
  /// crash on old/future snapshots). Returns the restored row count.
  int restoreFromDisk(Map<String, dynamic> root, int nowMs) {
    var n = 0;
    try {
      final items = root['items'];
      if (items is! Map) return 0;
      for (final e in items.entries) {
        try {
          final k = e.key.toString();
          final o = e.value;
          if (o is! Map) continue;
          final t = _asInt(o['t'], 0);
          if (nowMs - t > diskTtlMs) continue;
          final u = (o['u'] ?? '').toString();
          if (u.isEmpty) continue;
          if (!rows.containsKey(k)) {
            rows[k] = UrlRow(u, t);
            n++;
          }
        } catch (_) {}
      }
      try {
        while (rows.length > memCap) {
          rows.remove(rows.keys.first);
        }
      } catch (_) {}
    } catch (_) {}
    return n;
  }
}

/// Bundle cache TTLs: stream URLs die in hours and ride [UrlCache];
/// metadata barely changes — 24h mem + 24h disk.
const int bundleMemTtlMs = 24 * 60 * 60 * 1000;
const int bundleDiskTtlMs = 24 * 60 * 60 * 1000;

/// Session memo for bundles: videoId -> (meta + muxed video URLs).
/// Audio URLs stay in [UrlCache]; this cache is purely additive.
class BundleCache {
  // Vendored contract: rows map is part of streamkit's tested API.
  final Map<String, _BundleRow> rows = {}; // ignore: library_private_types_in_public_api

  TrackMeta? metaFor(String videoId, int nowMs) {
    try {
      final hit = rows[videoId];
      if (hit == null) return null;
      if (nowMs - hit.atMs > bundleMemTtlMs) {
        rows.remove(videoId);
        return null;
      }
      return hit.meta;
    } catch (_) {
      return null;
    }
  }

  List<(String, int)> videoFor(String videoId, int nowMs) {
    try {
      final hit = rows[videoId];
      if (hit == null) return const [];
      if (nowMs - hit.atMs > bundleMemTtlMs) {
        rows.remove(videoId);
        return const [];
      }
      return hit.videoUrls;
    } catch (_) {
      return const [];
    }
  }

  void remember(StreamBundle b, int nowMs) {
    try {
      if (b.videoId.isEmpty) return;
      rows[b.videoId] = _BundleRow(b.meta, List.of(b.videoUrls), nowMs);
      while (rows.length > bundleMemCap) {
        rows.remove(rows.keys.first);
      }
    } catch (_) {}
  }

  void drop(String videoId) {
    try {
      rows.remove(videoId);
    } catch (_) {}
  }

  /// Snapshot for disk. Schema v2: {v: 2, savedAt, items:
  /// {videoId: {m, v, t}}}. Rows without real details are skipped. Null
  /// when nothing to write. Never throws.
  Map<String, dynamic>? snapshotForDisk(int nowMs) {
    try {
      final items = <String, dynamic>{};
      for (final e in rows.entries) {
        try {
          if (nowMs - e.value.atMs > bundleDiskTtlMs) continue;
          if (!e.value.meta.hasDetails) continue;
          items[e.key] = {
            'm': e.value.meta.toJson(),
            'v': [
              for (final v in e.value.videoUrls) {'u': v.$1, 'h': v.$2},
            ],
            't': e.value.atMs,
          };
        } catch (_) {}
      }
      if (items.isEmpty) return null;
      return {'v': bundleSnapshotVersion, 'savedAt': nowMs, 'items': items};
    } catch (_) {
      return null;
    }
  }

  /// Restore from a disk snapshot (v1 + v2+ accepted, migrate on read).
  /// Returns restored row count. Never throws, never crashes on old
  /// snapshots (bad rows skipped individually).
  int restoreFromDisk(Map<String, dynamic> root, int nowMs) {
    var n = 0;
    try {
      final items = root['items'];
      if (items is! Map) return 0;
      for (final e in items.entries) {
        try {
          final k = e.key.toString();
          if (k.isEmpty || rows.containsKey(k)) continue;
          final o = e.value;
          if (o is! Map) continue;
          final t = _asInt(o['t'], 0);
          if (nowMs - t > bundleDiskTtlMs) continue;
          final m = _map(o['m']);
          if (m == null) continue;
          final meta = TrackMeta.fromJson(m);
          if (!meta.hasDetails) continue;
          final vids = <(String, int)>[];
          try {
            final arr = o['v'];
            if (arr is List) {
              for (final v in arr) {
                if (v is! Map) continue;
                final u = (v['u'] ?? '').toString();
                final h = _asInt(v['h'], 0);
                if (u.isNotEmpty && h > 0) vids.add((u, h));
              }
            }
          } catch (_) {}
          rows[k] = _BundleRow(meta, vids, t);
          n++;
        } catch (_) {}
      }
      try {
        while (rows.length > bundleMemCap) {
          rows.remove(rows.keys.first);
        }
      } catch (_) {}
    } catch (_) {}
    return n;
  }
}

class _BundleRow {
  final TrackMeta meta;
  final List<(String, int)> videoUrls;
  final int atMs;
  const _BundleRow(this.meta, this.videoUrls, this.atMs);
}
