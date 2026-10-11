// Cache tier table (single source of truth — budgets, TTLs, floors).
// Everything here is pure maps + JSON (no file IO) so `flutter test`
// covers every rule without a filesystem. File IO stays in repository.
//
// Tier | Store | Budget | TTL | Floor / policy
// -----|-------|--------|-----|----------------
// T1 stream-URL mem (UrlCache.rows) | RAM map | cap 500 rows (~50KB) | 5h
//    fresh, refresh-behind past 4.5h | get-time + eager prune eviction
// T2 stream-URL disk (yt_urls.json) | disk JSON {v,savedAt,items} | ~200KB,
//    stale rows skipped at write | 6h | <=1 write / 30s
// T3 bundle memo (BundleCache.rows, streamkit/bundle.dart) | RAM map | cap
//    200 rows (meta+video URLs only, audio rides T1) | 24h mem / 24h disk
//    (yt_meta.json) | detail-less rows never persist
// T4 song-list mem (repository _memSnaps) | RAM map | cap 50 keys x 100
//    tracks | home 12h / search 30m / trending 7d (same TTLs as disk) |
//    stale-served instantly + refresh behind (SWR)
// T5 song-list disk (yt_<key>.json) | disk JSON {v,savedAt,items} | each
//    <~200KB, total <5MB | same TTLs as T4 | atomic tmp+rename writes
// T6 media bytes (ExoPlayer just_audio LockCachingAudioSource,
//    exoplayer/yt:<id> keys) | 4GB LRU, 10MB/track cap | URL TTLs govern
//    freshness, bytes evicted LRU-only | prefetch next-2 window
// T7 artwork (cached_network_image thumbs) | RAM ImageCache + disk via
//    flutter_cache_manager | RAM ~200 imgs, disk 2000 objs / ~200MB / 30d
//    stale | LRU; prefetch via pickArtworkPrefetch (visible rails only)
// NEG negative memo (misses/dead tracks) | RAM map | cap 200 keys | 5m
//    short TTL — stops re-hitting dead tracks every visit, never hides
//    fresh data past TTL.
//
// Native refs: YoutubeRepository (URL_TTL 5h mem / 6h disk yt_urls.json,
// throttled disk writes <=1/30s, single-flight), SongCache (yt_<key>.json
// {savedAt, items[{id,title,artist,thumb,watch}]}), MainActivity
// (HOME 12h / SEARCH 30m), HomeFeed (sections 12h), trending 7d.
//
// Audit note (cached_network_image 3.4.1, read-only widgets): track_row /
// player_sheet use CachedNetworkImage with the DEFAULT manager (≈200
// objects / 30d stale). That thrashes across thousands of thumbs —
// sane config is a shared custom CacheManager (maxNrOfCacheObjects
// 2000, stalePeriod 30d, ~200MB) passed as cacheManager:. Widgets are
// outside this overhaul's edit scope, so the pure helper
// [pickArtworkPrefetch] + [artworkDisk*] consts below define the sane
// values; callers wire them without new packages.

import '../core/track.dart';

/// Cache TTLs (single source of truth, RESTRUCTURE.md section 3).
const int urlMemTtlMs = 5 * 60 * 60 * 1000;
const int urlDiskTtlMs = 6 * 60 * 60 * 1000;
const int urlDiskWriteFloorMs = 30 * 1000;
const int homeCacheTtlMs = 12 * 60 * 60 * 1000;
const int searchCacheTtlMs = 30 * 60 * 1000;
const int trendingCacheTtlMs = 7 * 24 * 60 * 60 * 1000;

/// Snapshot schema version. v1 = {savedAt, items} (no 'v' key, legacy
/// native + old app writes). v2 adds 'v': 2. Readers accept v1 (migrate
/// on read) and any future v (best-effort parse, never crash); writers
/// always emit v2.
const int snapshotSchemaVersion = 2;

/// Memory caps (RAM budgets — evict oldest-first past cap).
const int urlMemCap = 500;
const int songMemCapKeys = 50;
const int songMemCapTracks = 100;

/// Negative-cache TTL: dead tracks / empty results are skipped for this
/// long, then retried. Short on purpose (5m) — hides nothing for long.
const int negativeTtlMs = 5 * 60 * 1000;
const int negativeCap = 200;

/// Artwork disk policy (sane values for thousands of thumbs — see header
/// audit note; widgets pass these via a shared custom CacheManager).
const int artworkDiskStaleMs = 30 * 24 * 60 * 60 * 1000;
const int artworkDiskMaxObjects = 2000;
const int artworkMemCacheSize = 200;

/// Visible-rail artwork prefetch window (cheap: URL list only, no bytes;
/// callers feed precacheImage/CachedNetworkImage prefetch).
const int artworkPrefetchMax = 6;

const String urlDiskFile = 'yt_urls.json';

/// Bundle memo disk file (meta + muxed video URLs, 24h TTL inside).
/// Schema mirrors BundleCache.snapshotForDisk exactly:
/// {savedAt, items: {videoId: {m, v, t}}}.
const String bundleDiskFile = 'yt_meta.json';

String songCacheFile(String key) => 'yt_$key.json';

bool isFresh(int savedAtMs, int ttlMs, int nowMs) =>
    nowMs - savedAtMs <= ttlMs;

/// Stream-URL memory entry.
class UrlRow {
  final String url;
  final int atMs;
  const UrlRow(this.url, this.atMs);
}

/// Stream-URL cache: 5h memory fronted by a 6h disk snapshot.
/// Schema matches native yt_urls.json exactly:
/// {savedAt, items: {watchUrl: {u, t}}}.
class UrlCache {
  final Map<String, UrlRow> rows = {};
  int lastDiskSaveMs = 0;

  String? getFresh(String watchUrl, int nowMs) {
    try {
      final hit = rows[watchUrl];
      if (hit == null) return null;
      if (nowMs - hit.atMs > urlMemTtlMs) {
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
      // Cap: evict oldest-inserted past budget (insertion-ordered map).
      while (rows.length > urlMemCap) {
        rows.remove(rows.keys.first);
      }
    } catch (_) {}
  }

  void drop(String watchUrl) {
    try {
      rows.remove(watchUrl);
    } catch (_) {}
  }

  /// Snapshot for disk. Skips already-stale rows at write time (native).
  /// Returns null when inside the <=1-write/30s floor (caller skips IO).
  /// Schema v2: {v: 2, savedAt, items}. Never throws.
  Map<String, dynamic>? snapshotForDisk(int nowMs) {
    try {
      if (nowMs - lastDiskSaveMs < urlDiskWriteFloorMs) return null;
      lastDiskSaveMs = nowMs;
      final items = <String, dynamic>{};
      for (final e in rows.entries) {
        if (nowMs - e.value.atMs > urlDiskTtlMs) continue;
        items[e.key] = {'u': e.value.url, 't': e.value.atMs};
      }
      return {'v': snapshotSchemaVersion, 'savedAt': nowMs, 'items': items};
    } catch (_) {
      return null;
    }
  }

  /// Restore from a disk snapshot. Stale/blank rows dropped, existing
  /// memory rows win (putIfAbsent — native). Accepts v1 (no 'v') and v2+;
  /// corrupt/unknown shapes load as 0 rows, never crash.
  /// Returns the restored row count.
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
          final t = int.tryParse(o['t'].toString()) ?? 0;
          if (nowMs - t > urlDiskTtlMs) continue;
          final u = (o['u'] ?? '').toString();
          if (u.isEmpty) continue;
          if (!rows.containsKey(k)) {
            rows[k] = UrlRow(u, t);
            n++;
          }
        } catch (_) {}
      }
    } catch (_) {}
    return n;
  }

  /// Drops memory rows older than [urlMemTtlMs]. Returns the evicted count.
  /// Called on track change so a long session never grows stale entries
  /// (native relies on get-time eviction; this bounds the map eagerly).
  int pruneExpired(int nowMs) {
    var n = 0;
    try {
      final dead = <String>[];
      for (final e in rows.entries) {
        if (nowMs - e.value.atMs > urlMemTtlMs) dead.add(e.key);
      }
      for (final k in dead) {
        rows.remove(k);
        n++;
      }
    } catch (_) {}
    return n;
  }

  /// True when the cached URL for [watchUrl] is inside the background-
  /// refresh window (last [thresholdMs] of memory TTL). Hits are still
  /// served instantly; the caller re-resolves behind (stale-while-
  /// revalidate) so playback never blocks on a cold race.
  bool needsBackgroundRefresh(String watchUrl, int nowMs,
      {int thresholdMs = 30 * 60 * 1000}) {
    try {
      final hit = rows[watchUrl];
      if (hit == null) return false;
      final age = nowMs - hit.atMs;
      if (age > urlMemTtlMs) return false;
      return age > urlMemTtlMs - thresholdMs;
    } catch (_) {
      return false;
    }
  }
}

/// Audio byte-cache discipline (mirrors native ExoCache + Precache caps:
/// 4GB LRU budget, 10MB per-track cap, `exoplayer/yt:<id>` videoId keys).
/// just_audio streams through LockCachingAudioSource into videoId-keyed
/// files; these pure helpers decide WHAT to prefetch and WHAT to evict so
/// `flutter test` covers the budget without a filesystem.
const int audioCacheBudgetBytes = 4 * 1024 * 1024 * 1024;
const int audioCacheTrackCapBytes = 10 * 1024 * 1024;
const String audioCacheDirName = 'exoplayer';

/// Next-2 prefetch window (native primeNext [current, +1, +2]).
const int audioPrefetchCount = 2;

/// Picks the prefetch set from the upcoming window: first [max] tracks
/// with a non-blank watchUrl, deduped, order preserved. Never throws.
List<YtTrack> pickPrefetch(List<YtTrack> upcoming,
    {int max = audioPrefetchCount, Set<String>? skipIds}) {
  try {
    if (upcoming.isEmpty || max <= 0) return const [];
    final skip = skipIds ?? const <String>{};
    final seen = <String>{};
    final out = <YtTrack>[];
    for (final t in upcoming) {
      if (out.length >= max) break;
      try {
        if (t.watchUrl.isEmpty) continue;
        if (skip.contains(t.id)) continue;
        if (!seen.add(t.id)) continue;
        out.add(t);
      } catch (_) {}
    }
    return out;
  } catch (_) {
    return const [];
  }
}

/// File row for eviction planning (path key, size bytes, modified time).
class CacheFileRow {
  final String key;
  final int size;
  final int modifiedMs;
  const CacheFileRow(this.key, this.size, this.modifiedMs);
}

/// Plans an LRU eviction: oversized single files (>track cap) go first,
/// then oldest-first until [totalBytes] fits [budgetBytes]. Returns the
/// keys to delete, oldest first. Pure (caller owns file IO). Never throws.
List<String> planCacheEviction(
  List<CacheFileRow> files,
  int totalBytes, {
  int budgetBytes = audioCacheBudgetBytes,
  int trackCapBytes = audioCacheTrackCapBytes,
}) {
  try {
    final over = <String>[];
    final rest = <CacheFileRow>[];
    for (final f in files) {
      if (f.size > trackCapBytes) {
        over.add(f.key);
      } else {
        rest.add(f);
      }
    }
    var total = totalBytes;
    for (final f in files) {
      if (f.size > trackCapBytes) total -= f.size;
    }
    rest.sort((a, b) => a.modifiedMs.compareTo(b.modifiedMs));
    final lru = <String>[];
    for (final f in rest) {
      if (total <= budgetBytes) break;
      lru.add(f.key);
      total -= f.size;
    }
    return [...over, ...lru];
  } catch (_) {
    return const [];
  }
}

/// Song-list disk payload. Schema v2 matches SongCache exactly plus 'v':
/// {v: 2, savedAt, items: [{id,title,artist,thumb,watch}]}.
/// Empty-id rows and empty lists load as null (native).
Map<String, dynamic> songListToJson(List<YtTrack> tracks, int nowMs) => {
      'v': snapshotSchemaVersion,
      'savedAt': nowMs,
      'items': [
        for (final t in tracks)
          {
            'id': t.id,
            'title': t.title,
            'artist': t.artist,
            'thumb': t.thumbUrl,
            'watch': t.watchUrl,
          },
      ],
    };

/// Parses a song-list snapshot. Accepts v1 (no 'v') and v2+ (migrate on
/// read: unknown future fields ignored, never crash). Stale/empty loads
/// as null (native). Never throws.
List<YtTrack>? songListFromJson(Map<String, dynamic> root, int ttlMs,
    [int? nowMs]) {
  try {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final savedAt = int.tryParse(root['savedAt'].toString()) ?? 0;
    if (now - savedAt > ttlMs) return null;
    final arr = root['items'];
    if (arr is! List || arr.isEmpty) return null;
    final out = <YtTrack>[];
    for (final e in arr) {
      try {
        if (e is! Map) continue;
        final id = (e['id'] ?? '').toString();
        if (id.isEmpty) continue;
        out.add(YtTrack(
          id: id,
          title: (e['title'] ?? '').toString(),
          artist: (e['artist'] ?? '').toString(),
          thumbUrl: (e['thumb'] ?? '').toString(),
          watchUrl: (e['watch'] ?? '').toString(),
        ));
      } catch (_) {}
    }
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  }
}

/// Stale-while-revalidate gate: true when [savedAtMs] is stale-but-
/// servable — past TTL yet inside the grace window, so callers serve the
/// cached rows instantly and refresh behind. Fresh rows return false
/// (no refresh needed); long-dead rows return false (fetch, don't serve).
/// Pure + never throws.
bool isStaleForServe(int savedAtMs, int ttlMs, int nowMs,
    {int graceMs = 30 * 60 * 1000}) {
  try {
    final age = nowMs - savedAtMs;
    return age > ttlMs && age <= ttlMs + graceMs;
  } catch (_) {
    return false;
  }
}

/// Negative memo: remembers dead tracks / empty results so repeat visits
/// skip the network for [negativeTtlMs], then retry. Capped (oldest-
/// first eviction). Pure maps — callers own timers. Never throws.
class NegativeMemo {
  final Map<String, int> deadAtMs = {};

  bool shouldSkip(String key, int nowMs, {int? ttlMs}) {
    try {
      final at = deadAtMs[key];
      if (at == null) return false;
      final ttl = ttlMs ?? negativeTtlMs;
      if (nowMs - at > ttl) {
        deadAtMs.remove(key);
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  void markDead(String key, int nowMs) {
    try {
      if (key.isEmpty) return;
      deadAtMs[key] = nowMs;
      while (deadAtMs.length > negativeCap) {
        deadAtMs.remove(deadAtMs.keys.first);
      }
    } catch (_) {}
  }

  void clear(String key) {
    try {
      deadAtMs.remove(key);
    } catch (_) {}
  }
}

/// Picks artwork URLs to prefetch for the visible rails: first [max]
/// non-blank thumbs, deduped, order preserved. URL list only (no bytes —
/// callers feed precacheImage / prefetchToMemory). Cheap enough to call
/// per rail paint. Never throws.
List<String> pickArtworkPrefetch(List<YtTrack> tracks,
    {int max = artworkPrefetchMax}) {
  try {
    if (tracks.isEmpty || max <= 0) return const [];
    final seen = <String>{};
    final out = <String>[];
    for (final t in tracks) {
      if (out.length >= max) break;
      try {
        final u = t.thumbUrl;
        if (u.isEmpty || !seen.add(u)) continue;
        out.add(u);
      } catch (_) {}
    }
    return out;
  } catch (_) {
    return const [];
  }
}
