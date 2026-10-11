// Podcast subscriptions + per-episode resume store (P2 slice of the
// MVP): `podcast_subs.json` + `episode_progress.json` next to the other
// app stores, atomic .tmp+rename writes, silent fallbacks throughout.
// Reuses library.dart's atomicWrite/readText/backupCorrupt (read-only).

import 'dart:convert';
import 'dart:io';

import '../app/library.dart'
    show atomicWrite, backupCorrupt, readText;
import 'models.dart';

const String podcastSubsFile = 'podcast_subs.json';
const String episodeProgressFile = 'episode_progress.json';

/// Max subscribed shows (parity with playlist caps; FIFO prune beyond).
const int podcastSubsCap = 500;

/// Max per-episode bookmarks (LRU-ish: oldest insertion entries pruned).
const int episodeProgressCap = 2000;

/// Fresh-start window: bookmarks below this are dropped on read.
const int resumeFreshMs = 10000;

Map<String, PodcastShow> podcastSubsFromJson(String raw,
    {int cap = podcastSubsCap}) {
  final out = <String, PodcastShow>{};
  try {
    if (raw.trim().isEmpty) return out;
    final root = jsonDecode(raw);
    if (root is! Map) return out;
    for (final e in root.entries) {
      try {
        if (out.length >= cap) break;
        if (e.value is! Map) continue;
        final s = PodcastShow.fromJson(
            (e.value as Map).cast<String, dynamic>());
        final key = e.key.toString();
        if (key.isEmpty || s.id.isEmpty) continue;
        out[key] = s;
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

String podcastSubsToJson(Map<String, PodcastShow> subs,
        {int cap = podcastSubsCap}) =>
    jsonEncode({
      for (final e in subs.entries.take(cap))
        if (e.key.isNotEmpty)
          e.key: e.value.toJson(),
    });

Map<String, int> episodeProgressFromJson(String raw,
    {int cap = episodeProgressCap}) {
  final out = <String, int>{};
  try {
    if (raw.trim().isEmpty) return out;
    final root = jsonDecode(raw);
    if (root is! Map) return out;
    for (final e in root.entries) {
      try {
        if (out.length >= cap) break;
        final key = e.key.toString();
        if (key.isEmpty) continue;
        final v = e.value;
        final ms = v is int
            ? v
            : v is double
                ? v.round()
                : int.tryParse(v.toString()) ?? 0;
        if (ms < resumeFreshMs) continue;
        out[key] = ms;
      } catch (_) {}
    }
  } catch (_) {}
  return out;
}

String episodeProgressToJson(Map<String, int> progress,
        {int cap = episodeProgressCap}) =>
    jsonEncode({
      for (final e in progress.entries.take(cap))
        if (e.key.isNotEmpty && e.value >= resumeFreshMs) e.key: e.value,
    });

/// File-backed subscriptions + resume store. All methods never throw.
class PodcastStore {
  final Directory appDir;
  final Map<String, PodcastShow> subs = {};
  final Map<String, int> progress = {};

  PodcastStore(this.appDir);

  File get _subsFile => File('${appDir.path}/$podcastSubsFile');
  File get _progressFile =>
      File('${appDir.path}/$episodeProgressFile');

  Future<void> load() async {
    try {
      final rawSubs = await readText(_subsFile);
      subs
        ..clear()
        ..addAll(podcastSubsFromJson(rawSubs));
      try {
        final t = rawSubs.trim();
        if (subs.isEmpty && t.length > 2 && t != '{}' && t != '[]') {
          await backupCorrupt(_subsFile, rawSubs);
        }
      } catch (_) {}
      final rawProgress = await readText(_progressFile);
      progress
        ..clear()
        ..addAll(episodeProgressFromJson(rawProgress));
      try {
        final t = rawProgress.trim();
        if (progress.isEmpty && t.length > 2 && t != '{}' && t != '[]') {
          await backupCorrupt(_progressFile, rawProgress);
        }
      } catch (_) {}
    } catch (_) {}
  }

  bool isSubscribed(String showId) {
    try {
      return showId.isNotEmpty && subs.containsKey(showId);
    } catch (_) {
      return false;
    }
  }

  List<PodcastShow> subsList() {
    try {
      final list = subs.values.toList()
        ..sort((a, b) => b.subscribedAtMs.compareTo(a.subscribedAtMs));
      return list;
    } catch (_) {
      return [];
    }
  }

  Future<void> subscribe(PodcastShow show) async {
    try {
      if (show.id.isEmpty) return;
      subs[show.id] = show.subscribedAtMs > 0
          ? show
          : PodcastShow(
              id: show.id,
              title: show.title,
              author: show.author,
              thumbUrl: show.thumbUrl,
              description: show.description,
              subscribedAtMs:
                  DateTime.now().millisecondsSinceEpoch,
            );
      while (subs.length > podcastSubsCap) {
        try {
          subs.remove(subs.keys.first);
        } catch (_) {
          break;
        }
      }
      await atomicWrite(_subsFile, podcastSubsToJson(subs));
    } catch (_) {}
  }

  Future<void> unsubscribe(String showId) async {
    try {
      if (subs.remove(showId) != null) {
        await atomicWrite(_subsFile, podcastSubsToJson(subs));
      }
    } catch (_) {}
  }

  int progressFor(String episodeId) {
    try {
      if (episodeId.isEmpty) return 0;
      return progress[episodeId] ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<void> saveProgress(String episodeId, int positionMs) async {
    try {
      if (episodeId.isEmpty) return;
      if (positionMs < resumeFreshMs) {
        if (progress.remove(episodeId) != null) {
          await atomicWrite(
              _progressFile, episodeProgressToJson(progress));
        }
        return;
      }
      progress[episodeId] = positionMs;
      while (progress.length > episodeProgressCap) {
        try {
          progress.remove(progress.keys.first);
        } catch (_) {
          break;
        }
      }
      await atomicWrite(
          _progressFile, episodeProgressToJson(progress));
    } catch (_) {}
  }

  Future<void> clearProgress(String episodeId) async {
    try {
      if (progress.remove(episodeId) != null) {
        await atomicWrite(
            _progressFile, episodeProgressToJson(progress));
      }
    } catch (_) {}
  }
}
