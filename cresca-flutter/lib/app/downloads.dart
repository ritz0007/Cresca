// Offline downloads (L5): `Artist - Title.m4a`, in-app vs device-Music
// switch, MB list, offline-first playback, clean delete, replay prefers
// file. Native refs: DownloadStore.kt (dlmap rows, sanitize, both dirs,
// legacy names), YtDlpWrapper (`.m4a` ext). Transport is vendored
// streamkit chunked fetch (IDM-style 4-part Range segments with
// sequential retry + whole-GET fallback — googlevideo persistently 403s
// a URL after a few quick ranges, so segments are downloads-only by
// design; live playback bytes always flow inside ExoPlayer). Rows
// persist as downloads.json (same row schema as dlmap).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:http/http.dart' as http;

import '../core/track.dart';
import '../data/streamkit/chunks.dart' as sk;
import 'library.dart' show atomicWrite, backupCorrupt, readText;

const String downloadExt = '.m4a';
const String downloadSubdir = 'Cresca';

/// Max persisted download rows. Enforced in memory AND on write so the
/// map can never grow without bound (parity with playlist caps).
const int downloadRowsCap = 2000;

/// Human file name: "Artist - Title". Falls back to the id.
String downloadFileName(YtTrack t) {
  try {
    final base = '${t.artist.trim()} - ${t.title.trim()}'.trim();
    final clean = sanitizeFileName(base == '-' ? t.id : base);
    return '$clean$downloadExt';
  } catch (_) {
    return '${t.id}$downloadExt';
  }
}

String sanitizeFileName(String name) {
  try {
    final buf = StringBuffer();
    for (final c in name.runes) {
      final ch = String.fromCharCode(c);
      if ((ch.compareTo('A') >= 0 && ch.compareTo('Z') <= 0) ||
          (ch.compareTo('a') >= 0 && ch.compareTo('z') <= 0) ||
          (ch.compareTo('0') >= 0 && ch.compareTo('9') <= 0) ||
          ch == ' ' ||
          ch == '_' ||
          ch == '-' ||
          ch == '(' ||
          ch == ')' ||
          ch == '&') {
        buf.write(ch);
      }
    }
    var s = buf.toString().trim();
    if (s.length > 80) s = s.substring(0, 80).trim();
    return s.isEmpty ? 'track' : s;
  } catch (_) {
    return 'track';
  }
}

class DownloadEntry {
  final String trackId;
  final String taskId;
  final String title;
  final String artist;
  final String name;
  final bool isPublic;
  const DownloadEntry({
    required this.trackId,
    required this.taskId,
    required this.title,
    required this.artist,
    required this.name,
    required this.isPublic,
  });
}

Map<String, DownloadEntry> downloadRowsFromJson(String raw,
    {int cap = downloadRowsCap}) {
  final out = <String, DownloadEntry>{};
  try {
    if (raw.trim().isEmpty) return out;
    final root = jsonDecode(raw);
    if (root is! Map) return out;
    for (final e in root.entries) {
      try {
        if (out.length >= cap) break;
        final key = e.key.toString();
        if (key.isEmpty) continue;
        final o = e.value;
        if (o is! Map) continue;
        out[key] = DownloadEntry(
          trackId: key,
          taskId: (o['downloadId'] ?? '').toString(),
          title: (o['title'] ?? '').toString(),
          artist: (o['artist'] ?? '').toString(),
          name: (o['name'] ?? '').toString(),
          isPublic: o['public'] == true,
        );
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

String downloadRowsToJson(Map<String, DownloadEntry> rows,
        {int cap = downloadRowsCap}) =>
    jsonEncode({
      for (final e in rows.entries.take(cap))
        if (e.key.isNotEmpty)
          e.key: {
            'downloadId': e.value.taskId,
            'title': e.value.title,
            'artist': e.value.artist,
            'name': e.value.name,
            'public': e.value.isPublic,
          },
    });

class DownloadStore {
  final Directory appDir;
  Directory? publicDir;
  final http.Client httpClient;
  final Map<String, DownloadEntry> rows = {};
  final Map<String, double> progress = {};
  final Map<String, TaskStatus> status = {};

  /// 'app' (private folder) or 'device' (public Music folder).
  String location = 'app';
  void Function()? onChanged;

  StreamSubscription<TaskUpdate>? _sub;

  DownloadStore(this.appDir, {this.publicDir, http.Client? httpClient})
      : httpClient = httpClient ?? http.Client();

  File get _rowsFile => File('${appDir.path}/downloads.json');

  List<Directory> _dirs() => [
        Directory('${appDir.path}/$downloadSubdir'),
        if (publicDir != null)
          Directory('${publicDir!.path}/$downloadSubdir'),
      ];

  /// Track ids with a fetch currently in flight. Guards against
  /// double-enqueue (double-tap Download) which would otherwise fetch
  /// the same bytes twice and clobber the row.
  final Set<String> _active = {};

  Future<void> load() async {
    try {
      final raw = await readText(_rowsFile);
      rows.clear();
      rows.addAll(downloadRowsFromJson(raw));
      // Blank-id guard (hand-edited / torn writes must never seed rows).
      try {
        rows.removeWhere((k, v) => k.isEmpty || v.trackId.isEmpty);
      } catch (_) {}
      // Corrupt file that parses to empty while raw was non-trivial:
      // back it up once instead of silently resetting.
      try {
        final t = raw.trim();
        if (rows.isEmpty && t.length > 2 && t != '{}' && t != '[]') {
          await backupCorrupt(_rowsFile, raw);
        }
      } catch (_) {}
      _enforceCap();
      await _sweepPartials();
      await _listen();
      // Orphan-row prune (files deleted outside the app) stays off the
      // load hot path: it re-saves when it drops rows, so run it in the
      // background without blocking callers of load().
      try {
        unawaited(pruneMissing());
      } catch (_) {}
    } catch (_) {}
  }

  /// Caps [rows] in memory (oldest insertion-order entries without a
  /// file on disk go first; never drops actively downloading rows).
  /// Never throws.
  void _enforceCap() {
    try {
      if (rows.length <= downloadRowsCap) return;
      final drop = <String>[];
      for (final id in rows.keys) {
        try {
          if (rows.length - drop.length <= downloadRowsCap) break;
          if (_active.contains(id)) continue;
          if (fileFor(id) != null) continue;
          drop.add(id);
        } catch (_) {}
      }
      for (final id in rows.keys) {
        try {
          if (rows.length - drop.length <= downloadRowsCap) break;
          if (_active.contains(id) || drop.contains(id)) continue;
          drop.add(id);
        } catch (_) {}
      }
      for (final id in drop) {
        try {
          final row = rows.remove(id);
          if (row != null) {
            progress.remove(row.taskId);
            status.remove(row.taskId);
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// Removes stale `.part` files left by killed/failed fetches plus
  /// zero-byte `.m4a` crash remnants, so they never surface as
  /// completed downloads. Never throws.
  Future<void> _sweepPartials() async {
    try {
      for (final d in _dirs()) {
        List<FileSystemEntity> files;
        try {
          if (!d.existsSync()) continue;
          files = d.listSync().toList();
        } catch (_) {
          continue;
        }
        for (final e in files) {
          try {
            if (e is! File) continue;
            final low = e.path.toLowerCase();
            if (low.endsWith('.part')) {
              await e.delete();
            } else if (low.endsWith(downloadExt)) {
              try {
                if (e.statSync().size <= 0) await e.delete();
              } catch (_) {}
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<void> _listen() async {
    try {
      await _sub?.cancel();
    } catch (_) {}
    try {
      _sub = FileDownloader()
          .updates
          .listen(_onUpdate, onError: (_) {});
    } catch (_) {}
  }

  void _onUpdate(TaskUpdate u) {
    try {
      if (u is TaskProgressUpdate) {
        progress[u.task.taskId] =
            (u.progress * 100).clamp(0.0, 100.0);
      } else if (u is TaskStatusUpdate) {
        status[u.task.taskId] = u.status;
        if (u.status == TaskStatus.complete ||
            u.status == TaskStatus.failed ||
            u.status == TaskStatus.notFound ||
            u.status == TaskStatus.canceled) {
          progress.remove(u.task.taskId);
        }
      }
      try {
        onChanged?.call();
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _saveRows() async {
    try {
      // Cap enforced on write too (load caps at downloadRowsCap; without
      // this the in-memory map grows without bound).
      _enforceCap();
      await atomicWrite(_rowsFile, downloadRowsToJson(rows));
    } catch (_) {}
  }

  /// True while a fetch for [trackId] is in flight.
  bool isDownloading(String trackId) {
    try {
      return _active.contains(trackId);
    } catch (_) {
      return false;
    }
  }

  /// Total bytes held by completed download files across both
  /// locations (storage accounting for the downloads sheet).
  int totalBytes() {
    var total = 0;
    try {
      for (final (_, f, _) in listAll()) {
        try {
          total += f.statSync().size;
        } catch (_) {}
      }
    } catch (_) {}
    return total;
  }

  /// Drops rows whose file is gone and which are not actively
  /// downloading (e.g. user deleted files via a file manager).
  /// Returns the number of rows pruned. Never throws.
  Future<int> pruneMissing() async {
    var n = 0;
    try {
      final dead = <String>[];
      for (final id in rows.keys.toList()) {
        try {
          if (_active.contains(id)) continue;
          if (fileFor(id) != null) continue;
          dead.add(id);
        } catch (_) {}
      }
      for (final id in dead) {
        try {
          final row = rows.remove(id);
          if (row != null) {
            progress.remove(row.taskId);
            status.remove(row.taskId);
          }
          n++;
        } catch (_) {}
      }
      if (n > 0) await _saveRows();
    } catch (_) {}
    return n;
  }

  /// Re-resolves a fresh stream URL via [resolveUrl] and re-enqueues a
  /// failed/missing download. Stored URLs expire, so callers must pass
  /// a resolver (AppState.resolver.audioUrl). Returns false when a
  /// fetch is already in flight or the row is complete. Never throws.
  Future<bool> retry(
      YtTrack track, Future<String?> Function() resolveUrl) async {
    try {
      if (_active.contains(track.id)) return false;
      if (isDownloaded(track.id)) return false;
      String? url;
      try {
        url = await resolveUrl().timeout(const Duration(seconds: 45));
      } catch (_) {
        return false;
      }
      if (url == null || url.isEmpty) return false;
      return await enqueue(track, url);
    } catch (_) {
      return false;
    }
  }

  /// 0–100, -1 when failed/missing (native progress() semantics).
  int progressFor(String trackId) {
    try {
      final row = rows[trackId];
      if (row == null) return -1;
      final st = status[row.taskId];
      if (st == TaskStatus.complete) return 100;
      if (st == TaskStatus.failed ||
          st == TaskStatus.notFound ||
          st == TaskStatus.canceled) {
        return -1;
      }
      final p = progress[row.taskId];
      if (p == null) {
        return fileFor(trackId) != null ? 100 : 0;
      }
      return p.round().clamp(0, 100);
    } catch (_) {
      return -1;
    }
  }

  bool isDownloaded(String trackId) {
    try {
      return fileFor(trackId) != null;
    } catch (_) {
      return false;
    }
  }

  File? fileFor(String trackId) {
    try {
      final row = rows[trackId];
      final names = <String>[
        if (row != null && row.name.isNotEmpty) row.name,
        '${sanitizeFileName(trackId)}$downloadExt', // legacy layout
      ];
      for (final d in _dirs()) {
        for (final n in names) {
          try {
            final f = File('${d.path}/$n');
            if (f.existsSync() && f.statSync().type ==
                FileSystemEntityType.file) {
              return f;
            }
          } catch (_) {}
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Segmented offline fetch (streamkit downloadChunked, default 4
  /// parts): size probed first (whole-GET when unknown), progress
  /// reported per row, whole-file fallback on throttle. Fetches into
  /// a `.part` temp file and renames on success, so failed attempts
  /// never surface as completed downloads. Concurrent enqueues for
  /// the same track are rejected. Same signature and row schema as
  /// before; never throws (false on any failure).
  Future<bool> enqueue(YtTrack track, String audioUrl) async {
    try {
      if (audioUrl.isEmpty || track.id.isEmpty) return false;
      if (fileFor(track.id) != null) return false;
      if (!_active.add(track.id)) return false;
      final name = downloadFileName(track);
      final pub = location == 'device';
      final base = pub ? publicDir : null;
      final dir = Directory(
          '${(base ?? appDir).path}/$downloadSubdir');
      try {
        await dir.create(recursive: true);
      } catch (_) {}
      final taskId =
          'dl_${track.id}_${DateTime.now().millisecondsSinceEpoch}';
      status[taskId] = TaskStatus.running;
      progress[taskId] = 0;
      try {
        onChanged?.call();
      } catch (_) {}
      var size = 0;
      try {
        final probe = await sk
            .probeUrl(httpClient, audioUrl)
            .timeout(const Duration(seconds: 10));
        if (probe.alive) size = probe.contentLength;
      } catch (_) {}
      final file = File('${dir.path}/$name');
      final tmp = File('${file.path}.part');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      final ok = await sk
          .downloadChunked(httpClient, audioUrl, tmp, size,
              parts: 4,
              onProgress: (rx, total) {
            try {
              progress[taskId] = total > 0
                  ? (rx / total * 100).clamp(0.0, 100.0)
                  : 0.0;
              onChanged?.call();
            } catch (_) {}
          }).timeout(const Duration(minutes: 15)).catchError((_) => false);
      try {
        progress.remove(taskId);
      } catch (_) {}
      if (!ok) {
        try {
          status[taskId] = TaskStatus.failed;
          if (await tmp.exists()) await tmp.delete();
          onChanged?.call();
        } catch (_) {}
        try {
          _active.remove(track.id);
        } catch (_) {}
        return false;
      }
      try {
        // Validate + publish atomically: zero-byte output is a
        // failed fetch, not a download.
        final len = await tmp.length();
        if (len <= 0) {
          try {
            await tmp.delete();
          } catch (_) {}
          status[taskId] = TaskStatus.failed;
          onChanged?.call();
          return false;
        }
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
        await tmp.rename(file.path);
      } catch (_) {
        try {
          status[taskId] = TaskStatus.failed;
        } catch (_) {}
        try {
          onChanged?.call();
        } catch (_) {}
        return false;
      } finally {
        try {
          _active.remove(track.id);
        } catch (_) {}
      }
      final prev = rows[track.id];
      status[taskId] = TaskStatus.complete;
      rows[track.id] = DownloadEntry(
        trackId: track.id,
        taskId: taskId,
        title: track.title,
        artist: track.artist,
        name: name,
        isPublic: pub,
      );
      // Retire the previous attempt's progress/status so maps don't
      // grow one entry per retry.
      try {
        if (prev != null && prev.taskId != taskId) {
          progress.remove(prev.taskId);
          status.remove(prev.taskId);
        }
      } catch (_) {}
      await _saveRows();
      try {
        onChanged?.call();
      } catch (_) {}
      return true;
    } catch (_) {
      try {
        _active.remove(track.id);
      } catch (_) {}
      return false;
    }
  }

  /// Download list with files: (track, file, MB). Unknown-origin .m4a
  /// files surface with filename-derived metadata (native parity).
  /// Zero-byte files (crashed writes) are skipped, and a track present
  /// in both locations is listed once.
  List<(YtTrack, File, double)> listAll() {
    final out = <(YtTrack, File, double)>[];
    final seenIds = <String>{};
    try {
      final byName = <String, DownloadEntry>{};
      for (final r in rows.values) {
        if (r.name.isNotEmpty) byName[r.name] = r;
      }
      for (final d in _dirs()) {
        List<FileSystemEntity> files;
        try {
          if (!d.existsSync()) continue;
          files = d.listSync().where((e) {
            try {
              if (e is! File) return false;
              if (!e.path.toLowerCase().endsWith(downloadExt)) {
                return false;
              }
              // Skip crashed/partial writes; real audio is never empty.
              return e.statSync().size > 0;
            } catch (_) {
              return false;
            }
          }).toList();
        } catch (_) {
          continue;
        }
        for (final e in files) {
          try {
            final f = e as File;
            final name =
                f.path.split(RegExp(r'[/\\]')).last;
            final hit = byName[name];
            final base = name.substring(
                0, name.length - downloadExt.length);
            final id = hit != null ? hit.trackId : base;
            if (!seenIds.add(id)) continue;
            final t = hit != null
                ? YtTrack(
                    id: hit.trackId,
                    title: hit.title.isEmpty ? base : hit.title,
                    artist: hit.artist.isEmpty
                        ? 'Unknown Artist'
                        : hit.artist,
                    thumbUrl: '',
                    watchUrl: '',
                    localPath: f.path,
                  )
                : YtTrack(
                    id: base,
                    title: base,
                    artist: 'Unknown Artist',
                    thumbUrl: '',
                    watchUrl: '',
                    localPath: f.path,
                  );
            double mb = 0;
            try {
              mb = f.statSync().size / (1024 * 1024);
            } catch (_) {}
            out.add((t, f, mb));
          } catch (_) {}
        }
      }
    } catch (_) {}
    return out;
  }

  /// Removes every copy of a download (row-named + legacy files in all
  /// locations, plus stale `.part` files) and retires its
  /// progress/status so maps don't leak one entry per download.
  Future<void> delete(String trackId) async {
    try {
      final row = rows[trackId];
      final names = <String>{
        if (row != null && row.name.isNotEmpty) row.name,
        if (row != null && row.name.isNotEmpty) '${row.name}.part',
        '${sanitizeFileName(trackId)}$downloadExt', // legacy layout
      };
      for (final d in _dirs()) {
        for (final n in names) {
          try {
            final f = File('${d.path}/$n');
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
    try {
      final row = rows.remove(trackId);
      try {
        if (row != null) {
          progress.remove(row.taskId);
          status.remove(row.taskId);
        }
      } catch (_) {}
      await _saveRows();
      try {
        onChanged?.call();
      } catch (_) {}
    } catch (_) {}
  }

  void dispose() {
    try {
      _sub?.cancel();
    } catch (_) {}
    try {
      httpClient.close();
    } catch (_) {}
  }
}
