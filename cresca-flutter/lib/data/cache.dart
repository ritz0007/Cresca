// Pure-Dart cache layer (C1 numbers, native-compatible JSON schemas).
// Native refs: YoutubeRepository (URL_TTL 5h mem / 6h disk yt_urls.json,
// throttled disk writes <=1/30s, single-flight), SongCache (yt_<key>.json
// {savedAt, items[{id,title,artist,thumb,watch}]}), MainActivity
// (HOME 12h / SEARCH 30m), HomeFeed (sections 12h), trending 7d.
//
// File IO stays in the repository; this file is pure maps + JSON so
// `flutter test` covers every TTL/schema rule without a filesystem.

import '../core/track.dart';

/// Cache TTLs (single source of truth, RESTRUCTURE.md section 3).
const int urlMemTtlMs = 5 * 60 * 60 * 1000;
const int urlDiskTtlMs = 6 * 60 * 60 * 1000;
const int urlDiskWriteFloorMs = 30 * 1000;
const int homeCacheTtlMs = 12 * 60 * 60 * 1000;
const int searchCacheTtlMs = 30 * 60 * 1000;
const int trendingCacheTtlMs = 7 * 24 * 60 * 60 * 1000;

const String urlDiskFile = 'yt_urls.json';

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
    } catch (_) {}
  }

  void drop(String watchUrl) {
    try {
      rows.remove(watchUrl);
    } catch (_) {}
  }

  /// Snapshot for disk. Skips already-stale rows at write time (native).
  /// Returns null when inside the <=1-write/30s floor (caller skips IO).
  Map<String, dynamic>? snapshotForDisk(int nowMs) {
    try {
      if (nowMs - lastDiskSaveMs < urlDiskWriteFloorMs) return null;
      lastDiskSaveMs = nowMs;
      final items = <String, dynamic>{};
      for (final e in rows.entries) {
        if (nowMs - e.value.atMs > urlDiskTtlMs) continue;
        items[e.key] = {'u': e.value.url, 't': e.value.atMs};
      }
      return {'savedAt': nowMs, 'items': items};
    } catch (_) {
      return null;
    }
  }

  /// Restore from a disk snapshot. Stale/blank rows dropped, existing
  /// memory rows win (putIfAbsent — native).
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
}

/// Song-list disk payload. Schema matches SongCache exactly:
/// {savedAt, items: [{id,title,artist,thumb,watch}]}.
/// Empty-id rows and empty lists load as null (native).
Map<String, dynamic> songListToJson(List<YtTrack> tracks, int nowMs) => {
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
