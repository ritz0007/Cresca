// On-device crash log (A9): crash/*.log, ring of 5, share newest
// (100KB cap) via system sheet. Native ref: CrashLog.kt. Pure filename/
// ring math lives in core/crash_log.dart; this file owns file IO.
//
// Breadcrumb model: every log() call is a breadcrumb appended to a
// per-day file (crash-log-yyyyMMdd.log), so a trail of breadcrumbs
// survives until the incident instead of each breadcrumb becoming its
// own file and evicting real crashes from the ring. When the day file
// exceeds [crashDayBytes], new incidents fall back to per-incident
// files (core crashName) so the newest incident is never dropped.

import 'dart:io';

import 'package:share_plus/share_plus.dart';

import '../core/crash_log.dart';

/// Per-day breadcrumb file cap; overflow rotates to per-incident files.
const int crashDayBytes = 200 * 1024;

/// Day-file name: crash-log-yyyyMMdd.log (sorts after per-incident
/// yyyyMMdd-HHmmss.log names, so the live trail is "newest").
String crashDayName(DateTime t) {
  String p(int v, int w) => v.toString().padLeft(w, '0');
  return 'crash-log-${p(t.year, 4)}${p(t.month, 2)}${p(t.day, 2)}.log';
}

class CrashLog {
  final Directory dir;
  CrashLog(this.dir);

  Directory get _crashDir {
    final d = Directory('${dir.path}/crash');
    try {
      d.createSync(recursive: true);
    } catch (_) {}
    return d;
  }

  String _osTag() {
    try {
      return '${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'unknown';
    }
  }

  /// Appends a crash/error breadcrumb. Never throws. Entry carries a
  /// timestamp, the OS tag (native CrashLog writes version/sdk/device;
  /// Dart has no package context here, so the OS tag is the stable
  /// subset), the message, and the error + stack trace when given.
  Future<void> log(String text, [Object? error, StackTrace? st]) async {
    try {
      final d = _crashDir;
      final now = DateTime.now();
      File f = File('${d.path}/${crashDayName(now)}');
      try {
        if (await f.exists() && await f.length() > crashDayBytes) {
          final name = crashName(now).split('/').last;
          f = File('${d.path}/$name');
        }
      } catch (_) {}
      final entry = StringBuffer()
        ..writeln('--- [${now.toIso8601String()}] $text')
        ..writeln('os=${_osTag()}');
      if (error != null) {
        try {
          entry.writeln('$error');
        } catch (_) {}
      }
      if (st != null) {
        try {
          entry.writeln('$st');
        } catch (_) {}
      }
      entry.writeln();
      try {
        await f.writeAsString(entry.toString(), mode: FileMode.append);
      } catch (_) {}
      await _enforceRing(d);
    } catch (_) {}
  }

  Future<void> _enforceRing(Directory d) async {
    try {
      final files = await d
          .list()
          .where((e) => e is File && e.path.endsWith('.log'))
          .cast<File>()
          .toList();
      files.sort((a, b) => a.path.compareTo(b.path));
      while (files.length > crashRingCap) {
        try {
          await files.removeAt(0).delete();
        } catch (_) {
          break;
        }
      }
    } catch (_) {}
  }

  Future<String?> newestPath() async {
    try {
      final files = await _crashDir
          .list()
          .where((e) => e is File && e.path.endsWith('.log'))
          .map((e) => e.path)
          .toList();
      final name = crashNewest(files.map((p) {
        final base = p.split(RegExp(r'[/\\]')).last;
        return 'crash/$base';
      }).toList());
      if (name == null) return null;
      return '${_crashDir.path}/${name.split('/').last}';
    } catch (_) {
      return null;
    }
  }

  /// Shares the newest log via the system sheet. Files over the 100KB
  /// cap share a truncated tail copy (newest entries matter most)
  /// instead of refusing like before; native shares text.take(100KB).
  Future<bool> shareNewest() async {
    try {
      final p = await newestPath();
      if (p == null) return false;
      final f = File(p);
      if (!await f.exists()) return false;
      if (await f.length() <= crashShareBytes) {
        await SharePlus.instance.share(
            ShareParams(files: [XFile(p)], text: 'Cresca crash log'));
        return true;
      }
      final tmp = File(
          '${Directory.systemTemp.path}/cresca-crash-shared.log');
      try {
        final raf = await f.open(mode: FileMode.read);
        try {
          final len = await raf.length();
          final start = len > crashShareBytes ? len - crashShareBytes : 0;
          await raf.setPosition(start);
          final bytes = <int>[];
          var remaining = crashShareBytes;
          while (remaining > 0) {
            final chunk =
                await raf.read(remaining > 65536 ? 65536 : remaining);
            if (chunk.isEmpty) break;
            bytes.addAll(chunk);
            remaining -= chunk.length;
          }
          // Start at a line boundary so the tail isn't half a line.
          var off = 0;
          for (var i = 0; i < bytes.length; i++) {
            if (bytes[i] == 10) {
              off = i + 1;
              break;
            }
          }
          await tmp.writeAsBytes(bytes.sublist(off), flush: true);
        } finally {
          try {
            await raf.close();
          } catch (_) {}
        }
        await SharePlus.instance.share(ShareParams(
            files: [XFile(tmp.path)], text: 'Cresca crash log (tail)'));
        return true;
      } catch (_) {
        return false;
      }
    } catch (_) {
      return false;
    }
  }
}
