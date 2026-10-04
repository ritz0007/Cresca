// Offline downloads (L5): `Artist - Title.m4a`, in-app vs device-Music
// switch, MB list, offline-first playback, clean delete, replay prefers
// file. Native refs: DownloadStore.kt (dlmap rows, sanitize, both dirs,
// legacy names), YtDlpWrapper (`.m4a` ext). Transport is
// background_downloader (DownloadManager twin): enqueue + progress +
// cancel; rows persist as downloads.json (same row schema as dlmap).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';

import '../core/track.dart';
import 'library.dart' show atomicWrite, readText;

const String downloadExt = '.m4a';
const String downloadSubdir = 'Cresca';

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

Map<String, DownloadEntry> downloadRowsFromJson(String raw) {
  final out = <String, DownloadEntry>{};
  try {
    if (raw.trim().isEmpty) return out;
    final root = jsonDecode(raw);
    if (root is! Map) return out;
    for (final e in root.entries) {
      try {
        final o = e.value;
        if (o is! Map) continue;
        out[e.key.toString()] = DownloadEntry(
          trackId: e.key.toString(),
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

String downloadRowsToJson(Map<String, DownloadEntry> rows) => jsonEncode({
      for (final e in rows.entries)
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
  final Map<String, DownloadEntry> rows = {};
  final Map<String, double> progress = {};
  final Map<String, TaskStatus> status = {};

  /// 'app' (private folder) or 'device' (public Music folder).
  String location = 'app';
  void Function()? onChanged;

  StreamSubscription<TaskUpdate>? _sub;

  DownloadStore(this.appDir, {this.publicDir});

  File get _rowsFile => File('${appDir.path}/downloads.json');

  List<Directory> _dirs() => [
        Directory('${appDir.path}/$downloadSubdir'),
        if (publicDir != null)
          Directory('${publicDir!.path}/$downloadSubdir'),
      ];

  Future<void> load() async {
    try {
      rows.clear();
      rows.addAll(
          downloadRowsFromJson(await readText(_rowsFile)));
      await _listen();
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
      await atomicWrite(_rowsFile, downloadRowsToJson(rows));
    } catch (_) {}
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

  Future<bool> enqueue(YtTrack track, String audioUrl) async {
    try {
      if (audioUrl.isEmpty) return false;
      final name = downloadFileName(track);
      final pub = location == 'device';
      final task = DownloadTask(
        taskId: 'dl_${track.id}_${DateTime.now().millisecondsSinceEpoch}',
        url: audioUrl,
        filename: name,
        directory: pub ? 'Music/$downloadSubdir' : downloadSubdir,
        baseDirectory: pub
            ? BaseDirectory.root
            : BaseDirectory.applicationDocuments,
        updates: Updates.statusAndProgress,
        retries: 2,
      );
      final ok = await FileDownloader().enqueue(task);
      if (!ok) return false;
      rows[track.id] = DownloadEntry(
        trackId: track.id,
        taskId: task.taskId,
        title: track.title,
        artist: track.artist,
        name: name,
        isPublic: pub,
      );
      await _saveRows();
      try {
        onChanged?.call();
      } catch (_) {}
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Download list with files: (track, file, MB). Unknown-origin .m4a
  /// files surface with filename-derived metadata (native parity).
  List<(YtTrack, File, double)> listAll() {
    final out = <(YtTrack, File, double)>[];
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
              return e is File &&
                  e.path.toLowerCase().endsWith(downloadExt);
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

  Future<void> delete(String trackId) async {
    try {
      final row = rows[trackId];
      if (row != null && row.taskId.isNotEmpty) {
        try {
          await FileDownloader()
              .cancelTaskWithId(row.taskId);
        } catch (_) {}
      }
    } catch (_) {}
    try {
      final f = fileFor(trackId);
      if (f != null) {
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
    try {
      rows.remove(trackId);
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
  }
}
