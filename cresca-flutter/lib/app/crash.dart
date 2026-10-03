// On-device crash log (A9): crash/<stamp>.log, ring of 5, share newest
// (100KB cap) via system sheet. Native ref: CrashLog.kt. Pure filename/
// ring math lives in core/crash_log.dart; this file owns file IO.

import 'dart:io';

import 'package:share_plus/share_plus.dart';

import '../core/crash_log.dart';

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

  /// Appends a crash/error entry. Never throws.
  Future<void> log(String text, [Object? error, StackTrace? st]) async {
    try {
      final d = _crashDir;
      final name = crashName(DateTime.now()).split('/').last;
      final f = File('${d.path}/$name');
      final entry = '[${DateTime.now().toIso8601String()}] $text'
          '${error == null ? '' : '\n$error'}'
          '${st == null ? '' : '\n$st'}\n';
      try {
        await f.writeAsString(entry, mode: FileMode.append);
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

  /// Shares the newest log (100KB cap) via the system sheet.
  Future<bool> shareNewest() async {
    try {
      final p = await newestPath();
      if (p == null) return false;
      final f = File(p);
      if (!await f.exists()) return false;
      if (await f.length() > crashShareBytes) return false;
      await SharePlus.instance.share(
          ShareParams(files: [XFile(p)], text: 'Cresca crash log'));
      return true;
    } catch (_) {
      return false;
    }
  }
}
