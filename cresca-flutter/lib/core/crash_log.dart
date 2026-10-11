// Pure-Dart crash-log filename/ring logic.
// Native ref: CrashLog.kt (crash/<stamp>.log, ring of 5, 100 KB cap).

const int crashRingCap = 5;
const int crashShareBytes = 100 * 1024;

/// Filename stamp: yyyyMMdd-HHmmss, filesystem-safe.
String crashStamp(DateTime t) {
  String p(int v, int w) => v.toString().padLeft(w, '0');
  return '${p(t.year, 4)}${p(t.month, 2)}${p(t.day, 2)}-'
      '${p(t.hour, 2)}${p(t.minute, 2)}${p(t.second, 2)}';
}

String crashName(DateTime t) => 'crash/${crashStamp(t)}.log';

/// Ring-of-5: oldest deleted first. Returns the survivors + the new file.
List<String> crashRing(List<String> existing, String next) {
  final all = [...existing, next]..sort();
  while (all.length > crashRingCap) {
    all.removeAt(0);
  }
  return all;
}

/// Newest-first pick for the share sheet.
String? crashNewest(List<String> files) {
  if (files.isEmpty) return null;
  final sorted = [...files]..sort();
  return sorted.last;
}

/// Bounded breadcrumb trail (last-N action crumbs attached to the next
/// crash report). Pure; never throws.
List<String> crashBreadcrumbs(
  List<String> existing,
  String next, [
  int cap = 20,
]) {
  try {
    final c = cap < 1 ? 20 : cap;
    final all = [...existing, next];
    while (all.length > c) {
      all.removeAt(0);
    }
    return all;
  } catch (_) {
    return [...existing, next];
  }
}

/// Full on-device report body (native CrashLog.write info block 1:1:
/// time/thread/version/sdk/device + stack + breadcrumbs). Pure; never
/// throws, no network.
String crashBody({
  required String thread,
  required String text,
  String version = '',
  String sdk = '',
  String device = '',
  Object? error,
  StackTrace? stackTrace,
  List<String> breadcrumbs = const [],
}) {
  try {
    final b = StringBuffer();
    b.writeln('time=${DateTime.now().toIso8601String()}');
    b.writeln('thread=$thread');
    if (version.isNotEmpty) b.writeln('version=$version');
    if (sdk.isNotEmpty) b.writeln('sdk=$sdk');
    if (device.isNotEmpty) b.writeln('device=$device');
    b.writeln(text);
    if (error != null) b.writeln('$error');
    if (stackTrace != null) b.writeln('$stackTrace');
    if (breadcrumbs.isNotEmpty) {
      b.writeln('breadcrumbs:');
      for (final c in breadcrumbs) {
        b.writeln('- $c');
      }
    }
    return b.toString();
  } catch (_) {
    return text;
  }
}

/// Share-safe slice (native `take(100KB)` 1:1 — head kept so the
/// header/version/stack top survive). Pure; never throws.
String crashShareSlice(String text) {
  try {
    if (text.length <= crashShareBytes) return text;
    return text.substring(0, crashShareBytes);
  } catch (_) {
    return '';
  }
}
