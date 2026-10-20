// Vendored from cresca-streamkit (streaming-logic reference: see its README). Only relative imports rewritten to package:cresca_app/...; do not edit logic here, fix upstream.
// Chunked transfer: HTTP Range probe + partial fetch + parallel
// multi-chunk download. Everything here is total (null/empty on failure)
// and injectable (pass any http.Client, e.g. MockClient in tests).
//
// Cache role (budgets — full matrix in lib/data/cache.dart):
// T6 media bytes ride the native player cache (4GB LRU, 10MB/track);
// Dart never caches media bytes (CDN throttles/403s out-of-player
// fetches). This file adds only a tiny probe memo: [ProbeMemo] caches
// 1-byte liveness checks (60s positive, 30s negative, cap 100 URLs,
// single-flight) so repeat opens skip the probe RTT. Segmented fetches
// stay uncached (offline files persist via DownloadStore).
//
// Where this is used:
//   * probeUrl — 1-byte Range GET that validates a stream URL is alive
//     and reports size/range support WITHOUT downloading the stream.
//   * fetchChunk — single Range GET, the primitive for resumable and
//     parallel downloads.
//   * downloadChunked — N parallel Range parts -> one file, with per-
//     part retry. Used for offline files, never for live playback:
//     playback bytes must flow inside the native player (ExoPlayer /
//     AVPlayer issue their own Range requests); fetching media bytes in
//     Dart gets throttled/403 by the CDN.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Browser-consistent headers for media hosts. googlevideo throttles
/// bare/script UAs; a desktop-Chrome profile + consent cookie keeps
/// Range requests at browser parity.
Map<String, String> mediaHeaders({String? range}) {
  final h = <String, String>{
    'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
    'Accept': '*/*',
    'Accept-Language': 'en-US,en;q=0.9',
    'Cookie': 'CONSENT=YES+cb',
  };
  if (range != null) h['Range'] = range;
  return h;
}

/// Result of a 1-byte probe.
class UrlProbe {
  /// True when the host answered 200 or 206 (URL is alive).
  final bool alive;

  /// True when the host honored the Range request (206) — chunked
  /// resume/parallel download is possible.
  final bool rangeOk;

  /// Total object size when the host reported it, else -1.
  final int contentLength;

  /// MIME when reported, else ''.
  final String contentType;

  const UrlProbe({
    this.alive = false,
    this.rangeOk = false,
    this.contentLength = -1,
    this.contentType = '',
  });
}

/// 1-byte Range probe: validates [url] and reports size/range support.
/// Costs ~hundreds of bytes, bounded by [timeout]. Never throws.
Future<UrlProbe> probeUrl(
  http.Client client,
  String url, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    if (url.isEmpty) return const UrlProbe();
    final res = await client
        .get(Uri.parse(url), headers: mediaHeaders(range: 'bytes=0-0'))
        .timeout(timeout);
    if (res.statusCode != 200 && res.statusCode != 206) {
      return const UrlProbe();
    }
    var total = -1;
    try {
      // "bytes 0-0/12345" on 206; full length on 200.
      final cr = res.headers['content-range'] ?? '';
      final m = RegExp(r'/(\d+)\s*$').firstMatch(cr);
      if (m != null) {
        total = int.tryParse(m.group(1) ?? '') ?? -1;
      } else {
        total = int.tryParse(res.headers['content-length'] ?? '') ?? -1;
      }
    } catch (_) {}
    var type = '';
    try {
      type = (res.headers['content-type'] ?? '').split(';').first.trim();
    } catch (_) {}
    return UrlProbe(
      alive: true,
      rangeOk: res.statusCode == 206,
      contentLength: total,
      contentType: type,
    );
  } catch (_) {
    return const UrlProbe();
  }
}

/// Probe memo budgets: 60s positive (alive URLs skip the re-probe),
/// 30s negative (dead URLs fail fast), cap 100 URLs (LRU-ish oldest
/// eviction). Single-flight joins concurrent probes of one URL.
const int probePosTtlMs = 60 * 1000;
const int probeNegTtlMs = 30 * 1000;
const int probeMemoCap = 100;

/// Memory memo for 1-byte liveness probes. Pure maps (no network);
/// [probeUrlCached] wires it to [probeUrl]. Never throws.
class ProbeMemo {
  // ignore: library_private_types_in_public_api
  final Map<String, _ProbeRow> rows = {};
  final Map<String, Future<UrlProbe>> flight = {};

  UrlProbe? getFresh(String url, int nowMs) {
    try {
      final hit = rows[url];
      if (hit == null) return null;
      final ttl = hit.probe.alive ? probePosTtlMs : probeNegTtlMs;
      if (nowMs - hit.atMs > ttl) {
        rows.remove(url);
        return null;
      }
      return hit.probe;
    } catch (_) {
      return null;
    }
  }

  void remember(String url, UrlProbe probe, int nowMs) {
    try {
      if (url.isEmpty) return;
      rows[url] = _ProbeRow(probe, nowMs);
      while (rows.length > probeMemoCap) {
        rows.remove(rows.keys.first);
      }
    } catch (_) {}
  }

  void drop(String url) {
    try {
      rows.remove(url);
    } catch (_) {}
  }
}

class _ProbeRow {
  final UrlProbe probe;
  final int atMs;
  const _ProbeRow(this.probe, this.atMs);
}

/// [probeUrl] with memo + single-flight: fresh rows serve with zero RTT
/// (microseconds); concurrent callers join one probe; misses memoize
/// (negative) so dead URLs fail fast. Same contract as [probeUrl];
/// never throws.
Future<UrlProbe> probeUrlCached(
  ProbeMemo memo,
  http.Client client,
  String url, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  try {
    if (url.isEmpty) return const UrlProbe();
    final now = DateTime.now().millisecondsSinceEpoch;
    final hit = memo.getFresh(url, now);
    if (hit != null) return hit;
    final existing = memo.flight[url];
    if (existing != null) {
      try {
        return await existing;
      } catch (_) {
        return const UrlProbe();
      }
    }
    final mine = probeUrl(client, url, timeout: timeout);
    memo.flight[url] = mine;
    try {
      while (memo.flight.length > probeMemoCap) {
        memo.flight.remove(memo.flight.keys.first);
      }
    } catch (_) {}
    UrlProbe out = const UrlProbe();
    try {
      out = await mine;
    } catch (_) {
      out = const UrlProbe();
    } finally {
      try {
        if (memo.flight[url] == mine) memo.flight.remove(url);
      } catch (_) {}
      try {
        memo.remember(url, out, DateTime.now().millisecondsSinceEpoch);
      } catch (_) {}
    }
    return out;
  } catch (_) {
    return const UrlProbe();
  }
}

/// Fetches bytes [start]..[end] (inclusive) from [url].
/// Returns empty bytes on any failure. Never throws.
Future<Uint8List> fetchChunk(
  http.Client client,
  String url,
  int start,
  int end, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  try {
    if (url.isEmpty || start < 0 || end < start) return Uint8List(0);
    final res = await client
        .get(Uri.parse(url),
            headers: mediaHeaders(range: 'bytes=$start-$end'))
        .timeout(timeout);
    if (res.statusCode != 200 && res.statusCode != 206) {
      return Uint8List(0);
    }
    return res.bodyBytes;
  } catch (_) {
    return Uint8List(0);
  }
}

/// Progress callback: received bytes, total bytes (-1 when unknown).
typedef ChunkProgress = void Function(int received, int total);

/// IDM/FDM-style segmented fetch: downloads bytes [start]..[end]
/// (inclusive) over [parts] parallel Range connections (up to 16, ALL in
/// flight at once) and returns the assembled bytes in order. Strict
/// accept per part (206 + exact byte count); any part failing after
/// [retries] fails the whole segment (caller falls back to a plain GET).
/// Never throws; empty bytes on failure.
Future<Uint8List> fetchSegmented(
  http.Client client,
  String url,
  int start,
  int end, {
  int parts = 8,
  int retries = 2,
  Duration timeout = const Duration(seconds: 30),
  ChunkProgress? onProgress,
}) async {
  try {
    if (url.isEmpty || start < 0 || end < start) return Uint8List(0);
    final total = end - start + 1;
    final n = parts.clamp(1, 16);
    if (n == 1) {
      return await fetchChunk(client, url, start, end, timeout: timeout);
    }
    final size = (total + n - 1) ~/ n;
    var received = 0;
    final bufs = List<Uint8List?>.filled(n, null);
    // Wave 1: all connections open at once (IDM pattern), each
    // self-retrying. Parts past the end (uneven totals) short-circuit.
    await Future.wait([
      for (var j = 0; j < n; j++)
        (() {
          final s = start + j * size;
          if (s > end) {
            bufs[j] = Uint8List(0);
            return Future.value();
          }
          final e = (j == n - 1) ? end : (s + size - 1);
          return _part(client, url, s, e > end ? end : e, retries, timeout)
              .then((b) {
            if (b != null) {
              bufs[j] = b;
              received += b.length;
              try {
                onProgress?.call(received, total);
              } catch (_) {}
            }
          });
        })(),
    ]);
    // Wave 2: failed parts retried SEQUENTIALLY (CDN throttles bursts;
    // one-at-a-time almost always succeeds). Skipped when wave 1 won.
    for (var j = 0; j < n; j++) {
      if (bufs[j] != null) continue;
      final s = start + j * size;
      if (s > end) {
        bufs[j] = Uint8List(0);
        continue;
      }
      final e = (j == n - 1) ? end : (s + size - 1);
      try {
        final b = await _part(client, url, s, e > end ? end : e,
            retries + 1, timeout * 2);
        if (b != null) {
          bufs[j] = b;
          received += b.length;
          try {
            onProgress?.call(received, total);
          } catch (_) {}
        }
      } catch (_) {}
    }
    if (bufs.any((b) => b == null)) return Uint8List(0);
    final out = BytesBuilder();
    for (final b in bufs) {
      out.add(b!);
    }
    final bytes = out.toBytes();
    // Paranoia: exact length or reject (never hand back a corrupt file).
    if (bytes.length != total) return Uint8List(0);
    return bytes;
  } catch (_) {
    return Uint8List(0);
  }
}

/// Parallel chunked download: splits [totalSize] into [parts] Range
/// connections (IDM-style, up to 16, all in flight), retries each part
/// up to [retries], and streams parts straight to [target] at their file
/// offsets (RandomAccessFile) instead of assembling the whole file in
/// RAM — offline files can be 50MB+. Falls back to a single plain GET
/// when the size is unknown, the host ignores Range, OR the CDN throttles
/// segmented fetching (googlevideo persistently 403s a URL after a few
/// quick ranges — the whole-GET fallback is the production path for full
/// files). Default 4 parts: stays inside the observed per-URL range quota
/// while still 4x-ing head throughput. Never throws.
Future<bool> downloadChunked(
  http.Client client,
  String url,
  File target,
  int totalSize, {
  int parts = 4,
  int retries = 2,
  Duration timeout = const Duration(seconds: 30),
  ChunkProgress? onProgress,
}) async {
  try {
    if (url.isEmpty) return false;
    if (totalSize <= 0 || parts <= 1) {
      return await _downloadWhole(client, url, target,
          timeout: timeout, onProgress: onProgress);
    }
    final n = parts.clamp(1, 16);
    final size = (totalSize + n - 1) ~/ n;
    RandomAccessFile? raf;
    try {
      raf = await target.open(mode: FileMode.write);
    } catch (_) {
      return false;
    }
    try {
      var received = 0;
      for (var j = 0; j < n; j++) {
        final s = j * size;
        if (s >= totalSize) break;
        var e = s + size - 1;
        if (e >= totalSize) e = totalSize - 1;
        // Sequential (CDN throttles Range bursts; one-at-a-time almost
        // always succeeds), appended straight to the file: RAM stays
        // ~one part, never the whole file.
        var b = await _part(client, url, s, e, retries, timeout);
        b ??= await _part(client, url, s, e, retries + 1, timeout * 2);
        if (b == null) throw StateError('part $j rejected');
        raf.writeFromSync(b);
        received += b.length;
        try {
          onProgress?.call(received, totalSize);
        } catch (_) {}
      }
      await raf.close();
    } catch (_) {
      try {
        await raf.close();
      } catch (_) {}
      // A rejected part (host ignores Range, short part, ...) falls back
      // to one plain GET rather than a corrupt file.
      return await _downloadWhole(client, url, target,
          timeout: timeout, onProgress: onProgress);
    }
    // Paranoia: exact length or reject (never hand back a corrupt file).
    try {
      if (await target.length() != totalSize) {
        return await _downloadWhole(client, url, target,
            timeout: timeout, onProgress: onProgress);
      }
    } catch (_) {
      return false;
    }
    return true;
  } catch (_) {
    return false;
  }
}

Future<Uint8List?> _part(
  http.Client client,
  String url,
  int start,
  int end,
  int retries,
  Duration timeout,
) async {
  // Strict accept: 206 + EXACTLY the requested byte count. A host that
  // answers 200 (or a short/long 206) ignored the Range — rejecting the
  // part forces the single-GET fallback instead of a corrupt file.
  final want = end - start + 1;
  for (var attempt = 0; attempt <= retries; attempt++) {
    try {
      final res = await client
          .get(Uri.parse(url),
              headers: mediaHeaders(range: 'bytes=$start-$end'))
          .timeout(timeout);
      if (res.statusCode == 206 && res.bodyBytes.length == want) {
        return res.bodyBytes;
      }
    } catch (_) {}
  }
  return null;
}

Future<bool> _downloadWhole(
  http.Client client,
  String url,
  File target, {
  required Duration timeout,
  ChunkProgress? onProgress,
}) async {
  // Streams response bytes straight to [target] (never buffers the whole
  // body in RAM): this is the production path for full files.
  http.StreamedResponse? res;
  try {
    final req = http.Request('GET', Uri.parse(url))
      ..headers.addAll(mediaHeaders());
    res = await client.send(req).timeout(timeout);
  } catch (_) {
    return false;
  }
  try {
    if (res.statusCode != 200 && res.statusCode != 206) {
      try {
        await res.stream.drain();
      } catch (_) {}
      return false;
    }
    RandomAccessFile? raf;
    try {
      raf = await target.open(mode: FileMode.write);
    } catch (_) {
      try {
        await res.stream.drain();
      } catch (_) {}
      return false;
    }
    var received = 0;
    final total = res.contentLength ?? -1;
    try {
      await for (final chunk in res.stream.timeout(timeout)) {
        raf.writeFromSync(chunk);
        received += chunk.length;
        try {
          onProgress?.call(received, total);
        } catch (_) {}
      }
      await raf.close();
    } catch (_) {
      try {
        await raf.close();
      } catch (_) {}
      return false;
    }
    if (received <= 0) return false;
    try {
      onProgress?.call(received, received);
    } catch (_) {}
    return true;
  } catch (_) {
    return false;
  }
}
