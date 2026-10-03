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
